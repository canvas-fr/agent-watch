"""Fixture checks for metadata-only hooks and guarded configuration changes."""

from __future__ import annotations

import fcntl
import hashlib
import json
from pathlib import Path
import runpy
import shutil
import shlex
import stat
import subprocess
import sys
import tempfile


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ADAPTERS = PROJECT_ROOT / "adapters"
EMITTER = ADAPTERS / "emit.py"
INSTALLER = ADAPTERS / "manage_hooks.py"
STATE_FOR = runpy.run_path(str(EMITTER))["state_for"]


def run_script(script: Path, *arguments: str, input_text: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(script), *arguments],
        input=input_text,
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )


def hook_payload(event_name: str, **fields: object) -> str:
    return json.dumps({"hook_event_name": event_name, **fields}, ensure_ascii=False)


def event_directory(home: Path) -> Path:
    return home / "Library" / "Application Support" / "Agent Watch" / "events"


def read_events(home: Path) -> list[dict[str, object]]:
    events = []
    for event_path in sorted(event_directory(home).glob("*.json")):
        contents = event_path.read_text(encoding="utf-8")
        assert contents.count("\n") == 1, "each event is a single JSON line"
        events.append(json.loads(contents))
    return events


def events_for(home: Path, session_id: str) -> list[dict[str, object]]:
    return sorted(
        (event for event in read_events(home) if event.get("sessionID") == session_id),
        key=lambda event: int(event["sequence"]),
    )


def check_event_bridge() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch 用户数据 ") as temporary_root:
        home = Path(temporary_root) / "家庭 空间 数据"
        user_prompt = "PRIVATE PROMPT MUST NOT BE SAVED"
        tool_input = "PRIVATE TOOL ARGUMENT MUST NOT BE SAVED"

        result = run_script(
            EMITTER,
            "--app",
            "claude_code",
            "--home",
            str(home),
            input_text=hook_payload(
                "UserPromptSubmit",
                session_id="claude-session-一",
                prompt_id="claude-turn-一",
                prompt=user_prompt,
                transcript_path="/private/user/transcript.jsonl",
            ),
        )
        assert result.returncode == 0 and result.stdout == "" and result.stderr == ""

        for tool_number in (1, 2):
            result = run_script(
                EMITTER,
                "--app",
                "claude_code",
                "--home",
                str(home),
                input_text=hook_payload(
                    "PreToolUse",
                    session_id="claude-session-一",
                    tool_name="Bash",
                    tool_input={"command": f"private tool argument {tool_number}: {tool_input}"},
                ),
            )
            assert result.returncode == 0 and result.stdout == "" and result.stderr == ""

        result = run_script(
            EMITTER,
            "--app",
            "claude_code",
            "--home",
            str(home),
            input_text=hook_payload("Stop", session_id="claude-session-一", last_assistant_message="private reply"),
        )
        assert result.returncode == 0 and result.stdout == ""

        events = events_for(home, "claude-session-一")
        assert len(events) == 4
        assert [event["state"] for event in events] == ["running", "running", "running", "responseEnded"]
        assert {event["turnID"] for event in events} == {"claude-turn-一"}
        assert [event["sequence"] for event in events] == [1, 2, 3, 4]
        required = {"id", "appID", "sessionID", "turnID", "state", "evidence", "observedAt", "sequence", "source"}
        for event in events:
            assert required.issubset(event)
            assert event["appID"] == "claude_code"
            assert event["evidence"] == "explicit"
            assert event["source"].startswith("claude_code:")
            assert "parentSessionID" not in event

        serialized = "\n".join(path.read_text(encoding="utf-8") for path in event_directory(home).glob("*.json"))
        metadata = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (home / "Library" / "Application Support" / "Agent Watch" / "metadata").glob("*.json")
        )
        assert user_prompt not in serialized and user_prompt not in metadata
        assert tool_input not in serialized and tool_input not in metadata
        assert "transcript_path" not in serialized and "tool_input" not in serialized
        assert "last_assistant_message" not in serialized

        root = home / "Library" / "Application Support" / "Agent Watch"
        assert stat.S_IMODE(root.stat().st_mode) == 0o700
        assert stat.S_IMODE(event_directory(home).stat().st_mode) == 0o700
        assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in event_directory(home).glob("*.json"))
        assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in (root / "metadata").glob("*.json"))

        # A second submitted prompt begins a new turn; a supplied turn id is
        # authoritative for Codex, while generated IDs are local to one session.
        run_script(
            EMITTER,
            "--app",
            "claude_code",
            "--home",
            str(home),
            input_text=hook_payload("UserPromptSubmit", session_id="claude-session-一", prompt="secret two"),
        )
        next_result = run_script(
            EMITTER,
            "--app",
            "claude_code",
            "--home",
            str(home),
            input_text=hook_payload("PreToolUse", session_id="claude-session-一", tool_input={"x": "secret"}),
        )
        assert next_result.returncode == 0
        assert events_for(home, "claude-session-一")[-1]["turnID"] != "claude-turn-一"

        # Only the two documented notification types are translated.
        for notification_type, expected_state in (
            ("permission_prompt", "waitingApproval"),
            ("idle_prompt", "waitingInput"),
        ):
            run_script(
                EMITTER,
                "--app",
                "claude_code",
                "--home",
                str(home),
                input_text=hook_payload(
                    "Notification",
                    session_id="claude-session-一",
                    notification_type=notification_type,
                    message="private notification detail",
                ),
            )
            assert events_for(home, "claude-session-一")[-1]["state"] == expected_state
        before_unknown_notification = len(read_events(home))
        run_script(
            EMITTER,
            "--app",
            "claude_code",
            "--home",
            str(home),
            input_text=hook_payload(
                "Notification",
                session_id="claude-session-一",
                notification_type="unknown_notification",
                message="private unknown detail",
            ),
        )
        assert len(read_events(home)) == before_unknown_notification

        # Permission requests are observed, but no approval decision is emitted.
        permission_result = run_script(
            EMITTER,
            "--app",
            "codex",
            "--home",
            str(home),
            input_text=hook_payload(
                "PermissionRequest",
                session_id="codex-session",
                turn_id="codex-turn",
                tool_input={"command": "private command"},
                description="private approval detail",
            ),
        )
        assert permission_result.returncode == 0 and permission_result.stdout == "{}\n" and permission_result.stderr == ""
        assert events_for(home, "codex-session")[-1]["state"] == "waitingApproval"
        assert "allow" not in permission_result.stdout and "deny" not in permission_result.stdout
        codex_notification_before = len(events_for(home, "codex-session"))
        run_script(
            EMITTER,
            "--app",
            "codex",
            "--home",
            str(home),
            input_text=hook_payload("Notification", session_id="codex-session", notification_type="idle_prompt"),
        )
        assert len(events_for(home, "codex-session")) == codex_notification_before

        codex_prompt = run_script(
            EMITTER,
            "--app",
            "codex",
            "--home",
            str(home),
            input_text=hook_payload("UserPromptSubmit", session_id="codex-session", turn_id="codex-turn", prompt="secret"),
        )
        codex_tool = run_script(
            EMITTER,
            "--app",
            "codex",
            "--home",
            str(home),
            input_text=hook_payload("PreToolUse", session_id="codex-session", turn_id="codex-turn", tool_input={"secret": 1}),
        )
        assert codex_prompt.returncode == 0 and codex_prompt.stdout == "{}\n"
        assert codex_tool.returncode == 0 and codex_tool.stdout == "{}\n"
        assert events_for(home, "codex-session")[-1]["turnID"] == "codex-turn"

        stop_result = run_script(
            EMITTER,
            "--app",
            "codex",
            "--home",
            str(home),
            input_text=hook_payload("Stop", session_id="codex-session", turn_id="codex-turn", last_assistant_message="secret"),
        )
        assert stop_result.returncode == 0 and stop_result.stdout == "{}\n"
        assert events_for(home, "codex-session")[-1]["state"] == "responseEnded"
        interrupt_result = run_script(
            EMITTER,
            "--app",
            "codex",
            "--home",
            str(home),
            input_text=hook_payload("Interrupt", session_id="codex-session", turn_id="codex-turn"),
        )
        assert interrupt_result.returncode == 0 and interrupt_result.stdout == "{}\n"
        assert events_for(home, "codex-session")[-1]["state"] == "cancelled"

        # Explicit subagent identifiers remain separate from parent sessions.
        run_script(
            EMITTER,
            "--app",
            "claude_code",
            "--home",
            str(home),
            input_text=hook_payload(
                "PreToolUse",
                session_id="claude-parent",
                agent_id="claude-agent-child",
                tool_input={"text": "private"},
            ),
        )
        child_event = events_for(home, "claude-agent-child")[-1]
        assert child_event["sessionID"] == "claude-agent-child"
        assert child_event["parentSessionID"] == "claude-parent"

        run_script(
            EMITTER,
            "--app",
            "workbuddy",
            "--home",
            str(home),
            input_text=hook_payload("StopFailure", session_id="workbuddy-session"),
        )
        assert events_for(home, "workbuddy-session")[-1]["state"] == "failed"

        count_before_malformed = len(read_events(home))
        malformed = run_script(EMITTER, "--app", "claude_code", "--home", str(home), input_text="not json")
        assert malformed.returncode == 0 and malformed.stdout == "" and malformed.stderr == ""
        assert len(read_events(home)) == count_before_malformed

        too_large_payload = hook_payload(
            "Stop",
            session_id="oversized-session",
            last_assistant_message="x" * (1024 * 1024 + 100),
        )
        oversized = run_script(
            EMITTER,
            "--app",
            "claude_code",
            "--home",
            str(home),
            input_text=too_large_payload,
        )
        assert oversized.returncode == 0 and oversized.stdout == "" and oversized.stderr == ""
        assert not events_for(home, "oversized-session")

        # A concurrent writer can delay an event by at most the bounded retry
        # window; it must never hold up the agent for an open-ended flock.
        locked_session = "briefly-locked-session"
        metadata_dir = home / "Library" / "Application Support" / "Agent Watch" / "metadata"
        identity = "\0".join(("claude_code", locked_session))
        lock_hash = hashlib.sha256(identity.encode("utf-8")).hexdigest()
        locked_file = metadata_dir / f"{lock_hash}.lock"
        with locked_file.open("a+") as lock_handle:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            timed_out_lock = run_script(
                EMITTER,
                "--app",
                "claude_code",
                "--home",
                str(home),
                input_text=hook_payload("UserPromptSubmit", session_id=locked_session, prompt="private"),
            )
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
        assert timed_out_lock.returncode == 0 and timed_out_lock.stdout == "" and timed_out_lock.stderr == ""
        assert not events_for(home, locked_session)

        # A filesystem failure must not turn the observer into a blocking hook.
        broken_home = Path(temporary_root) / "broken home"
        broken_root = broken_home / "Library" / "Application Support" / "Agent Watch"
        broken_root.mkdir(parents=True)
        (broken_root / "events").write_text("file instead of directory", encoding="utf-8")
        failed_write = run_script(
            EMITTER,
            "--app",
            "claude_code",
            "--home",
            str(broken_home),
            input_text=hook_payload("Stop", session_id="cannot-write"),
        )
        assert failed_write.returncode == 0 and failed_write.stdout == "" and failed_write.stderr == ""


def check_waiting_input_tool_names() -> None:
    class MetadataOnlyPayload(dict[str, object]):
        forbidden_fields = {"tool_input", "args", "body", "questions"}

        def __getitem__(self, key: str) -> object:
            if key in self.forbidden_fields:
                raise AssertionError(f"unexpected read of {key}")
            return super().__getitem__(key)

        def get(self, key: str, default: object = None) -> object:
            if key in self.forbidden_fields:
                raise AssertionError(f"unexpected read of {key}")
            return super().get(key, default)

    known_tools = (
        ("claude_code", "AskUserQuestion"),
        ("workbuddy", "AskUserQuestion"),
        ("codex", "request_user_input"),
    )
    for app_id, tool_name in known_tools:
        payload = MetadataOnlyPayload(
            hook_event_name="PreToolUse",
            session_id="metadata-only-session",
            turn_id="metadata-only-turn",
            tool_name=tool_name,
            tool_input=object(),
            args=object(),
            body=object(),
            questions=object(),
        )
        assert STATE_FOR(app_id, payload) == (
            "waitingInput",
            f"{app_id}:PreToolUse:{tool_name}",
        )

    # Similar names and cross-host names stay ordinary tool activity.
    unrecognized = (
        ("claude_code", "AskUserQuestionExtra"),
        ("workbuddy", "ask_user_question"),
        ("codex", "AskUserQuestion"),
    )
    for app_id, tool_name in unrecognized:
        payload = MetadataOnlyPayload(
            hook_event_name="PreToolUse",
            session_id="metadata-only-session",
            tool_name=tool_name,
            tool_input=object(),
            args=object(),
            body=object(),
            questions=object(),
        )
        assert STATE_FOR(app_id, payload) == ("running", f"{app_id}:PreToolUse")


def check_lifecycle_recovery() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch 生命周期 ") as temporary_root:
        home = Path(temporary_root)
        hosts = (
            ("claude_code", "AskUserQuestion"),
            ("workbuddy", "AskUserQuestion"),
            ("codex", "request_user_input"),
        )
        for app_id, question_tool in hosts:
            session_id = f"{app_id}-lifecycle-session"
            turn_fields = {"turn_id": "codex-lifecycle-turn"} if app_id == "codex" else {}
            expected_stdout = "{}\n" if app_id == "codex" else ""

            for event_name, fields in (
                ("UserPromptSubmit", turn_fields),
                ("PreToolUse", {"tool_name": question_tool}),
                ("PostToolUse", {"tool_name": question_tool}),
                ("PermissionRequest", {}),
                ("PostToolUse", {"tool_name": "Bash"}),
            ):
                payload_fields = {**turn_fields, **fields}
                result = run_script(
                    EMITTER,
                    "--app",
                    app_id,
                    "--home",
                    str(home),
                    input_text=hook_payload(event_name, session_id=session_id, **payload_fields),
                )
                assert result.returncode == 0
                assert result.stdout == expected_stdout and result.stderr == ""

            events = events_for(home, session_id)
            assert [event["state"] for event in events] == [
                "running",
                "waitingInput",
                "running",
                "waitingApproval",
                "running",
            ]
            assert len({event["turnID"] for event in events}) == 1

            parent_id = f"{app_id}-subagent-parent"
            child_id = f"{app_id}-subagent-child"
            stop_fields = {"turn_id": "codex-subagent-turn"} if app_id == "codex" else {}
            subagent_stop = run_script(
                EMITTER,
                "--app",
                app_id,
                "--home",
                str(home),
                input_text=hook_payload(
                    "SubagentStop",
                    session_id=parent_id,
                    agent_id=child_id,
                    **stop_fields,
                ),
            )
            assert subagent_stop.returncode == 0
            assert subagent_stop.stdout == expected_stdout and subagent_stop.stderr == ""
            child_event = events_for(home, child_id)[-1]
            assert child_event["state"] == "responseEnded"
            assert child_event["sessionID"] == child_id
            assert child_event["parentSessionID"] == parent_id

            before_unknown_events = len(read_events(home))
            run_script(
                EMITTER,
                "--app",
                app_id,
                "--home",
                str(home),
                input_text=hook_payload(
                    "SubagentStop",
                    session_id=f"{app_id}-missing-agent-parent",
                ),
            )
            run_script(
                EMITTER,
                "--app",
                app_id,
                "--home",
                str(home),
                input_text=hook_payload(
                    "PostToolUseFailure",
                    session_id=f"{app_id}-failed-tool-session",
                ),
            )
            assert len(read_events(home)) == before_unknown_events


def check_subagent_state_identity() -> None:
    def emit_codex(home: Path, event_name: str, **fields: object) -> None:
        result = run_script(
            EMITTER,
            "--app",
            "codex",
            "--home",
            str(home),
            input_text=hook_payload(event_name, **fields),
        )
        assert result.returncode == 0 and result.stdout == "{}\n" and result.stderr == ""

    with tempfile.TemporaryDirectory(prefix="Agent Watch 子会话状态 ") as temporary_root:
        home = Path(temporary_root)

        # A Codex child may identify itself directly during tool use, then
        # appear under its parent session when the subagent stops.
        child_id = "child-session-direct"
        parent_id = "parent-session-direct"
        emit_codex(
            home,
            "PreToolUse",
            session_id=child_id,
            turn_id="child-turn-direct",
            tool_name="Bash",
        )
        emit_codex(
            home,
            "SubagentStop",
            session_id=parent_id,
            agent_id=child_id,
            turn_id="parent-turn-direct",
        )
        direct_events = events_for(home, child_id)
        assert [event["sequence"] for event in direct_events] == [1, 2]
        assert {event["turnID"] for event in direct_events} == {"child-turn-direct"}
        assert direct_events[-1]["parentSessionID"] == parent_id
        assert direct_events[-1]["state"] == "responseEnded"

        # The same child must stay coherent when both hooks name it through
        # agent_id and the parent session_id.
        child_id = "child-session-agent-field"
        parent_id = "parent-session-agent-field"
        emit_codex(
            home,
            "PreToolUse",
            session_id=parent_id,
            agent_id=child_id,
            turn_id="child-turn-agent-field",
            tool_name="Bash",
        )
        emit_codex(
            home,
            "SubagentStop",
            session_id=parent_id,
            agent_id=child_id,
            turn_id="parent-turn-agent-field",
        )
        agent_field_events = events_for(home, child_id)
        assert [event["sequence"] for event in agent_field_events] == [1, 2]
        assert {event["turnID"] for event in agent_field_events} == {"child-turn-agent-field"}
        assert agent_field_events[-1]["parentSessionID"] == parent_id

        # A cold SubagentStop closes a child turn of its own, never its
        # parent's turn from the hook payload.
        cold_child = "child-session-cold"
        cold_parent = "parent-session-cold"
        emit_codex(
            home,
            "SubagentStop",
            session_id=cold_parent,
            agent_id=cold_child,
            turn_id="parent-turn-cold",
        )
        cold_event = events_for(home, cold_child)[0]
        assert cold_event["sequence"] == 1
        assert cold_event["turnID"] != "parent-turn-cold"
        assert cold_event["parentSessionID"] == cold_parent

        # Migrate the highest-sequence child record among old parent-scoped
        # keys before writing the new app/session-scoped key.
        metadata_directory = home / "Library" / "Application Support" / "Agent Watch" / "metadata"
        metadata_directory.mkdir(parents=True, exist_ok=True)
        legacy_child = "child-session-legacy"
        legacy_parent = "parent-session-legacy"
        for legacy_parent_key, turn_id, sequence in (
            (legacy_child, "older-child-turn", 3),
            (legacy_parent, "latest-child-turn", 7),
        ):
            identity = "\0".join(("codex", legacy_parent_key, legacy_child))
            digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
            legacy_path = metadata_directory / f"{digest}.json"
            legacy_path.write_text(
                json.dumps({"turnID": turn_id, "sequence": sequence}) + "\n",
                encoding="utf-8",
            )
            legacy_path.chmod(0o600)

        emit_codex(
            home,
            "SubagentStop",
            session_id=legacy_parent,
            agent_id=legacy_child,
            turn_id="parent-turn-legacy",
        )
        migrated_event = events_for(home, legacy_child)[0]
        assert migrated_event["sequence"] == 8
        assert migrated_event["turnID"] == "latest-child-turn"
        assert migrated_event["parentSessionID"] == legacy_parent


def managed_handlers(document: dict[str, object], app_id: str) -> list[dict[str, object]]:
    marker = f"# agent-watch-managed:v1:{app_id}"
    found = []
    hooks = document.get("hooks", {})
    if not isinstance(hooks, dict):
        return found
    for groups in hooks.values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            handlers = group.get("hooks", [])
            if isinstance(handlers, list):
                found.extend(
                    handler
                    for handler in handlers
                    if isinstance(handler, dict)
                    and isinstance(handler.get("command"), str)
                    and marker in handler["command"]
                )
    return found


def check_installer() -> None:
    with tempfile.TemporaryDirectory(prefix="Agent Watch hooks ") as temporary_root:
        fixture_root = Path(temporary_root)
        home = fixture_root / "用户 配置 家目录"
        adapter_copy = fixture_root / "Hook 工具 含空格" / "adapters"
        adapter_copy.mkdir(parents=True)
        shutil.copy2(EMITTER, adapter_copy / "emit.py")
        shutil.copy2(INSTALLER, adapter_copy / "manage_hooks.py")
        installer = adapter_copy / "manage_hooks.py"

        config = home / ".codex" / "hooks.json"
        config.parent.mkdir(parents=True)
        initial = {
            "apiSettings": {"privateToken": "DO NOT PRINT THIS SECRET"},
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "^Bash$",
                        "hooks": [{"type": "command", "command": "echo keep-my-pre-tool-hook", "timeout": 20}],
                    }
                ],
                "Stop": [
                    {"hooks": [{"type": "command", "command": "echo keep-my-stop-hook"}]}
                ],
                "Notification": [
                    {
                        "matcher": "permission_prompt",
                        "hooks": [{"type": "command", "command": "echo keep-my-notification-hook"}],
                    }
                ],
            },
        }
        original_text = json.dumps(initial, ensure_ascii=False, indent=2) + "\n"
        config.write_text(original_text, encoding="utf-8")

        dry_run = run_script(installer, "--app", "codex", "--home", str(home))
        assert dry_run.returncode == 0 and "Dry run" in dry_run.stdout
        assert "DO NOT PRINT THIS SECRET" not in dry_run.stdout + dry_run.stderr
        assert "~/Library/Application Support/Agent Watch/bridge/emit.py" in dry_run.stdout
        assert "Event bridge installed:" not in dry_run.stdout
        assert config.read_text(encoding="utf-8") == original_text
        assert not list(config.parent.glob("*.agent-watch-backup-*"))
        bridge_root = home / "Library" / "Application Support" / "Agent Watch"
        bridge_directory = bridge_root / "bridge"
        bridge_file = bridge_directory / "emit.py"
        assert not bridge_root.exists(), "dry-run must not create any Agent Watch directory"
        assert not bridge_file.exists(), "dry-run must not install the stable bridge copy"

        applied = run_script(installer, "--app", "codex", "--home", str(home), "--apply")
        assert applied.returncode == 0 and "Backup:" in applied.stdout
        assert "Event bridge installed:" in applied.stdout
        assert "DO NOT PRINT THIS SECRET" not in applied.stdout + applied.stderr
        backups = list(config.parent.glob("hooks.json.agent-watch-backup-*"))
        assert len(backups) == 1 and backups[0].read_text(encoding="utf-8") == original_text
        installed_text = config.read_text(encoding="utf-8")
        installed = json.loads(installed_text)
        own = managed_handlers(installed, "codex")
        assert len(own) == 7
        assert all(handler["timeout"] == 1 for handler in own)
        assert installed["apiSettings"] == initial["apiSettings"]
        assert bridge_file.read_bytes() == EMITTER.read_bytes()
        assert stat.S_IMODE(bridge_root.stat().st_mode) == 0o700
        assert stat.S_IMODE(bridge_directory.stat().st_mode) == 0o700
        assert stat.S_IMODE(bridge_file.stat().st_mode) == 0o600

        # The command uses a stable private copy and quotes paths with spaces.
        own_command = own[0]["command"]
        parsed_command = shlex.split(own_command, comments=True)
        expected_command = [
            str(Path(sys.executable).resolve()),
            str(bridge_file),
            "--app",
            "codex",
        ]
        assert parsed_command == expected_command, (parsed_command, expected_command)
        assert str(adapter_copy) not in own_command

        # The installed command still works if the source checkout disappears.
        source_script = adapter_copy / "emit.py"
        moved_source = adapter_copy / "emit.py.temporarily-moved"
        source_script.rename(moved_source)
        try:
            stable_run = subprocess.run(
                parsed_command + ["--home", str(home)],
                input=hook_payload(
                    "UserPromptSubmit",
                    session_id="stable-script-session",
                    turn_id="stable-script-turn",
                    prompt="private test prompt",
                ),
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
        finally:
            moved_source.rename(source_script)
        assert stable_run.returncode == 0 and stable_run.stdout == "{}\n" and stable_run.stderr == ""
        assert events_for(home, "stable-script-session")[-1]["turnID"] == "stable-script-turn"

        # Re-applying is a no-op: no duplicate hooks or second backup.
        bridge_inode = bridge_file.stat().st_ino
        second_apply = run_script(installer, "--app", "codex", "--home", str(home), "--apply")
        assert second_apply.returncode == 0 and "no configuration or bridge change needed" in second_apply.stdout
        assert config.read_text(encoding="utf-8") == installed_text
        assert bridge_file.stat().st_ino == bridge_inode, "an unchanged bridge copy should not be rewritten"
        assert len(list(config.parent.glob("hooks.json.agent-watch-backup-*"))) == 1

        # Uninstall removes owned hook definitions but retains local event data
        # and the bridge file; users can decide when to remove that directory.
        event_directory = bridge_root / "events"
        metadata_directory = bridge_root / "metadata"
        event_record = next(event_directory.glob("*.json"))
        metadata_record = next(metadata_directory.glob("*.json"))
        retained_event = event_record.read_bytes()
        retained_metadata = metadata_record.read_bytes()

        before_uninstall = config.read_bytes()
        uninstall_dry_run = run_script(installer, "--app", "codex", "--home", str(home), "--uninstall")
        assert uninstall_dry_run.returncode == 0 and "Dry run" in uninstall_dry_run.stdout
        assert config.read_bytes() == before_uninstall

        uninstalled = run_script(installer, "--app", "codex", "--home", str(home), "--uninstall", "--apply")
        assert uninstalled.returncode == 0 and "Backup:" in uninstalled.stdout
        final_document = json.loads(config.read_text(encoding="utf-8"))
        assert managed_handlers(final_document, "codex") == []
        assert final_document["apiSettings"] == initial["apiSettings"]
        assert final_document["hooks"]["PreToolUse"] == initial["hooks"]["PreToolUse"]
        assert final_document["hooks"]["Stop"] == initial["hooks"]["Stop"]
        notification_hooks = final_document["hooks"]["Notification"][0]["hooks"]
        assert notification_hooks == initial["hooks"]["Notification"][0]["hooks"]
        assert bridge_file.read_bytes() == EMITTER.read_bytes()
        assert event_record.read_bytes() == retained_event
        assert metadata_record.read_bytes() == retained_metadata
        backups_after_uninstall = list(config.parent.glob("hooks.json.agent-watch-backup-*"))
        assert len(backups_after_uninstall) == 2
        assert any(path.read_bytes() == before_uninstall for path in backups_after_uninstall)

        # Invalid JSON is rejected before any backup or write.
        broken = home / ".claude" / "settings.json"
        broken.parent.mkdir(parents=True)
        broken.write_text("{malformed private config", encoding="utf-8")
        bad_apply = run_script(installer, "--app", "claude_code", "--home", str(home), "--apply")
        assert bad_apply.returncode == 2
        assert broken.read_text(encoding="utf-8") == "{malformed private config"
        assert not list(broken.parent.glob("*.agent-watch-backup-*"))

        # App-specific user configuration paths are selected explicitly.
        for app_id, expected_path in (
            ("claude_code", home / ".claude" / "settings.json"),
            ("workbuddy", home / ".workbuddy" / "settings.json"),
        ):
            expected_path.parent.mkdir(parents=True, exist_ok=True)
            expected_path.write_text('{"custom":"keep"}\n', encoding="utf-8")
            result = run_script(installer, "--app", app_id, "--home", str(home), "--apply")
            assert result.returncode == 0, result.stderr
            app_document = json.loads(expected_path.read_text(encoding="utf-8"))
            assert app_document["custom"] == "keep"
            assert len(managed_handlers(app_document, app_id)) == 9


def main() -> None:
    check_event_bridge()
    check_waiting_input_tool_names()
    check_lifecycle_recovery()
    check_subagent_state_identity()
    check_installer()
    print("PASS: metadata-only lifecycle recovery, child session continuity, legacy migration, installer safety, and quoted paths")


if __name__ == "__main__":
    main()
