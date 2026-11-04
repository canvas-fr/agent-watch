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

    def write_journal(self, records: list[dict[str, object]], cli_id: str | None = None) -> None:
        directory = self.home / ".claude" / "projects" / "project-hash"
        directory.mkdir(parents=True, exist_ok=True)
        journal = directory / f"{cli_id or self.cli_session_id}.jsonl"
        with journal.open("w", encoding="utf-8") as output:
            for record in records:
                output.write(json.dumps(record, separators=(",", ":")) + "\n")

    def root_user(
        self, prompt_id: str, frame: datetime, uuid: str, cli_id: str | None = None,
        text: str = "PRIVATE_JOURNAL_BODY_DO_NOT_CAPTURE",
        version: str | None = "2.1.309",
    ) -> dict[str, object]:
        record: dict[str, object] = {
            "type": "user", "uuid": uuid, "promptId": prompt_id,
            "timestamp": frame.isoformat().replace("+00:00", "Z"),
            "sessionId": cli_id or self.cli_session_id, "isSidechain": False,
            "origin": {"kind": "cli"},
            "message": {"role": "user", "content": text},
        }
        if version is not None:
            record["version"] = version
        return record

    def root_attachment(
        self, attachment_uuid: str, parent_uuid: str, cli_id: str | None = None,
    ) -> dict[str, object]:
        return {
            "type": "attachment", "uuid": attachment_uuid, "parentUuid": parent_uuid,
            "sessionId": cli_id or self.cli_session_id,
            "attachment": {"text": "PRIVATE_ATTACHMENT_BODY_DO_NOT_CAPTURE"},
        }

    def root_assistant(
        self, assistant_uuid: str, parent_uuid: str, at: datetime,
        stop_reason: str | None = "end_turn", cli_id: str | None = None,
        version: str | None = "2.1.309",
    ) -> dict[str, object]:
        record: dict[str, object] = {
            "type": "assistant", "uuid": assistant_uuid, "parentUuid": parent_uuid,
            "timestamp": at.isoformat().replace("+00:00", "Z"),
            "sessionId": cli_id or self.cli_session_id, "isSidechain": False,
            "message": {
                "id": "msg_" + assistant_uuid,
                "role": "assistant",
                "stop_reason": stop_reason,
                "content": "PRIVATE_ASSISTANT_BODY_DO_NOT_CAPTURE",
            },
        }
        if version is not None:
            record["version"] = version
        return record

    def root_aborted_assistant(
        self, assistant_uuid: str, parent_uuid: str, at: datetime,
        cli_id: str | None = None, *, sidechain: bool = False,
        version: str | None = "2.1.309",
    ) -> dict[str, object]:
        record: dict[str, object] = {
            "type": "assistant", "uuid": assistant_uuid, "parentUuid": parent_uuid,
            "timestamp": at.isoformat().replace("+00:00", "Z"),
            "sessionId": cli_id or self.cli_session_id, "isSidechain": sidechain,
            "isAbortedMidStream": True,
            "message": {
                "id": "msg_" + assistant_uuid,
                "role": "assistant",
                "stop_reason": None,
                "content": [{"type": "text", "text": "PRIVATE_ABORTED_TEXT_DO_NOT_CAPTURE"}],
            },
        }
        if version is not None:
            record["version"] = version
        return record

    def root_interrupt_marker(
        self, prompt_id: str, marker_uuid: str, parent_uuid: str, at: datetime,
        marker: str = "[Request interrupted by user]",
        cli_id: str | None = None, *, sidechain: bool = False, origin: bool = False,
        version: str | None = "2.1.309",
    ) -> dict[str, object]:
        record: dict[str, object] = {
            "type": "user", "uuid": marker_uuid, "parentUuid": parent_uuid,
            "promptId": prompt_id, "timestamp": at.isoformat().replace("+00:00", "Z"),
            "sessionId": cli_id or self.cli_session_id, "isSidechain": sidechain,
            "message": {"role": "user", "content": [{"type": "text", "text": marker}]},
        }
        if origin:
            record["origin"] = {"kind": "cli"}
        if version is not None:
            record["version"] = version
        return record

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

    def test_active_journal_probe_does_not_emit_a_mtime_heartbeat(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-heartbeat", frame, "human-heartbeat")])
        self.assertEqual(self.reader.poll_once().events_written, 1)
        self.assertEqual(self.reader.poll_once().events_written, 0)
        self.assertEqual([record["state"] for record in self.read_events()], ["running"])

    def test_current_prompt_interrupt_cancels_tracked_run_without_counter_or_assistant_change(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-A", frame, "human-A")])
        self.assertEqual(self.reader.poll_once().events_written, 1)
        self.assertEqual(self.ordered_events()[-1]["state"], "running")

        self.now += timedelta(seconds=1)
        parent_at = self.now - timedelta(milliseconds=200)
        marker_at = self.now - timedelta(milliseconds=100)
        self.write_metadata(
            completed=0, frame=frame,
            edge=frame - timedelta(milliseconds=185), cut_short=True,
        )
        self.write_journal([
            self.root_user("prompt-A", frame, "human-A"),
            self.root_aborted_assistant("assistant-aborted-A", "human-A", parent_at),
            self.root_interrupt_marker("prompt-A", "interrupt-A", "assistant-aborted-A", marker_at),
        ])

        result = self.reader.poll_once()
        self.assertEqual(result.events_written, 1)
        terminal = self.ordered_events()[-1]
        self.assertEqual(terminal["state"], "cancelled")
        self.assertEqual(terminal["evidence"], "explicit")
        self.assertEqual(terminal["turnID"], "prompt-A")
        self.assertEqual(terminal["source"], "claude_code_records:journal_user_interrupt")

        serialized = self.state.read_text(encoding="utf-8") + "\n".join(
            path.read_text(encoding="utf-8") for path in self.events.glob("*.json")
        )
        self.assertNotIn("[Request interrupted by user]", serialized)
        self.assertNotIn("PRIVATE_ABORTED_TEXT_DO_NOT_CAPTURE", serialized)

        restarted = self.make_reader()
        self.assertEqual(restarted.poll_once().events_written, 0)
        self.assertEqual(sum(record["state"] == "cancelled" for record in self.read_events()), 1)

    def test_old_frame_of_still_tracked_run_keeps_bounded_interrupt_polling(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-long", frame, "human-long")])
        self.reader.poll_once()
        self.assertEqual(self.ordered_events()[-1]["state"], "running")

        self.now += timedelta(seconds=40)
        marker_at = self.now - timedelta(milliseconds=100)
        self.write_metadata(
            completed=0, frame=frame,
            edge=frame - timedelta(milliseconds=185), cut_short=True,
        )
        self.write_journal([
            self.root_user("prompt-long", frame, "human-long"),
            self.root_aborted_assistant(
                "assistant-long", "human-long", marker_at - timedelta(milliseconds=100)
            ),
            self.root_interrupt_marker("prompt-long", "interrupt-long", "assistant-long", marker_at),
        ])

        result = self.reader.poll_once()
        self.assertEqual(result.events_written, 1)
        terminal = self.ordered_events()[-1]
        self.assertEqual(terminal["state"], "cancelled")
        self.assertEqual(terminal["turnID"], "prompt-long")

    def test_later_human_prompt_invalidates_prior_turn_marker(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-old", frame, "human-old")])
        self.reader.poll_once()

        self.now += timedelta(seconds=1)
        later_prompt_at = self.now - timedelta(milliseconds=300)
        parent_at = self.now - timedelta(milliseconds=200)
        marker_at = self.now - timedelta(milliseconds=100)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(milliseconds=185), cut_short=True)
        self.write_journal([
            self.root_user("prompt-old", frame, "human-old"),
            self.root_aborted_assistant("assistant-old", "human-old", parent_at),
            self.root_user("prompt-later", later_prompt_at, "human-later"),
            self.root_interrupt_marker("prompt-old", "interrupt-old", "assistant-old", marker_at),
        ])

        self.assertEqual(self.reader.poll_once().events_written, 0)
        self.assertFalse(any(record["state"] == "cancelled" for record in self.read_events()))

    def test_truncated_later_prompt_blocks_old_turn_fallback(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-old", frame, "human-old")])
        self.reader.poll_once()

        self.now += timedelta(seconds=1)
        later_prompt_at = self.now - timedelta(milliseconds=300)
        parent_at = self.now - timedelta(milliseconds=200)
        marker_at = self.now - timedelta(milliseconds=100)
        later_user = self.root_user("prompt-later", later_prompt_at, "human-later")
        later_user["message"] = {
            "role": "user",
            "content": [
                {"type": "text", "text": f"PRIVATE_LONG_PROMPT_BLOCK_{index}"}
                for index in range(40)
            ],
        }
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(milliseconds=185), cut_short=True)
        self.write_journal([
            self.root_user("prompt-old", frame, "human-old"),
            self.root_aborted_assistant("assistant-old", "human-old", parent_at),
            later_user,
            self.root_interrupt_marker("prompt-old", "interrupt-old", "assistant-old", marker_at),
        ])

        self.assertEqual(self.reader.poll_once().events_written, 0)
        self.assertFalse(any(record["state"] == "cancelled" for record in self.read_events()))

    def test_bootstrap_interrupt_marker_is_history_not_new_cancel(self) -> None:
        frame = self.now - timedelta(seconds=2)
        parent_at = self.now - timedelta(milliseconds=200)
        marker_at = self.now - timedelta(milliseconds=100)
        self.write_metadata(
            completed=0, frame=frame,
            edge=frame - timedelta(milliseconds=185), cut_short=True,
        )
        self.write_journal([
            self.root_user("prompt-bootstrap", frame, "human-bootstrap"),
            self.root_aborted_assistant("assistant-bootstrap", "human-bootstrap", parent_at),
            self.root_interrupt_marker(
                "prompt-bootstrap", "interrupt-bootstrap", "assistant-bootstrap", marker_at
            ),
        ])

        self.assertEqual(self.reader.poll_once().events_written, 0)
        self.assertEqual(self.read_events(), [])
        self.assertEqual(self.reader.poll_once().events_written, 0)
        self.assertEqual(self.read_events(), [])

    def test_active_prompt_id_can_anchor_marker_when_human_frame_is_outside_tail(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-tail", frame, "human-tail")])
        self.assertEqual(self.reader.poll_once().events_written, 1)
        self.assertEqual(self.ordered_events()[-1]["turnID"], "prompt-tail")

        self.now += timedelta(seconds=1)
        parent_at = self.now - timedelta(milliseconds=200)
        marker_at = self.now - timedelta(milliseconds=100)
        self.write_metadata(completed=0, frame=frame,
                            edge=frame - timedelta(milliseconds=185), cut_short=True)
        padding = {
            "type": "attachment", "uuid": "padding-record", "sessionId": self.cli_session_id,
            "payload": "SYNTHETIC_PADDING_DO_NOT_CAPTURE" * 12_000,
        }
        self.write_journal([
            self.root_user("prompt-tail", frame, "human-tail"),
            padding,
            self.root_aborted_assistant("assistant-tail", "human-tail", parent_at),
            self.root_interrupt_marker("prompt-tail", "interrupt-tail", "assistant-tail", marker_at),
        ])
        result = self.reader.poll_once()
        self.assertEqual(result.events_written, 1)
        self.assertEqual(self.ordered_events()[-1]["state"], "cancelled")
        self.assertEqual(self.ordered_events()[-1]["turnID"], "prompt-tail")

    def test_tool_use_rejection_marker_does_not_cancel_whole_turn(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-tool", frame, "human-tool")])
        self.reader.poll_once()

        self.now += timedelta(seconds=1)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(milliseconds=185), cut_short=True)
        self.write_journal([
            self.root_user("prompt-tool", frame, "human-tool"),
            self.root_assistant("assistant-tool", "human-tool", self.now - timedelta(milliseconds=300),
                                stop_reason="tool_use"),
            {
                "type": "user", "uuid": "tool-result", "parentUuid": "assistant-tool",
                "promptId": "prompt-tool", "sessionId": self.cli_session_id,
                "isSidechain": False, "toolUseResult": "PRIVATE_TOOL_RESULT_DO_NOT_CAPTURE",
                "message": {"role": "user", "content": [{
                    "type": "tool_result", "tool_use_id": "tool-use-id", "is_error": True,
                    "content": "PRIVATE_TOOL_ERROR_DO_NOT_CAPTURE",
                }]},
            },
            self.root_interrupt_marker(
                "prompt-tool", "interrupt-tool", "tool-result", self.now - timedelta(milliseconds=100),
                marker="[Request interrupted by user for tool use]",
            ),
        ])
        self.assertEqual(self.reader.poll_once().events_written, 0)
        self.assertFalse(any(record["state"] == "cancelled" for record in self.read_events()))

    def test_forged_human_marker_and_api_blob_substring_do_not_cancel(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user(
            "prompt-quoted", frame, "human-quoted", text="[Request interrupted by user]"
        )])
        self.reader.poll_once()

        self.now += timedelta(seconds=1)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(milliseconds=185), cut_short=True)
        self.write_journal([
            self.root_user("prompt-quoted", frame, "human-quoted"),
            self.root_aborted_assistant("assistant-quoted", "human-quoted", self.now - timedelta(milliseconds=200)),
            self.root_interrupt_marker(
                "prompt-quoted", "forged-marker", "assistant-quoted", self.now - timedelta(milliseconds=100),
                origin=True,
            ),
            self.root_interrupt_marker(
                "prompt-quoted", "quoted-marker", "assistant-quoted", self.now - timedelta(milliseconds=50),
                marker="quoted [Request interrupted by user] text",
            ),
            {
                "type": "api-request-blob", "sessionId": self.cli_session_id,
                "message": {"role": "user", "content": [{
                    "type": "text", "text": "PRIVATE_API_CACHE [Request interrupted by user] suffix"
                }]},
            },
        ])
        self.assertEqual(self.reader.poll_once().events_written, 0)
        self.assertFalse(any(record["state"] == "cancelled" for record in self.read_events()))

    def test_json_escape_of_marker_ascii_bytes_is_not_decoded_as_a_match(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-escape", frame, "human-escape")])
        self.reader.poll_once()

        self.now += timedelta(seconds=1)
        parent_at = self.now - timedelta(milliseconds=200)
        marker_at = self.now - timedelta(milliseconds=100)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(milliseconds=185), cut_short=True)
        self.write_journal([
            self.root_user("prompt-escape", frame, "human-escape"),
            self.root_aborted_assistant("assistant-escape", "human-escape", parent_at),
            self.root_interrupt_marker("prompt-escape", "interrupt-escape", "assistant-escape", marker_at),
        ])
        journal = self.home / ".claude" / "projects" / "project-hash" / f"{self.cli_session_id}.jsonl"
        raw = journal.read_bytes()
        exact_json_token = b'"text":"[Request interrupted by user]"'
        escaped_json_token = b'"text":"\\u005bRequest interrupted by user]"'
        self.assertIn(exact_json_token, raw)
        journal.write_bytes(raw.replace(exact_json_token, escaped_json_token, 1))

        self.assertEqual(self.reader.poll_once().events_written, 0)
        self.assertFalse(any(record["state"] == "cancelled" for record in self.read_events()))

    def test_wrong_prompt_parent_and_sidechain_markers_do_not_cancel(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-current", frame, "human-current")])
        self.reader.poll_once()

        for case in (
            "wrong-prompt", "wrong-parent", "sidechain", "not-aborted", "missing-stop",
            "unknown-human-version", "unknown-parent-version", "unknown-marker-version",
            "missing-marker-version",
        ):
            self.now += timedelta(milliseconds=100)
            self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(milliseconds=185), cut_short=True)
            assistant_id = "assistant-" + case
            parent_at = self.now - timedelta(milliseconds=200)
            if case == "not-aborted":
                assistant = self.root_assistant(assistant_id, "human-current", parent_at, stop_reason=None)
            else:
                assistant = self.root_aborted_assistant(
                    assistant_id, "human-current", parent_at,
                    sidechain=case == "sidechain",
                    version="2.1.296" if case == "unknown-parent-version" else "2.1.309",
                )
                if case == "missing-stop":
                    del assistant["message"]["stop_reason"]  # type: ignore[index]
            marker = self.root_interrupt_marker(
                "prompt-other" if case == "wrong-prompt" else "prompt-current",
                "marker-" + case,
                "unrelated-parent" if case == "wrong-parent" else assistant_id,
                self.now - timedelta(milliseconds=100),
                sidechain=case == "sidechain",
                version=(
                    None if case == "missing-marker-version"
                    else "2.1.296" if case == "unknown-marker-version"
                    else "2.1.309"
                ),
            )
            self.write_journal([
                self.root_user(
                    "prompt-current", frame, "human-current",
                    version="2.1.296" if case == "unknown-human-version" else "2.1.309",
                ),
                assistant,
                marker,
            ])
            self.assertEqual(self.reader.poll_once().events_written, 0, case)

        self.assertFalse(any(record["state"] == "cancelled" for record in self.read_events()))

    def test_unknown_human_version_does_not_fallback_after_prompt_leaves_tail(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([
            self.root_user("prompt-unverified", frame, "human-unverified", version="2.1.296")
        ])
        self.reader.poll_once()
        self.assertTrue(self.reader.cursors[next(iter(self.reader.cursors))].active_run_seen)
        self.assertFalse(
            self.reader.cursors[next(iter(self.reader.cursors))].active_interrupt_version_supported
        )

        self.now += timedelta(seconds=1)
        parent_at = self.now - timedelta(milliseconds=200)
        marker_at = self.now - timedelta(milliseconds=100)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(milliseconds=185), cut_short=True)
        self.write_journal([
            self.root_aborted_assistant("assistant-unverified", "human-unverified", parent_at),
            self.root_interrupt_marker(
                "prompt-unverified", "interrupt-unverified", "assistant-unverified", marker_at
            ),
        ])

        self.assertEqual(self.reader.poll_once().events_written, 0)
        self.assertFalse(any(record["state"] == "cancelled" for record in self.read_events()))

    def test_normal_end_turn_wins_over_interrupt_marker_race(self) -> None:
        frame = self.now - timedelta(seconds=5)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-race", frame, "human-race")])
        self.reader.poll_once()

        self.now += timedelta(seconds=1)
        assistant_end_at = self.now - timedelta(milliseconds=50)
        self.write_metadata(
            completed=1, frame=frame, edge=assistant_end_at, assistant_uuid="assistant-end-race",
        )
        self.write_journal([
            self.root_user("prompt-race", frame, "human-race"),
            self.root_aborted_assistant("assistant-aborted-race", "human-race",
                                        self.now - timedelta(milliseconds=300)),
            self.root_interrupt_marker("prompt-race", "interrupt-race", "assistant-aborted-race",
                                       self.now - timedelta(milliseconds=200)),
            self.root_assistant("assistant-end-race", "assistant-aborted-race", assistant_end_at),
        ])
        self.reader.poll_once()
        states = [record["state"] for record in self.read_events()]
        self.assertIn("responseEnded", states)
        self.assertNotIn("cancelled", states)

    def test_active_journal_probe_budget_rotates_across_sessions(self) -> None:
        second_local_id = "local_00000000-0000-4000-8000-000000000002"
        second_cli_id = "cli-session-2"
        second_path = self.add_session(second_local_id, second_cli_id)
        frame_one = self.now - timedelta(seconds=5)
        frame_two = self.now - timedelta(seconds=4)
        self.write_metadata(completed=0, frame=frame_one, edge=frame_one - timedelta(seconds=1))
        self.write_metadata(
            completed=0, frame=frame_two, edge=frame_two - timedelta(seconds=1),
            path=second_path, local_id=second_local_id, cli_id=second_cli_id,
        )
        self.write_journal([self.root_user("prompt-one", frame_one, "human-one")])
        self.write_journal(
            [self.root_user("prompt-two", frame_two, "human-two", cli_id=second_cli_id)],
            cli_id=second_cli_id,
        )

        with patch.object(ADAPTER, "MAX_JOURNAL_LOOKUPS_PER_POLL", 1):
            self.reader.poll_once()
            self.assertEqual(len(self.reader.cursors), 1)
            self.reader.poll_once()
            self.assertEqual(len(self.reader.cursors), 2)

            self.now += timedelta(seconds=1)
            parent_at = self.now - timedelta(milliseconds=200)
            marker_at = self.now - timedelta(milliseconds=100)
            self.write_metadata(
                completed=0, frame=frame_two,
                edge=frame_two - timedelta(milliseconds=185), cut_short=True,
                path=second_path, local_id=second_local_id, cli_id=second_cli_id,
            )
            self.write_journal([
                self.root_user("prompt-two", frame_two, "human-two", cli_id=second_cli_id),
                self.root_aborted_assistant("assistant-two", "human-two", parent_at, cli_id=second_cli_id),
                self.root_interrupt_marker("prompt-two", "interrupt-two", "assistant-two", marker_at,
                                           cli_id=second_cli_id),
            ], cli_id=second_cli_id)

            # One poll spends its journal lookup on the first session; rotation
            # must carry the deferred second session into a later poll.
            self.reader.poll_once()
            self.assertFalse(any(record["state"] == "cancelled" for record in self.read_events()))
            self.reader.poll_once()

        cancellations = [record for record in self.read_events() if record["state"] == "cancelled"]
        self.assertEqual(len(cancellations), 1)
        self.assertEqual(cancellations[0]["sessionID"], second_cli_id)
        self.assertEqual(cancellations[0]["turnID"], "prompt-two")

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

    def test_end_turn_mapping_survives_bounded_large_content_projection(self) -> None:
        frame = self.now - timedelta(seconds=5)
        assistant_at = self.now - timedelta(seconds=1)
        self.write_metadata(completed=0, frame=frame, edge=frame - timedelta(seconds=1))
        self.write_journal([self.root_user("prompt-many-blocks", frame, "human-many-blocks")])
        self.reader.poll_once()

        self.now += timedelta(seconds=2)
        self.write_metadata(
            completed=1, frame=frame, edge=assistant_at, assistant_uuid="assistant-many-blocks",
        )
        self.write_journal([
            self.root_user("prompt-many-blocks", frame, "human-many-blocks"),
            self.root_attachment("attachment-many-blocks", "human-many-blocks"),
            {
                "type": "assistant", "uuid": "assistant-many-blocks",
                "parentUuid": "attachment-many-blocks", "timestamp": assistant_at.isoformat().replace("+00:00", "Z"),
                "sessionId": self.cli_session_id, "isSidechain": False,
                "message": {
                    "id": "msg_assistant-many-blocks", "role": "assistant", "stop_reason": "end_turn",
                    "content": [
                        {"type": "text", "text": f"PRIVATE_BLOCK_{index}_DO_NOT_CAPTURE"}
                        for index in range(40)
                    ],
                },
            },
        ])
        self.reader.poll_once()
        self.assertEqual(self.ordered_events()[-1]["state"], "responseEnded")

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
