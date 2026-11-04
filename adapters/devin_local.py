#!/usr/bin/env python3
# agent-watch-bridge-owner: devin-local-v1
"""Capture metadata-only lifecycle events from Devin Local hooks."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any, TextIO


APP_ID = "devin"
OWNERSHIP_MARKER = "--agent-watch-devin-local-managed-v1"
MAX_INPUT_BYTES = 1024 * 1024
HOOK_STATES = {
    "UserPromptSubmit": "running",
    "PermissionRequest": "waitingApproval",
    "PreToolUse": "running",
    "PostToolUse": "running",
    "Stop": "unknown",
}
STOP_INTENT_SOURCE = "devin_local:Stop:awaiting_confirmation"
ALLOWED_FIELDS = frozenset({"hook_event_name", "session_id", "prompt_id"})
JSON_PRIMITIVE = re.compile(
    rb"(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)"
)


def private_root(home: Path) -> Path:
    return home / "Library" / "Application Support" / "Agent Watch"


def clean_identifier(value: Any) -> str | None:
    """Accept bounded opaque identifiers only."""
    if not isinstance(value, str) or not value:
        return None
    try:
        if len(value.encode("utf-8")) > 256:
            return None
    except UnicodeEncodeError:
        return None
    if any(ord(character) < 32 or character in "\u0085\u2028\u2029" for character in value):
        return None
    return value


def receipt_timestamp(value: datetime | None = None) -> str:
    """Use hook receipt time because Devin does not document a source timestamp."""
    timestamp = value or datetime.now(timezone.utc)
    if timestamp.tzinfo is None:
        timestamp = timestamp.replace(tzinfo=timezone.utc)
    return timestamp.astimezone(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def event_for(payload: Any, observed_at: datetime | None = None) -> dict[str, Any] | None:
    """Project documented lifecycle IDs and event name; ignore all content fields."""
    if not isinstance(payload, dict):
        return None

    hook_name = payload.get("hook_event_name")
    state = HOOK_STATES.get(hook_name) if isinstance(hook_name, str) else None
    if state is None:
        return None

    session_id = clean_identifier(payload.get("session_id"))
    turn_id = clean_identifier(payload.get("prompt_id"))
    if session_id is None or turn_id is None:
        return None

    source_time = receipt_timestamp(observed_at)
    event_key = "\0".join((APP_ID, hook_name, session_id, turn_id, source_time))
    event_id = hashlib.sha256(event_key.encode("utf-8")).hexdigest()
    source = STOP_INTENT_SOURCE if hook_name == "Stop" else f"devin_local:{hook_name}"
    return {
        "id": event_id,
        "appID": APP_ID,
        "sessionID": session_id,
        "turnID": turn_id,
        "state": state,
        "evidence": "explicit",
        "observedAt": source_time,
        "source": source,
    }


def valid_utf8(raw: bytes) -> bool:
    """Validate UTF-8 bytes without decoding unapproved JSON strings."""
    index = 0
    while index < len(raw):
        first = raw[index]
        if first <= 0x7F:
            index += 1
            continue

        if 0xC2 <= first <= 0xDF:
            width = 2
            second_low, second_high = 0x80, 0xBF
        elif first == 0xE0:
            width = 3
            second_low, second_high = 0xA0, 0xBF
        elif 0xE1 <= first <= 0xEC or 0xEE <= first <= 0xEF:
            width = 3
            second_low, second_high = 0x80, 0xBF
        elif first == 0xED:
            width = 3
            second_low, second_high = 0x80, 0x9F
        elif first == 0xF0:
            width = 4
            second_low, second_high = 0x90, 0xBF
        elif 0xF1 <= first <= 0xF3:
            width = 4
            second_low, second_high = 0x80, 0xBF
        elif first == 0xF4:
            width = 4
            second_low, second_high = 0x80, 0x8F
        else:
            return False

        if index + width > len(raw):
            return False
        second = raw[index + 1]
        if not second_low <= second <= second_high:
            return False
        if any(not 0x80 <= raw[position] <= 0xBF for position in range(index + 2, index + width)):
            return False
        index += width
    return True


class MetadataJSONReader:
    """Validate hook JSON while decoding only event name and correlation IDs."""

    def __init__(self, raw: bytes, allowed_fields: frozenset[str]) -> None:
        self.raw = raw
        self.allowed_fields = allowed_fields

    def skip_space(self, index: int) -> int:
        while index < len(self.raw) and self.raw[index] in (32, 9, 13, 10):
            index += 1
        return index

    def skip_string(self, index: int) -> int:
        if index >= len(self.raw) or self.raw[index] != 34:
            raise ValueError("expected JSON string")
        index += 1
        while index < len(self.raw):
            character = self.raw[index]
            if character == 34:
                return index + 1
            if character < 0x20:
                raise ValueError("invalid JSON string")
            if character == 92:
                index += 1
                if index >= len(self.raw):
                    raise ValueError("incomplete JSON escape")
                escape = self.raw[index]
                if escape == 117:
                    digits = self.raw[index + 1 : index + 5]
                    if len(digits) != 4 or any(digit not in b"0123456789abcdefABCDEF" for digit in digits):
                        raise ValueError("invalid JSON unicode escape")
                    index += 4
                elif escape not in (34, 92, 47, 98, 102, 110, 114, 116):
                    raise ValueError("invalid JSON escape")
            index += 1
        raise ValueError("unterminated JSON string")

    def skip_value(self, index: int) -> int:
        index = self.skip_space(index)
        if index >= len(self.raw):
            raise ValueError("missing JSON value")
        character = self.raw[index]
        if character == 34:
            return self.skip_string(index)
        if character == 123:
            index = self.skip_space(index + 1)
            if index < len(self.raw) and self.raw[index] == 125:
                return index + 1
            while True:
                index = self.skip_string(index)
                index = self.skip_space(index)
                if index >= len(self.raw) or self.raw[index] != 58:
                    raise ValueError("invalid JSON object")
                index = self.skip_value(index + 1)
                index = self.skip_space(index)
                if index < len(self.raw) and self.raw[index] == 125:
                    return index + 1
                if index >= len(self.raw) or self.raw[index] != 44:
                    raise ValueError("invalid JSON object")
                index = self.skip_space(index + 1)
        if character == 91:
            index = self.skip_space(index + 1)
            if index < len(self.raw) and self.raw[index] == 93:
                return index + 1
            while True:
                index = self.skip_value(index)
                index = self.skip_space(index)
                if index < len(self.raw) and self.raw[index] == 93:
                    return index + 1
                if index >= len(self.raw) or self.raw[index] != 44:
                    raise ValueError("invalid JSON array")
                index = self.skip_space(index + 1)

        match = JSON_PRIMITIVE.match(self.raw, index)
        if match is None:
            raise ValueError("invalid JSON value")
        end = match.end()
        if end < len(self.raw) and self.raw[end] not in b" \t\r\n,]}":
            raise ValueError("invalid JSON primitive")
        return end

    def parse_selected_value(self, key: str, start: int, end: int) -> Any:
        raw_value = self.raw[start:end]
        max_bytes = 128 if key == "hook_event_name" else 4096
        if not raw_value.startswith(b'"') or len(raw_value) > max_bytes:
            raise ValueError("invalid bounded metadata field")
        return json.loads(raw_value.decode("utf-8"))

    def read(self) -> dict[str, Any]:
        index = self.skip_space(0)
        if index >= len(self.raw) or self.raw[index] != 123:
            raise ValueError("hook payload must be a JSON object")
        index = self.skip_space(index + 1)
        selected: dict[str, Any] = {}
        seen: set[str] = set()
        if index < len(self.raw) and self.raw[index] == 125:
            index = self.skip_space(index + 1)
            if index != len(self.raw):
                raise ValueError("trailing JSON content")
            return selected

        while True:
            key_start = index
            key_end = self.skip_string(key_start)
            if key_end - key_start > 512:
                raise ValueError("JSON field name exceeds size limit")
            key = json.loads(self.raw[key_start:key_end].decode("utf-8"))
            if not isinstance(key, str):
                raise ValueError("invalid JSON field name")
            if key in seen:
                raise ValueError("duplicate JSON field")
            seen.add(key)
            index = self.skip_space(key_end)
            if index >= len(self.raw) or self.raw[index] != 58:
                raise ValueError("invalid JSON object")
            value_start = self.skip_space(index + 1)
            if key in self.allowed_fields:
                value_end = self.skip_value(value_start)
                selected[key] = self.parse_selected_value(key, value_start, value_end)
                index = value_end
            else:
                index = self.skip_value(value_start)

            index = self.skip_space(index)
            if index < len(self.raw) and self.raw[index] == 125:
                index = self.skip_space(index + 1)
                if index != len(self.raw):
                    raise ValueError("trailing JSON content")
                return selected
            if index >= len(self.raw) or self.raw[index] != 44:
                raise ValueError("invalid JSON object")
            index = self.skip_space(index + 1)


def ensure_private_directory(path: Path) -> None:
    if path.is_symlink():
        raise OSError("Agent Watch output path cannot be a symbolic link")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.is_dir():
        raise OSError("Agent Watch output path is not a directory")
    os.chmod(path, 0o700)


def atomic_private_write(directory: Path, name: str, contents: str) -> Path:
    ensure_private_directory(directory)
    target = directory / name
    if target.is_symlink():
        raise OSError("Agent Watch event path cannot be a symbolic link")

    descriptor, temporary_name = tempfile.mkstemp(prefix=".agent-watch-devin-local-", dir=directory)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            descriptor = -1
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        if target.is_symlink():
            raise OSError("Agent Watch event path cannot be a symbolic link")
        os.replace(temporary_path, target)
        os.chmod(target, 0o600)
        return target
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def read_hook_payload(stream: TextIO) -> dict[str, Any]:
    """Read one bounded chunk and decode only explicit metadata fields."""
    binary_stream = getattr(stream, "buffer", None)
    if binary_stream is not None:
        raw = binary_stream.read(MAX_INPUT_BYTES + 1)
    else:
        raw = stream.read(MAX_INPUT_BYTES + 1).encode("utf-8")
    if len(raw) > MAX_INPUT_BYTES:
        raise ValueError("hook input exceeds size limit")
    if not valid_utf8(raw):
        raise ValueError("hook input is not valid UTF-8 JSON")
    return MetadataJSONReader(raw, ALLOWED_FIELDS).read()


def process_payload(
    payload: Any,
    home: Path,
    observed_at: datetime | None = None,
) -> dict[str, Any] | None:
    event = event_for(payload, observed_at)
    if event is None:
        return None

    root = private_root(home)
    ensure_private_directory(root)
    event_directory = root / "events"
    atomic_private_write(
        event_directory,
        f"{event['id']}.json",
        json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n",
    )
    return event


def parse_arguments(arguments: list[str]) -> Path | None:
    """Require the installer's marker and accept a hidden fixture home path."""
    home = Path.home()
    found_marker = False
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == OWNERSHIP_MARKER:
            found_marker = True
        elif argument == "--home" and index + 1 < len(arguments):
            index += 1
            home = Path(arguments[index])
        else:
            return None
        index += 1
    return home if found_marker else None


def main(arguments: list[str] | None = None, stdin: TextIO | None = None) -> int:
    options = parse_arguments(sys.argv[1:] if arguments is None else arguments)
    if options is None:
        return 0

    received_at = datetime.now(timezone.utc)
    try:
        stream = sys.stdin if stdin is None else stdin
        payload = read_hook_payload(stream)
        process_payload(payload, options, received_at)
    except Exception:
        # Metadata observation must not delay or alter Devin's lifecycle action.
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
