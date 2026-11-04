#!/usr/bin/env python3
"""Synthetic checks for the metadata-only Claude Code record reader."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "claude_code_records_adapter", PROJECT_ROOT / "adapters" / "claude_code_records.py"
)
assert SPEC is not None and SPEC.loader is not None
ADAPTER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ADAPTER
SPEC.loader.exec_module(ADAPTER)


class ClaudeCodeRecordChecks(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="agent-watch-claude-code-records-")
        self.home = Path(self.temporary.name)
        self.root = self.home / "Claude-3p" / "claude-code-sessions"
        self.events = self.home / "Agent Watch" / "events"
        self.state = self.home / "Agent Watch" / "metadata" / "claude_code_records_state.json"
        self.bundle = self.home / "Claude.app"
        info = self.bundle / "Contents" / "Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.anthropic.claudefordesktop",
            "CFBundleShortVersionString": "4.4212.0",
        }))
        self.now = datetime(2026, 11, 4, 0, 0, 10, tzinfo=timezone.utc)
        self.session_id = "local_00000000-0000-4000-8000-000000000001"
        self.cli_session_id = "fa358146-fa88-4191-9800-db8ac56ba835"
        self.metadata_path = self.add_session(self.session_id, self.cli_session_id)
        self.reader = self.make_reader()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_reader(self):
        return ADAPTER.ClaudeCodeRecordsReader(
            home=self.home,
            roots=(("Claude-3p", self.root),),
            events_directory=self.events,
            state_file=self.state,
            app_bundle=self.bundle,
            now=lambda: self.now,
        )

    def add_session(self, local_id: str, cli_id: str, profile: str = "Claude-3p") -> Path:
        directory = self.home / profile / "claude-code-sessions" / "account" / "project"
        directory.mkdir(parents=True, exist_ok=True)
        return directory / f"{local_id}.json"

    @staticmethod
    def milliseconds(value: datetime) -> int:
        return int(value.timestamp() * 1000)

    def write_metadata(
        self,
        *,
        completed: int | None,
        frame: datetime | None,
        edge: datetime | None = None,
        assistant_uuid: str | None = None,
        cut_short: bool = False,
        archived: bool = False,
        error_category: str | None = None,
        error_at: datetime | None = None,
        path: Path | None = None,
        local_id: str | None = None,
        cli_id: str | None = None,
    ) -> None:
        record_path = path or self.metadata_path
        record_path.parent.mkdir(parents=True, exist_ok=True)
        metadata = {
            "sessionId": local_id or self.session_id,
            "cliSessionId": cli_id or self.cli_session_id,
            "latestUserFrameAt": self.milliseconds(frame) if frame else None,
            "lastTurnEdgeAt": self.milliseconds(edge) if edge else None,
            "lastTurnCutShort": cut_short,
            "isArchived": archived,
            "errorCategory": error_category,
            "errorAt": self.milliseconds(error_at) if error_at else None,
            "lastAssistantUuid": assistant_uuid,
            "title": "PRIVATE_METADATA_TITLE_DO_NOT_CAPTURE",
            "unselectedPayload": {"text": "PRIVATE_METADATA_BODY_DO_NOT_CAPTURE"},
        }
        if completed is not None:
            metadata["completedTurns"] = completed
        record_path.write_text(json.dumps(metadata), encoding="utf-8")

    def write_journal(self, records: list[dict[str, object]]) -> None:
        directory = self.home / ".claude" / "projects" / "project-hash"
        directory.mkdir(parents=True, exist_ok=True)
        journal = directory / f"{self.cli_session_id}.jsonl"
        with journal.open("w", encoding="utf-8") as output:
            for record in records:
                output.write(json.dumps(record, separators=(",", ":")) + "\n")

    def root_user(self, prompt_id: str, frame: datetime, uuid: str) -> dict[str, object]:
        return {
            "type": "user", "uuid": uuid, "promptId": prompt_id,
            "timestamp": frame.isoformat().replace("+00:00", "Z"),
            "sessionId": self.cli_session_id,
            "message": {"content": "PRIVATE_JOURNAL_BODY_DO_NOT_CAPTURE"},
        }

    def root_attachment(self, attachment_uuid: str, parent_uuid: str) -> dict[str, object]:
        return {
            "type": "attachment", "uuid": attachment_uuid, "parentUuid": parent_uuid,
            "sessionId": self.cli_session_id,
            "attachment": {"text": "PRIVATE_ATTACHMENT_BODY_DO_NOT_CAPTURE"},
        }

    def root_assistant(
        self, assistant_uuid: str, parent_uuid: str, at: datetime, stop_reason: str = "end_turn"
    ) -> dict[str, object]:
        return {
            "type": "assistant", "uuid": assistant_uuid, "parentUuid": parent_uuid,
            "timestamp": at.isoformat().replace("+00:00", "Z"),
            "sessionId": self.cli_session_id,
            "message": {
                "stop_reason": stop_reason,
                "content": "PRIVATE_ASSISTANT_BODY_DO_NOT_CAPTURE",
            },
        }

    def read_events(self) -> list[dict[str, object]]:
        return [json.loads(path.read_text(encoding="utf-8")) for path in sorted(self.events.glob("*.json"))]

    def ordered_events(self) -> list[dict[str, object]]:
        return sorted(self.read_events(), key=lambda record: int(record["sequence"]))

    def test_bootstrap_and_restart_never_emit_old_completion(self) -> None:
        frame = self.now - timedelta(minutes=3)
        assistant_at = frame + timedelta(seconds=1)
        self.write_metadata(completed=4, frame=frame, edge=assistant_at, assistant_uuid="assistant-A")
        self.write_journal([
            self.root_user("prompt-A", frame, "user-A"),
            self.root_attachment("attachment-A", "user-A"),
            self.root_assistant("assistant-A", "attachment-A", assistant_at),
        ])

        first = self.reader.poll_once()
        self.assertEqual(first.events_written, 0)
        self.assertEqual(self.read_events(), [])

        restarted = self.make_reader()
        second = restarted.poll_once()
        self.assertEqual(second.events_written, 0)
        self.assertEqual(self.read_events(), [])

    def test_counter_advance_maps_to_exact_cli_prompt_and_persists(self) -> None:
        frame = self.now - timedelta(seconds=5)
        assistant_at = self.now - timedelta(seconds=1)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-A", frame, "user-A")])

        initial = self.reader.poll_once()
        self.assertEqual(initial.events_written, 1)
        running = self.ordered_events()[0]
        self.assertEqual(running["appID"], "claude_code")
        self.assertEqual(running["sessionID"], self.cli_session_id)
        self.assertEqual(running["turnID"], "prompt-A")
        self.assertEqual(running["state"], "running")

        self.now += timedelta(seconds=2)
        self.write_metadata(
            completed=1, frame=frame, edge=assistant_at, assistant_uuid="assistant-A"
        )
        self.write_journal([
            self.root_user("prompt-A", frame, "user-A"),
            self.root_assistant("assistant-A", "user-A", assistant_at),
        ])
        completed = self.reader.poll_once()
        self.assertEqual(completed.events_written, 1)
        terminal = self.ordered_events()[-1]
        self.assertEqual(terminal["state"], "responseEnded")
        self.assertEqual(terminal["evidence"], "explicit")
        self.assertEqual(terminal["turnID"], "prompt-A")

        restarted = self.make_reader()
        self.assertEqual(restarted.poll_once().events_written, 0)
        serialized = self.state.read_text(encoding="utf-8") + "\n".join(
            path.read_text(encoding="utf-8") for path in self.events.glob("*.json")
        )
        for secret in (
            "PRIVATE_METADATA_TITLE_DO_NOT_CAPTURE",
            "PRIVATE_METADATA_BODY_DO_NOT_CAPTURE",
            "PRIVATE_JOURNAL_BODY_DO_NOT_CAPTURE",
            "PRIVATE_ASSISTANT_BODY_DO_NOT_CAPTURE",
            "PRIVATE_ATTACHMENT_BODY_DO_NOT_CAPTURE",
        ):
            self.assertNotIn(secret, serialized)

    def test_first_completion_is_observed_when_counter_was_absent_at_start(self) -> None:
        frame = self.now - timedelta(seconds=3)
        assistant_at = self.now - timedelta(milliseconds=500)
        self.write_metadata(completed=None, frame=frame, edge=frame - timedelta(milliseconds=100))
        self.write_journal([self.root_user("prompt-first", frame, "user-first")])
        self.reader.poll_once()
        self.assertEqual(self.ordered_events()[-1]["state"], "running")

        self.now += timedelta(seconds=1)
        self.write_metadata(
            completed=1, frame=frame, edge=assistant_at, assistant_uuid="assistant-first"
        )
        self.write_journal([
            self.root_user("prompt-first", frame, "user-first"),
            self.root_attachment("attachment-first", "user-first"),
            self.root_assistant("assistant-first", "attachment-first", assistant_at),
        ])
        self.reader.poll_once()
        self.assertEqual(self.ordered_events()[-1]["state"], "responseEnded")
        self.assertEqual(self.ordered_events()[-1]["turnID"], "prompt-first")

    def test_prompt_start_race_does_not_close_the_newer_turn_with_old_assistant(self) -> None:
        frame_a = self.now - timedelta(seconds=8)
        assistant_a_at = frame_a + timedelta(seconds=3)
        frame_b = frame_a + timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame_a, edge=frame_a - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-A", frame_a, "user-A")])
        self.reader.poll_once()

        self.now += timedelta(seconds=3)
        self.write_metadata(
            completed=1,
            frame=frame_b,
            edge=frame_b + timedelta(milliseconds=100),
            assistant_uuid="assistant-A",
        )
        self.write_journal([
            self.root_user("prompt-A", frame_a, "user-A"),
            self.root_attachment("attachment-A", "user-A"),
            self.root_assistant("assistant-A", "attachment-A", assistant_a_at),
            self.root_user("prompt-B", frame_b, "user-B"),
        ])

        self.reader.poll_once()
        records = self.ordered_events()
        self.assertEqual(records[-1]["state"], "running")
        self.assertEqual(records[-1]["turnID"], "prompt-B")
        self.assertFalse(any(record["state"] == "responseEnded" for record in records))

    def test_cut_short_without_distinct_cancel_evidence_is_unknown(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-A", frame, "user-A")])
        self.reader.poll_once()

        self.now += timedelta(seconds=2)
        self.write_metadata(completed=0, frame=frame, edge=self.now, cut_short=True)
        self.reader.poll_once()
        latest = self.ordered_events()[-1]
        self.assertEqual(latest["state"], "unknown")
        self.assertNotIn(latest["state"], {"cancelled", "responseEnded"})

    def test_fresh_error_takes_priority_over_success_counter(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-A", frame, "user-A")])
        self.reader.poll_once()

        self.now += timedelta(seconds=2)
        error_at = self.now - timedelta(milliseconds=100)
        self.write_metadata(
            completed=1, frame=frame, edge=error_at, assistant_uuid="assistant-A",
            error_category="api_error", error_at=error_at,
        )
        self.write_journal([
            self.root_user("prompt-A", frame, "user-A"),
            self.root_attachment("attachment-A", "user-A"),
            self.root_assistant("assistant-A", "attachment-A", error_at),
        ])
        self.reader.poll_once()
        self.assertEqual(self.ordered_events()[-1]["state"], "failed")
        self.assertFalse(any(record["state"] == "responseEnded" for record in self.read_events()))

    def test_counter_increment_requires_fully_recorded_end_turn(self) -> None:
        frame = self.now - timedelta(seconds=5)
        assistant_at = self.now - timedelta(seconds=1)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-A", frame, "user-A")])
        self.reader.poll_once()

        self.now += timedelta(seconds=2)
        self.write_metadata(completed=1, frame=frame, edge=assistant_at, assistant_uuid="assistant-A")
        self.write_journal([
            self.root_user("prompt-A", frame, "user-A"),
            self.root_attachment("attachment-A", "user-A"),
            self.root_assistant("assistant-A", "attachment-A", assistant_at, stop_reason="tool_use"),
        ])
        self.reader.poll_once()
        self.assertFalse(any(record["state"] == "responseEnded" for record in self.read_events()))

    def test_assistant_uuid_change_without_counter_does_not_end(self) -> None:
        frame = self.now - timedelta(seconds=5)
        assistant_at = self.now - timedelta(seconds=1)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-A", frame, "user-A")])
        self.reader.poll_once()

        self.now += timedelta(seconds=2)
        self.write_metadata(completed=0, frame=frame, edge=assistant_at, assistant_uuid="assistant-A")
        self.write_journal([
            self.root_user("prompt-A", frame, "user-A"),
            self.root_attachment("attachment-A", "user-A"),
            self.root_assistant("assistant-A", "attachment-A", assistant_at),
        ])
        self.reader.poll_once()
        self.assertFalse(any(record["state"] == "responseEnded" for record in self.read_events()))

    def test_old_assistant_after_new_prompt_is_not_mapped_to_current_turn(self) -> None:
        frame_a = self.now - timedelta(seconds=8)
        frame_b = frame_a + timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame_a, edge=frame_a - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-A", frame_a, "user-A")])
        self.reader.poll_once()

        self.now += timedelta(seconds=3)
        late_assistant_time = frame_b + timedelta(seconds=1)
        self.write_metadata(
            completed=1, frame=frame_b, edge=late_assistant_time, assistant_uuid="assistant-A"
        )
        self.write_journal([
            self.root_user("prompt-A", frame_a, "user-A"),
            self.root_attachment("attachment-A", "user-A"),
            self.root_assistant("assistant-A", "attachment-A", late_assistant_time),
            self.root_user("prompt-B", frame_b, "user-B"),
        ])
        self.reader.poll_once()
        self.assertFalse(any(record["state"] == "responseEnded" for record in self.read_events()))

    def test_stale_frame_does_not_emit_running_or_cut_short_terminal(self) -> None:
        frame = self.now - timedelta(minutes=2)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-A", frame, "user-A")])
        self.assertEqual(self.reader.poll_once().events_written, 0)

        self.now += timedelta(seconds=2)
        self.write_metadata(completed=0, frame=frame, edge=self.now, cut_short=True)
        self.assertEqual(self.reader.poll_once().events_written, 0)
        self.assertEqual(self.read_events(), [])

    def test_round_robin_cursor_advances_with_bounded_session_work(self) -> None:
        second_id = "local_00000000-0000-4000-8000-000000000002"
        second_path = self.add_session(second_id, "cli-session-2")
        stale_frame = self.now - timedelta(minutes=5)
        self.write_metadata(completed=0, frame=stale_frame)
        self.write_metadata(
            completed=0, frame=stale_frame, path=second_path,
            local_id=second_id, cli_id="cli-session-2",
        )
        with patch.object(ADAPTER, "MAX_SESSIONS_PER_POLL", 1):
            self.reader.poll_once()
            self.assertEqual(len(self.reader.cursors), 1)
            self.reader = self.make_reader()
            self.reader.poll_once()
        self.assertEqual(len(self.reader.cursors), 2)


if __name__ == "__main__":
    unittest.main()
