#!/usr/bin/env python3
"""Read Claude Desktop local Chat/Cowork lifecycle metadata only."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import tempfile
import time
from typing import Any


APP_ID = "claude"
EXPECTED_CLAUDE_VERSION = "4.4212.0"
SESSION_ID = re.compile(r"^local_[A-Za-z0-9_-]{1,128}$")
NUMBER = re.compile(rb"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
MAX_METADATA_BYTES = 1024 * 1024
MAX_METADATA_BYTES_PER_POLL = 2 * 1024 * 1024
MAX_STATE_BYTES = 1024 * 1024
MAX_TAIL_BYTES = 256 * 1024
MAX_AUDIT_BYTES_PER_SESSION = 1024 * 1024
MAX_AUDIT_BYTES_PER_POLL = 4 * 1024 * 1024
MAX_AUDIT_LINE_BYTES = 1024 * 1024
MAX_SESSIONS = 500
MAX_TRACKED_SESSIONS = MAX_SESSIONS * 2
MAX_SESSIONS_PER_POLL = 64
MAX_DIRECTORY_ENTRIES = 2_000
MAX_EVENTS_PER_SESSION_SCAN = 128
MAX_JSON_DEPTH = 64
FRESH_LAUNCH_SECONDS = 10 * 60
ABORTED_PREFIX = "aborted_"
APP_VERSION = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_-]{0,79}$")

ROOT_FIELD_TOKENS = {
    b'"type"': "type",
    b'"subtype"': "subtype",
    b'"is_error"': "is_error",
    b'"terminal_reason"': "terminal_reason",
    b'"tool_name"': "tool_name",
    b'"parent_tool_use_id"': "parent_tool_use_id",
    b'"sessionId"': "sessionId",
    b'"sessionType"': "sessionType",
    b'"isArchived"': "isArchived",
    b'"lastActivityAt"': "lastActivityAt",
    b'"_audit_timestamp"': "_audit_timestamp",
}


class MetadataError(ValueError):
    """A metadata record did not match the bounded JSON shape we accept."""


class StatusOnlyJSONReader:
    """Walk JSON structure while decoding only small, allowlisted fields.

    String values such as message content, prompts, tool input, and result text
    are scanned only to find their closing quote. They are never decoded or
    copied into a Python string.
    """

    def __init__(
        self,
        raw: bytes,
        allowed_root_fields: frozenset[str] | None = None,
        scan_nested_types: bool = True,
    ):
        self.raw = raw
        self.allowed_root_fields = allowed_root_fields or frozenset(ROOT_FIELD_TOKENS.values())
        self.scan_nested_types = scan_nested_types
        self.fields: dict[str, Any] = {}
        self.has_tool_result = False
        self.steps = 0

    def parse(self) -> tuple[dict[str, Any], bool]:
        index = self._space(0)
        if index >= len(self.raw) or self.raw[index] != 123:
            raise MetadataError("root_not_object")
        end = self._object(index, depth=0, root=True)
        if self._space(end) != len(self.raw):
            raise MetadataError("trailing_json")
        return self.fields, self.has_tool_result

    def _space(self, index: int) -> int:
        while index < len(self.raw) and self.raw[index] in (32, 9, 10, 13):
            index += 1
        return index

    def _string_end(self, index: int) -> int:
        if index >= len(self.raw) or self.raw[index] != 34:
            raise MetadataError("expected_string")
        index += 1
        while index < len(self.raw):
            character = self.raw[index]
            if character == 34:
                return index + 1
            if character < 32:
                raise MetadataError("invalid_string")
            if character == 92:
                index += 1
                if index >= len(self.raw):
                    raise MetadataError("incomplete_escape")
                escape = self.raw[index]
                if escape == 117:
                    digits = self.raw[index + 1 : index + 5]
                    if len(digits) != 4 or any(value not in b"0123456789abcdefABCDEF" for value in digits):
                        raise MetadataError("invalid_unicode_escape")
                    index += 4
                elif escape not in (34, 92, 47, 98, 102, 110, 114, 116):
                    raise MetadataError("invalid_escape")
            index += 1
        raise MetadataError("unterminated_string")

    def _selected_string(self, index: int, maximum: int) -> tuple[int, str | None]:
        end = self._string_end(index)
        if end - index > maximum:
            return end, None
        try:
            value = json.loads(self.raw[index:end].decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise MetadataError("invalid_selected_string") from None
        return end, value if isinstance(value, str) else None

    def _primitive(self, index: int) -> tuple[int, Any]:
        if self.raw.startswith(b"true", index):
            return index + 4, True
        if self.raw.startswith(b"false", index):
            return index + 5, False
        if self.raw.startswith(b"null", index):
            return index + 4, None
        match = NUMBER.match(self.raw, index)
        if match is None:
            raise MetadataError("invalid_primitive")
        token = match.group(0)
        try:
            value = int(token) if b"." not in token and b"e" not in token.lower() else float(token)
        except ValueError:
            raise MetadataError("invalid_number") from None
        return match.end(), value

    def _object(self, index: int, depth: int, root: bool) -> int:
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
            if root and b"\\" in key_token:
                raise MetadataError("escaped_root_key")
            field_name = ROOT_FIELD_TOKENS.get(key_token)
            if root and field_name not in self.allowed_root_fields:
                field_name = None
            if root and field_name in seen_selected:
                raise MetadataError("duplicate_selected_field")
            if root and field_name is not None:
                seen_selected.add(field_name)
            index = self._space(key_end)
            if index >= len(self.raw) or self.raw[index] != 58:
                raise MetadataError("missing_colon")
            value_start = self._space(index + 1)
            end, value = self._value(
                value_start,
                depth + 1,
                root_field=field_name if root else None,
                nested_type=(not root and self.scan_nested_types and key_token == b'"type"'),
            )
            if root and field_name is not None:
                if field_name == "parent_tool_use_id":
                    self.fields["has_parent_tool_use_id"] = value is not None
                    self.fields["parent_tool_use_id_is_null"] = value is None
                else:
                    self.fields[field_name] = value
            index = self._space(end)
            if index < len(self.raw) and self.raw[index] == 125:
                return index + 1
            if index >= len(self.raw) or self.raw[index] != 44:
                raise MetadataError("invalid_object_separator")
            index = self._space(index + 1)

    def _array(self, index: int, depth: int) -> int:
        if depth > MAX_JSON_DEPTH:
            raise MetadataError("json_too_deep")
        index = self._space(index + 1)
        if index < len(self.raw) and self.raw[index] == 93:
            return index + 1
        while True:
            end, _ = self._value(index, depth + 1)
            index = self._space(end)
            if index < len(self.raw) and self.raw[index] == 93:
                return index + 1
            if index >= len(self.raw) or self.raw[index] != 44:
                raise MetadataError("invalid_array_separator")
            index = self._space(index + 1)

    def _value(
        self,
        index: int,
        depth: int,
        root_field: str | None = None,
        nested_type: bool = False,
    ) -> tuple[int, Any]:
        self.steps += 1
        if self.steps > 2_000_000:
            raise MetadataError("json_too_complex")
        index = self._space(index)
        if index >= len(self.raw):
            raise MetadataError("missing_value")
        character = self.raw[index]
        if character == 123:
            end = self._object(index, depth, root=False)
            return end, True if root_field == "parent_tool_use_id" else None
        if character == 91:
            end = self._array(index, depth)
            return end, True if root_field == "parent_tool_use_id" else None
        if character == 34:
            if root_field == "parent_tool_use_id":
                return self._string_end(index), True
            maximum = 256 if root_field in {"sessionId", "sessionType"} else 512
            if root_field in {
                "type", "subtype", "is_error", "terminal_reason", "tool_name",
                "sessionId", "sessionType", "_audit_timestamp"
            }:
                end, value = self._selected_string(index, maximum)
            elif nested_type:
                end, value = self._selected_string(index, 64)
                if value == "tool_result":
                    self.has_tool_result = True
            else:
                return self._string_end(index), None
            return end, value
        end, value = self._primitive(index)
        if root_field == "lastActivityAt":
            return end, value if isinstance(value, (int, float)) and not isinstance(value, bool) else None
        if root_field == "isArchived":
            return end, value if isinstance(value, bool) else None
        if root_field == "is_error":
            return end, value if isinstance(value, bool) else None
        if root_field == "parent_tool_use_id":
            return end, value
        return end, value if root_field in {"type", "subtype", "terminal_reason", "tool_name", "_audit_timestamp"} else None


@dataclass(frozen=True)
class LocalSession:
    session_id: str
    session_type: str
    archived: bool
    last_activity: float | None


@dataclass(frozen=True)
class MetadataCursor:
    device: int
    inode: int
    modified_ns: int
    session_type: str
    archived: bool
    last_activity: float | None

    def matches(self, info: os.stat_result) -> bool:
        return (
            self.device == info.st_dev
            and self.inode == info.st_ino
            and self.modified_ns == info.st_mtime_ns
        )

    def session(self, session_id: str) -> LocalSession:
        return LocalSession(session_id, self.session_type, self.archived, self.last_activity)

    def to_json(self) -> dict[str, Any]:
        return {
            "device": self.device,
            "inode": self.inode,
            "modifiedNS": self.modified_ns,
            "sessionType": self.session_type,
            "archived": self.archived,
            "lastActivity": self.last_activity,
        }

    @classmethod
    def from_json(cls, value: Any) -> "MetadataCursor | None":
        if not isinstance(value, dict):
            return None
        try:
            device, inode, modified_ns = value["device"], value["inode"], value["modifiedNS"]
            session_type, archived = value["sessionType"], value["archived"]
            last_activity = value.get("lastActivity")
            if any(not isinstance(number, int) or number < 0 for number in (device, inode, modified_ns)):
                return None
            if session_type not in {"chat", "cowork"} or not isinstance(archived, bool):
                return None
            if last_activity is not None and (
                isinstance(last_activity, bool)
                or not isinstance(last_activity, (int, float))
                or not (0 < last_activity < 10**13)
            ):
                return None
            return cls(device, inode, modified_ns, session_type, archived, last_activity)
        except (KeyError, TypeError):
            return None


@dataclass
class Cursor:
    device: int
    inode: int
    offset: int
    turn_id: str | None = None
    state: str | None = None
    mode: str = "cowork"
    last_observed_at: str | None = None

    def to_json(self) -> dict[str, Any]:
        return {
            "device": self.device,
            "inode": self.inode,
            "offset": self.offset,
            "turnID": self.turn_id,
            "state": self.state,
            "mode": self.mode,
            "lastObservedAt": self.last_observed_at,
        }

    @classmethod
    def from_json(cls, value: Any) -> "Cursor | None":
        if not isinstance(value, dict):
            return None
        try:
            device = value["device"]
            inode = value["inode"]
            offset = value["offset"]
            if any(not isinstance(item, int) or item < 0 for item in (device, inode, offset)):
                return None
            turn_id = value.get("turnID")
            state = value.get("state")
            mode = value.get("mode", "cowork")
            last_observed_at = value.get("lastObservedAt")
            if turn_id is not None and not _bounded_string(turn_id, 128):
                return None
            if state is not None and state not in STATES:
                return None
            if mode not in {"chat", "cowork"}:
                return None
            if last_observed_at is not None and not _bounded_string(last_observed_at, 80):
                return None
            return cls(device, inode, offset, turn_id, state, mode, last_observed_at)
        except (KeyError, TypeError):
            return None


@dataclass(frozen=True)
class Observation:
    state: str
    evidence: str
    turn_id: str
    offset: int
    observed_at: datetime | None = None


@dataclass
class ScanSummary:
    events_written: int = 0
    diagnostic: str = "none"
    schema: str = "cowork-audit-v1"
    validation: str = "schema-compatible"
    app_version: str = "unknown"

    def to_json(self) -> dict[str, Any]:
        return {
            "adapter": "claude_desktop",
            "status": "ok" if self.diagnostic in {"none", "no_status_signal", "store_empty"} else "degraded",
            "eventsWritten": self.events_written,
            "diagnostic": self.diagnostic,
            "schema": self.schema,
            "validation": self.validation,
            "appVersion": self.app_version,
        }


STATES = {"unknown", "running", "waitingApproval", "waitingInput", "responseEnded", "failed", "cancelled"}
TERMINAL_STATES = {"responseEnded", "failed", "cancelled"}


def _bounded_string(value: Any, maximum: int) -> bool:
    return isinstance(value, str) and bool(value) and len(value.encode("utf-8")) <= maximum and not any(ord(c) < 32 for c in value)


def _sha256(*parts: str) -> str:
    return hashlib.sha256("\0".join(parts).encode("utf-8")).hexdigest()


def support_root(home: Path | None = None) -> Path:
    base = home or Path.home()
    return base / "Library" / "Application Support" / "Claude" / "local-agent-mode-sessions"


def support_roots(home: Path | None = None) -> tuple[Path, ...]:
    base = home or Path.home()
    directory = base / "Library" / "Application Support"
    # The vendor's Gateway build uses a separate user-data profile. Never
    # enumerate sibling directories such as the session-secret store.
    return tuple(directory / profile / "local-agent-mode-sessions" for profile in ("Claude", "Claude-3p"))


def agent_watch_root(home: Path | None = None) -> Path:
    base = home or Path.home()
    return base / "Library" / "Application Support" / "Agent Watch"


def app_version(bundle: Path) -> str:
    info = bundle / "Contents" / "Info.plist"
    try:
        if info.is_symlink() or not info.is_file() or info.stat().st_size > 256 * 1024:
            return "unknown"
        with info.open("rb") as source:
            record = plistlib.load(source)
        if not isinstance(record, dict) or record.get("CFBundleIdentifier") != "com.anthropic.claudefordesktop":
            return "unknown"
        version = record.get("CFBundleShortVersionString") if isinstance(record, dict) else None
        return version if isinstance(version, str) and APP_VERSION.fullmatch(version) else "unknown"
    except Exception:
        return "unknown"


def _version_tag(version: str) -> str:
    return "schema-confirmed-4.4212.0" if version == EXPECTED_CLAUDE_VERSION else "schema-compatible"


def _parse_metadata(raw: bytes, filename_id: str) -> LocalSession:
    fields, _ = StatusOnlyJSONReader(
        raw,
        frozenset({"sessionId", "sessionType", "isArchived", "lastActivityAt"}),
        scan_nested_types=False,
    ).parse()
    session_id = fields.get("sessionId")
    if not isinstance(session_id, str) or not SESSION_ID.fullmatch(session_id) or session_id != filename_id:
        raise MetadataError("session_id_mismatch")
    session_type = fields.get("sessionType")
    if session_type is None:
        session_type = "cowork"
    if session_type not in {"chat", "cowork"}:
        raise MetadataError("unsupported_session_type")
    archived = fields.get("isArchived", False)
    if not isinstance(archived, bool):
        raise MetadataError("invalid_archive_flag")
    last_activity = fields.get("lastActivityAt")
    if isinstance(last_activity, bool) or not isinstance(last_activity, (int, float)):
        last_activity = None
    elif not (last_activity > 0 and last_activity < 10**16):
        last_activity = None
    else:
        last_activity = float(last_activity) / 1000.0
    return LocalSession(session_id, session_type, archived, last_activity)


def _open_regular(path: Path, maximum_bytes: int) -> tuple[int, os.stat_result] | None:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum_bytes:
            os.close(descriptor)
            return None
        return descriptor, info
    except OSError:
        return None


def _read_metadata(path: Path, filename_id: str) -> LocalSession | None:
    opened = _open_regular(path, MAX_METADATA_BYTES)
    if opened is None:
        return None
    descriptor, _ = opened
    try:
        raw = bytearray()
        while len(raw) <= MAX_METADATA_BYTES:
            chunk = os.read(descriptor, min(64 * 1024, MAX_METADATA_BYTES + 1 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        if len(raw) > MAX_METADATA_BYTES:
            return None
        return _parse_metadata(bytes(raw), filename_id)
    except MetadataError:
        raise
    except Exception:
        raise MetadataError("metadata_unreadable") from None
    finally:
        os.close(descriptor)


def _session_directories(root: Path) -> tuple[list[tuple[Path, Path, str]], str]:
    try:
        root_info = root.lstat()
        profile_info = root.parent.lstat()
    except OSError:
        return [], "store_unavailable"
    if (not stat.S_ISDIR(root_info.st_mode) or stat.S_ISLNK(root_info.st_mode)
            or not stat.S_ISDIR(profile_info.st_mode) or stat.S_ISLNK(profile_info.st_mode)):
        return [], "store_unavailable"
    result: list[tuple[Path, Path, str]] = []
    scanned = 0
    try:
        with os.scandir(root) as accounts:
            account_entries = sorted(accounts, key=lambda item: item.name)
        for account in account_entries:
            if account.name == "skills-plugin" or account.name.startswith(".") or not account.is_dir(follow_symlinks=False):
                continue
            account_path = Path(account.path)
            with os.scandir(account_path) as orgs:
                org_entries = sorted(orgs, key=lambda item: item.name)
            for org in org_entries:
                if org.name.startswith(".") or not org.is_dir(follow_symlinks=False):
                    continue
                org_path = Path(org.path)
                with os.scandir(org_path) as entries:
                    session_entries = sorted(entries, key=lambda item: item.name)
                for entry in session_entries:
                    scanned += 1
                    if scanned > MAX_DIRECTORY_ENTRIES:
                        return result[:MAX_SESSIONS], "directory_scan_limited"
                    if not entry.name.endswith(".json") or not entry.is_file(follow_symlinks=False):
                        continue
                    session_id = entry.name[:-5]
                    if not SESSION_ID.fullmatch(session_id):
                        continue
                    relative_scope = f"{account.name}/{org.name}/{session_id}"
                    result.append((Path(entry.path), org_path, relative_scope))
                    if len(result) > MAX_SESSIONS:
                        return result[:MAX_SESSIONS], "session_scan_limited"
    except OSError:
        return result, "directory_scan_error"
    return result, "none" if result else "store_empty"


def _safe_audit_path(session_directory: Path, session_id: str) -> Path | None:
    try:
        session_info = session_directory.lstat()
        if not stat.S_ISDIR(session_info.st_mode) or stat.S_ISLNK(session_info.st_mode):
            return None
        path = session_directory / "audit.jsonl"
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
            return None
        return path
    except OSError:
        return None


def _session_audit_path(account_directory: Path, session_id: str) -> Path | None:
    direct = _safe_audit_path(account_directory / session_id, session_id)
    if direct is not None:
        return direct
    # Current Gateway host-loop builds use the first eight UUID characters as
    # the storage directory. Refuse a shared prefix instead of merging chats.
    match = re.fullmatch(r"local_([0-9a-f]{8})-[0-9a-f-]{27,40}", session_id)
    if match is None:
        return None
    prefix = match.group(1)
    matches = 0
    scanned = 0
    try:
        with os.scandir(account_directory) as entries:
            for entry in entries:
                scanned += 1
                if scanned > MAX_DIRECTORY_ENTRIES:
                    return None
                if entry.name.startswith("local_" + prefix) and entry.name.endswith(".json"):
                    matches += 1
                    if matches > 1:
                        return None
        if matches != 1:
            return None
    except OSError:
        return None
    return _safe_audit_path(account_directory / prefix, session_id)


def _scope_hash(relative_scope: str) -> str:
    return _sha256("claude-desktop-local-session-v1", relative_scope)


def _new_turn_id(session_hash: str, device: int, inode: int, offset: int) -> str:
    return _sha256("claude-turn-v1", session_hash, str(device), str(inode), str(offset))


def _audit_fields(line: bytes) -> tuple[dict[str, Any], bool]:
    if len(line) > MAX_AUDIT_LINE_BYTES:
        raise MetadataError("audit_line_too_large")
    fields, has_tool_result = StatusOnlyJSONReader(
        line,
        frozenset({
            "type", "subtype", "is_error", "terminal_reason", "tool_name",
            "parent_tool_use_id", "_audit_timestamp",
        }),
        scan_nested_types=True,
    ).parse()
    if not isinstance(fields.get("type"), str):
        raise MetadataError("missing_event_type")
    return fields, has_tool_result


def _observation_for(
    fields: dict[str, Any],
    has_tool_result: bool,
    current_state: str | None,
    turn_id: str | None,
    session_hash: str,
    device: int,
    inode: int,
    line_offset: int,
    observed_at: datetime | None = None,
) -> Observation | None:
    # Audit records carrying a non-null parent tool marker belong to a child
    # agent. Without a separately reliable child session identity, none of its
    # prompts, results, permissions, or errors may change the parent snapshot.
    if fields.get("has_parent_tool_use_id") is True:
        return None
    event_type = fields.get("type")
    subtype = fields.get("subtype") if isinstance(fields.get("subtype"), str) else ""
    if event_type == "user":
        if has_tool_result:
            return None
        turn_id = _new_turn_id(session_hash, device, inode, line_offset)
        return Observation("running", "inferred", turn_id, line_offset, observed_at)
    if event_type == "system":
        if subtype == "init":
            if turn_id is None or current_state in TERMINAL_STATES:
                turn_id = _new_turn_id(session_hash, device, inode, line_offset)
            return Observation("running", "inferred", turn_id, line_offset, observed_at)
        if subtype == "permission_request":
            if turn_id is None or current_state in TERMINAL_STATES:
                turn_id = _new_turn_id(session_hash, device, inode, line_offset)
            state = "waitingInput" if fields.get("tool_name") == "AskUserQuestion" else "waitingApproval"
            return Observation(state, "explicit", turn_id, line_offset, observed_at)
        if subtype == "permission_response":
            if turn_id is None:
                turn_id = _new_turn_id(session_hash, device, inode, line_offset)
            return Observation("running", "inferred", turn_id, line_offset, observed_at)
        return None
    if event_type == "assistant":
        if fields.get("parent_tool_use_id_is_null") is not True:
            return None
        if turn_id is None or current_state in TERMINAL_STATES:
            turn_id = _new_turn_id(session_hash, device, inode, line_offset)
        return Observation("running", "inferred", turn_id, line_offset, observed_at)
    if event_type == "result":
        if turn_id is None:
            turn_id = _new_turn_id(session_hash, device, inode, line_offset)
        terminal_reason = fields.get("terminal_reason")
        if isinstance(terminal_reason, str) and terminal_reason.startswith(ABORTED_PREFIX):
            return Observation("cancelled", "explicit", turn_id, line_offset, observed_at)
        if fields.get("is_error") is True or subtype.startswith("error"):
            return Observation("failed", "explicit", turn_id, line_offset, observed_at)
        if subtype == "success" and fields.get("is_error") is False:
            return Observation("responseEnded", "explicit", turn_id, line_offset, observed_at)
        return Observation("unknown", "explicit", turn_id, line_offset, observed_at)
    return None


def _latest_activity(session: LocalSession, audit_info: os.stat_result) -> float:
    return max(session.last_activity or 0, audit_info.st_mtime)


def _event_timestamp(fields: dict[str, Any], audit_mtime: float, now: datetime) -> datetime:
    """Use the audit timestamp when valid, else the local file's mtime."""
    value = fields.get("_audit_timestamp")
    candidate: datetime | None = None
    if isinstance(value, str) and len(value) <= 80:
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is not None:
                candidate = parsed.astimezone(timezone.utc)
        except ValueError:
            pass
    fallback = datetime.fromtimestamp(audit_mtime, tz=timezone.utc)
    if candidate is None:
        candidate = fallback
    if candidate > now + timedelta(seconds=30):
        candidate = fallback
    if candidate > now + timedelta(seconds=30):
        candidate = now
    return candidate


def _read_window(descriptor: int, size: int, start: int, maximum: int) -> tuple[bytes, int]:
    length = max(0, min(size - start, maximum))
    if length == 0:
        return b"", start
    os.lseek(descriptor, start, os.SEEK_SET)
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = os.read(descriptor, min(64 * 1024, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    data = b"".join(chunks)
    return data, start + len(data)


def _complete_lines(data: bytes, absolute_start: int, skipped_partial: bool) -> tuple[list[tuple[int, bytes]], int]:
    lines: list[tuple[int, bytes]] = []
    local_start = 0
    if skipped_partial:
        newline = data.find(b"\n")
        if newline < 0:
            return [], absolute_start + len(data)
        local_start = newline + 1
    absolute_line_start = absolute_start + local_start
    while True:
        newline = data.find(b"\n", local_start)
        if newline < 0:
            return lines, absolute_start + local_start
        lines.append((absolute_line_start, data[local_start:newline]))
        local_start = newline + 1
        absolute_line_start = absolute_start + local_start


def _timestamp(candidate: datetime, previous: str | None) -> tuple[str, datetime]:
    observed = candidate.astimezone(timezone.utc)
    if previous:
        try:
            prior = datetime.fromisoformat(previous.replace("Z", "+00:00"))
            if prior.tzinfo is not None and observed <= prior.astimezone(timezone.utc):
                observed = prior.astimezone(timezone.utc) + timedelta(microseconds=1)
        except ValueError:
            pass
    value = observed.isoformat(timespec="microseconds").replace("+00:00", "Z")
    return value, observed


def _event_for(
    observation: Observation,
    session_hash: str,
    cursor: Cursor,
    mode: str,
    version_tag: str,
    now: datetime,
) -> dict[str, Any]:
    event_id = _sha256(
        "claude-audit-event-v1",
        session_hash,
        str(cursor.device),
        str(cursor.inode),
        str(observation.offset),
        observation.turn_id,
        observation.state,
    )
    observed_at, _ = _timestamp(observation.observed_at or now, cursor.last_observed_at)
    source = f"claude_desktop_{mode}:audit_v1:{version_tag}"
    return {
        "id": event_id,
        "appID": APP_ID,
        "sessionID": session_hash,
        "turnID": observation.turn_id,
        "state": observation.state,
        "evidence": observation.evidence,
        "observedAt": observed_at,
        "source": source,
    }


def _ensure_private_directory(path: Path) -> None:
    if path.is_symlink():
        raise OSError("symlink")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise OSError("not_directory")
    os.chmod(path, 0o700)


def _atomic_private_write(directory: Path, name: str, contents: bytes) -> None:
    _ensure_private_directory(directory)
    target = directory / name
    if target.is_symlink():
        raise OSError("symlink")
    descriptor, temporary_name = tempfile.mkstemp(prefix=".claude-desktop-", dir=directory)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        if target.is_symlink():
            raise OSError("symlink")
        os.replace(temporary_path, target)
        os.chmod(target, 0o600)
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def _load_state(path: Path) -> tuple[dict[str, Cursor], dict[str, MetadataCursor], int, str]:
    opened = _open_regular(path, MAX_STATE_BYTES)
    if opened is None:
        if not path.exists():
            return {}, {}, 0, "none"
        return {}, {}, 0, "state_unavailable"
    descriptor, _ = opened
    try:
        raw = os.read(descriptor, MAX_STATE_BYTES + 1)
    except OSError:
        return {}, {}, 0, "state_unavailable"
    finally:
        os.close(descriptor)
    if len(raw) > MAX_STATE_BYTES:
        return {}, {}, 0, "state_unavailable"
    try:
        value = json.loads(raw)
        if not isinstance(value, dict) or value.get("schema") != 1 or not isinstance(value.get("sessions"), dict):
            return {}, {}, 0, "state_reset"
        cursors: dict[str, Cursor] = {}
        for key, item in value["sessions"].items():
            if not isinstance(key, str) or not re.fullmatch(r"[0-9a-f]{64}", key):
                continue
            cursor = Cursor.from_json(item)
            if cursor is not None:
                cursors[key] = cursor
        metadata: dict[str, MetadataCursor] = {}
        saved_metadata = value.get("metadata", {})
        if isinstance(saved_metadata, dict):
            for key, item in saved_metadata.items():
                if not isinstance(key, str) or not re.fullmatch(r"[0-9a-f]{64}", key):
                    continue
                record = MetadataCursor.from_json(item)
                if record is not None:
                    metadata[key] = record
        rotation = value.get("rotation", 0)
        if not isinstance(rotation, int) or rotation < 0:
            rotation = 0
        return cursors, metadata, rotation, "none"
    except Exception:
        return {}, {}, 0, "state_reset"


def _save_state(
    path: Path,
    cursors: dict[str, Cursor],
    metadata: dict[str, MetadataCursor],
    rotation: int,
) -> None:
    bounded = dict(list(sorted(cursors.items()))[-MAX_TRACKED_SESSIONS:])
    bounded_metadata = dict(list(sorted(metadata.items()))[-MAX_TRACKED_SESSIONS:])
    payload = json.dumps(
        {
            "schema": 1,
            "sessions": {key: cursor.to_json() for key, cursor in bounded.items()},
            "metadata": {key: record.to_json() for key, record in bounded_metadata.items()},
            "rotation": max(0, rotation),
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    _atomic_private_write(path.parent, path.name, payload)


class ClaudeDesktopReader:
    """Poll Claude Desktop's structured local-agent session store read-only."""

    def __init__(
        self,
        root: Path | None = None,
        events_directory: Path | None = None,
        state_file: Path | None = None,
        app_bundle: Path = Path("/Applications/Claude.app"),
        now: Any = lambda: datetime.now(timezone.utc),
    ):
        self.root = root or support_root()
        self.roots = (root,) if root is not None else support_roots()
        watch_root = agent_watch_root()
        self.events_directory = events_directory or watch_root / "events"
        self.state_file = state_file or watch_root / "metadata" / "claude_desktop_state.json"
        self.version = app_version(app_bundle)
        self.version_tag = _version_tag(self.version)
        self.now = now
        self.cursors, self.metadata_cache, self.rotation, self.state_diagnostic = _load_state(self.state_file)

    def poll_once(self) -> ScanSummary:
        summary = ScanSummary(app_version=self.version, validation=self.version_tag)
        if self.state_diagnostic != "none":
            summary.diagnostic = self.state_diagnostic
        sessions: list[tuple[Path, Path, str]] = []
        profile_groups: list[list[tuple[Path, Path, str]]] = []
        scan_diagnostic = "store_unavailable"
        for root_index, profile_root in enumerate(self.roots):
            profile_sessions, profile_diagnostic = _session_directories(profile_root)
            if profile_diagnostic == "store_unavailable":
                continue
            if scan_diagnostic == "store_unavailable":
                scan_diagnostic = "store_empty"
            if profile_diagnostic not in {"none", "store_empty"}:
                scan_diagnostic = profile_diagnostic
            elif profile_sessions and scan_diagnostic == "store_empty":
                scan_diagnostic = "none"
            # Preserve standard-profile identities used by earlier cursors,
            # while giving the second profile a distinct namespace.
            prefix = "" if root_index == 0 else "gateway/"
            profile_groups.append([(path, directory, prefix + scope) for path, directory, scope in profile_sessions])
        # Rotate over the complete bounded two-profile set. Truncating a
        # standard-first concatenation would permanently starve Gateway.
        for index in range(max((len(group) for group in profile_groups), default=0)):
            for group in profile_groups:
                if index < len(group):
                    sessions.append(group[index])
        if scan_diagnostic not in {"none", "store_empty"}:
            summary.diagnostic = scan_diagnostic
        if scan_diagnostic == "store_unavailable":
            return summary
        now = self.now().astimezone(timezone.utc)
        now_epoch = now.timestamp()
        if not sessions:
            self.rotation = 0
            if summary.diagnostic == "none":
                summary.diagnostic = "store_empty"
            try:
                _save_state(self.state_file, self.cursors, self.metadata_cache, self.rotation)
            except OSError:
                summary.diagnostic = "state_write_failed"
            return summary

        start_index = self.rotation % len(sessions)
        ordered_sessions = sessions[start_index:] + sessions[:start_index]
        metadata_budget = MAX_METADATA_BYTES_PER_POLL
        audit_budget = MAX_AUDIT_BYTES_PER_POLL
        visited = 0
        stop_before_current = False
        active_keys = {_scope_hash(relative_scope) for _, _, relative_scope in sessions}
        self.metadata_cache = {
            key: record for key, record in self.metadata_cache.items() if key in active_keys
        }
        self.cursors = {key: cursor for key, cursor in self.cursors.items() if key in active_keys}

        for metadata_path, account_directory, relative_scope in ordered_sessions:
            if visited >= MAX_SESSIONS_PER_POLL:
                break
            if metadata_budget <= 0 and audit_budget <= 0:
                if summary.diagnostic == "none":
                    summary.diagnostic = "scan_limited"
                break
            visited += 1
            session_id = metadata_path.name[:-5]
            session_hash = _scope_hash(relative_scope)
            try:
                metadata_info = metadata_path.lstat()
                if not stat.S_ISREG(metadata_info.st_mode) or stat.S_ISLNK(metadata_info.st_mode):
                    raise MetadataError("metadata_unavailable")
                cached_metadata = self.metadata_cache.get(session_hash)
                if cached_metadata is not None and cached_metadata.matches(metadata_info):
                    metadata = cached_metadata.session(session_id)
                else:
                    if metadata_info.st_size > MAX_METADATA_BYTES:
                        summary.diagnostic = "metadata_unavailable"
                        continue
                    if metadata_info.st_size > metadata_budget:
                        if summary.diagnostic == "none":
                            summary.diagnostic = "scan_limited"
                        stop_before_current = True
                        break
                    metadata = _read_metadata(metadata_path, session_id)
                    if metadata is not None:
                        metadata_budget -= metadata_info.st_size
                        self.metadata_cache[session_hash] = MetadataCursor(
                            metadata_info.st_dev,
                            metadata_info.st_ino,
                            metadata_info.st_mtime_ns,
                            metadata.session_type,
                            metadata.archived,
                            metadata.last_activity,
                        )
            except MetadataError as error:
                code = str(error)
                if code == "unsupported_session_type":
                    summary.diagnostic = "unsupported_session_type"
                elif code == "metadata_unavailable":
                    summary.diagnostic = "metadata_unavailable"
                else:
                    summary.diagnostic = "unsupported_metadata_schema"
                continue
            except OSError:
                summary.diagnostic = "metadata_unavailable"
                continue
            if metadata is None:
                summary.diagnostic = "metadata_unavailable"
                continue
            if metadata.archived:
                continue
            if metadata.session_type not in {"chat", "cowork"}:
                summary.diagnostic = "unsupported_session_type"
                continue
            audit_path = _session_audit_path(account_directory, session_id)
            if audit_path is None:
                continue
            opened = _open_regular(audit_path, 2**63 - 1)
            if opened is None:
                continue
            descriptor, audit_info = opened
            previous = self.cursors.get(session_hash)
            generation_changed = previous is not None and (previous.device != audit_info.st_dev or previous.inode != audit_info.st_ino)
            truncated = previous is not None and audit_info.st_size < previous.offset
            cursor = previous
            initial = cursor is None or generation_changed or truncated
            try:
                if initial:
                    cursor = Cursor(
                        device=audit_info.st_dev,
                        inode=audit_info.st_ino,
                        offset=0,
                        mode=metadata.session_type,
                    )
                    activity = _latest_activity(metadata, audit_info)
                    if now_epoch - activity > FRESH_LAUNCH_SECONDS or activity - now_epoch > 30:
                        cursor.offset = audit_info.st_size
                        self.cursors[session_hash] = cursor
                        continue
                    window_size = min(MAX_TAIL_BYTES, audit_info.st_size)
                    if window_size > audit_budget:
                        if summary.diagnostic == "none":
                            summary.diagnostic = "scan_limited"
                        stop_before_current = True
                        break
                    start = max(0, audit_info.st_size - window_size)
                    data, read_end = _read_window(descriptor, audit_info.st_size, start, window_size)
                    audit_budget -= len(data)
                    lines, complete_end = _complete_lines(data, start, skipped_partial=start > 0)
                    observations: list[Observation] = []
                    for line_offset, line in lines:
                        try:
                            fields, has_tool_result = _audit_fields(line)
                        except MetadataError:
                            if summary.diagnostic == "none":
                                summary.diagnostic = "unsupported_audit_schema"
                            continue
                        event_time = _event_timestamp(fields, audit_info.st_mtime, now)
                        observation = _observation_for(
                            fields,
                            has_tool_result,
                            cursor.state,
                            cursor.turn_id,
                            session_hash,
                            cursor.device,
                            cursor.inode,
                            line_offset,
                            event_time,
                        )
                        if observation is not None:
                            cursor.turn_id = observation.turn_id
                            cursor.state = observation.state
                            observations.append(observation)
                    # Bootstrap a single inferred active snapshot. A terminal
                    # record is history at startup and must not create an
                    # unread-completion receipt.
                    if observations:
                        latest = observations[-1]
                        if latest.state not in TERMINAL_STATES:
                            baseline = Observation(
                                latest.state, "inferred", latest.turn_id,
                                latest.offset, latest.observed_at
                            )
                            event = _event_for(baseline, session_hash, cursor, metadata.session_type, self.version_tag, now)
                            try:
                                _write_event(self.events_directory, event)
                                summary.events_written += 1
                                cursor.last_observed_at = event["observedAt"]
                            except OSError:
                                summary.diagnostic = "event_write_failed"
                                continue
                    cursor.offset = complete_end
                    # Any incomplete last line is re-read on the next pass.
                    if cursor.offset > audit_info.st_size:
                        cursor.offset = audit_info.st_size
                    self.cursors[session_hash] = cursor
                    continue

                assert cursor is not None
                cursor.mode = metadata.session_type
                if cursor.device != audit_info.st_dev or cursor.inode != audit_info.st_ino:
                    cursor.device = audit_info.st_dev
                    cursor.inode = audit_info.st_ino
                    cursor.offset = 0
                gap = audit_info.st_size - cursor.offset
                if gap <= 0:
                    continue
                if gap > MAX_AUDIT_BYTES_PER_SESSION:
                    window_size = min(MAX_TAIL_BYTES, audit_info.st_size)
                    if window_size > audit_budget:
                        if summary.diagnostic == "none":
                            summary.diagnostic = "scan_limited"
                        stop_before_current = True
                        break
                    start = max(0, audit_info.st_size - window_size)
                    data, read_end = _read_window(descriptor, audit_info.st_size, start, window_size)
                    lines, complete_end = _complete_lines(data, start, skipped_partial=start > 0)
                    resync = True
                else:
                    window_size = min(gap, MAX_AUDIT_BYTES_PER_SESSION)
                    if window_size > audit_budget:
                        if summary.diagnostic == "none":
                            summary.diagnostic = "scan_limited"
                        stop_before_current = True
                        break
                    start = cursor.offset
                    data, read_end = _read_window(descriptor, audit_info.st_size, start, window_size)
                    lines, complete_end = _complete_lines(data, start, skipped_partial=False)
                    resync = False
                audit_budget -= len(data)
                observations: list[Observation] = []
                running_state = cursor.state
                running_turn_id = cursor.turn_id
                for line_offset, line in lines:
                    try:
                        fields, has_tool_result = _audit_fields(line)
                    except MetadataError:
                        if summary.diagnostic == "none":
                            summary.diagnostic = "unsupported_audit_schema"
                        continue
                    event_time = _event_timestamp(fields, audit_info.st_mtime, now)
                    observation = _observation_for(
                        fields,
                        has_tool_result,
                        running_state,
                        running_turn_id,
                        session_hash,
                        cursor.device,
                        cursor.inode,
                        line_offset,
                        event_time,
                    )
                    if observation is not None:
                        running_state = observation.state
                        running_turn_id = observation.turn_id
                        observations.append(observation)
                if resync and observations:
                    latest = observations[-1]
                    recent_terminal = (
                        latest.state in TERMINAL_STATES
                        and latest.observed_at is not None
                        and 0 <= (now - latest.observed_at).total_seconds() <= 30
                        and (cursor.state not in TERMINAL_STATES or latest.turn_id != cursor.turn_id)
                    )
                    if latest.state in TERMINAL_STATES and not recent_terminal:
                        observations = []
                    elif latest.state not in TERMINAL_STATES:
                        observations = [Observation(
                            latest.state, "inferred", latest.turn_id,
                            latest.offset, latest.observed_at
                        )]
                    else:
                        observations = [latest]
                if len(observations) > MAX_EVENTS_PER_SESSION_SCAN:
                    observations = observations[-MAX_EVENTS_PER_SESSION_SCAN:]
                emit_failed = False
                for observation in observations:
                    next_cursor = Cursor(
                        device=cursor.device,
                        inode=cursor.inode,
                        offset=complete_end,
                        turn_id=observation.turn_id,
                        state=observation.state,
                        mode=metadata.session_type,
                        last_observed_at=cursor.last_observed_at,
                    )
                    event = _event_for(
                        observation,
                        session_hash,
                        next_cursor,
                        metadata.session_type,
                        self.version_tag,
                        now,
                    )
                    try:
                        _write_event(self.events_directory, event)
                    except OSError:
                        summary.diagnostic = "event_write_failed"
                        emit_failed = True
                        break
                    summary.events_written += 1
                    next_cursor.last_observed_at = event["observedAt"]
                    cursor = next_cursor
                if emit_failed:
                    # Leave the persistent cursor before this batch so the same
                    # deterministic event IDs are retried on the next poll.
                    continue
                cursor.offset = complete_end
                cursor.turn_id = running_turn_id
                cursor.state = running_state
                cursor.mode = metadata.session_type
                self.cursors[session_hash] = cursor
            except Exception:
                summary.diagnostic = "audit_read_failed"
            finally:
                os.close(descriptor)
        advance = visited - (1 if stop_before_current and visited > 0 else 0)
        self.rotation = (start_index + max(advance, 1)) % len(sessions)
        if visited < len(sessions) and summary.diagnostic == "none":
            summary.diagnostic = "scan_limited"
        try:
            _save_state(self.state_file, self.cursors, self.metadata_cache, self.rotation)
        except OSError:
            summary.diagnostic = "state_write_failed"
        if summary.diagnostic == "none" and summary.events_written == 0 and not sessions:
            summary.diagnostic = "store_empty"
        if summary.diagnostic == "none" and summary.events_written == 0:
            summary.diagnostic = "no_status_signal"
        return summary


def _write_event(directory: Path, event: dict[str, Any]) -> None:
    identifier = event.get("id")
    if not isinstance(identifier, str) or not re.fullmatch(r"[0-9a-f]{64}", identifier):
        raise OSError("invalid_event_id")
    contents = json.dumps(event, separators=(",", ":"), sort_keys=True).encode("utf-8") + b"\n"
    _atomic_private_write(directory, f"{identifier}.json", contents)


def _summary_line(summary: ScanSummary) -> str:
    return json.dumps(summary.to_json(), separators=(",", ":"), sort_keys=True)


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Read Claude Desktop local lifecycle metadata only.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--once", action="store_true", help="scan once and exit (default)")
    mode.add_argument("--watch", action="store_true", help="scan repeatedly")
    parser.add_argument("--root", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--events-directory", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--state-file", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--app-bundle", type=Path, default=Path("/Applications/Claude.app"), help=argparse.SUPPRESS)
    parser.add_argument("--interval", type=float, default=0.5)
    options = parser.parse_args(arguments)
    interval = min(5.0, max(0.1, options.interval))
    try:
        reader = ClaudeDesktopReader(
            root=options.root,
            events_directory=options.events_directory,
            state_file=options.state_file,
            app_bundle=options.app_bundle,
        )
        if not options.watch:
            print(_summary_line(reader.poll_once()))
            return 0
        previous_diagnostic: str | None = None
        while True:
            summary = reader.poll_once()
            if summary.events_written or summary.diagnostic != previous_diagnostic:
                print(_summary_line(summary), flush=True)
            previous_diagnostic = summary.diagnostic
            time.sleep(interval)
    except KeyboardInterrupt:
        return 0
    except Exception:
        # Internal errors are reported with fixed labels only; never include a
        # path, input line, exception text, or application-provided value.
        print(
            _summary_line(
                ScanSummary(
                    diagnostic="adapter_error",
                    app_version=app_version(options.app_bundle),
                    validation=_version_tag(app_version(options.app_bundle)),
                )
            ),
            flush=True,
        )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
