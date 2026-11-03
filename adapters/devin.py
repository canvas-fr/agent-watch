#!/usr/bin/env python3
"""Capture legacy Devin Desktop Cascade hook lifecycle metadata only."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
from typing import Any, TextIO


APP_ID = "devin"
MAX_INPUT_BYTES = 1024 * 1024
HOOK_STATES = {
    "pre_user_prompt": ("running", 1),
    "post_cascade_response": ("responseEnded", 2),
}


def private_root(home: Path) -> Path:
    return home / "Library" / "Application Support" / "Agent Watch"


def clean_identifier(value: Any) -> str | None:
    """Accept bounded opaque hook IDs, never arbitrary payload values."""
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 256:
        return None
    if any(ord(character) < 32 for character in value):
        return None
    return value


def normalized_timestamp(value: Any) -> str | None:
    """Normalize the documented ISO-8601 timestamp without using local time."""
    if not isinstance(value, str) or not value or len(value) > 80:
        return None
    try:
        timestamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if timestamp.tzinfo is None:
        return None
    return timestamp.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def event_for(payload: Any) -> dict[str, Any] | None:
    """Project only stable IDs, lifecycle state, and the source timestamp."""
    if not isinstance(payload, dict):
        return None

    action = payload.get("agent_action_name")
    mapped = HOOK_STATES.get(action) if isinstance(action, str) else None
    if mapped is None:
        return None

    session_id = clean_identifier(payload.get("trajectory_id"))
    turn_id = clean_identifier(payload.get("execution_id"))
    observed_at = normalized_timestamp(payload.get("timestamp"))
    if session_id is None or turn_id is None or observed_at is None:
        return None

    state, sequence = mapped
    event_key = "\0".join((APP_ID, action, session_id, turn_id, observed_at))
    event_id = hashlib.sha256(event_key.encode("utf-8")).hexdigest()
    return {
        "id": event_id,
        "appID": APP_ID,
        "sessionID": session_id,
        "turnID": turn_id,
        "state": state,
        "evidence": "explicit",
        "observedAt": observed_at,
        "sequence": sequence,
        "source": f"{APP_ID}:{action}",
    }


def ensure_private_directory(path: Path) -> None:
    if path.is_symlink():
        raise OSError("Agent Watch output path cannot be a symbolic link")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.is_dir():
        raise OSError("Agent Watch output path is not a directory")
    os.chmod(path, 0o700)


def atomic_private_write(directory: Path, name: str, contents: str) -> Path:
    ensure_private_directory(directory)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".agent-watch-devin-", dir=directory)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            descriptor = -1
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        target = directory / name
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


def read_hook_payload(stream: TextIO) -> Any:
    """Read bounded stdin; never print or persist the original hook input."""
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


def process_payload(payload: Any, home: Path) -> dict[str, Any] | None:
    event = event_for(payload)
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


def main(arguments: list[str] | None = None, stdin: TextIO | None = None) -> int:
    parser = argparse.ArgumentParser(description="Capture metadata from legacy Devin Desktop Cascade hooks.")
    parser.add_argument("--agent-watch-managed-v1", action="store_true", required=True, help=argparse.SUPPRESS)
    parser.add_argument("--home", type=Path, help=argparse.SUPPRESS)
    options = parser.parse_args(arguments)

    try:
        payload = read_hook_payload(stdin or sys.stdin)
        process_payload(payload, options.home or Path.home())
    except Exception:
        # This observer must never interrupt the original Cascade action.
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
