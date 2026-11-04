"""Fixture checks for Devin Local hook ingestion and installation."""

from __future__ import annotations

import io
import json
from datetime import datetime, timezone
from pathlib import Path
import runpy
import shlex
import stat
import subprocess
import sys
import tempfile
from unittest.mock import patch


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ADAPTERS = PROJECT_ROOT / "adapters"
ADAPTER_SCRIPT = ADAPTERS / "devin_local.py"
MANAGER_SCRIPT = ADAPTERS / "manage_devin_local.py"
ADAPTER = runpy.run_path(str(ADAPTER_SCRIPT))
MANAGER = runpy.run_path(str(MANAGER_SCRIPT))
FIXED_TIME = datetime(2026, 11, 4, 1, 23, 45, 678901, tzinfo=timezone.utc)


def run_script(script: Path, *arguments: str, input_text: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(script), *arguments],
        input=input_text,
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )


def payload(event_name: str, *, session: str = "session-001", turn: str = "prompt-001") -> dict[str, object]:
    return {
        "hook_event_name": event_name,
        "session_id": session,
        "prompt_id": turn,
    }


def event_directory(home: Path) -> Path:
    return home / "Library" / "Application Support" / "Agent Watch" / "events"


def all_events(home: Path) -> list[dict[str, object]]:
    directory = event_directory(home)
    if not directory.exists():
        return []
    return [json.loads(path.read_text(encoding="utf-8")) for path in sorted(directory.glob("*.json"))]


def check_metadata_projection() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin Local data ") as temporary_root:
        home = Path(temporary_root) / "家庭 空间"
        prompt = payload("UserPromptSubmit")
        prompt["prompt"] = "PRIVATE PROMPT MUST NOT BE SAVED"
        prompt["tool_input"] = {"token": "PRIVATE CREDENTIAL MUST NOT BE SAVED"}
        prompt["workspace"] = "/private/user/workspace"

        class NoContentRead(dict[str, object]):
            def get(self, key: str, default: object = None) -> object:
                if key in {"prompt", "tool_input", "tool_response", "workspace", "transcript_path"}:
                    raise AssertionError(f"unexpected read of {key}")
                return super().get(key, default)

        projected = ADAPTER["event_for"](NoContentRead(prompt), FIXED_TIME)
        assert projected is not None
        assert projected["appID"] == "devin"
        assert projected["sessionID"] == "session-001"
        assert projected["turnID"] == "prompt-001"
        assert projected["state"] == "running"
        assert projected["evidence"] == "explicit"
        assert projected["source"] == "devin_local:UserPromptSubmit"
        assert len(projected["id"]) == 64
        assert projected["observedAt"] == "2026-11-04T01:23:45.678901Z"

        decoded_fields: list[str] = []
        reader_type = ADAPTER["MetadataJSONReader"]
        original_parse = reader_type.parse_selected_value

        def record_decoded_field(reader: object, key: str, start: int, end: int) -> object:
            decoded_fields.append(key)
            return original_parse(reader, key, start, end)

        raw_payload = json.dumps(prompt, ensure_ascii=False).encode("utf-8")
        with patch.object(reader_type, "parse_selected_value", record_decoded_field):
            selected = ADAPTER["read_hook_payload"](io.StringIO(raw_payload.decode("utf-8")))
        assert selected == {
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-001",
            "prompt_id": "prompt-001",
        }
        assert decoded_fields == ["hook_event_name", "session_id", "prompt_id"]

        assert ADAPTER["process_payload"](prompt, home, FIXED_TIME) == projected
        assert ADAPTER["process_payload"](prompt, home, FIXED_TIME) == projected
        waiting = ADAPTER["process_payload"](
            payload("PermissionRequest"), home, FIXED_TIME.replace(microsecond=679001)
        )
        assert waiting is not None and waiting["state"] == "waitingApproval"
        running_before_tool = ADAPTER["process_payload"](
            payload("PreToolUse"), home, FIXED_TIME.replace(microsecond=679051)
        )
        running_after_tool = ADAPTER["process_payload"](
            payload("PostToolUse"), home, FIXED_TIME.replace(microsecond=679076)
        )
        ended = ADAPTER["process_payload"](
            payload("Stop"), home, FIXED_TIME.replace(microsecond=679101)
        )
        assert ended is not None and ended["state"] == "responseEnded"
        assert running_before_tool is not None and running_before_tool["state"] == "running"
        assert running_after_tool is not None and running_after_tool["state"] == "running"
        assert len(all_events(home)) == 5

        persisted = "\n".join(path.read_text(encoding="utf-8") for path in event_directory(home).glob("*.json"))
        for forbidden in (
            "PRIVATE PROMPT MUST NOT BE SAVED",
            "PRIVATE CREDENTIAL MUST NOT BE SAVED",
            "/private/user/workspace",
            '"tool_input"',
            '"prompt"',
        ):
            assert forbidden not in persisted

        root = home / "Library" / "Application Support" / "Agent Watch"
        assert stat.S_IMODE(root.stat().st_mode) == 0o700
        assert stat.S_IMODE(event_directory(home).stat().st_mode) == 0o700
        assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in event_directory(home).glob("*.json"))


def check_event_contract_boundaries_and_silent_failure() -> None:
    event_for = ADAPTER["event_for"]
    assert event_for(payload("SessionStart"), FIXED_TIME) is None
    assert event_for(payload("SessionEnd"), FIXED_TIME) is None
    assert event_for(payload("PreToolUse"), FIXED_TIME)["state"] == "running"
    assert event_for(payload("PostToolUse"), FIXED_TIME)["state"] == "running"
    assert event_for(payload("UserPromptSubmit", session="", turn="prompt-001"), FIXED_TIME) is None
    assert event_for(payload("UserPromptSubmit", session="session-001", turn=""), FIXED_TIME) is None
    assert event_for(payload("UserPromptSubmit", session="x" * 257), FIXED_TIME) is None
    assert event_for(payload("UserPromptSubmit", session="bad\u2028id"), FIXED_TIME) is None

    missing_turn = payload("Stop")
    missing_turn.pop("prompt_id")
    assert event_for(missing_turn, FIXED_TIME) is None

    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin Local silent ") as temporary_root:
        home = Path(temporary_root)
        marker = ADAPTER["OWNERSHIP_MARKER"]

        invalid = run_script(
            ADAPTER_SCRIPT,
            marker,
            "--home",
            str(home),
            input_text="not JSON",
        )
        assert invalid.returncode == 0 and invalid.stdout == "" and invalid.stderr == ""

        unknown = run_script(
            ADAPTER_SCRIPT,
            marker,
            "--home",
            str(home),
            input_text=json.dumps(payload("SessionStart")),
        )
        assert unknown.returncode == 0 and unknown.stdout == "" and unknown.stderr == ""
        assert not (home / "Library" / "Application Support" / "Agent Watch").exists()

        captured = run_script(
            ADAPTER_SCRIPT,
            marker,
            "--home",
            str(home),
            input_text=json.dumps(payload("UserPromptSubmit")),
        )
        assert captured.returncode == 0 and captured.stdout == "" and captured.stderr == ""
        assert len(all_events(home)) == 1

        oversized = "x" * (ADAPTER["MAX_INPUT_BYTES"] + 1)
        too_large = run_script(
            ADAPTER_SCRIPT,
            marker,
            "--home",
            str(home),
            input_text=oversized,
        )
        assert too_large.returncode == 0 and too_large.stdout == "" and too_large.stderr == ""

        class ReadOnceOversized:
            def __init__(self) -> None:
                self.calls = 0

            def read(self, limit: int) -> str:
                self.calls += 1
                assert limit == ADAPTER["MAX_INPUT_BYTES"] + 1
                return "x" * limit

        oversized_stream = ReadOnceOversized()
        try:
            ADAPTER["read_hook_payload"](oversized_stream)
            raise AssertionError("oversized hook input must be rejected")
        except ValueError:
            pass
        assert oversized_stream.calls == 1, "oversized input must fail open without draining stdin"


def check_installer_dry_run_apply_idempotency_and_uninstall() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin Local config ") as temporary_root:
        home = Path(temporary_root) / "用户 主目录"
        config_path = MANAGER["config_path"](home)
        original = {
            "permission_mode": "normal",
            "privateSetting": "PRIVATE CONFIG VALUE MUST NOT BE PRINTED",
            "hooks": {
                "UserPromptSubmit": [
                    {"matcher": "", "hooks": [{"type": "command", "command": "user prompt hook"}]}
                ],
                "SessionStart": [
                    {"matcher": "", "hooks": [{"type": "command", "command": "user session hook"}]}
                ],
            },
        }
        config_path.parent.mkdir(parents=True)
        original_bytes = (json.dumps(original, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        config_path.write_bytes(original_bytes)

        dry_run = run_script(MANAGER_SCRIPT, "--home", str(home))
        assert dry_run.returncode == 0
        assert "Dry run:" in dry_run.stdout and "No files were changed" in dry_run.stdout
        assert config_path.read_bytes() == original_bytes
        assert not MANAGER["bridge_script_path"](home).exists()
        assert not list(config_path.parent.glob("*.agent-watch-backup-*"))
        assert "PRIVATE CONFIG VALUE MUST NOT BE PRINTED" not in dry_run.stdout + dry_run.stderr

        applied = run_script(MANAGER_SCRIPT, "--home", str(home), "--apply")
        assert applied.returncode == 0 and "Applied:" in applied.stdout
        bridge_path = MANAGER["bridge_script_path"](home)
        assert bridge_path.read_bytes() == ADAPTER_SCRIPT.read_bytes()
        assert stat.S_IMODE(bridge_path.stat().st_mode) == 0o600
        assert stat.S_IMODE(bridge_path.parent.stat().st_mode) == 0o700
        assert stat.S_IMODE(MANAGER["bridge_root"](home).stat().st_mode) == 0o700

        backups = list(config_path.parent.glob("*.agent-watch-backup-*"))
        assert len(backups) == 1 and backups[0].read_bytes() == original_bytes
        installed = json.loads(config_path.read_text(encoding="utf-8"))
        assert installed["permission_mode"] == "normal"
        assert installed["hooks"]["SessionStart"] == original["hooks"]["SessionStart"]
        assert installed["hooks"]["UserPromptSubmit"][0]["hooks"][0] == original["hooks"]["UserPromptSubmit"][0]["hooks"][0]

        for event_name in MANAGER["HOOK_EVENTS"]:
            matching_groups = [
                group
                for group in installed["hooks"][event_name]
                if group.get("matcher", "") == ""
            ]
            owned = [
                hook
                for group in matching_groups
                for hook in group["hooks"]
                if MANAGER["handler_is_owned"](hook)
            ]
            assert len(owned) == 1
            assert owned[0]["type"] == "command"
            assert owned[0]["timeout"] == MANAGER["HOOK_TIMEOUT_SECONDS"]
            command_parts = shlex.split(owned[0]["command"])
            assert command_parts[0] == str(Path(sys.executable).resolve())
            assert command_parts[1] == str(bridge_path)
            assert command_parts[2] == MANAGER["OWNERSHIP_MARKER"]

        installed_once = json.loads(config_path.read_text(encoding="utf-8"))
        repeated_apply = run_script(MANAGER_SCRIPT, "--home", str(home), "--apply")
        assert repeated_apply.returncode == 0
        installed_twice = json.loads(config_path.read_text(encoding="utf-8"))
        assert installed_twice == installed_once
        assert len(list(config_path.parent.glob("*.agent-watch-backup-*"))) == 1

        dry_uninstall = run_script(MANAGER_SCRIPT, "--home", str(home), "--uninstall")
        assert dry_uninstall.returncode == 0 and "No files were changed" in dry_uninstall.stdout
        assert json.loads(config_path.read_text(encoding="utf-8")) == installed_once

        uninstalled = run_script(MANAGER_SCRIPT, "--home", str(home), "--uninstall", "--apply")
        assert uninstalled.returncode == 0
        restored_shape = json.loads(config_path.read_text(encoding="utf-8"))
        assert restored_shape == original
        assert bridge_path.exists()


def check_jsonc_refusal_is_read_only() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin Local jsonc ") as temporary_root:
        home = Path(temporary_root)
        path = MANAGER["config_path"](home)
        path.parent.mkdir(parents=True)
        original = b'{\n  // keep user comments\n  "hooks": {}\n}\n'
        path.write_bytes(original)

        result = run_script(MANAGER_SCRIPT, "--home", str(home), "--apply")
        assert result.returncode == 2
        assert path.read_bytes() == original
        assert not MANAGER["bridge_script_path"](home).exists()
        assert not list(path.parent.glob("*.agent-watch-backup-*"))


def check_non_json_constants_are_refused() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin Local constants ") as temporary_root:
        home = Path(temporary_root)
        path = MANAGER["config_path"](home)
        path.parent.mkdir(parents=True)
        for constant in ("NaN", "Infinity", "-Infinity"):
            original = f'{{"setting": {constant}}}\n'.encode("utf-8")
            path.write_bytes(original)
            result = run_script(MANAGER_SCRIPT, "--home", str(home), "--apply")
            assert result.returncode == 2
            assert path.read_bytes() == original
            assert not MANAGER["bridge_script_path"](home).exists()
            assert not list(path.parent.glob("*.agent-watch-backup-*"))


def check_unowned_bridge_is_never_overwritten() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin Local bridge ") as temporary_root:
        home = Path(temporary_root)
        bridge_path = MANAGER["bridge_script_path"](home)
        bridge_path.parent.mkdir(parents=True, mode=0o700)
        original = b"user-owned bridge contents\n"
        bridge_path.write_bytes(original)
        bridge_path.chmod(0o600)

        dry_run = run_script(MANAGER_SCRIPT, "--home", str(home))
        assert dry_run.returncode == 2
        assert bridge_path.read_bytes() == original
        assert not MANAGER["config_path"](home).exists()

        applied = run_script(MANAGER_SCRIPT, "--home", str(home), "--apply")
        assert applied.returncode == 2
        assert bridge_path.read_bytes() == original
        assert not MANAGER["config_path"](home).exists()
        assert not list(bridge_path.parent.glob(".agent-watch-bridge-*"))


def check_owned_bridge_can_be_updated() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin Local owned bridge ") as temporary_root:
        home = Path(temporary_root)
        bridge_path = MANAGER["bridge_script_path"](home)
        bridge_path.parent.mkdir(parents=True, mode=0o700)
        bridge_path.write_bytes(b"#!/usr/bin/env python3\n# agent-watch-bridge-owner: devin-local-v1\nold bridge\n")
        bridge_path.chmod(0o600)

        applied = run_script(MANAGER_SCRIPT, "--home", str(home), "--apply")
        assert applied.returncode == 0 and "Applied:" in applied.stdout
        assert bridge_path.read_bytes() == ADAPTER_SCRIPT.read_bytes()


def main() -> None:
    check_metadata_projection()
    check_event_contract_boundaries_and_silent_failure()
    check_installer_dry_run_apply_idempotency_and_uninstall()
    check_jsonc_refusal_is_read_only()
    check_non_json_constants_are_refused()
    check_unowned_bridge_is_never_overwritten()
    check_owned_bridge_can_be_updated()
    print("Devin Local hook adapter checks passed.")


if __name__ == "__main__":
    main()
