"""Fixtures for the Antigravity desktop hook bridge and installer."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import time


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ADAPTER = PROJECT_ROOT / "adapters" / "antigravity.py"
MANAGER = PROJECT_ROOT / "adapters" / "manage_antigravity.py"
PRIVATE_SECRET = "ANTIGRAVITY PRIVATE PAYLOAD MUST NOT BE SAVED"


def run_adapter(
    home: Path,
    event_name: str,
    payload: dict[str, object] | bytes,
    timeout: float = 3,
) -> subprocess.CompletedProcess[bytes]:
    raw = payload if isinstance(payload, bytes) else json.dumps(payload).encode("utf-8")
    return subprocess.run(
        [
            sys.executable,
            str(ADAPTER),
            "--event",
            event_name,
            "--home",
            str(home),
            "--agent-watch-owner",
            "antigravity-v1:test",
        ],
        input=raw,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


def run_manager(home: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(MANAGER), "--home", str(home), *arguments],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )


def root_for(home: Path) -> Path:
    return home / "Library" / "Application Support" / "Agent Watch"


def read_events(home: Path) -> list[dict[str, object]]:
    directory = root_for(home) / "events"
    if not directory.exists():
        return []
    events = []
    for path in sorted(directory.glob("*.json")):
        text = path.read_text(encoding="utf-8")
        assert text.count("\n") == 1
        events.append(json.loads(text))
    return events


def events_for(home: Path, conversation_id: str) -> list[dict[str, object]]:
    return sorted(
        (event for event in read_events(home) if event.get("sessionID") == conversation_id),
        key=lambda event: int(event["sequence"]),
    )


def fixture_payload(event_name: str, conversation_id: str, **overrides: object) -> dict[str, object]:
    payload: dict[str, object] = {
        "prompt": PRIVATE_SECRET,
        "toolCall": {"name": "run_command", "args": {"CommandLine": PRIVATE_SECRET}},
        "workspacePaths": [PRIVATE_SECRET],
        "transcriptPath": PRIVATE_SECRET,
        "artifactDirectoryPath": PRIVATE_SECRET,
        "error": PRIVATE_SECRET,
        "conversationId": conversation_id,
    }
    if event_name == "PreInvocation":
        payload.update({"invocationNum": 0, "initialNumSteps": 2})
    else:
        payload.update({"executionNum": 1, "terminationReason": "model_stop", "fullyIdle": True})
    payload.update(overrides)
    return payload


def check_lifecycle_pairing_and_privacy() -> None:
    with tempfile.TemporaryDirectory(prefix="Antigravity private fixture ") as temporary:
        home = Path(temporary) / "Local Home"
        conversation_id = "ag-conversation-01"

        first = run_adapter(home, "PreInvocation", fixture_payload("PreInvocation", conversation_id))
        second = run_adapter(
            home,
            "PreInvocation",
            fixture_payload("PreInvocation", conversation_id, invocationNum=1, initialNumSteps=5),
        )
        stop = run_adapter(
            home,
            "Stop",
            fixture_payload("Stop", conversation_id, executionNum=9),
        )
        assert first.returncode == second.returncode == stop.returncode == 0
        assert first.stdout == second.stdout == b"{}\n"
        assert json.loads(stop.stdout) == {"decision": "allow"}

        events = events_for(home, conversation_id)
        assert [event["state"] for event in events] == ["running", "running", "responseEnded"]
        assert len({event["turnID"] for event in events}) == 1
        assert [event["sequence"] for event in events] == [1, 2, 3]
        assert events[-1]["source"] == "antigravity:Stop:model_stop"
        assert all(event["appID"] == "antigravity" for event in events)
        assert all(event["evidence"] == "explicit" for event in events)

        # A new invocation after a terminal Stop begins a new turn.
        run_adapter(
            home,
            "PreInvocation",
            fixture_payload("PreInvocation", conversation_id, invocationNum=2, initialNumSteps=0),
        )
        later = events_for(home, conversation_id)
        assert later[-1]["turnID"] != events[-1]["turnID"]
        assert [event["sequence"] for event in later] == [1, 2, 3, 4]

        all_saved = "\n".join(
            path.read_text(encoding="utf-8")
            for directory in (root_for(home) / "events", root_for(home) / "metadata")
            for path in directory.glob("*.json")
        )
        assert PRIVATE_SECRET not in all_saved
        for forbidden_key in ("prompt", "toolCall", "workspacePaths", "transcriptPath", "artifactDirectoryPath", "error"):
            assert f'"{forbidden_key}"' not in all_saved
        metadata_files = list((root_for(home) / "metadata").glob("*.antigravity.json"))
        assert len(metadata_files) == 1
        metadata = json.loads(metadata_files[0].read_text(encoding="utf-8"))
        assert set(metadata) == {"conversationId", "turnID", "sequence", "active"}
        assert stat.S_IMODE((root_for(home) / "events").stat().st_mode) == 0o700
        assert stat.S_IMODE(metadata_files[0].stat().st_mode) == 0o600


def check_stop_mappings_and_orphans() -> None:
    with tempfile.TemporaryDirectory(prefix="Antigravity stop fixture ") as temporary:
        home = Path(temporary)
        conversation_id = "ag-stop-fixture"
        run_adapter(home, "PreInvocation", fixture_payload("PreInvocation", conversation_id))
        turn_id = events_for(home, conversation_id)[-1]["turnID"]

        pending = run_adapter(
            home,
            "Stop",
            fixture_payload("Stop", conversation_id, terminationReason="model_stop", fullyIdle=False),
        )
        background = events_for(home, conversation_id)[-1]
        assert json.loads(pending.stdout) == {"decision": "allow"}
        assert background["state"] == "running"
        assert background["source"] == "antigravity:Stop:background_tasks"
        assert background["turnID"] == turn_id

        # A resumed invocation after unfinished background work remains in the same turn.
        run_adapter(
            home,
            "PreInvocation",
            fixture_payload("PreInvocation", conversation_id, invocationNum=2, initialNumSteps=4),
        )
        assert events_for(home, conversation_id)[-1]["turnID"] == turn_id

        run_adapter(
            home,
            "Stop",
            fixture_payload("Stop", conversation_id, executionNum=2, terminationReason="model_stop", fullyIdle=True),
        )
        assert events_for(home, conversation_id)[-1]["state"] == "responseEnded"
        assert events_for(home, conversation_id)[-1]["turnID"] == turn_id

        error_with_background = "ag-error-with-background"
        run_adapter(home, "PreInvocation", fixture_payload("PreInvocation", error_with_background))
        run_adapter(
            home,
            "Stop",
            fixture_payload(
                "Stop",
                error_with_background,
                terminationReason="error",
                fullyIdle=False,
            ),
        )
        background_error = events_for(home, error_with_background)[-1]
        assert background_error["state"] == "failed"
        assert background_error["source"] == "antigravity:Stop:error:background_pending"
        run_adapter(
            home,
            "PreInvocation",
            fixture_payload("PreInvocation", error_with_background, invocationNum=1, initialNumSteps=1),
        )
        assert events_for(home, error_with_background)[-1]["turnID"] != background_error["turnID"]

        max_steps_with_background = "ag-max-steps-with-background"
        run_adapter(home, "PreInvocation", fixture_payload("PreInvocation", max_steps_with_background))
        run_adapter(
            home,
            "Stop",
            fixture_payload(
                "Stop",
                max_steps_with_background,
                terminationReason="max_steps_exceeded",
                fullyIdle=False,
            ),
        )
        max_steps_event = events_for(home, max_steps_with_background)[-1]
        assert max_steps_event["state"] == "failed"
        assert max_steps_event["source"] == "antigravity:Stop:max_steps_exceeded:background_pending"

        for index, reason in enumerate(("error", "max_steps_exceeded"), start=1):
            current_id = f"ag-failed-{index}"
            run_adapter(home, "PreInvocation", fixture_payload("PreInvocation", current_id))
            run_adapter(
                home,
                "Stop",
                fixture_payload("Stop", current_id, terminationReason=reason),
            )
            event = events_for(home, current_id)[-1]
            assert event["state"] == "failed"
            assert event["source"] == f"antigravity:Stop:{reason}"

        # The public hook contract has no cancellation enum; even a plausible
        # cancellation string stays unknown until Google documents its meaning.
        for reason, fully_idle in (("cancelled", True), ("future_reason", False)):
            current_id = f"ag-unknown-{reason}"
            run_adapter(home, "PreInvocation", fixture_payload("PreInvocation", current_id))
            run_adapter(
                home,
                "Stop",
                fixture_payload("Stop", current_id, terminationReason=reason, fullyIdle=fully_idle),
            )
            event = events_for(home, current_id)[-1]
            assert event["state"] == "unknown"
            expected_source = "antigravity:Stop:unknown_termination"
            if not fully_idle:
                expected_source += ":background_pending"
            assert event["source"] == expected_source

        # Stop exposes executionNum but cannot create a turn without a preceding
        # PreInvocation record to pair with it.
        orphan_id = "ag-orphan-stop"
        result = run_adapter(home, "Stop", fixture_payload("Stop", orphan_id, executionNum=33))
        assert result.returncode == 0 and json.loads(result.stdout) == {"decision": "allow"}
        assert events_for(home, orphan_id) == []
        assert not list((root_for(home) / "metadata").glob("*orphan*"))


def check_current_app_and_question_lifecycle() -> None:
    with tempfile.TemporaryDirectory(prefix="Antigravity question fixture ") as temporary:
        home = Path(temporary)
        session = "question-test"
        tool = {"conversationId": session, "toolCall": {"name": "ask_question", "args": {"questions": [PRIVATE_SECRET]}}}
        # A tool callback without an active task must not create a session.
        run_adapter(home, "PreToolUse", tool)
        assert read_events(home) == []
        run_adapter(home, "PreInvocation", fixture_payload("PreInvocation", session))
        before = run_adapter(home, "PreToolUse", tool)
        after = run_adapter(home, "PostToolUse", tool)
        assert json.loads(before.stdout) == {"decision": "allow"}
        assert after.stdout == b"{}\n"
        run_adapter(home, "Stop", fixture_payload("Stop", session, terminationReason="NO_TOOL_CALL"))
        events = events_for(home, session)
        assert [event["state"] for event in events] == ["running", "waitingInput", "running", "responseEnded"]
        assert len({event["turnID"] for event in events}) == 1
        assert events[-1]["source"] == "antigravity:Stop:NO_TOOL_CALL"
        run_adapter(home, "PostToolUse", tool)
        assert len(events_for(home, session)) == 4, "late tool callbacks cannot revive a completed turn"
        for path in root_for(home).rglob("*.json"):
            assert PRIVATE_SECRET not in path.read_text()
        # Permission requests may be satisfied from a prior grant. Do not
        # announce waitingApproval simply because ask_permission was invoked.
        run_adapter(home, "PreInvocation", fixture_payload("PreInvocation", session))
        tool["toolCall"]["name"] = "ask_permission"
        run_adapter(home, "PreToolUse", tool)
        assert len(events_for(home, session)) == 5
        run_adapter(home, "PreToolUse", b'{"conversationId":"question-test","toolCall":{"name":"ask_question","name":"run_command"}}')
        assert len(events_for(home, session)) == 5
        # The same observed reason is not complete while background work remains.
        run_adapter(home, "Stop", fixture_payload("Stop", session, terminationReason="NO_TOOL_CALL", fullyIdle=False))
        assert events_for(home, session)[-1]["state"] == "running"
        for reason in ("ERROR", "MAX_INVOCATIONS", "MAX_FORCED_INVOCATIONS", "MAX_TOKEN_BUDGET_EXCEEDED", "USER_CANCELED"):
            session = "current-app-" + reason
            run_adapter(home, "PreInvocation", fixture_payload("PreInvocation", session))
            run_adapter(home, "Stop", fixture_payload("Stop", session, terminationReason=reason, fullyIdle=False))
            event = events_for(home, session)[-1]
            assert event["state"] == ("cancelled" if reason == "USER_CANCELED" else "failed")
            run_adapter(home, "PreInvocation", fixture_payload("PreInvocation", session))
            assert events_for(home, session)[-1]["turnID"] != event["turnID"]
        for reason in ("TERMINAL_STEP_TYPE", "TERMINAL_CUSTOM_HOOK", "INJECTED_RESPONSE", "HALTED_STEP"):
            session = "unclassified-" + reason
            run_adapter(home, "PreInvocation", fixture_payload("PreInvocation", session))
            run_adapter(home, "Stop", fixture_payload("Stop", session, terminationReason=reason))
            assert events_for(home, session)[-1]["state"] == "unknown"


def check_input_and_lock_bounds() -> None:
    with tempfile.TemporaryDirectory(prefix="Antigravity bounds fixture ") as temporary:
        home = Path(temporary)
        oversized = b'{"conversationId":"too-large","padding":"' + b"x" * (1024 * 1024) + b'"}'
        result = run_adapter(home, "Stop", oversized)
        assert result.returncode == 0 and json.loads(result.stdout) == {"decision": "allow"}
        assert read_events(home) == []

        conversation_id = "locked-conversation"
        metadata = root_for(home) / "metadata"
        metadata.mkdir(parents=True, mode=0o700)
        digest = hashlib.sha256(f"antigravity\0{conversation_id}".encode()).hexdigest()
        lock_path = metadata / f"{digest}.antigravity.lock"
        with lock_path.open("a+b") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            started = time.monotonic()
            result = run_adapter(
                home,
                "PreInvocation",
                fixture_payload("PreInvocation", conversation_id),
            )
            elapsed = time.monotonic() - started
            assert result.returncode == 0 and result.stdout == b"{}\n"
            assert elapsed < 1.0
            assert read_events(home) == []
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)

        # Bad JSON also fails open and does not persist partial metadata.
        result = run_adapter(home, "PreInvocation", b'{"conversationId":"bad",')
        assert result.returncode == 0 and result.stdout == b"{}\n"
        assert read_events(home) == []


def check_dry_run_apply_merge_and_uninstall() -> None:
    with tempfile.TemporaryDirectory(prefix="Antigravity config fixture ") as temporary:
        home = Path(temporary) / "Home With Spaces"
        config = home / ".gemini" / "config" / "hooks.json"
        config.parent.mkdir(parents=True)
        foreign_command = "python3 /tmp/not-antigravity.py --agent-watch-owner antigravity-v1:foreign"
        original = {
            "$schema": "https://antigravity.google/schemas/v1/hooks.json",
            "user-hook": {
                "enabled": True,
                "PreInvocation": [{"type": "command", "command": "echo user", "timeout": 3}],
                "Stop": [{"type": "command", "command": "echo keep", "timeout": 4}],
            },
            # A same-name user group is preserved; the installer chooses a free name.
            "agent-watch-antigravity": {
                "enabled": False,
                "PreInvocation": [{"type": "command", "command": foreign_command, "timeout": 9}],
            },
        }
        original_bytes = (json.dumps(original, ensure_ascii=False, indent=2) + "\n").encode()
        config.write_bytes(original_bytes)
        config.chmod(0o640)

        dry = run_manager(home)
        assert dry.returncode == 0, dry.stderr
        assert "Dry run:" in dry.stdout and "No files were changed" in dry.stdout
        assert config.read_bytes() == original_bytes
        assert not (root_for(home) / "bridge" / "antigravity.py").exists()

        applied = run_manager(home, "--apply")
        assert applied.returncode == 0, applied.stderr
        assert "Applied:" in applied.stdout
        assert config.stat().st_mode & 0o777 == 0o640
        backup_paths = list(config.parent.glob("hooks.json.agent-watch-backup-*"))
        assert len(backup_paths) == 1 and backup_paths[0].read_bytes() == original_bytes
        bridge = root_for(home) / "bridge" / "antigravity.py"
        assert bridge.read_bytes() == ADAPTER.read_bytes()
        assert stat.S_IMODE(bridge.stat().st_mode) == 0o600
        assert stat.S_IMODE(bridge.parent.stat().st_mode) == 0o700

        installed = json.loads(config.read_text(encoding="utf-8"))
        assert installed["$schema"] == original["$schema"]
        assert installed["user-hook"] == original["user-hook"]
        assert installed["agent-watch-antigravity"] == original["agent-watch-antigravity"]
        managed = installed["agent-watch-antigravity-2"]
        assert managed["enabled"] is True
        assert set(managed) == {"enabled", "PreInvocation", "Stop", "PreToolUse", "PostToolUse"}
        assert len(managed["PreInvocation"]) == len(managed["Stop"]) == 1
        for event_name in ("PreInvocation", "Stop"):
            handler = managed[event_name][0]
            assert set(handler) == {"type", "command", "timeout"}
            assert handler["type"] == "command" and handler["timeout"] == 1
            command_parts = shlex.split(handler["command"])
            assert str(bridge) == command_parts[1]
            assert command_parts[command_parts.index("--event") + 1] == event_name
            assert command_parts[command_parts.index("--agent-watch-owner") + 1].startswith("antigravity-v1:")
        for event_name in ("PreToolUse", "PostToolUse"):
            wrapper = managed[event_name][0]
            assert wrapper["matcher"] == "^ask_question$"
            assert len(wrapper["hooks"]) == 1
            assert wrapper["hooks"][0]["timeout"] == 1

        environment = os.environ.copy()
        environment["HOME"] = str(home)
        stable_hook = subprocess.run(
            shlex.split(managed["PreInvocation"][0]["command"]),
            input=json.dumps({"conversationId": "stable-bridge", "invocationNum": 0, "initialNumSteps": 0}).encode(),
            capture_output=True,
            env=environment,
            timeout=3,
            check=False,
        )
        assert stable_hook.returncode == 0 and stable_hook.stdout == b"{}\n"
        assert len(events_for(home, "stable-bridge")) == 1

        applied_bytes = config.read_bytes()
        no_change = run_manager(home)
        assert no_change.returncode == 0 and "no configuration or bridge change needed" in no_change.stdout
        repeated_apply = run_manager(home, "--apply")
        assert repeated_apply.returncode == 0, repeated_apply.stderr
        assert config.read_bytes() == applied_bytes
        assert len(list(config.parent.glob("hooks.json.agent-watch-backup-*"))) == 1

        uninstall_dry = run_manager(home, "--uninstall")
        assert uninstall_dry.returncode == 0
        assert config.read_bytes() == applied_bytes
        uninstall = run_manager(home, "--uninstall", "--apply")
        assert uninstall.returncode == 0, uninstall.stderr
        removed = json.loads(config.read_text(encoding="utf-8"))
        assert removed["user-hook"] == original["user-hook"]
        assert removed["agent-watch-antigravity"] == original["agent-watch-antigravity"]
        assert removed["agent-watch-antigravity-2"]["enabled"] is True
        assert removed["agent-watch-antigravity-2"]["PreInvocation"] == []
        assert removed["agent-watch-antigravity-2"]["Stop"] == []
        assert removed["agent-watch-antigravity-2"]["PreToolUse"] == []
        assert removed["agent-watch-antigravity-2"]["PostToolUse"] == []
        assert bridge.exists(), "uninstall removes only its config marker, not stored data or bridge copy"
        assert len(events_for(home, "stable-bridge")) == 1

        after_uninstall = config.read_bytes()
        repeated_uninstall = run_manager(home, "--uninstall", "--apply")
        assert repeated_uninstall.returncode == 0, repeated_uninstall.stderr
        assert config.read_bytes() == after_uninstall
        assert len(list(config.parent.glob("hooks.json.agent-watch-backup-*"))) == 2


def check_uninstall_only_removes_exact_marker() -> None:
    with tempfile.TemporaryDirectory(prefix="Antigravity uninstall fixture ") as temporary:
        home = Path(temporary)
        config = home / ".gemini" / "config" / "hooks.json"
        config.parent.mkdir(parents=True)
        document = {
            "user-owned": {
                "enabled": True,
                "PreInvocation": [
                    {"type": "command", "command": "python /tmp/not-antigravity.py --agent-watch-owner antigravity-v1:no", "timeout": 1},
                    {"type": "command", "command": "echo user", "timeout": 1},
                ],
            }
        }
        config.write_text(json.dumps(document), encoding="utf-8")
        result = run_manager(home, "--uninstall", "--apply")
        assert result.returncode == 0, result.stderr
        assert json.loads(config.read_text(encoding="utf-8")) == document
        assert not list(config.parent.glob("hooks.json.agent-watch-backup-*"))


def check_unowned_bridge_is_preserved() -> None:
    with tempfile.TemporaryDirectory(prefix="Antigravity bridge conflict ") as temporary:
        home = Path(temporary)
        bridge = root_for(home) / "bridge" / "antigravity.py"
        bridge.parent.mkdir(parents=True, mode=0o700)
        unrelated_bytes = b"user-owned bridge file; must not be replaced\n"
        bridge.write_bytes(unrelated_bytes)
        bridge.chmod(0o600)

        result = run_manager(home, "--apply")
        assert result.returncode == 2
        assert "Unable to inspect or update" in result.stderr
        assert bridge.read_bytes() == unrelated_bytes
        assert not (home / ".gemini" / "config" / "hooks.json").exists()


def check_nested_uninstall_preserves_other_handlers() -> None:
    with tempfile.TemporaryDirectory(prefix="Antigravity mixed hook fixture ") as temporary:
        home = Path(temporary)
        assert run_manager(home, "--apply").returncode == 0
        config = home / ".gemini/config/hooks.json"
        doc = json.loads(config.read_text())
        foreign = {"type": "command", "command": "echo user", "timeout": 2}
        doc["agent-watch-antigravity"]["PreToolUse"][0]["hooks"].append(foreign)
        doc["agent-watch-antigravity"]["PostToolUse"][0]["userMetadata"] = {"keep": True}
        config.write_text(json.dumps(doc))
        assert run_manager(home, "--uninstall", "--apply").returncode == 0
        remaining = json.loads(config.read_text())["agent-watch-antigravity"]["PreToolUse"]
        assert remaining == [{"matcher": "^ask_question$", "hooks": [foreign]}]
        preserved = json.loads(config.read_text())["agent-watch-antigravity"]["PostToolUse"]
        assert preserved == [{"matcher": "^ask_question$", "hooks": [], "userMetadata": {"keep": True}}]


def main() -> None:
    check_lifecycle_pairing_and_privacy()
    check_stop_mappings_and_orphans()
    check_current_app_and_question_lifecycle()
    check_input_and_lock_bounds()
    check_dry_run_apply_merge_and_uninstall()
    check_uninstall_only_removes_exact_marker()
    check_unowned_bridge_is_preserved()
    check_nested_uninstall_preserves_other_handlers()
    print("PASS: Antigravity lifecycle pairing, privacy, stop boundaries, bounded input/lock, and dry-run configuration merge/uninstall")


if __name__ == "__main__":
    main()
