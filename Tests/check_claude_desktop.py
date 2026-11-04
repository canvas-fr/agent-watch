#!/usr/bin/env python3
"""Status-only Claude Desktop reader checks using synthetic local records."""

from __future__ import annotations

from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout


PROJECT_ROOT = Path(__file__).resolve().parents[1]
FIXTURES = PROJECT_ROOT / "Tests" / "fixtures" / "claude_desktop_audit"
SPEC = importlib.util.spec_from_file_location(
    "claude_desktop_adapter", PROJECT_ROOT / "adapters" / "claude_desktop.py"
)
assert SPEC is not None and SPEC.loader is not None
ADAPTER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ADAPTER
SPEC.loader.exec_module(ADAPTER)


class ClaudeDesktopReaderChecks(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="agent-watch-claude-desktop-")
        self.base = Path(self.temporary.name)
        self.root = self.base / "local-agent-mode-sessions"
        self.account_directory = self.root / "fixture-account" / "fixture-org"
        self.events = self.base / "events"
        self.state_file = self.base / "metadata" / "claude-desktop-state.json"
        self.bundle = self.base / "Claude.app"
        info = self.bundle / "Contents" / "Info.plist"
        info.parent.mkdir(parents=True)
        import plistlib

        info.write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "com.anthropic.claudefordesktop",
                    "CFBundleShortVersionString": "4.4212.0",
                }
            )
        )
        self.account_directory.mkdir(parents=True)
        self.now = datetime(2026, 11, 4, 0, 0, 10, tzinfo=timezone.utc)
        self.writer = ADAPTER.ClaudeDesktopReader(
            root=self.root,
            events_directory=self.events,
            state_file=self.state_file,
            app_bundle=self.bundle,
            now=lambda: self.now,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def add_session(self, fixture_name: str, session_id: str, audit_fixture: str) -> Path:
        metadata_path = self.account_directory / f"{session_id}.json"
        shutil.copyfile(FIXTURES / fixture_name, metadata_path)
        session_directory = self.account_directory / session_id
        session_directory.mkdir()
        audit_path = session_directory / "audit.jsonl"
        shutil.copyfile(FIXTURES / audit_fixture, audit_path)
        os.utime(audit_path, (self.now.timestamp(), self.now.timestamp()))
        return audit_path

    def event_records(self) -> list[dict[str, object]]:
        records = [json.loads(path.read_text()) for path in self.events.glob("*.json")]
        return sorted(records, key=lambda record: record["observedAt"])

    def test_gateway_profile_is_discovered_without_merging_standard_session(self) -> None:
        session_id = "local_00000000-0000-0000-0000-000000000001"
        self.add_session("cowork_metadata.json", session_id, "cowork_initial.jsonl")
        gateway = self.base / "Claude-3p" / "local-agent-mode-sessions"
        shutil.copytree(self.root, gateway)
        self.writer.roots = (self.root, gateway)
        summary = self.writer.poll_once()
        self.assertEqual(summary.events_written, 2)
        records = self.event_records()
        self.assertEqual(len({record["sessionID"] for record in records}), 2)
        self.assertEqual({record["state"] for record in records}, {"waitingApproval"})
        self.assertEqual(self.writer.poll_once().events_written, 0)

    def test_short_gateway_folder_requires_a_unique_session_prefix(self) -> None:
        session_id = "local_00000000-0000-0000-0000-000000000001"
        audit = self.add_session("cowork_metadata.json", session_id, "cowork_initial.jsonl")
        short_folder = self.account_directory / "00000000"
        audit.parent.rename(short_folder)
        self.assertEqual(ADAPTER._session_audit_path(self.account_directory, session_id), short_folder / "audit.jsonl")
        self.assertEqual(self.writer.poll_once().events_written, 1)
        other_id = "local_00000000-0000-0000-0000-000000000002"
        metadata = json.loads((self.account_directory / (session_id + ".json")).read_text())
        metadata["sessionId"] = other_id
        (self.account_directory / (other_id + ".json")).write_text(json.dumps(metadata))
        self.assertIsNone(ADAPTER._session_audit_path(self.account_directory, session_id))
        self.assertIsNone(ADAPTER._session_audit_path(self.account_directory, other_id))

    def test_cowork_approval_resume_and_completion_are_status_only(self) -> None:
        audit_path = self.add_session(
            "cowork_metadata.json",
            "local_00000000-0000-0000-0000-000000000001",
            "cowork_initial.jsonl",
        )

        first = self.writer.poll_once()
        self.assertEqual(first.events_written, 1)
        self.assertEqual(first.validation, "schema-confirmed-4.4212.0")
        first_record = self.event_records()[0]
        self.assertEqual(first_record["appID"], "claude")
        self.assertEqual(first_record["state"], "waitingApproval")
        self.assertEqual(first_record["evidence"], "inferred")
        self.assertIn("claude_desktop_cowork:audit_v1:schema-confirmed-4.4212.0", first_record["source"])

        # A fresh process resumes its persisted cursor instead of replaying an
        # old approval or generating a second completion notification.
        restarted = ADAPTER.ClaudeDesktopReader(
            root=self.root,
            events_directory=self.events,
            state_file=self.state_file,
            app_bundle=self.bundle,
            now=lambda: self.now,
        )
        self.assertEqual(restarted.poll_once().events_written, 0)

        with audit_path.open("ab") as audit:
            audit.write((FIXTURES / "cowork_finish.jsonl").read_bytes())
        self.now = self.now.replace(microsecond=500_000)
        second = restarted.poll_once()
        self.assertEqual(second.events_written, 3)
        records = self.event_records()
        self.assertEqual(
            [record["state"] for record in records],
            ["waitingApproval", "running", "running", "responseEnded"],
        )
        self.assertEqual(len({record["id"] for record in records}), 4)

        serialized = self.events.joinpath(next(self.events.glob("*.json")).name).read_text()
        all_serialized = "\n".join(path.read_text() for path in self.events.glob("*.json"))
        state_serialized = self.state_file.read_text()
        for secret in (
            "SYNTHETIC_PROMPT_DO_NOT_CAPTURE",
            "SYNTHETIC_INPUT_DO_NOT_CAPTURE",
            "SYNTHETIC_REPLY_DO_NOT_CAPTURE",
            "SYNTHETIC_RESULT_DO_NOT_CAPTURE",
            "SYNTHETIC_TITLE_DO_NOT_CAPTURE",
            "decision",
            "granted",
        ):
            self.assertNotIn(secret, all_serialized)
            self.assertNotIn(secret, state_serialized)
        self.assertTrue(serialized)

    def test_local_chat_record_is_supported_but_unknown_schema_fails_closed(self) -> None:
        self.add_session(
            "chat_metadata.json",
            "local_00000000-0000-0000-0000-000000000002",
            "chat_running.jsonl",
        )
        summary = self.writer.poll_once()
        records = self.event_records()
        self.assertEqual(summary.events_written, 1)
        self.assertEqual(records[0]["state"], "running")
        self.assertEqual(records[0]["evidence"], "inferred")
        self.assertIn("claude_desktop_chat:audit_v1:schema-confirmed-4.4212.0", records[0]["source"])

        # A future metadata type is not silently reported as Cowork or Chat.
        bad_path = self.account_directory / "local_00000000-0000-0000-0000-000000000003.json"
        bad_path.write_text(
            '{"sessionId":"local_00000000-0000-0000-0000-000000000003",'
            '"sessionType":"future_mode","isArchived":false}'
        )
        summary = self.writer.poll_once()
        self.assertEqual(summary.diagnostic, "unsupported_session_type")
        self.assertEqual(len(self.event_records()), 1)

    def test_once_command_writes_monitor_event_contract(self) -> None:
        audit_path = self.add_session(
            "chat_metadata.json",
            "local_00000000-0000-0000-0000-000000000002",
            "chat_running.jsonl",
        )
        os.utime(audit_path, (time.time(), time.time()))
        output = io.StringIO()
        with redirect_stdout(output):
            exit_code = ADAPTER.main(
                [
                    "--once",
                    "--root", str(self.root),
                    "--events-directory", str(self.events),
                    "--state-file", str(self.state_file),
                    "--app-bundle", str(self.bundle),
                ]
            )
        self.assertEqual(exit_code, 0)
        summary = json.loads(output.getvalue())
        self.assertEqual(summary["eventsWritten"], 1)
        event = self.event_records()[0]
        self.assertEqual(
            set(event),
            {"id", "appID", "sessionID", "turnID", "state", "evidence", "observedAt", "source"},
        )
        self.assertEqual(event["appID"], "claude")
        self.assertEqual(event["state"], "running")

    def test_other_app_version_is_schema_compatible_not_marked_validated(self) -> None:
        self.add_session(
            "chat_metadata.json",
            "local_00000000-0000-0000-0000-000000000002",
            "chat_running.jsonl",
        )
        import plistlib

        info = self.bundle / "Contents" / "Info.plist"
        info.write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "com.anthropic.claudefordesktop",
                    "CFBundleShortVersionString": "4.9999.0",
                }
            )
        )
        reader = ADAPTER.ClaudeDesktopReader(
            root=self.root,
            events_directory=self.events,
            state_file=self.state_file,
            app_bundle=self.bundle,
            now=lambda: self.now,
        )
        summary = reader.poll_once()
        self.assertEqual(summary.events_written, 1)
        self.assertEqual(summary.validation, "schema-compatible")
        self.assertIn("claude_desktop_chat:audit_v1:schema-compatible", self.event_records()[0]["source"])

    def test_terminal_history_bootstrap_does_not_create_an_unread_completion(self) -> None:
        self.add_session(
            "chat_metadata.json",
            "local_00000000-0000-0000-0000-000000000002",
            "chat_finished.jsonl",
        )
        first = self.writer.poll_once()
        self.assertEqual(first.events_written, 0)
        self.assertEqual(list(self.events.glob("*.json")), [])

        restarted = ADAPTER.ClaudeDesktopReader(
            root=self.root,
            events_directory=self.events,
            state_file=self.state_file,
            app_bundle=self.bundle,
            now=lambda: self.now,
        )
        self.assertEqual(restarted.poll_once().events_written, 0)
        state = json.loads(self.state_file.read_text())
        self.assertEqual(len(state["sessions"]), 1)
        self.assertEqual(next(iter(state["sessions"].values()))["state"], "responseEnded")
        self.assertEqual(len(state["metadata"]), 1)

    def test_large_store_budget_rotates_fairly_and_persists(self) -> None:
        original_budget = ADAPTER.MAX_AUDIT_BYTES_PER_POLL
        original_tail = ADAPTER.MAX_TAIL_BYTES
        original_session_limit = ADAPTER.MAX_SESSIONS_PER_POLL
        session_ids = [
            f"local_00000000-0000-0000-0000-{number:012d}"
            for number in (11, 12, 13)
        ]
        try:
            for session_id in session_ids:
                metadata = {
                    "sessionId": session_id,
                    "sessionType": "chat",
                    "isArchived": False,
                    "lastActivityAt": self.now.timestamp() * 1000,
                }
                (self.account_directory / f"{session_id}.json").write_text(json.dumps(metadata))
                session_directory = self.account_directory / session_id
                session_directory.mkdir()
                shutil.copyfile(
                    FIXTURES / "chat_running.jsonl",
                    session_directory / "audit.jsonl",
                )
                os.utime(
                    session_directory / "audit.jsonl",
                    (self.now.timestamp(), self.now.timestamp()),
                )

            record_size = (self.account_directory / session_ids[0] / "audit.jsonl").stat().st_size
            ADAPTER.MAX_AUDIT_BYTES_PER_POLL = record_size * 2 + 1
            ADAPTER.MAX_TAIL_BYTES = record_size
            ADAPTER.MAX_SESSIONS_PER_POLL = 3
            first = self.writer.poll_once()
            self.assertEqual(first.events_written, 2)
            self.assertEqual(self.writer.rotation, 2)

            restarted = ADAPTER.ClaudeDesktopReader(
                root=self.root,
                events_directory=self.events,
                state_file=self.state_file,
                app_bundle=self.bundle,
                now=lambda: self.now,
            )
            self.assertEqual(restarted.rotation, 2)
            second = restarted.poll_once()
            self.assertEqual(second.events_written, 1)
            expected = {
                ADAPTER._scope_hash(f"fixture-account/fixture-org/{session_id}")
                for session_id in session_ids
            }
            self.assertEqual({record["sessionID"] for record in self.event_records()}, expected)
        finally:
            ADAPTER.MAX_AUDIT_BYTES_PER_POLL = original_budget
            ADAPTER.MAX_TAIL_BYTES = original_tail
            ADAPTER.MAX_SESSIONS_PER_POLL = original_session_limit

    def test_result_abort_and_error_have_distinct_terminal_states(self) -> None:
        session_hash = "a" * 64
        for raw, expected in (
            (b'{"type":"result","subtype":"success","is_error":false,"terminal_reason":"aborted_tools"}', "cancelled"),
            (b'{"type":"result","subtype":"error_during_execution","is_error":true}', "failed"),
            (b'{"type":"result","subtype":"success","is_error":false}', "responseEnded"),
        ):
            fields, has_tool_result = ADAPTER._audit_fields(raw)
            observation = ADAPTER._observation_for(
                fields, has_tool_result, "running", "turn", session_hash, 1, 2, 20
            )
            self.assertIsNotNone(observation)
            self.assertEqual(observation.state, expected)

    def test_child_user_and_terminal_records_do_not_change_parent(self) -> None:
        parent_session = "a" * 64
        child_records = (
            b'{"type":"user","parent_tool_use_id":"task-child","message":{"content":"ignored"}}',
            b'{"type":"result","subtype":"success","is_error":false,"parent_tool_use_id":"task-child"}',
            b'{"type":"result","subtype":"error_during_execution","is_error":true,"parent_tool_use_id":"task-child"}',
            b'{"type":"system","subtype":"permission_request","tool_name":"Bash","parent_tool_use_id":"task-child"}',
        )
        for raw in child_records:
            fields, has_tool_result = ADAPTER._audit_fields(raw)
            observation = ADAPTER._observation_for(
                fields, has_tool_result, "running", "parent-turn", parent_session, 1, 2, 20
            )
            self.assertIsNone(observation)

    def test_chat_body_values_are_skipped_by_the_json_reader(self) -> None:
        raw = (
            b'{"type":"user","message":{"content":"SYNTHETIC_SECRET \\"type\\":\\"tool_result\\""},'
            b'"parent_tool_use_id":null}'
        )
        fields, has_tool_result = ADAPTER._audit_fields(raw)
        self.assertEqual(fields["type"], "user")
        self.assertFalse(has_tool_result)
        self.assertNotIn("message", fields)
        self.assertNotIn("SYNTHETIC_SECRET", repr(fields))


if __name__ == "__main__":
    unittest.main()
