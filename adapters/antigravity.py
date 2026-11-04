#!/usr/bin/env python3
# agent-watch-bridge-owner: antigravity-v1
"""Metadata-only bridge for Antigravity desktop lifecycle hooks.

Only the documented conversation, invocation, and stop metadata is retained.
All other top-level JSON values are structurally skipped and never decoded.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
from datetime import datetime, timezone
from typing import Any, BinaryIO
import uuid


APP_ID = "antigravity"
MAX_INPUT_BYTES = 1024 * 1024
LOCK_WAIT_SECONDS = 0.1
MAX_STATE_BYTES = 4096
JSON_PRIMITIVE = re.compile(rb"(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)")
JSON_INTEGER = re.compile(rb"-?(?:0|[1-9][0-9]*)\Z")

PRE_INVOCATION_FIELDS = frozenset({"conversationId", "invocationNum", "initialNumSteps"})
STOP_FIELDS = frozenset({"conversationId", "executionNum", "terminationReason", "fullyIdle"})
TOOL_FIELDS = frozenset({"conversationId", "toolCall"})

# The web guide uses lowercase examples; the installed 2.28.2 Hook Contract
# names ExecutorTerminationReason values. Only documented meanings are mapped.
NORMAL_STOP_REASONS = frozenset({"model_stop", "NO_TOOL_CALL"})
FAILED_STOP_REASONS = frozenset({"error", "max_steps_exceeded", "ERROR", "MAX_INVOCATIONS",
                                "MAX_FORCED_INVOCATIONS", "MAX_TOKEN_BUDGET_EXCEEDED"})
CANCELLED_STOP_REASONS = frozenset({"USER_CANCELED"})


def private_root(home: Path) -> Path:
    return home / "Library" / "Application Support" / "Agent Watch"


def ensure_private_directory(path: Path) -> None:
    if path.is_symlink():
        raise OSError("Agent Watch output path cannot be a symbolic link")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.is_dir():
        raise OSError("Agent Watch output path is not a directory")
    os.chmod(path, 0o700)


def atomic_private_write(directory: Path, name: str, contents: bytes) -> Path:
    ensure_private_directory(directory)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".agent-watch-", dir=directory)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        target = directory / name
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


def clean_identifier(value: Any) -> str | None:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 256:
        return None
    if any(ord(character) < 32 for character in value):
        return None
    return value


def valid_utf8(raw: bytes) -> bool:
    """Validate UTF-8 without decoding or retaining unapproved string values."""
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
    """Validate JSON bytes while decoding values only for an explicit allowlist."""

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
        if key == "toolCall":
            # Read the tool's name, skipping args without decoding their values.
            return MetadataJSONReader(raw_value, frozenset({"name"})).read()
        if key in {"conversationId", "terminationReason"}:
            max_bytes = 2048 if key == "conversationId" else 128
            if not raw_value.startswith(b'"') or len(raw_value) > max_bytes:
                raise ValueError("invalid bounded string field")
        elif key == "name":
            if not raw_value.startswith(b'"') or len(raw_value) > 128:
                raise ValueError("invalid tool name")
        elif key in {"invocationNum", "initialNumSteps", "executionNum"}:
            if len(raw_value) > 20 or JSON_INTEGER.fullmatch(raw_value) is None:
                raise ValueError("invalid sequence number")
        elif key == "fullyIdle" and raw_value not in (b"true", b"false"):
            raise ValueError("invalid fullyIdle field")
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
                value = self.parse_selected_value(key, value_start, value_end)
                selected[key] = value
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


def read_hook_payload(stream: BinaryIO, event_name: str) -> dict[str, Any]:
    raw = stream.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        raise ValueError("hook input exceeds size limit")
    if not valid_utf8(raw):
        raise ValueError("hook input is not valid UTF-8 JSON")
    allowed = (PRE_INVOCATION_FIELDS if event_name == "PreInvocation" else
               STOP_FIELDS if event_name == "Stop" else TOOL_FIELDS)
    return MetadataJSONReader(raw, allowed).read()


def state_path(root: Path, conversation_id: str) -> Path:
    identity = f"{APP_ID}\0{conversation_id}"
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
    return root / "metadata" / f"{digest}.antigravity.json"


def read_state(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        return {}
    try:
        with path.open("rb") as source:
            raw = source.read(MAX_STATE_BYTES + 1)
        if len(raw) > MAX_STATE_BYTES:
            return {}
        value = json.loads(raw.decode("utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {}


def acquire_lock(descriptor: int) -> None:
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    while True:
        if time.monotonic() >= deadline:
            raise TimeoutError("session metadata lock remained busy")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("session metadata lock remained busy")
            time.sleep(min(0.005, remaining))


def state_for_stop(termination_reason: str, fully_idle: bool) -> tuple[str, str]:
    if termination_reason in CANCELLED_STOP_REASONS:
        pending_suffix = ":background_pending" if not fully_idle else ""
        return "cancelled", f"antigravity:Stop:{termination_reason}{pending_suffix}"
    if termination_reason in FAILED_STOP_REASONS:
        pending_suffix = ":background_pending" if not fully_idle else ""
        return "failed", f"antigravity:Stop:{termination_reason}{pending_suffix}"
    if termination_reason in NORMAL_STOP_REASONS:
        if fully_idle:
            return "responseEnded", f"antigravity:Stop:{termination_reason}"
        return "running", "antigravity:Stop:background_tasks"
    pending_suffix = ":background_pending" if not fully_idle else ""
    return "unknown", f"antigravity:Stop:unknown_termination{pending_suffix}"


def event_record(
    conversation_id: str,
    turn_id: str,
    sequence: int,
    state: str,
    source: str,
) -> dict[str, Any]:
    return {
        "id": str(uuid.uuid4()),
        "appID": APP_ID,
        "sessionID": conversation_id,
        "turnID": turn_id,
        "state": state,
        "evidence": "explicit",
        "observedAt": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "sequence": sequence,
        "source": source,
    }


def process_payload(payload: dict[str, Any], event_name: str, home: Path) -> dict[str, Any] | None:
    conversation_id = clean_identifier(payload.get("conversationId"))
    if conversation_id is None:
        return None

    if event_name == "PreInvocation":
        if type(payload.get("invocationNum")) is not int or payload["invocationNum"] < 0:
            return None
        if type(payload.get("initialNumSteps")) is not int or payload["initialNumSteps"] < 0:
            return None
    elif event_name == "Stop":
        if type(payload.get("executionNum")) is not int or payload["executionNum"] < 0:
            return None
        if not isinstance(payload.get("terminationReason"), str):
            return None
        if type(payload.get("fullyIdle")) is not bool:
            return None
    elif event_name in {"PreToolUse", "PostToolUse"}:
        tool = payload.get("toolCall")
        if not isinstance(tool, dict) or tool.get("name") != "ask_question":
            return None
    else:
        return None

    root = private_root(home)
    ensure_private_directory(root)
    metadata_dir = root / "metadata"
    ensure_private_directory(metadata_dir)
    path = state_path(root, conversation_id)
    lock_path = path.with_suffix(".lock")
    open_flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        open_flags |= os.O_NOFOLLOW
    descriptor = os.open(lock_path, open_flags, 0o600)
    acquired = False
    try:
        os.fchmod(descriptor, 0o600)
        acquire_lock(descriptor)
        acquired = True
        previous = read_state(path)
        sequence = previous.get("sequence", 0)
        if type(sequence) is not int or sequence < 0:
            sequence = 0
        active = previous.get("active") is True
        current_turn = clean_identifier(previous.get("turnID")) if active else None

        if event_name == "PreInvocation":
            turn_id = current_turn or str(uuid.uuid4())
            sequence += 1
            state_data = {
                "conversationId": conversation_id,
                "turnID": turn_id,
                "sequence": sequence,
                "active": True,
            }
            event = event_record(
                conversation_id,
                turn_id,
                sequence,
                "running",
                "antigravity:PreInvocation",
            )
        elif event_name in {"PreToolUse", "PostToolUse"}:
            # Tools cannot invent a task identity or revive a terminal turn.
            if current_turn is None:
                return None
            sequence += 1
            state_data = {
                "conversationId": conversation_id, "turnID": current_turn,
                "sequence": sequence, "active": True,
            }
            state = "waitingInput" if event_name == "PreToolUse" else "running"
            event = event_record(conversation_id, current_turn, sequence, state,
                                 f"antigravity:{event_name}:ask_question")
        else:
            # executionNum is introduced only by Stop. It must never create a
            # new turn: without an open PreInvocation turn, ignore this event.
            if current_turn is None:
                return None
            turn_id = current_turn
            state, source = state_for_stop(payload["terminationReason"], payload["fullyIdle"])
            sequence += 1
            state_data = {
                "conversationId": conversation_id,
                "turnID": turn_id,
                "sequence": sequence,
                # A failed foreground execution is terminal in the shared
                # state machine. A later retry must begin a new observation
                # turn even if background work from the failed one remains.
                "active": not payload["fullyIdle"] and state not in {"failed", "cancelled"},
            }
            event = event_record(conversation_id, turn_id, sequence, state, source)

        atomic_private_write(
            metadata_dir,
            path.name,
            (json.dumps(state_data, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"),
        )
        events_dir = root / "events"
        atomic_private_write(
            events_dir,
            f"{event['id']}.json",
            (json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"),
        )
        return event
    finally:
        try:
            if acquired:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def main(arguments: list[str] | None = None, stdin: BinaryIO | None = None, stdout: Any = None) -> int:
    parser = argparse.ArgumentParser(description="Record Antigravity lifecycle metadata for Agent Watch.")
    parser.add_argument("--event", required=True, choices=("PreInvocation", "Stop", "PreToolUse", "PostToolUse"))
    parser.add_argument("--home", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--agent-watch-owner", help=argparse.SUPPRESS)
    options = parser.parse_args(arguments)
    input_stream = stdin or sys.stdin.buffer
    output_stream = stdout or sys.stdout

    try:
        payload = read_hook_payload(input_stream, options.event)
        process_payload(payload, options.event, options.home or Path.home())
    except Exception:
        # A monitor hook must fail open and never delay the host's execution.
        pass

    # Antigravity expects a JSON object from command hooks. `allow` does not
    # inject steps or continue the loop; only `continue` blocks Stop according
    # to the Hooks contract.
    try:
        if options.event in {"Stop", "PreToolUse"}:
            output_stream.write('{"decision":"allow"}\n')
        else:
            output_stream.write("{}\n")
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
