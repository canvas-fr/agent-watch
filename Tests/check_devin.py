"""Fixture checks for legacy Devin Desktop Cascade hook ingestion/install."""

from __future__ import annotations

import io
import json
from pathlib import Path
import runpy
import shlex
import stat
import subprocess
import sys
import tempfile


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ADAPTERS = PROJECT_ROOT / "adapters"
ADAPTER_SCRIPT = ADAPTERS / "devin.py"
MANAGER_SCRIPT = ADAPTERS / "manage_devin.py"
ADAPTER = runpy.run_path(str(ADAPTER_SCRIPT))
MANAGER = runpy.run_path(str(MANAGER_SCRIPT))


def run_script(script: Path, *arguments: str, input_text: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(script), *arguments],
        input=input_text,
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )


def payload(action: str, *, session: str = "trajectory-001", turn: str = "execution-001") -> dict[str, object]:
    return {
        "agent_action_name": action,
        "trajectory_id": session,
        "execution_id": turn,
        "timestamp": "2026-11-03T01:23:45.678Z",
    }


def event_directory(home: Path) -> Path:
    return home / "Library" / "Application Support" / "Agent Watch" / "events"


def all_events(home: Path) -> list[dict[str, object]]:
    directory = event_directory(home)
    if not directory.exists():
        return []
    return [json.loads(path.read_text(encoding="utf-8")) for path in sorted(directory.glob("*.json"))]


def check_metadata_projection() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin data ") as temporary_root:
        home = Path(temporary_root) / "家庭 空间"
        running = payload("pre_user_prompt")
        running["tool_info"] = {
            "user_prompt": "PRIVATE PROMPT MUST NOT BE SAVED",
            "response": "PRIVATE RESPONSE MUST NOT BE SAVED",
            "transcript_path": "/private/user/transcript.jsonl",
        }
        # Make sure the projection does not even inspect the content container.
        class NoContentRead(dict[str, object]):
            def get(self, key: str, default: object = None) -> object:
                if key in {"tool_info", "prompt", "response", "transcript_path"}:
                    raise AssertionError(f"unexpected read of {key}")
                return super().get(key, default)

        projected = ADAPTER["event_for"](NoContentRead(running))
        assert projected is not None
        assert projected["appID"] == "devin"
        assert projected["sessionID"] == "trajectory-001"
        assert projected["turnID"] == "execution-001"
        assert projected["state"] == "running"
        assert projected["sequence"] == 1
        assert projected["source"] == "devin:pre_user_prompt"
        assert len(projected["id"]) == 64
        assert projected["observedAt"] == "2026-11-03T01:23:45.678Z"

        assert ADAPTER["process_payload"](running, home) == projected
        repeated = ADAPTER["process_payload"](running, home)
        assert repeated == projected
        assert len(all_events(home)) == 1, "replayed lifecycle hook should have a stable event ID"

        response_observed = payload("post_cascade_response")
        response_observed["tool_info"] = {
            "response": "PRIVATE CASCADE RESPONSE MUST NOT BE SAVED",
            "command": "private command text",
        }
        result = ADAPTER["process_payload"](response_observed, home)
        assert result is not None
        assert result["state"] == "unknown"
        assert result["evidence"] == "explicit"
        assert result["source"] == "devin:post_cascade_response:awaiting_confirmation"
        assert result["turnID"] == projected["turnID"], "execution_id must correlate both lifecycle events"
        assert result["sequence"] == 2
        assert len(all_events(home)) == 2

        terminal_text = "\n".join(
            path.read_text(encoding="utf-8") for path in event_directory(home).glob("*.json")
        )
        for forbidden in (
            "PRIVATE PROMPT MUST NOT BE SAVED",
            "PRIVATE RESPONSE MUST NOT BE SAVED",
            "PRIVATE CASCADE RESPONSE MUST NOT BE SAVED",
            "transcript_path",
            "private command text",
            "tool_info",
        ):
            assert forbidden not in terminal_text
        assert not (home / "Library" / "Application Support" / "Agent Watch" / "metadata").exists()

        root = home / "Library" / "Application Support" / "Agent Watch"
        assert stat.S_IMODE(root.stat().st_mode) == 0o700
        assert stat.S_IMODE(event_directory(home).stat().st_mode) == 0o700
        assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in event_directory(home).glob("*.json"))


def check_event_contract_boundaries() -> None:
    event_for = ADAPTER["event_for"]
    assert event_for(payload("post_user_prompt")) is None
    assert event_for(payload("post_cascade_response_with_transcript")) is None
    response_observed = event_for(payload("post_cascade_response"))
    assert response_observed is not None
    assert response_observed["state"] == "unknown"
    assert response_observed["evidence"] == "explicit"
    assert response_observed["source"] == "devin:post_cascade_response:awaiting_confirmation"
    assert event_for({"hook_event_name": "UserPromptSubmit", "session_id": "cli-session", "prompt_id": "cli-turn"}) is None
    assert event_for(payload("pre_user_prompt", session="", turn="execution-001")) is None
    assert event_for(payload("pre_user_prompt", session="trajectory-001", turn="")) is None

    missing_timestamp = payload("pre_user_prompt")
    missing_timestamp.pop("timestamp")
    assert event_for(missing_timestamp) is None
    naive_timestamp = payload("pre_user_prompt")
    naive_timestamp["timestamp"] = "2026-11-03T01:23:45"
    assert event_for(naive_timestamp) is None
    long_identifier = payload("pre_user_prompt", session="x" * 257)
    assert event_for(long_identifier) is None

    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin data ") as temporary_root:
        home = Path(temporary_root)
        input_text = json.dumps(payload("post_user_prompt"), ensure_ascii=False)
        result = ADAPTER["main"](
            ["--agent-watch-managed-v1", "--home", str(home)],
            io.StringIO(input_text),
        )
        assert result == 0
        assert all_events(home) == []

        command_result = run_script(
            ADAPTER_SCRIPT,
            "--agent-watch-managed-v1",
            "--home",
            str(home),
            input_text=json.dumps(payload("pre_user_prompt", turn="cli-turn"), ensure_ascii=False),
        )
        assert command_result.returncode == 0 and command_result.stdout == "" and command_result.stderr == ""
        assert len(all_events(home)) == 1

        too_large = "x" * (ADAPTER["MAX_INPUT_BYTES"] + 1)
        result = ADAPTER["main"](
            ["--agent-watch-managed-v1", "--home", str(home)],
            io.StringIO(too_large),
        )
        assert result == 0
        assert len(all_events(home)) == 1


def check_manager_dry_run_apply_idempotency_and_uninstall() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin config ") as temporary_root:
        home = Path(temporary_root) / "用户 主目录"
        config_path = MANAGER["config_path"](home)
        original = {
            "otherSetting": {"preserve": True},
            "privateSetting": "PRIVATE CONFIG VALUE MUST NOT BE PRINTED",
            "hooks": {
                "pre_user_prompt": [{"command": "user prompt observer", "show_output": True}],
                "post_setup_worktree": [{"command": "user worktree observer"}],
            },
        }
        config_path.parent.mkdir(parents=True)
        original_bytes = (json.dumps(original, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        config_path.write_bytes(original_bytes)

        dry_run = run_script(MANAGER_SCRIPT, "--home", str(home))
        assert dry_run.returncode == 0 and "Dry run:" in dry_run.stdout and "No files were changed" in dry_run.stdout
        assert config_path.read_bytes() == original_bytes
        assert not MANAGER["bridge_script_path"](home).exists()
        assert not list(config_path.parent.glob("*.agent-watch-backup-*"))
        assert "PRIVATE CONFIG VALUE MUST NOT BE PRINTED" not in dry_run.stdout + dry_run.stderr

        applied = run_script(MANAGER_SCRIPT, "--home", str(home), "--apply")
        assert applied.returncode == 0 and "Applied:" in applied.stdout
        assert "Backup: ~/" in applied.stdout
        bridge_path = MANAGER["bridge_script_path"](home)
        assert bridge_path.read_bytes() == ADAPTER_SCRIPT.read_bytes()
        assert stat.S_IMODE(bridge_path.stat().st_mode) == 0o600
        assert stat.S_IMODE(bridge_path.parent.stat().st_mode) == 0o700
        assert stat.S_IMODE(MANAGER["bridge_root"](home).stat().st_mode) == 0o700

        stable_event = payload("pre_user_prompt", session="stable-copy-session", turn="stable-copy-turn")
        stable_run = run_script(
            bridge_path,
            "--agent-watch-managed-v1",
            "--home",
            str(home),
            input_text=json.dumps(stable_event, ensure_ascii=False),
        )
        assert stable_run.returncode == 0 and stable_run.stdout == "" and stable_run.stderr == ""
        assert any(event["sessionID"] == "stable-copy-session" for event in all_events(home))

        backups = list(config_path.parent.glob("*.agent-watch-backup-*"))
        assert len(backups) == 1 and backups[0].read_bytes() == original_bytes
        installed = json.loads(config_path.read_text(encoding="utf-8"))
        assert installed["otherSetting"] == original["otherSetting"]
        assert installed["hooks"]["post_setup_worktree"] == original["hooks"]["post_setup_worktree"]
        prompt_handlers = installed["hooks"]["pre_user_prompt"]
        response_handlers = installed["hooks"]["post_cascade_response"]
        assert len(prompt_handlers) == 2
        assert prompt_handlers[0] == original["hooks"]["pre_user_prompt"][0]
        assert len(response_handlers) == 1
        for handler in (prompt_handlers[1], response_handlers[0]):
            assert handler["show_output"] is False
            command_parts = shlex.split(handler["command"])
            assert command_parts[0] == str(Path(sys.executable).resolve())
            assert command_parts[1] == str(bridge_path)
            assert command_parts[2] == MANAGER["OWNERSHIP_MARKER"]

        repeated_apply = run_script(MANAGER_SCRIPT, "--home", str(home), "--apply")
        assert repeated_apply.returncode == 0
        installed_again = json.loads(config_path.read_text(encoding="utf-8"))
        assert installed_again == installed
        assert len(list(config_path.parent.glob("*.agent-watch-backup-*"))) == 1

        dry_uninstall = run_script(MANAGER_SCRIPT, "--home", str(home), "--uninstall")
        assert dry_uninstall.returncode == 0 and "No files were changed" in dry_uninstall.stdout
        assert json.loads(config_path.read_text(encoding="utf-8")) == installed

        uninstalled = run_script(MANAGER_SCRIPT, "--home", str(home), "--uninstall", "--apply")
        assert uninstalled.returncode == 0
        restored_shape = json.loads(config_path.read_text(encoding="utf-8"))
        assert restored_shape == original
        assert bridge_path.exists(), "uninstall removes only hook entries, not the installed bridge copy"


def check_missing_config_and_stale_marker_cleanup() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin stale ") as temporary_root:
        home = Path(temporary_root)
        config_path = MANAGER["config_path"](home)
        managed_command = (
            f"{shlex.quote(str(Path(sys.executable).resolve()))} "
            f"{shlex.quote(str(MANAGER['bridge_script_path'](home)))} {MANAGER['OWNERSHIP_MARKER']} old"
        )
        config_path.parent.mkdir(parents=True)
        config_path.write_text(
            json.dumps(
                {
                    "keep": 7,
                    "hooks": {
                        "pre_user_prompt": [
                            {"command": managed_command},
                            {"command": "user pre hook"},
                        ],
                        "obsolete_event": [{"command": managed_command}],
                    },
                }
            ),
            encoding="utf-8",
        )

        apply_result = run_script(MANAGER_SCRIPT, "--home", str(home), "--apply")
        assert apply_result.returncode == 0
        installed = json.loads(config_path.read_text(encoding="utf-8"))
        assert installed["keep"] == 7
        assert "obsolete_event" not in installed["hooks"] or installed["hooks"]["obsolete_event"] == []
        assert len(installed["hooks"]["pre_user_prompt"]) == 2
        assert installed["hooks"]["pre_user_prompt"][0]["command"].endswith(MANAGER["OWNERSHIP_MARKER"])
        assert installed["hooks"]["pre_user_prompt"][1] == {"command": "user pre hook"}

        with tempfile.TemporaryDirectory(prefix="Agent Watch Devin new ") as missing_home_root:
            missing_home = Path(missing_home_root)
            applied = run_script(MANAGER_SCRIPT, "--home", str(missing_home), "--apply")
            assert applied.returncode == 0
            missing_config = MANAGER["config_path"](missing_home)
            assert missing_config.exists()
            assert stat.S_IMODE(missing_config.stat().st_mode) == 0o600
            remove_result = run_script(MANAGER_SCRIPT, "--home", str(missing_home), "--uninstall", "--apply")
            assert remove_result.returncode == 0
            assert json.loads(missing_config.read_text(encoding="utf-8")) == {}


def check_config_safety() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin unsafe ") as temporary_root:
        home = Path(temporary_root)
        config_path = MANAGER["config_path"](home)
        config_path.parent.mkdir(parents=True)
        config_path.write_text('{"hooks": {}, "hooks": {}}', encoding="utf-8")
        duplicate_key = run_script(MANAGER_SCRIPT, "--home", str(home))
        assert duplicate_key.returncode == 2
        assert "hooks" not in duplicate_key.stdout and "hooks" not in duplicate_key.stderr

    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin symlink ") as temporary_root:
        home = Path(temporary_root)
        external = home / "outside.json"
        external.write_text("{}", encoding="utf-8")
        path = MANAGER["config_path"](home)
        path.parent.mkdir(parents=True)
        path.symlink_to(external)
        refused = run_script(MANAGER_SCRIPT, "--home", str(home), "--apply")
        assert refused.returncode == 2
        assert external.read_text(encoding="utf-8") == "{}"

    with tempfile.TemporaryDirectory(prefix="Agent Watch Devin parent symlink ") as temporary_root:
        home = Path(temporary_root) / "home"
        outside_directory = Path(temporary_root) / "outside"
        outside_directory.mkdir()
        (outside_directory / "hooks.json").write_text("{}", encoding="utf-8")
        codeium_directory = home / ".codeium"
        codeium_directory.mkdir(parents=True)
        (codeium_directory / "windsurf").symlink_to(outside_directory, target_is_directory=True)
        refused = run_script(MANAGER_SCRIPT, "--home", str(home), "--apply")
        assert refused.returncode == 2
        assert (outside_directory / "hooks.json").read_text(encoding="utf-8") == "{}"


def main() -> None:
    check_metadata_projection()
    check_event_contract_boundaries()
    check_manager_dry_run_apply_idempotency_and_uninstall()
    check_missing_config_and_stale_marker_cleanup()
    check_config_safety()
    print("Devin legacy Cascade adapter checks passed.")


if __name__ == "__main__":
    main()
