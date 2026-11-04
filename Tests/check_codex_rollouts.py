"""Lifecycle journal checks against temporary indexes, never a user transcript."""
from datetime import datetime, timezone, timedelta
import json
from pathlib import Path
import sqlite3
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "adapters"))
import codex_rollouts as reader

SECRET = "PRIVATE MESSAGE VALUES MUST NEVER BE DECODED OR SAVED"


def record(kind, turn, stamp, **extra):
    return json.dumps({"timestamp": stamp.isoformat(), "type": "event_msg", "payload": {
        "type": kind, "turn_id": turn, "last_agent_message": SECRET, **extra
    }}).encode() + b"\n"


def emitted(output):
    return [json.loads(p.read_bytes()) for p in (output / "events").glob("*.json")]


def check_projection():
    now = datetime.now(timezone.utc)
    raw = record("task_complete", "turn-safe", now)
    original = json.loads
    def guarded(value, *args, **kwargs):
        encoded = value.encode() if isinstance(value, str) else value
        assert SECRET.encode() not in encoded, "decoder touched a message value"
        return original(value, *args, **kwargs)
    json.loads = guarded
    try:
        event = reader.decode_lifecycle(raw)
    finally:
        json.loads = original
    assert event["state"] == "responseEnded" and event["turnID"] == "turn-safe"
    assert SECRET not in str(event)
    assert reader.decode_lifecycle(record("agent_message", "turn-safe", now)) is None
    assert reader.decode_lifecycle(b'{"type":"event_msg"') is None
    assert reader.decode_lifecycle(record("turn_aborted", "turn-safe", now, reason="interrupted"))["state"] == "cancelled"
    assert reader.decode_lifecycle(record("turn_aborted", "turn-safe", now, reason="new_reason")) is None
    assert reader.decode_lifecycle(record("turn_complete", "turn-safe", now))["state"] == "responseEnded"
    terminal_error = record("task_complete", "turn-safe", now, error={"message": SECRET})
    json.loads = guarded
    try:
        failed = reader.decode_lifecycle(terminal_error)
    finally:
        json.loads = original
    assert failed["state"] == "failed" and SECRET not in str(failed)


def check_index_and_cursor():
    with tempfile.TemporaryDirectory() as name:
        source = Path(name) / "source"
        output = Path(name) / "monitor"
        source.mkdir()
        log = source / "rollout.jsonl"
        now = datetime.now(timezone.utc)
        log.write_bytes(record("task_started", "old", now - timedelta(hours=1)) +
                        record("task_complete", "old", now - timedelta(minutes=30)))
        db = sqlite3.connect(source / "state_5.sqlite")
        db.execute("CREATE TABLE threads(id TEXT, rollout_path TEXT, attached_thread_parent_id TEXT, updated_at INTEGER, title TEXT)")
        db.execute("INSERT INTO threads VALUES(?,?,?,?,?)", ("child", str(log), "parent", 1, SECRET))
        db.commit()
        first = reader.poll(source, output, now)
        assert first["events"] == 1
        assert emitted(output)[0]["state"] == "responseEnded", "bootstrap must not replay a historical start/end pair"
        assert emitted(output)[0]["parentSessionID"] == "parent"
        assert reader.poll(source, output, now)["events"] == 0
        # A partial append must not advance past an unfinished record.
        new_start = record("task_started", "new", now + timedelta(seconds=1))
        with log.open("ab") as out: out.write(new_start[:30])
        assert reader.poll(source, output, now)["events"] == 0
        with log.open("ab") as out:
            out.write(new_start[30:])
            out.write(record("task_complete", "new", now + timedelta(seconds=2)))
        assert reader.poll(source, output, now)["events"] == 2
        assert reader.poll(source, output, now)["events"] == 0
        assert {e["state"] for e in emitted(output) if e["turnID"] == "new"} == {"running", "responseEnded"}
        # A newly discovered file after bootstrap retains its real new pair.
        fresh = source / "fresh.jsonl"
        fresh.write_bytes(record("task_started", "fresh", now + timedelta(seconds=3)) + record("task_complete", "fresh", now + timedelta(seconds=4)))
        db.execute("INSERT INTO threads VALUES(?,?,?,?,?)", ("fresh", str(fresh), None, 2, SECRET)); db.commit()
        assert reader.poll(source, output, now)["events"] == 2
        # Index paths cannot cause unrelated files to be read.
        outside = Path(name) / "outside.jsonl"
        outside.write_bytes(record("task_complete", "outside", now + timedelta(seconds=5)))
        db.execute("INSERT INTO threads VALUES(?,?,?,?,?)", ("outside", str(outside), None, 3, SECRET)); db.commit()
        assert reader.poll(source, output, now)["events"] == 0
        db.close()
        for path in output.rglob("*.json"):
            assert SECRET not in path.read_text()
            assert path.stat().st_mode & 0o777 == 0o600


if __name__ == "__main__":
    check_projection()
    check_index_and_cursor()
    print("PASS: Codex journal metadata projection, bootstrap, partial appends, identity, and cursor replay")
