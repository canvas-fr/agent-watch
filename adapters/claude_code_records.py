#!/usr/bin/env python3
"""Read Claude Code session metadata without decoding conversation content."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import time
from typing import Any


APP_ID = "claude_code"
ADAPTER_ID = "claude_code_records"
SCHEMA = "claude-code-session-metadata-v1"
EXPECTED_CLAUDE_VERSION = "4.4212.0"
LOCAL_SESSION_ID = re.compile(r"^local_[A-Za-z0-9_-]{1,128}$")
IDENTIFIER = re.compile(r"^[A-Za-z0-9._-]{1,256}$")
MAX_METADATA_BYTES = 256 * 1024
MAX_METADATA_BYTES_PER_POLL = 2 * 1024 * 1024
MAX_JOURNAL_BYTES = 256 * 1024
MAX_JOURNAL_BYTES_PER_POLL = 2 * 1024 * 1024
MAX_STATE_BYTES = 2 * 1024 * 1024
MAX_SESSIONS = 500
MAX_SESSIONS_PER_POLL = 64
MAX_DIRECTORY_ENTRIES = 2_000
MAX_PROJECT_ENTRIES = 5_000
MAX_JOURNAL_LOOKUPS_PER_POLL = 8
MAX_JOURNAL_RECORDS_PER_LOOKUP = 5_000
MAX_MESSAGE_BLOCKS = 32
MAX_JSON_DEPTH = 64
FRESH_FRAME_SECONDS = 30.0
FUTURE_TOLERANCE_SECONDS = 30.0
TIMESTAMP_MATCH_TOLERANCE_SECONDS = 0.001
SUPPORTED_CANCELLATION_CLI_VERSION = "2.1.309"
STANDARD_INTERRUPT_MARKER = b"[Request interrupted by user]"
TOOL_INTERRUPT_MARKER = b"[Request interrupted by user for tool use]"
_ORIGIN_OBJECT = object()

METADATA_FIELDS = frozenset({
    "sessionId", "cliSessionId", "completedTurns", "latestUserFrameAt",
    "lastTurnEdgeAt", "lastTurnCutShort", "isArchived", "errorCategory", "errorAt",
    "lastAssistantUuid",
})
JOURNAL_FIELDS = frozenset({
    "type", "timestamp", "promptId", "sessionId", "parentUuid", "isSidechain", "uuid", "message",
    "origin", "isMeta", "isAbortedMidStream", "toolUseResult", "version",
})
ROOT_FIELD_TOKENS = {
    (f'"{field}"').encode("ascii"): field
    for field in METADATA_FIELDS | JOURNAL_FIELDS
}
STRING_FIELDS = frozenset({
    "sessionId", "cliSessionId", "errorCategory", "type", "promptId",
    "parentUuid", "lastAssistantUuid", "uuid", "version",
})
TIMESTAMP_FIELDS = frozenset({"latestUserFrameAt", "lastTurnEdgeAt", "errorAt", "timestamp"})
NUMBER_FIELDS = frozenset({"completedTurns"})
BOOLEAN_FIELDS = frozenset({"lastTurnCutShort", "isArchived", "isSidechain", "isMeta", "isAbortedMidStream"})


def _load_desktop_reader() -> Any:
    path = Path(__file__).with_name("claude_desktop.py")
    spec = importlib.util.spec_from_file_location("agent_watch_claude_desktop_reader", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("claude_desktop_reader_unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


DESKTOP = _load_desktop_reader()
MetadataError = DESKTOP.MetadataError


class SelectedRootJSONReader(DESKTOP.StatusOnlyJSONReader):
    """Reuse the Desktop lexical walker while selecting this schema's root keys."""

    def __init__(self, raw: bytes, allowed_root_fields: frozenset[str]):
        super().__init__(raw, allowed_root_fields, scan_nested_types=False)

    def _object(self, index: int, depth: int, root: bool) -> int:
        if not root:
            return super()._object(index, depth, root)
        if depth > MAX_JSON_DEPTH:
            raise MetadataError("json_too_deep")
        index = self._space(index + 1)
        if index < len(self.raw) and self.raw[index] == 125:
            return index + 1
        seen_selected: set[str] = set()
        while True:
            key_start = index
            key_end = self._string_end(key_start)
            key_token = self.raw[key_start:key_end]
            if b"\\" in key_token:
                raise MetadataError("escaped_root_key")
            field_name = ROOT_FIELD_TOKENS.get(key_token)
            if field_name not in self.allowed_root_fields:
                field_name = None
            if field_name is not None and field_name in seen_selected:
                raise MetadataError("duplicate_selected_field")
            if field_name is not None:
                seen_selected.add(field_name)
            index = self._space(key_end)
            if index >= len(self.raw) or self.raw[index] != 58:
                raise MetadataError("missing_colon")
            value_start = self._space(index + 1)
            end, value = self._value(value_start, depth + 1, root_field=field_name)
            if field_name is not None:
                self.fields[field_name] = value
            index = self._space(end)
            if index < len(self.raw) and self.raw[index] == 125:
                return index + 1
            if index >= len(self.raw) or self.raw[index] != 44:
                raise MetadataError("invalid_object_separator")
            index = self._space(index + 1)

    def _value(
        self,
        index: int,
        depth: int,
        root_field: str | None = None,
        nested_type: bool = False,
    ) -> tuple[int, Any]:
        if root_field is None:
            return super()._value(index, depth, root_field, nested_type)
        index = self._space(index)
        if index >= len(self.raw):
            raise MetadataError("missing_value")
        character = self.raw[index]
        if root_field == "origin":
            end, _ = super()._value(index, depth, root_field, nested_type)
            return end, _ORIGIN_OBJECT if character == 123 else None
        if root_field == "message" and character == 123:
            return self._message_stop_reason(index, depth + 1)
        if root_field in STRING_FIELDS and character == 34:
            maximum = 64 if root_field == "errorCategory" else 256
            return self._selected_string(index, maximum)
        if root_field in TIMESTAMP_FIELDS and character == 34:
            return self._selected_string(index, 80)
        if root_field in NUMBER_FIELDS | TIMESTAMP_FIELDS | BOOLEAN_FIELDS and character not in (34, 91, 123):
            return self._primitive(index)
        return super()._value(index, depth, root_field, nested_type)

    def _message_stop_reason(self, index: int, depth: int) -> tuple[int, dict[str, Any]]:
        if depth > MAX_JSON_DEPTH:
            raise MetadataError("json_too_deep")
        index = self._space(index + 1)
        if index < len(self.raw) and self.raw[index] == 125:
            return index + 1, {}
        selected: dict[str, Any] = {}
        seen_selected: set[bytes] = set()
        message_fields = {b'"role"', b'"id"', b'"stop_reason"', b'"content"'}
        while True:
            key_start = index
            key_end = self._string_end(key_start)
            key_token = self.raw[key_start:key_end]
            if b"\\" in key_token:
                raise MetadataError("escaped_message_key")
            index = self._space(key_end)
            if index >= len(self.raw) or self.raw[index] != 58:
                raise MetadataError("missing_colon")
            value_start = self._space(index + 1)
            if key_token in message_fields:
                if key_token in seen_selected:
                    raise MetadataError("duplicate_selected_field")
                seen_selected.add(key_token)
                field_name = key_token[1:-1].decode("ascii")
                if field_name in {"role", "id"}:
                    if value_start < len(self.raw) and self.raw[value_start] == 34:
                        end, value = self._selected_string(value_start, 128)
                        selected[field_name] = value
                    else:
                        end, _ = super()._value(value_start, depth + 1)
                        selected[field_name] = None
                elif field_name == "stop_reason":
                    selected["stop_reason_present"] = True
                    selected["stop_reason_is_null"] = self.raw.startswith(b"null", value_start)
                    if value_start < len(self.raw) and self.raw[value_start] == 34:
                        end, value = self._selected_string(value_start, 64)
                        selected["stop_reason"] = value
                    else:
                        end, _ = super()._value(value_start, depth + 1)
                        selected["stop_reason"] = None
                else:
                    end, value = self._message_content(value_start, depth + 1)
                    selected.update(value)
            else:
                end, _ = super()._value(value_start, depth + 1)
            index = self._space(end)
            if index < len(self.raw) and self.raw[index] == 125:
                return index + 1, selected
            if index >= len(self.raw) or self.raw[index] != 44:
                raise MetadataError("invalid_object_separator")
            index = self._space(index + 1)

    def _message_content(self, index: int, depth: int) -> tuple[int, dict[str, Any]]:
        if depth > MAX_JSON_DEPTH:
            raise MetadataError("json_too_deep")
        if index >= len(self.raw) or self.raw[index] != 91:
            end, _ = super()._value(index, depth)
            return end, {"content_is_array": False, "content_block_count": 0,
                         "content_block_types": [], "standard_interrupt_exact": False,
                         "tool_interrupt_exact": False}

        index = self._space(index + 1)
        block_types: list[str | None] = []
        block_count = 0
        standard_matches = 0
        tool_matches = 0
        if index < len(self.raw) and self.raw[index] == 93:
            return index + 1, {"content_is_array": True, "content_block_count": 0,
                               "content_block_types": [], "standard_interrupt_exact": False,
                               "tool_interrupt_exact": False}

        while True:
            value_start = self._space(index)
            if block_count >= MAX_MESSAGE_BLOCKS:
                # Skip excess blocks so `stop_reason` can still support the
                # independent completion counter guard. Marker matching fails
                # closed once the message has more than one content block.
                end, _ = super()._value(value_start, depth + 1)
                block_count += 1
            elif value_start < len(self.raw) and self.raw[value_start] == 123:
                end, block = self._message_content_block(value_start, depth + 1)
                block_types.append(block.get("type"))
                standard_matches += bool(block.get("standard_interrupt_exact"))
                tool_matches += bool(block.get("tool_interrupt_exact"))
                block_count += 1
            else:
                end, _ = super()._value(value_start, depth + 1)
                block_types.append(None)
                block_count += 1
            index = self._space(end)
            if index < len(self.raw) and self.raw[index] == 93:
                return index + 1, {
                    "content_is_array": True,
                    "content_block_count": block_count,
                    "content_block_types": block_types,
                    "standard_interrupt_exact": standard_matches == 1 and len(block_types) == 1,
                    "tool_interrupt_exact": tool_matches == 1 and len(block_types) == 1,
                }
            if index >= len(self.raw) or self.raw[index] != 44:
                raise MetadataError("invalid_array_separator")
            index = self._space(index + 1)

    def _message_content_block(self, index: int, depth: int) -> tuple[int, dict[str, Any]]:
        if depth > MAX_JSON_DEPTH:
            raise MetadataError("json_too_deep")
        index = self._space(index + 1)
        block_type: str | None = None
        standard_interrupt_exact = False
        tool_interrupt_exact = False
        seen_selected: set[bytes] = set()
        selected_fields = {b'"type"', b'"text"'}
        if index < len(self.raw) and self.raw[index] == 125:
            return index + 1, {"type": None}
        while True:
            key_start = index
            key_end = self._string_end(key_start)
            key_token = self.raw[key_start:key_end]
            if b"\\" in key_token:
                raise MetadataError("escaped_message_content_key")
            index = self._space(key_end)
            if index >= len(self.raw) or self.raw[index] != 58:
                raise MetadataError("missing_colon")
            value_start = self._space(index + 1)
            if key_token in selected_fields:
                if key_token in seen_selected:
                    raise MetadataError("duplicate_selected_field")
                seen_selected.add(key_token)
                if key_token == b'"type"':
                    if value_start < len(self.raw) and self.raw[value_start] == 34:
                        end, block_type = self._selected_string(value_start, 64)
                    else:
                        end, _ = super()._value(value_start, depth + 1)
                elif value_start < len(self.raw) and self.raw[value_start] == 34:
                    end = self._string_end(value_start)
                    standard_token = b'"' + STANDARD_INTERRUPT_MARKER + b'"'
                    tool_token = b'"' + TOOL_INTERRUPT_MARKER + b'"'
                    standard_interrupt_exact = (
                        end - value_start == len(standard_token)
                        and self.raw.startswith(standard_token, value_start)
                    )
                    tool_interrupt_exact = (
                        end - value_start == len(tool_token)
                        and self.raw.startswith(tool_token, value_start)
                    )
                else:
                    end, _ = super()._value(value_start, depth + 1)
            else:
                end, _ = super()._value(value_start, depth + 1)
            index = self._space(end)
            if index < len(self.raw) and self.raw[index] == 125:
                return index + 1, {
                    "type": block_type,
                    "standard_interrupt_exact": standard_interrupt_exact and block_type == "text",
                    "tool_interrupt_exact": tool_interrupt_exact and block_type == "text",
                }
            if index >= len(self.raw) or self.raw[index] != 44:
                raise MetadataError("invalid_object_separator")
            index = self._space(index + 1)


@dataclass(frozen=True)
class SessionMetadata:
    session_id: str
    cli_session_id: str
    completed_turns: int
    latest_user_frame_at: float | None
    last_turn_edge_at: float | None
    last_turn_cut_short: bool
    is_archived: bool
    error_category: str | None
    error_at: float | None
    last_assistant_uuid: str | None


@dataclass(frozen=True)
class JournalProjection:
    latest_prompt_id: str | None = None
    assistant_prompt_id: str | None = None
    assistant_timestamp: float | None = None
    cancellation_prompt_id: str | None = None
    cancellation_timestamp: float | None = None
    cancellation_signature: str | None = None
    current_human_prompt_id: str | None = None
    current_human_version_supported: bool = False
    current_human_prompt_seen: bool = False
    bytes_read: int = 0


@dataclass(frozen=True)
class SessionFile:
    path: Path
    info: os.stat_result


@dataclass
class Cursor:
    device: int
    inode: int
    modified_ns: int
    size: int
    session_id: str
    cli_session_id: str
    completed_turns: int
    latest_user_frame_at: float | None
    last_turn_edge_at: float | None
    last_turn_cut_short: bool
    is_archived: bool
    error_category_present: bool
    error_at: float | None
    last_assistant_uuid: str | None
    turn_id: str | None = None
    active_frame_at: float | None = None
    active_run_seen: bool = False
    hook_sequence: int = 0
    sequence: int = 0
    last_observed_at: str | None = None
    last_interrupt_signature: str | None = None
    active_interrupt_version_supported: bool = False

    def to_json(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_json(cls, value: Any) -> Cursor | None:
        if not isinstance(value, dict):
            return None
        try:
            integer_fields = ("device", "inode", "modified_ns", "size", "completed_turns", "hook_sequence", "sequence")
            if any(not isinstance(value.get(name), int) or isinstance(value.get(name), bool) or value[name] < 0
                   for name in integer_fields):
                return None
            for name in ("latest_user_frame_at", "last_turn_edge_at", "error_at", "active_frame_at"):
                item = value.get(name)
                if item is not None and (
                    isinstance(item, bool) or not isinstance(item, (int, float)) or not math.isfinite(item)
                ):
                    return None
            for name in ("last_turn_cut_short", "is_archived", "error_category_present", "active_run_seen"):
                if not isinstance(value.get(name), bool):
                    return None
            active_interrupt_version_supported = value.get("active_interrupt_version_supported", False)
            if not isinstance(active_interrupt_version_supported, bool):
                return None
            if not isinstance(value.get("session_id"), str) or not LOCAL_SESSION_ID.fullmatch(value["session_id"]):
                return None
            if not isinstance(value.get("cli_session_id"), str) or not IDENTIFIER.fullmatch(value["cli_session_id"]):
                return None
            assistant_uuid = value.get("last_assistant_uuid")
            if assistant_uuid is not None and _identifier(assistant_uuid) is None:
                return None
            turn_id = value.get("turn_id")
            if turn_id is not None and not DESKTOP._bounded_string(turn_id, 256):
                return None
            last_observed_at = value.get("last_observed_at")
            if last_observed_at is not None and not DESKTOP._bounded_string(last_observed_at, 80):
                return None
            interrupt_signature = value.get("last_interrupt_signature")
            if interrupt_signature is not None and (
                not isinstance(interrupt_signature, str)
                or not re.fullmatch(r"[0-9a-f]{64}", interrupt_signature)
            ):
                return None
            return cls(**{
                name: value.get(
                    name,
                    False if name == "active_interrupt_version_supported" else None,
                )
                for name in cls.__dataclass_fields__
            })
        except (KeyError, TypeError, ValueError):
            return None


@dataclass
class ScanSummary:
    events_written: int = 0
    diagnostic: str = "none"
    app_version: str = "unknown"
    validation: str = "schema-compatible"

    def to_json(self) -> dict[str, Any]:
        status = "ok" if self.diagnostic in {"none", "no_status_signal", "no_records"} else "degraded"
        return {
            "adapter": ADAPTER_ID,
            "status": status,
            "eventsWritten": self.events_written,
            "diagnostic": self.diagnostic,
            "schema": SCHEMA,
            "validation": self.validation,
            "appVersion": self.app_version,
        }


def _sha256(*parts: str) -> str:
    return hashlib.sha256("\0".join(parts).encode("utf-8")).hexdigest()


def _identifier(value: Any, maximum: int = 256) -> str | None:
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        return None
    try:
        if len(value.encode("utf-8")) > maximum:
            return None
    except UnicodeEncodeError:
        return None
    return value


def _timestamp(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, str):
        if not value or len(value) > 80:
            return None
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                return None
            result = parsed.astimezone(timezone.utc).timestamp()
        except (ValueError, OverflowError):
            return None
    elif isinstance(value, (int, float)):
        result = float(value)
        if not math.isfinite(result):
            return None
        magnitude = abs(result)
        if magnitude > 10**17:
            result /= 1_000_000_000
        elif magnitude > 10**14:
            result /= 1_000_000
        elif magnitude > 10**11:
            result /= 1_000
    else:
        return None
    return result if 0 < result < 10**13 else None


def _parse_metadata(raw: bytes, filename_session_id: str) -> SessionMetadata:
    fields, _ = SelectedRootJSONReader(raw, METADATA_FIELDS).parse()
    session_id = fields.get("sessionId")
    cli_session_id = _identifier(fields.get("cliSessionId"))
    if not isinstance(session_id, str) or not LOCAL_SESSION_ID.fullmatch(session_id):
        raise MetadataError("invalid_session_id")
    if session_id != filename_session_id or cli_session_id is None:
        raise MetadataError("session_identity_mismatch")
    completed_turns = fields.get("completedTurns", 0)
    if (not isinstance(completed_turns, int) or isinstance(completed_turns, bool)
            or completed_turns < 0 or completed_turns > 10**12):
        raise MetadataError("invalid_completed_turns")
    archived = fields.get("isArchived", False)
    cut_short = fields.get("lastTurnCutShort", False)
    if not isinstance(archived, bool) or not isinstance(cut_short, bool):
        raise MetadataError("invalid_session_flags")
    category = fields.get("errorCategory")
    if category is not None:
        try:
            if not isinstance(category, str) or len(category.encode("utf-8")) > 64:
                category = None
        except UnicodeEncodeError:
            category = None
    return SessionMetadata(
        session_id=session_id,
        cli_session_id=cli_session_id,
        completed_turns=completed_turns,
        latest_user_frame_at=_timestamp(fields.get("latestUserFrameAt")),
        last_turn_edge_at=_timestamp(fields.get("lastTurnEdgeAt")),
        last_turn_cut_short=cut_short,
        is_archived=archived,
        error_category=category,
        error_at=_timestamp(fields.get("errorAt")),
        last_assistant_uuid=_identifier(fields.get("lastAssistantUuid")),
    )


def _support_roots(home: Path) -> tuple[tuple[str, Path], ...]:
    application_support = home / "Library" / "Application Support"
    return tuple(
        (profile, application_support / profile / "claude-code-sessions")
        for profile in ("Claude-3p", "Claude")
    )


def _plain_directory(path: Path) -> bool:
    try:
        info = path.lstat()
        return stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode)
    except OSError:
        return False


def _read_regular(path: Path, maximum_bytes: int) -> tuple[bytes, os.stat_result] | None:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return None
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum_bytes:
            return None
        chunks: list[bytes] = []
        remaining = maximum_bytes + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        after = os.fstat(descriptor)
        if (len(raw) != info.st_size or len(raw) > maximum_bytes
                or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                != (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)):
            return None
        return raw, after
    finally:
        os.close(descriptor)


def _load_state(path: Path) -> tuple[dict[str, Cursor], int, str]:
    opened = _read_regular(path, MAX_STATE_BYTES)
    if opened is None:
        if not path.exists():
            return {}, 0, "none"
        return {}, 0, "state_unavailable"
    raw, _ = opened
    try:
        value = json.loads(raw)
        if not isinstance(value, dict) or value.get("schema") != 1 or not isinstance(value.get("sessions"), dict):
            return {}, 0, "state_reset"
        cursors: dict[str, Cursor] = {}
        for key, item in value["sessions"].items():
            if isinstance(key, str) and re.fullmatch(r"[0-9a-f]{64}", key):
                cursor = Cursor.from_json(item)
                if cursor is not None:
                    cursors[key] = cursor
        rotation = value.get("rotation", 0)
        if not isinstance(rotation, int) or isinstance(rotation, bool) or rotation < 0:
            rotation = 0
        return cursors, rotation, "none"
    except (UnicodeError, json.JSONDecodeError, TypeError):
        return {}, 0, "state_reset"


def _save_state(path: Path, cursors: dict[str, Cursor], rotation: int) -> None:
    bounded = dict(sorted(cursors.items())[-MAX_SESSIONS:])
    payload = json.dumps(
        {"schema": 1, "sessions": {key: cursor.to_json() for key, cursor in bounded.items()},
         "rotation": max(0, rotation)},
        separators=(",", ":"), sort_keys=True,
    ).encode("utf-8")
    DESKTOP._atomic_private_write(path.parent, path.name, payload)


def _hook_state_path(agent_watch_root: Path, cli_session_id: str) -> Path:
    key = _sha256(APP_ID, cli_session_id)
    return agent_watch_root / "metadata" / f"{key}.json"


def _read_hook_turn(agent_watch_root: Path, cli_session_id: str) -> tuple[str | None, int]:
    opened = _read_regular(_hook_state_path(agent_watch_root, cli_session_id), 16 * 1024)
    if opened is None:
        return None, 0
    raw, _ = opened
    try:
        value = json.loads(raw)
    except (UnicodeError, json.JSONDecodeError):
        return None, 0
    if not isinstance(value, dict):
        return None, 0
    turn_id = _identifier(value.get("turnID"))
    sequence = value.get("sequence", 0)
    if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence < 0:
        sequence = 0
    return turn_id, sequence


def _journal_index(home: Path) -> tuple[dict[str, Path], str]:
    claude_directory = home / ".claude"
    root = claude_directory / "projects"
    if not _plain_directory(claude_directory) or not _plain_directory(root):
        return {}, "journal_unavailable"
    index: dict[str, Path] = {}
    visited = 0
    try:
        projects = sorted(os.scandir(root), key=lambda entry: entry.name)
        for project in projects:
            visited += 1
            if visited > MAX_PROJECT_ENTRIES:
                return index, "journal_index_limited"
            if project.name.startswith(".") or not project.is_dir(follow_symlinks=False):
                continue
            with os.scandir(project.path) as records:
                for record in records:
                    visited += 1
                    if visited > MAX_PROJECT_ENTRIES:
                        return index, "journal_index_limited"
                    if not record.name.endswith(".jsonl"):
                        continue
                    session_id = record.name[:-6]
                    if not IDENTIFIER.fullmatch(session_id) or not record.is_file(follow_symlinks=False):
                        continue
                    info = record.stat(follow_symlinks=False)
                    if stat.S_ISREG(info.st_mode):
                        index.setdefault(session_id, Path(record.path))
    except OSError:
        return index, "journal_index_error"
    return index, "none"


def _journal_prompt_id(
    path: Path,
    cli_session_id: str,
    latest_user_frame_at: float | None,
    last_assistant_uuid: str | None,
    remaining_budget: int,
    tracked_prompt_id: str | None = None,
    tracked_version_supported: bool = False,
) -> JournalProjection:
    try:
        info = path.lstat()
    except OSError:
        return JournalProjection()
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        return JournalProjection()
    window_size = min(info.st_size, MAX_JOURNAL_BYTES, remaining_budget)
    if window_size <= 0:
        return JournalProjection()
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return JournalProjection()
    try:
        current = os.fstat(descriptor)
        if (not stat.S_ISREG(current.st_mode) or current.st_dev != info.st_dev
                or current.st_ino != info.st_ino or current.st_size != info.st_size
                or current.st_mtime_ns != info.st_mtime_ns):
            return JournalProjection()
        start = max(0, current.st_size - window_size)
        os.lseek(descriptor, start, os.SEEK_SET)
        raw = bytearray()
        while len(raw) < window_size:
            chunk = os.read(descriptor, min(64 * 1024, window_size - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        after = os.fstat(descriptor)
        if (len(raw) != window_size
                or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                != (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns)):
            return JournalProjection()
    finally:
        os.close(descriptor)
    data = bytes(raw)
    if start > 0:
        newline = data.find(b"\n")
        data = b"" if newline < 0 else data[newline + 1:]
    # A growing final record is never treated as evidence until its newline
    # commits the record to the JSONL journal.
    if data and not data.endswith(b"\n"):
        newline = data.rfind(b"\n")
        data = b"" if newline < 0 else data[:newline + 1]
    bytes_read = len(raw)
    latest_prompt: str | None = None
    current_human_prompt: str | None = None
    current_human_version_supported = False
    current_human_prompt_seen = False
    assistant_prompt: str | None = None
    assistant_timestamp: float | None = None
    cancellation_prompt: str | None = None
    cancellation_timestamp: float | None = None
    cancellation_signature: str | None = None
    prompt_by_uuid: dict[str, str] = {}
    assistant_by_uuid: dict[str, dict[str, Any]] = {}
    records_read = 0
    for line in data.splitlines():
        if not line:
            continue
        records_read += 1
        if records_read > MAX_JOURNAL_RECORDS_PER_LOOKUP:
            # Do not make decisions from only the beginning of a bounded tail.
            return JournalProjection(bytes_read=bytes_read)
        try:
            fields, _ = SelectedRootJSONReader(line, JOURNAL_FIELDS).parse()
        except MetadataError:
            continue
        if fields.get("isSidechain") is True:
            continue
        session_id = fields.get("sessionId")
        if session_id is not None and session_id != cli_session_id:
            continue
        prompt_id = _identifier(fields.get("promptId"))
        uuid = _identifier(fields.get("uuid"))
        parent_uuid = _identifier(fields.get("parentUuid"))
        record_prompt = prompt_id or (prompt_by_uuid.get(parent_uuid) if parent_uuid else None)
        timestamp = _timestamp(fields.get("timestamp"))

        message = fields.get("message") if isinstance(fields.get("message"), dict) else {}
        content_types = message.get("content_block_types")
        human_prompt_record = (
            fields.get("type") == "user"
            and fields.get("sessionId") == cli_session_id
            and fields.get("isSidechain") is False
            and fields.get("isMeta") is not True
            and fields.get("origin") is _ORIGIN_OBJECT
            and "toolUseResult" not in fields
            and message.get("role") == "user"
        )
        content_types_complete = (
            isinstance(content_types, list)
            and message.get("content_block_count") == len(content_types)
        )
        if (human_prompt_record and content_types_complete
                and "tool_result" not in content_types):
            current_human_prompt_seen = True
            current_human_prompt = prompt_id
            current_human_version_supported = (
                fields.get("version") == SUPPORTED_CANCELLATION_CLI_VERSION
            )
        elif human_prompt_record and not content_types_complete:
            # The block cap may have hidden a tool-result child. Treat the
            # current human prompt as unresolved so an older tracked prompt
            # cannot fall back to cancellation evidence from the truncated tail.
            current_human_prompt_seen = True
            current_human_prompt = None
            current_human_version_supported = False

        if (fields.get("type") == "user"
                and latest_user_frame_at is not None
                and timestamp is not None and prompt_id is not None
                and abs(timestamp - latest_user_frame_at) <= TIMESTAMP_MATCH_TOLERANCE_SECONDS):
            latest_prompt = prompt_id
            record_prompt = prompt_id

        if uuid is not None and record_prompt is not None:
            prompt_by_uuid[uuid] = record_prompt
        if fields.get("type") == "assistant" and uuid is not None:
            assistant_by_uuid[uuid] = {
                "session_id": session_id,
                "prompt_id": record_prompt,
                "is_sidechain": fields.get("isSidechain"),
                "is_meta": fields.get("isMeta"),
                "is_aborted_mid_stream": fields.get("isAbortedMidStream"),
                "version": fields.get("version"),
                "message_role": message.get("role"),
                "message_id": _identifier(message.get("id")),
                "stop_reason_is_null": message.get("stop_reason_is_null") is True,
                "timestamp": timestamp,
            }

        if (cancellation_signature is None
                and fields.get("type") == "user"
                and fields.get("sessionId") == cli_session_id
                and fields.get("isSidechain") is False
                and fields.get("isMeta") is not True
                and "origin" not in fields
                and fields.get("version") == SUPPORTED_CANCELLATION_CLI_VERSION
                and "toolUseResult" not in fields
                and message.get("role") == "user"
                and message.get("content_is_array") is True
                and message.get("content_block_count") == 1
                and message.get("content_block_types") == ["text"]
                and message.get("standard_interrupt_exact") is True
                and message.get("tool_interrupt_exact") is False
                and prompt_id is not None
                and ((current_human_prompt_seen and prompt_id == current_human_prompt
                      and current_human_version_supported
                      and (prompt_id == latest_prompt or prompt_id == tracked_prompt_id))
                     or (not current_human_prompt_seen and tracked_prompt_id is not None
                         and tracked_version_supported
                         and prompt_id == tracked_prompt_id))
                and uuid is not None and parent_uuid is not None
                and timestamp is not None
                and latest_user_frame_at is not None
                and timestamp >= latest_user_frame_at):
            parent = assistant_by_uuid.get(parent_uuid)
            if (parent is not None
                    and parent.get("session_id") == cli_session_id
                    and (parent.get("prompt_id") == prompt_id
                         or (parent.get("prompt_id") is None and tracked_prompt_id == prompt_id))
                    and parent.get("is_sidechain") is False
                    and parent.get("is_meta") is not True
                    and parent.get("is_aborted_mid_stream") is True
                    and parent.get("version") == SUPPORTED_CANCELLATION_CLI_VERSION
                    and parent.get("message_role") == "assistant"
                    and parent.get("message_id") is not None
                    and parent.get("stop_reason_is_null") is True):
                cancellation_prompt = prompt_id
                cancellation_timestamp = timestamp
                cancellation_signature = _sha256(
                    "claude-code-user-interrupt-v1", cli_session_id,
                    prompt_id, uuid, parent_uuid,
                )

        if (fields.get("type") == "assistant" and uuid == last_assistant_uuid
              and last_assistant_uuid is not None
              and timestamp is not None
              and message.get("stop_reason") == "end_turn"):
            assistant_prompt = record_prompt
            assistant_timestamp = timestamp
    return JournalProjection(
        latest_prompt_id=latest_prompt,
        assistant_prompt_id=assistant_prompt,
        assistant_timestamp=assistant_timestamp,
        cancellation_prompt_id=cancellation_prompt,
        cancellation_timestamp=cancellation_timestamp,
        cancellation_signature=cancellation_signature,
        current_human_prompt_id=current_human_prompt,
        current_human_version_supported=current_human_version_supported,
        current_human_prompt_seen=current_human_prompt_seen,
        bytes_read=bytes_read,
    )


def _frame_is_fresh(frame_at: float | None, now_epoch: float) -> bool:
    if frame_at is None:
        return False
    age = now_epoch - frame_at
    return -FUTURE_TOLERANCE_SECONDS <= age <= FRESH_FRAME_SECONDS


def _turn_id(cli_session_id: str, frame_at: float | None) -> str:
    marker = "none" if frame_at is None else format(frame_at, ".6f")
    return _sha256("claude-code-metadata-turn-v1", cli_session_id, marker)


def _observe_time(value: float | None, now: datetime) -> datetime:
    if value is None:
        return now
    try:
        candidate = datetime.fromtimestamp(value, tz=timezone.utc)
    except (OverflowError, OSError, ValueError):
        return now
    if candidate > now + timedelta(seconds=FUTURE_TOLERANCE_SECONDS):
        return now
    return candidate


def _event_record(
    cli_session_id: str,
    turn_id: str,
    state: str,
    evidence: str,
    source: str,
    signature: str,
    sequence: int,
    observed_at: datetime,
    previous_observed_at: str | None,
) -> tuple[dict[str, Any], str]:
    event_id = _sha256("claude-code-record-event-v1", cli_session_id, turn_id, state, source, signature)
    observed_text, observed = DESKTOP._timestamp(observed_at, previous_observed_at)
    return ({
        "id": event_id,
        "appID": APP_ID,
        "sessionID": cli_session_id,
        "turnID": turn_id,
        "state": state,
        "evidence": evidence,
        "observedAt": observed_text,
        "sequence": sequence,
        "source": source,
    }, observed.isoformat(timespec="microseconds").replace("+00:00", "Z"))


def _write_event(directory: Path, event: dict[str, Any]) -> None:
    event_id = event.get("id")
    if not isinstance(event_id, str) or not re.fullmatch(r"[0-9a-f]{64}", event_id):
        raise OSError("invalid_event_id")
    payload = json.dumps(event, separators=(",", ":"), sort_keys=True).encode("utf-8") + b"\n"
    DESKTOP._atomic_private_write(directory, f"{event_id}.json", payload)


@dataclass(frozen=True)
class PlannedEvent:
    state: str
    evidence: str
    source: str
    signature: str
    turn_id: str
    observed_at: datetime


class ClaudeCodeRecordsReader:
    """Poll bounded Claude Code session metadata and emit canonical events."""

    def __init__(
        self,
        home: Path | None = None,
        roots: tuple[tuple[str, Path], ...] | None = None,
        events_directory: Path | None = None,
        state_file: Path | None = None,
        app_bundle: Path = Path("/Applications/Claude.app"),
        now: Any = lambda: datetime.now(timezone.utc),
    ):
        self.home = home or Path.home()
        self.roots = roots or _support_roots(self.home)
        watch_root = self.home / "Library" / "Application Support" / "Agent Watch"
        self.agent_watch_root = watch_root
        self.events_directory = events_directory or watch_root / "events"
        self.state_file = state_file or watch_root / "metadata" / "claude_code_records_state.json"
        self.app_version = DESKTOP.app_version(app_bundle)
        self.validation = (
            "schema-confirmed-4.4212.0" if self.app_version == EXPECTED_CLAUDE_VERSION
            else "schema-compatible"
        )
        self.now = now
        self.cursors, self.rotation, self.state_diagnostic = _load_state(self.state_file)

    def poll_once(self) -> ScanSummary:
        summary = ScanSummary(app_version=self.app_version, validation=self.validation)
        if self.state_diagnostic != "none":
            summary.diagnostic = self.state_diagnostic
        files, scan_diagnostic = self._list_sessions()
        if scan_diagnostic == "store_unavailable":
            summary.diagnostic = scan_diagnostic
            return summary
        if scan_diagnostic not in {"none", "no_records"}:
            summary.diagnostic = scan_diagnostic
        if not files:
            self.rotation = 0
            if summary.diagnostic == "none":
                summary.diagnostic = "no_records"
            self._save(summary)
            return summary

        now = self.now().astimezone(timezone.utc)
        now_epoch = now.timestamp()
        start_index = self.rotation % len(files)
        ordered = files[start_index:] + files[:start_index]
        metadata_budget = MAX_METADATA_BYTES_PER_POLL
        journal_budget = MAX_JOURNAL_BYTES_PER_POLL
        journal_lookups = 0
        journal_index: dict[str, Path] | None = None
        visited = 0
        stop_before_current = False
        seen_cli_sessions: set[str] = set()

        for record in ordered:
            if visited >= MAX_SESSIONS_PER_POLL:
                break
            visited += 1
            if record.info.st_size > metadata_budget:
                summary.diagnostic = "scan_limited"
                stop_before_current = True
                break
            opened = _read_regular(record.path, MAX_METADATA_BYTES)
            if opened is None:
                summary.diagnostic = "metadata_unavailable"
                continue
            raw, info = opened
            metadata_budget -= len(raw)
            if (info.st_dev != record.info.st_dev or info.st_ino != record.info.st_ino
                    or info.st_size != record.info.st_size or info.st_mtime_ns != record.info.st_mtime_ns):
                if summary.diagnostic == "none":
                    summary.diagnostic = "metadata_unavailable"
                continue
            try:
                filename_session_id = record.path.name[:-5]
                metadata = _parse_metadata(raw, filename_session_id)
            except MetadataError as error:
                summary.diagnostic = "unsupported_metadata_schema"
                continue
            if metadata.cli_session_id in seen_cli_sessions:
                continue
            seen_cli_sessions.add(metadata.cli_session_id)

            key = _sha256("claude-code-record-session-v1", metadata.cli_session_id)
            prior = self.cursors.get(key)
            hook_turn_id: str | None = None
            hook_sequence = 0
            if not metadata.is_archived:
                hook_turn_id, hook_sequence = _read_hook_turn(
                    self.agent_watch_root, metadata.cli_session_id
                )

            journal_projection = JournalProjection()
            mapping_unresolved = (
                prior is not None
                and metadata.latest_user_frame_at is not None
                and _frame_is_fresh(metadata.latest_user_frame_at, now_epoch)
                and prior.turn_id == _turn_id(metadata.cli_session_id, metadata.latest_user_frame_at)
            )
            cancellation_probe_due = (
                prior is not None
                and prior.active_run_seen
                and prior.turn_id is not None
                and prior.active_frame_at is not None
                and metadata.latest_user_frame_at is not None
                and metadata.latest_user_frame_at == prior.latest_user_frame_at
                and metadata.latest_user_frame_at == prior.active_frame_at
                and not metadata.is_archived
            )
            needs_turn_mapping = prior is None or (
                (metadata.latest_user_frame_at is not None
                 and (prior.latest_user_frame_at is None
                      or metadata.latest_user_frame_at > prior.latest_user_frame_at))
                or metadata.completed_turns > prior.completed_turns
                or metadata.last_assistant_uuid != prior.last_assistant_uuid
                or mapping_unresolved
                or cancellation_probe_due
            )
            journal_frame = metadata.latest_user_frame_at
            if journal_frame is None and prior is not None:
                journal_frame = prior.latest_user_frame_at
            if needs_turn_mapping and not metadata.is_archived:
                if journal_index is None:
                    journal_index, journal_diagnostic = _journal_index(self.home)
                    if journal_diagnostic == "journal_index_limited":
                        summary.diagnostic = "scan_limited"
                    elif journal_diagnostic == "journal_index_error":
                        summary.diagnostic = "directory_scan_error"
                journal_path = journal_index.get(metadata.cli_session_id) if journal_index is not None else None
                if journal_path is not None:
                    if (journal_lookups >= MAX_JOURNAL_LOOKUPS_PER_POLL
                            or journal_budget <= 0):
                        if summary.diagnostic == "none":
                            summary.diagnostic = "scan_limited"
                        stop_before_current = True
                        break
                    journal_projection = _journal_prompt_id(
                        journal_path,
                        metadata.cli_session_id,
                        journal_frame,
                        metadata.last_assistant_uuid,
                        journal_budget,
                        tracked_prompt_id=prior.turn_id if cancellation_probe_due else None,
                        tracked_version_supported=(
                            prior.active_interrupt_version_supported
                            if cancellation_probe_due and prior is not None else False
                        ),
                    )
                    journal_lookups += 1
                    journal_budget -= journal_projection.bytes_read

            plans, next_cursor = _reduce_snapshot(
                metadata=metadata,
                prior=prior,
                info=info,
                now=now,
                hook_turn_id=hook_turn_id,
                hook_sequence=hook_sequence,
                journal_prompt_id=journal_projection.latest_prompt_id,
                assistant_prompt_id=journal_projection.assistant_prompt_id,
                assistant_timestamp=journal_projection.assistant_timestamp,
                journal_cancel_prompt_id=journal_projection.cancellation_prompt_id,
                journal_cancel_timestamp=journal_projection.cancellation_timestamp,
                journal_cancel_signature=journal_projection.cancellation_signature,
                journal_human_prompt_id=journal_projection.current_human_prompt_id,
                journal_human_version_supported=journal_projection.current_human_version_supported,
                journal_human_prompt_seen=journal_projection.current_human_prompt_seen,
            )
            if metadata.is_archived:
                self.cursors[key] = next_cursor
                continue

            failed = False
            sequence = prior.sequence if prior is not None else 0
            observed_cursor = prior.last_observed_at if prior is not None else None
            for plan in sorted(plans, key=lambda item: (item.observed_at, _state_order(item.state))):
                sequence += 1
                event, observed_cursor = _event_record(
                    cli_session_id=metadata.cli_session_id,
                    turn_id=plan.turn_id,
                    state=plan.state,
                    evidence=plan.evidence,
                    source=plan.source,
                    signature=plan.signature,
                    sequence=sequence,
                    observed_at=plan.observed_at,
                    previous_observed_at=observed_cursor,
                )
                try:
                    _write_event(self.events_directory, event)
                except OSError:
                    summary.diagnostic = "event_write_failed"
                    failed = True
                    break
                summary.events_written += 1
            if failed:
                continue
            next_cursor.sequence = sequence
            next_cursor.last_observed_at = observed_cursor
            self.cursors[key] = next_cursor

        advance = visited - (1 if stop_before_current and visited > 0 else 0)
        self.rotation = (start_index + max(advance, 1)) % len(files)
        if visited < len(files) and summary.diagnostic == "none":
            summary.diagnostic = "scan_limited"
        if summary.diagnostic == "none" and summary.events_written == 0:
            summary.diagnostic = "no_status_signal"
        self._save(summary)
        return summary

    def _list_sessions(self) -> tuple[list[SessionFile], str]:
        files: list[SessionFile] = []
        roots_seen = 0
        diagnostic = "no_records"
        visited = 0
        for _, root in self.roots:
            if not _plain_directory(root):
                continue
            roots_seen += 1
            try:
                first_level = sorted(os.scandir(root), key=lambda entry: entry.name)
                for first in first_level:
                    visited += 1
                    if visited > MAX_DIRECTORY_ENTRIES:
                        return files[:MAX_SESSIONS], "directory_scan_limited"
                    if first.name.startswith(".") or not first.is_dir(follow_symlinks=False):
                        continue
                    with os.scandir(first.path) as iterator:
                        second_level = sorted(iterator, key=lambda entry: entry.name)
                    for second in second_level:
                        visited += 1
                        if visited > MAX_DIRECTORY_ENTRIES:
                            return files[:MAX_SESSIONS], "directory_scan_limited"
                        if second.name.startswith(".") or not second.is_dir(follow_symlinks=False):
                            continue
                        with os.scandir(second.path) as iterator:
                            records = sorted(iterator, key=lambda entry: entry.name)
                        for record in records:
                            visited += 1
                            if visited > MAX_DIRECTORY_ENTRIES:
                                return files[:MAX_SESSIONS], "directory_scan_limited"
                            if not record.name.endswith(".json"):
                                continue
                            if not LOCAL_SESSION_ID.fullmatch(record.name[:-5]):
                                continue
                            if not record.is_file(follow_symlinks=False):
                                continue
                            info = record.stat(follow_symlinks=False)
                            if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_METADATA_BYTES:
                                continue
                            files.append(SessionFile(Path(record.path), info))
                            if len(files) > MAX_SESSIONS:
                                return files[:MAX_SESSIONS], "session_scan_limited"
            except OSError:
                diagnostic = "directory_scan_error"
        if files:
            return files, "none"
        return files, diagnostic if roots_seen else "store_unavailable"

    def _save(self, summary: ScanSummary) -> None:
        try:
            _save_state(self.state_file, self.cursors, self.rotation)
        except OSError:
            summary.diagnostic = "state_write_failed"


def _state_order(state: str) -> int:
    return {"running": 0, "waitingApproval": 1, "waitingInput": 1,
            "responseEnded": 2, "cancelled": 2, "failed": 2}.get(state, 3)


def _fresh_timestamp(timestamp: float | None, now_epoch: float) -> bool:
    if timestamp is None:
        return False
    age = now_epoch - timestamp
    return -FUTURE_TOLERANCE_SECONDS <= age <= FRESH_FRAME_SECONDS


def _reduce_snapshot(
    metadata: SessionMetadata,
    prior: Cursor | None,
    info: os.stat_result,
    now: datetime,
    hook_turn_id: str | None,
    hook_sequence: int,
    journal_prompt_id: str | None,
    assistant_prompt_id: str | None,
    assistant_timestamp: float | None,
    journal_cancel_prompt_id: str | None,
    journal_cancel_timestamp: float | None,
    journal_cancel_signature: str | None,
    journal_human_prompt_id: str | None,
    journal_human_version_supported: bool,
    journal_human_prompt_seen: bool,
) -> tuple[list[PlannedEvent], Cursor]:
    now_epoch = now.timestamp()
    plans: list[PlannedEvent] = []

    def make_cursor(
        turn_id: str | None,
        active_frame_at: float | None,
        active_run_seen: bool,
        sequence: int,
        last_observed_at: str | None,
        last_interrupt_signature: str | None = None,
        active_interrupt_version_supported: bool | None = None,
    ) -> Cursor:
        if last_interrupt_signature is None and prior is not None:
            last_interrupt_signature = prior.last_interrupt_signature
        if active_interrupt_version_supported is None:
            active_interrupt_version_supported = (
                prior.active_interrupt_version_supported if prior is not None else False
            )
        return Cursor(
            device=info.st_dev,
            inode=info.st_ino,
            modified_ns=info.st_mtime_ns,
            size=info.st_size,
            session_id=metadata.session_id,
            cli_session_id=metadata.cli_session_id,
            completed_turns=metadata.completed_turns,
            latest_user_frame_at=metadata.latest_user_frame_at,
            last_turn_edge_at=metadata.last_turn_edge_at,
            last_turn_cut_short=metadata.last_turn_cut_short,
            is_archived=metadata.is_archived,
            error_category_present=metadata.error_category is not None,
            error_at=metadata.error_at,
            last_assistant_uuid=metadata.last_assistant_uuid,
            turn_id=turn_id,
            active_frame_at=active_frame_at,
            active_run_seen=active_run_seen,
            hook_sequence=max(hook_sequence, prior.hook_sequence if prior is not None else 0),
            sequence=sequence,
            last_observed_at=last_observed_at,
            last_interrupt_signature=last_interrupt_signature,
            active_interrupt_version_supported=active_interrupt_version_supported,
        )

    def plan(state: str, evidence: str, source_field: str, signature: str,
             turn_id: str, timestamp: float | None) -> None:
        plans.append(PlannedEvent(
            state=state,
            evidence=evidence,
            source=f"claude_code_records:{source_field}",
            signature=signature,
            turn_id=turn_id,
            observed_at=_observe_time(timestamp, now),
        ))

    current_frame = metadata.latest_user_frame_at
    current_edge = metadata.last_turn_edge_at
    frame_fresh = _frame_is_fresh(current_frame, now_epoch)
    frame_advanced = prior is not None and current_frame is not None and (
        prior.latest_user_frame_at is None or current_frame > prior.latest_user_frame_at
    )
    hook_is_new = prior is None or hook_sequence > prior.hook_sequence
    turn_id = (
        journal_prompt_id
            or (hook_turn_id if hook_turn_id is not None and hook_is_new
                and (prior is None or hook_turn_id != prior.turn_id) else None)
        or (prior.turn_id if prior is not None and not frame_advanced else None)
        or _turn_id(metadata.cli_session_id, current_frame)
    ) if current_frame is not None else None

    if prior is None:
        bootstrap_interrupt_signature = None
        bootstrap_interrupted = (
            journal_cancel_signature is not None
                and journal_cancel_prompt_id is not None
                and journal_cancel_prompt_id == journal_prompt_id
                and current_frame is not None
                and journal_cancel_timestamp is not None
                and journal_cancel_timestamp >= current_frame
                and _fresh_timestamp(journal_cancel_timestamp, now_epoch)
        )
        if bootstrap_interrupted:
            # A cancel already present during bootstrap is history. Remember its
            # opaque signature so it cannot be replayed as a new cancellation.
            bootstrap_interrupt_signature = journal_cancel_signature
        already_complete = (
            journal_prompt_id is not None
            and assistant_prompt_id == journal_prompt_id
            and current_edge is not None
            and current_frame is not None
            and current_edge >= current_frame
        )
        active = not metadata.is_archived and frame_fresh and not already_complete and not bootstrap_interrupted
        active_interrupt_version_supported = (
            active
            and journal_human_prompt_seen
            and journal_human_prompt_id == turn_id
            and journal_human_version_supported
        )
        if active and turn_id is not None:
            plan("running", "inferred", "latestUserFrameAt", f"frame:{current_frame:.6f}",
                 turn_id, current_frame)
        return plans, make_cursor(
            turn_id=turn_id,
            active_frame_at=current_frame if active else None,
            active_run_seen=active,
            sequence=0,
            last_observed_at=None,
            last_interrupt_signature=bootstrap_interrupt_signature,
            active_interrupt_version_supported=active_interrupt_version_supported,
        )

    regressed = metadata.completed_turns < prior.completed_turns
    if (current_frame is not None and prior.latest_user_frame_at is not None
            and current_frame < prior.latest_user_frame_at):
        regressed = True
    if regressed:
        return plans, make_cursor(
            turn_id=None, active_frame_at=None, active_run_seen=False,
            sequence=prior.sequence, last_observed_at=prior.last_observed_at,
            active_interrupt_version_supported=False,
        )

    if metadata.is_archived:
        return plans, make_cursor(
            turn_id=None, active_frame_at=None, active_run_seen=False,
            sequence=prior.sequence, last_observed_at=prior.last_observed_at,
            active_interrupt_version_supported=False,
        )

    edge_advanced = current_edge is not None and (
        prior.last_turn_edge_at is None or current_edge > prior.last_turn_edge_at
    )
    completed_advanced = metadata.completed_turns > prior.completed_turns
    assistant_advanced = metadata.last_assistant_uuid is not None and (
        metadata.last_assistant_uuid != prior.last_assistant_uuid
    )
    error_advanced = metadata.error_at is not None and (
        prior.error_at is None or metadata.error_at > prior.error_at
    )
    prior_active = prior.active_run_seen and prior.active_frame_at is not None and prior.turn_id is not None

    if frame_advanced and current_frame is not None and frame_fresh and turn_id is not None:
        plan("running", "inferred", "latestUserFrameAt", f"frame:{current_frame:.6f}",
             turn_id, current_frame)

    error_is_fresh = _fresh_timestamp(metadata.error_at, now_epoch)
    fresh_error = error_advanced and metadata.error_category is not None and error_is_fresh
    failure_turn: str | None = None
    failure_time: float | None = None
    if fresh_error and metadata.error_at is not None:
        if current_frame is not None and metadata.error_at >= current_frame:
            failure_turn = journal_prompt_id or (turn_id if not frame_advanced else None)
            failure_time = metadata.error_at
        elif (prior_active and prior.active_frame_at is not None
              and metadata.error_at >= prior.active_frame_at):
            failure_turn = prior.turn_id
            failure_time = metadata.error_at
    if failure_turn is not None and failure_time is not None:
        plan("failed", "explicit", "errorAt", f"error:{failure_time:.6f}",
             failure_turn, failure_time)

    completion_turn = None
    if (completed_advanced and assistant_advanced and assistant_prompt_id is not None
            and assistant_timestamp is not None
            and failure_turn is None and not fresh_error):
        mapped_turn_is_ambiguous = frame_advanced and assistant_prompt_id != turn_id
        if not mapped_turn_is_ambiguous:
            completion_turn = assistant_prompt_id
            plan(
                "responseEnded", "explicit", "completedTurns",
                f"completed:{metadata.completed_turns}:assistant:{metadata.last_assistant_uuid}",
                completion_turn, now.timestamp(),
            )

    cancellation_turn: str | None = None
    cancellation_evidence_is_current = (
        prior_active
        and not frame_advanced
        and current_frame is not None
        and prior.latest_user_frame_at == current_frame
        and prior.active_frame_at == current_frame
        and prior.turn_id is not None
        and journal_cancel_prompt_id is not None
        and (journal_cancel_prompt_id == journal_prompt_id
             or (journal_prompt_id is None and journal_cancel_prompt_id == prior.turn_id))
        and journal_cancel_timestamp is not None
        and journal_cancel_timestamp >= prior.active_frame_at
        and _fresh_timestamp(journal_cancel_timestamp, now_epoch)
        and journal_cancel_signature is not None
        and journal_cancel_signature != prior.last_interrupt_signature
        and not completed_advanced
        and failure_turn is None
        and not fresh_error
        and completion_turn is None
    )
    if cancellation_evidence_is_current:
        cancellation_turn = prior.turn_id
        plan(
            "cancelled", "explicit", "journal_user_interrupt",
            f"interrupt:{journal_cancel_signature}", cancellation_turn,
            journal_cancel_timestamp,
        )

    unknown_turn: str | None = None
    if (metadata.last_turn_cut_short and edge_advanced and prior_active
            and not completion_turn and cancellation_turn is None and failure_turn is None):
        if (not frame_advanced and current_edge is not None
                and prior.active_frame_at is not None and current_edge >= prior.active_frame_at):
            unknown_turn = prior.turn_id
        elif (frame_advanced and current_edge is not None and current_frame is not None
              and prior.active_frame_at is not None
              and prior.active_frame_at <= current_edge < current_frame):
            unknown_turn = prior.turn_id
        if unknown_turn is not None:
            plan("unknown", "explicit", "lastTurnCutShort_unclassified",
                 f"unclassified-edge:{current_edge:.6f}", unknown_turn, current_edge)

    active_frame = prior.active_frame_at if prior_active else None
    active_turn = prior.turn_id if prior_active else turn_id
    active = prior_active
    active_interrupt_version_supported = prior.active_interrupt_version_supported
    if frame_advanced:
        active = frame_fresh and turn_id is not None
        active_frame = current_frame if active else None
        active_turn = turn_id
        active_interrupt_version_supported = (
            active
            and journal_human_prompt_seen
            and journal_human_prompt_id == turn_id
            and journal_human_version_supported
        )
    elif prior_active and journal_human_prompt_seen:
        active_interrupt_version_supported = (
            journal_human_prompt_id == prior.turn_id
            and journal_human_version_supported
        )
    for event in plans:
        if event.state in {"failed", "responseEnded", "cancelled"} and event.turn_id == active_turn:
            active = False
            active_frame = None
            active_interrupt_version_supported = False
        elif (event.state == "unknown" and event.turn_id == active_turn
              and not event.source.endswith("lastTurnCutShort_unclassified")):
            active = False
            active_frame = None
            active_interrupt_version_supported = False
    if not active and active_turn is None:
        active_turn = turn_id
    return plans, make_cursor(
        turn_id=active_turn,
        active_frame_at=active_frame,
        active_run_seen=active,
        sequence=prior.sequence,
        last_observed_at=prior.last_observed_at,
        last_interrupt_signature=(
            journal_cancel_signature
            if cancellation_evidence_is_current else None
        ),
        active_interrupt_version_supported=active_interrupt_version_supported,
    )


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Read Claude Code session metadata only.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--once", action="store_true", help="scan once and exit (default)")
    mode.add_argument("--watch", action="store_true", help="scan repeatedly")
    parser.add_argument("--home", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--root", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--events-directory", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--state-file", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--app-bundle", type=Path, default=Path("/Applications/Claude.app"), help=argparse.SUPPRESS)
    parser.add_argument("--interval", type=float, default=0.5)
    options = parser.parse_args(arguments)
    home = options.home or Path.home()
    roots = (("test", options.root),) if options.root is not None else None
    reader = ClaudeCodeRecordsReader(
        home=home,
        roots=roots,
        events_directory=options.events_directory,
        state_file=options.state_file,
        app_bundle=options.app_bundle,
    )
    try:
        if options.watch:
            previous_diagnostic: str | None = None
            while True:
                summary = reader.poll_once()
                if summary.events_written or summary.diagnostic != previous_diagnostic:
                    print(json.dumps(summary.to_json(), separators=(",", ":"), sort_keys=True), flush=True)
                previous_diagnostic = summary.diagnostic
                time.sleep(max(0.1, min(options.interval, 60)))
        summary = reader.poll_once()
        print(json.dumps(summary.to_json(), separators=(",", ":"), sort_keys=True))
        return 0
    except KeyboardInterrupt:
        return 0
    except Exception:
        print(json.dumps({
            "adapter": ADAPTER_ID, "status": "degraded", "eventsWritten": 0,
            "diagnostic": "adapter_error", "schema": SCHEMA,
            "validation": reader.validation, "appVersion": reader.app_version,
        }, separators=(",", ":"), sort_keys=True))
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
