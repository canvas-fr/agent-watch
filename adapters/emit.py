#!/usr/bin/env python3
"""Write metadata-only lifecycle observations for Agent Watch.

This command is designed to be called by Claude Code, Codex, or the WorkBuddy
desktop CodeBuddy runtime as a local hook. Hook input is never echoed or copied
to disk; only the explicit session/turn identifiers and event metadata below
are retained.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
from datetime import datetime, timezone
import time
from typing import Any, TextIO
import uuid


APP_IDS = ("claude_code", "codex", "workbuddy")
WAITING_INPUT_TOOL_NAMES = {
    "claude_code": frozenset({"AskUserQuestion"}),
    "codex": frozenset({"request_user_input"}),
    "workbuddy": frozenset({"AskUserQuestion"}),
}
MAX_INPUT_BYTES = 1024 * 1024
LOCK_WAIT_SECONDS = 0.1


def clean_identifier(value: Any) -> str | None:
    """Accept bounded opaque IDs only; never stringify arbitrary hook data."""
    if not isinstance(value, str) or not value or len(value) > 256:
        return None
    if any(ord(character) < 32 for character in value):
        return None
    return value


def private_root(home: Path) -> Path:
    return home / "Library" / "Application Support" / "Agent Watch"


def ensure_private_directory(path: Path) -> None:
    if path.is_symlink():
        raise OSError("Agent Watch output path cannot be a symbolic link")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)


def atomic_private_write(directory: Path, name: str, contents: str) -> Path:
    """Atomically replace a file with owner-only permissions."""
    ensure_private_directory(directory)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".agent-watch-", dir=directory)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
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


def notification_state(payload: dict[str, Any]) -> str | None:
    """Map only notification types whose lifecycle meaning is documented."""
    notification_type = payload.get("notification_type")
    if notification_type == "permission_prompt":
        return "waitingApproval"
    if notification_type == "idle_prompt":
        return "waitingInput"
    return None


def state_for(app_id: str, payload: dict[str, Any]) -> tuple[str, str] | None:
    event_name = payload.get("hook_event_name")
    event_states = {
        "UserPromptSubmit": "running",
        "PreToolUse": "running",
        "PostToolUse": "running",
        "PermissionRequest": "waitingApproval",
        "Stop": "responseEnded",
    }

    if event_name == "PreToolUse":
        tool_name = payload.get("tool_name")
        if isinstance(tool_name, str) and tool_name in WAITING_INPUT_TOOL_NAMES.get(app_id, ()):
            return "waitingInput", f"{app_id}:PreToolUse:{tool_name}"

    if event_name == "Notification":
        if app_id not in {"claude_code", "workbuddy"}:
            return None
        mapped = notification_state(payload)
        if mapped is None:
            return None
        return mapped, f"{app_id}:Notification:{payload['notification_type']}"

    if not isinstance(event_name, str):
        return None

    if event_name == "SubagentStop":
        if clean_identifier(payload.get("agent_id")) is None:
            return None
        event_states["SubagentStop"] = "responseEnded"

    if event_name == "StopFailure" and app_id in {"claude_code", "workbuddy"}:
        event_states["StopFailure"] = "failed"
    # Interrupt is a Codex lifecycle event. Other hosts are ignored if they
    # happen to send a similarly named custom event.
    elif event_name == "Interrupt" and app_id == "codex":
        event_states["Interrupt"] = "cancelled"
    elif event_name in {"StopFailure", "Interrupt"}:
        return None

    mapped = event_states.get(event_name)
    if mapped is None:
        return None
    return mapped, f"{app_id}:{event_name}"


def event_session(payload: dict[str, Any]) -> tuple[str, str | None, str | None] | None:
    parent_id = clean_identifier(payload.get("session_id"))
    if parent_id is None:
        return None

    # These hosts identify subagents with agent_id while keeping session_id
    # set to their parent. Preserve that relation using identifiers only.
    agent_id = clean_identifier(payload.get("agent_id"))
    if agent_id is not None:
        return agent_id, parent_id, parent_id
    return parent_id, None, parent_id


def state_path(root: Path, app_id: str, session_id: str) -> Path:
    """Key metadata by the same app/session identity used by event records."""
    identity = "\0".join((app_id, session_id))
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
    return root / "metadata" / f"{digest}.json"


def legacy_state_paths(
    root: Path,
    app_id: str,
    session_id: str,
    parent_id: str | None,
    current_path: Path,
) -> tuple[Path, ...]:
    """Find old parent-scoped keys that may hold this actual session's state."""
    candidates = []
    seen = {current_path}
    for legacy_parent in (parent_id, session_id, None):
        identity = "\0".join((app_id, legacy_parent or "", session_id))
        digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
        candidate = root / "metadata" / f"{digest}.json"
        if candidate not in seen:
            candidates.append(candidate)
            seen.add(candidate)
    return tuple(candidates)


def read_state(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(value, dict):
            return value
    except (OSError, UnicodeError, json.JSONDecodeError):
        pass
    return {}


def stored_sequence(state: dict[str, Any]) -> int:
    sequence = state.get("sequence", 0)
    return sequence if isinstance(sequence, int) and sequence >= 0 else 0


def read_hook_payload(stream: TextIO) -> Any:
    """Read at most one MiB from hook stdin before decoding JSON."""
    binary_stream = getattr(stream, "buffer", None)
    if binary_stream is not None:
        raw = binary_stream.read(MAX_INPUT_BYTES + 1)
        if len(raw) > MAX_INPUT_BYTES:
            raise ValueError("hook input exceeds size limit")
        text = raw.decode("utf-8")
    else:
        text = stream.read(MAX_INPUT_BYTES + 1)
        if len(text.encode("utf-8")) > MAX_INPUT_BYTES:
            raise ValueError("hook input exceeds size limit")
    return json.loads(text)


def acquire_lock(descriptor: int) -> None:
    """Wait briefly for a session writer, then fail open if it stays busy."""
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


def next_sequence_and_turn(
    app_id: str,
    payload: dict[str, Any],
    event_state: str,
    session_id: str,
    parent_id: str | None,
    root: Path,
) -> tuple[str, int]:
    metadata_dir = root / "metadata"
    ensure_private_directory(metadata_dir)
    path = state_path(root, app_id, session_id)
    lock_path = path.with_suffix(".lock")
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    lock_acquired = False
    try:
        os.fchmod(descriptor, 0o600)
        acquire_lock(descriptor)
        lock_acquired = True
        previous = read_state(path)
        sequence = stored_sequence(previous)
        for candidate_path in legacy_state_paths(
            root, app_id, session_id, parent_id, path
        ):
            candidate = read_state(candidate_path)
            candidate_sequence = stored_sequence(candidate)
            if candidate and (not previous or candidate_sequence > sequence):
                previous = candidate
                sequence = candidate_sequence

        explicit_turn = clean_identifier(payload.get("turn_id"))
        prompt_id = clean_identifier(payload.get("prompt_id"))
        if payload.get("hook_event_name") == "SubagentStop":
            turn_id = clean_identifier(previous.get("turnID")) or str(uuid.uuid4())
        elif event_state == "running" and payload.get("hook_event_name") == "UserPromptSubmit":
            turn_id = explicit_turn or prompt_id or str(uuid.uuid4())
        else:
            turn_id = explicit_turn or clean_identifier(previous.get("turnID")) or str(uuid.uuid4())

        sequence += 1
        state_data = json.dumps(
            {"turnID": turn_id, "sequence": sequence},
            ensure_ascii=False,
            separators=(",", ":"),
        ) + "\n"
        atomic_private_write(metadata_dir, path.name, state_data)
        return turn_id, sequence
    finally:
        try:
            if lock_acquired:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def process_payload(payload: Any, app_id: str, home: Path) -> dict[str, Any] | None:
    if app_id not in APP_IDS or not isinstance(payload, dict):
        return None

    mapping = state_for(app_id, payload)
    session = event_session(payload)
    if mapping is None or session is None:
        return None

    state, source = mapping
    session_id, parent_session_id, metadata_parent_id = session
    root = private_root(home)
    ensure_private_directory(root)
    turn_id, sequence = next_sequence_and_turn(
        app_id, payload, state, session_id, metadata_parent_id, root
    )
    event = {
        "id": str(uuid.uuid4()),
        "appID": app_id,
        "sessionID": session_id,
        "turnID": turn_id,
        "state": state,
        "evidence": "explicit",
        "observedAt": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "sequence": sequence,
        "source": source,
    }
    if parent_session_id is not None:
        event["parentSessionID"] = parent_session_id

    events_directory = root / "events"
    atomic_private_write(
        events_directory,
        f"{event['id']}.json",
        json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n",
    )
    return event


def main(arguments: list[str] | None = None, stdin: TextIO | None = None) -> int:
    parser = argparse.ArgumentParser(description="Write one metadata-only Agent Watch event.")
    parser.add_argument("--app", required=True, choices=APP_IDS)
    parser.add_argument(
        "--home",
        type=Path,
        help=argparse.SUPPRESS,
    )
    options = parser.parse_args(arguments)
    input_stream = stdin or sys.stdin
    payload: Any = None

    try:
        payload = read_hook_payload(input_stream)
        process_payload(payload, options.app, options.home or Path.home())
    except Exception:
        # Observers must never prevent the original agent from handling its hook.
        pass

    # Codex Stop hooks require JSON on stdout. Returning an empty object for all
    # Codex hooks is a no-op, also keeping that protocol valid after an oversized
    # or malformed input prevents us from identifying the event name.
    if options.app == "codex":
        try:
            sys.stdout.write("{}\n")
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
