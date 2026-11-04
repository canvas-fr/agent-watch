#!/usr/bin/env python3
"""Read lifecycle metadata from Codex's local rollout journal; never read message values.

The index supplies only IDs, paths and update times. The selective JSON scanner
decodes type/time/turn fields, structurally skipping every message and tool body.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import time

from antigravity import MetadataJSONReader, valid_utf8

MAX_LINE = 2 * 1024 * 1024
MAX_READ = 4 * 1024 * 1024
MAX_THREADS = 256
MAX_CYCLE_SECONDS = 1.5
MAX_CYCLE_BYTES = 16 * 1024 * 1024
EVENT_FIELDS = frozenset({"type", "turn_id", "root_turn_id", "reason", "error"})
STATES = {"task_started": "running", "turn_started": "running",
          "task_complete": "responseEnded", "turn_complete": "responseEnded"}


class LifecycleReader(MetadataJSONReader):
    def parse_selected_value(self, key, start, end):
        raw = self.raw[start:end]
        if key == "payload":
            return LifecycleReader(raw, EVENT_FIELDS).read()
        if key == "error":
            if raw == b"null":
                return False
            if raw.startswith(b"{"):
                return True  # Presence only; terminal error text is never decoded.
            raise ValueError("unexpected terminal error shape")
        if len(raw) > 1024 or not raw.startswith(b'"'):
            raise ValueError("invalid metadata field")
        result = json.loads(raw)
        if not isinstance(result, str) or len(result.encode()) > 256:
            raise ValueError("metadata exceeds bounds")
        return result


def decode_lifecycle(raw):
    if len(raw) > MAX_LINE or not valid_utf8(raw):
        return None
    try:
        record = LifecycleReader(raw, frozenset({"type", "timestamp", "payload"})).read()
        if record.get("type") != "event_msg":
            return None
        payload = record.get("payload", {})
        kind = payload.get("type")
        state = STATES.get(kind)
        if kind in {"task_complete", "turn_complete"} and payload.get("error"):
            state = "failed"
        if kind == "turn_aborted" and payload.get("reason") == "interrupted":
            state = "failed" if payload.get("error") else "cancelled"
        turn = payload.get("turn_id")
        stamp = record.get("timestamp")
        if not state or not identifier(turn) or not isinstance(stamp, str):
            return None
        observed = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        if observed.tzinfo is None:
            return None
        return {"turnID": turn, "state": state, "observedAt": stamp,
                "source": "codex_rollout:" + kind + (":terminal_error" if payload.get("error") else "")}
    except (ValueError, TypeError, RecursionError, UnicodeError):
        return None


def identifier(value):
    return isinstance(value, str) and 0 < len(value.encode()) <= 256 and not any(ord(c) < 32 for c in value)


def atomic_json(path, value):
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError("unsafe monitor storage")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    fd, name = tempfile.mkstemp(prefix=".watch-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as out:
            json.dump(value, out, separators=(",", ":"))
            out.write("\n")
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def indexed_threads(source):
    # Future database names need an explicit compatibility review.
    index = source / "state_5.sqlite"
    if not index.is_file() or index.is_symlink():
        return []
    connection = sqlite3.connect(index.as_uri() + "?mode=ro", uri=True, timeout=0.2)
    try:
        connection.execute("PRAGMA query_only=ON")
        columns = {row[1] for row in connection.execute("PRAGMA table_info(threads)")}
        parent = "attached_thread_parent_id" if "attached_thread_parent_id" in columns else "NULL"
        return connection.execute(
            f"SELECT id, rollout_path, {parent} FROM threads "
            "WHERE rollout_path IS NOT NULL ORDER BY updated_at DESC LIMIT ?", (MAX_THREADS,)
        ).fetchall()
    finally:
        connection.close()


def poll(source, output, now=None):
    now = now or datetime.now(timezone.utc)
    metadata = output / "metadata" / "codex-rollouts.json"
    try:
        previous = json.loads(metadata.read_bytes()) if metadata.stat().st_size < 1024 * 1024 else {}
    except (OSError, ValueError):
        previous = {}
    cursors = previous.get("files", {})
    initialized = previous.get("initializedAt", now.isoformat())
    initialized_at = datetime.fromisoformat(initialized)
    rows = indexed_threads(source)
    active_keys = {hashlib.sha256(str(row[1]).encode()).hexdigest() for row in rows if isinstance(row[1], str)}
    next_cursors = {key: value for key, value in cursors.items() if key in active_keys}
    rotation = int(previous.get("rotation", 0)) % len(rows) if rows else 0
    rows = rows[rotation:] + rows[:rotation]
    visited = 0
    remaining_bytes = MAX_CYCLE_BYTES
    deadline = time.monotonic() + MAX_CYCLE_SECONDS
    total = 0
    watched = 0
    errors = 0
    for session_id, path_value, parent_id in rows:
        if time.monotonic() >= deadline or remaining_bytes <= 0:
            break
        visited += 1
        key = None
        if not identifier(session_id) or not isinstance(path_value, str):
            continue
        path = Path(path_value)
        # Never follow an index entry into unrelated files or a symbolic link.
        try:
            if path.is_symlink() or not path.resolve().is_relative_to(source.resolve()):
                continue
            stat = path.stat()
            if not path.is_file():
                continue
            key = hashlib.sha256(str(path).encode()).hexdigest()
            old = cursors.get(key, {})
            same_file = old.get("inode") == stat.st_ino and 0 <= old.get("offset", -1) <= stat.st_size
            start = old["offset"] if same_file else max(0, stat.st_size - MAX_READ)
            baseline = not old or old.get("bootstrapping", False)
            transitions = []
            with path.open("rb") as stream:
                stream.seek(start)
                skipping = bool(old.get("skipping")) if same_file else start > 0
                if start and not same_file:
                    fragment = stream.readline(MAX_LINE + 1)
                    skipping = not fragment.endswith(b"\n")
                scan_start = stream.tell()
                while stream.tell() - scan_start < min(MAX_READ, remaining_bytes) and time.monotonic() < deadline:
                    position = stream.tell()
                    line = stream.readline(MAX_LINE + 1)
                    if not line:
                        break
                    if skipping:
                        skipping = not line.endswith(b"\n")
                        continue
                    if not line.endswith(b"\n"):
                        # Partial append: retry it later. Oversized complete
                        # records are skipped through their next newline.
                        if len(line) <= MAX_LINE:
                            stream.seek(position)
                            break
                        skipping = True
                        continue
                    event = decode_lifecycle(line)
                    if event:
                        event.update({"id": hashlib.sha256((key + ":" + str(stat.st_ino) + ":" + str(position)).encode()).hexdigest(),
                                      "appID": "codex", "sessionID": session_id, "evidence": "explicit"})
                        if identifier(parent_id):
                            event["parentSessionID"] = parent_id
                        transitions.append(event)
                offset = stream.tell()
                remaining_bytes -= offset - start
            baseline_event = old.get("baselineEvent") if baseline else None
            if baseline:
                # Bootstrap one latest historical state, then keep all new
                # lifecycle events. Historical conversations never replay a
                # start/end pair just because the monitor was first installed.
                old_events = [e for e in transitions if datetime.fromisoformat(e["observedAt"].replace("Z", "+00:00")) < initialized_at]
                new_events = [e for e in transitions if e not in old_events]
                if old_events:
                    baseline_event = old_events[-1]
                if offset >= stat.st_size or new_events:
                    transitions = ([baseline_event] if baseline_event else []) + new_events
                    baseline = False
                    baseline_event = None
                else:
                    transitions = []
            for event in transitions:
                atomic_json(output / "events" / (event["id"] + ".json"), event)
                total += 1
            next_cursors[key] = {"inode": stat.st_ino, "offset": offset, "skipping": skipping,
                                 "bootstrapping": baseline, "baselineEvent": baseline_event}
            watched += 1
        except (OSError, ValueError, TypeError):
            errors += 1
            if key in cursors:
                next_cursors[key] = cursors[key]
    atomic_json(metadata, {"initializedAt": initialized, "files": next_cursors,
                           "rotation": (rotation + visited) % len(rows) if rows else 0})
    return {"status": "ok" if watched else "no_records", "sessions": watched, "events": total, "errors": errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--source", type=Path)
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    source = args.source or args.home / ".codex"
    output = args.home / "Library/Application Support/Agent Watch"
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = output / "codex-rollouts.lock"
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return 0
    try:
        while True:
            try:
                result = poll(source, output)
            except Exception:
                result = {"status": "source_unavailable", "events": 0}
            print(json.dumps(result), flush=True)
            if not args.watch:
                break
            time.sleep(1)
    finally:
        os.close(fd)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
