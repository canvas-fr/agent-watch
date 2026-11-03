#!/usr/bin/env python3
"""Read Codex app-server thread status without starting a server or a model turn.

Only the existing app-server control socket is used. The RPC allowlist below is
read-only: initialize, thread/loaded/list, thread/read, and thread/turns/list.
Returned thread objects may contain previews or other text; this adapter only
extracts IDs, status enums, timestamps, and parent/turn metadata.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from typing import Any


APP_ID = "codex"
SOURCE = "codex_app_server"
MAX_RPC_LINE_BYTES = 4 * 1024 * 1024
MAX_LOADED_THREADS = 256
DEFAULT_INTERVAL_SECONDS = 2.0
REQUEST_TIMEOUT_SECONDS = 5.0
ALLOWED_METHODS = {"thread/loaded/list", "thread/read", "thread/turns/list"}


class StatusBridgeError(Exception):
    """A bounded, user-safe app-server communication error."""


def private_root() -> Path:
    return Path.home() / "Library" / "Application Support" / "Agent Watch"


def codex_home() -> Path:
    configured = os.environ.get("CODEX_HOME")
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".codex"


def default_control_socket() -> Path:
    return codex_home() / "app-server-control" / "app-server-control.sock"


def codex_executable() -> str | None:
    bundled = Path(
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/"
        "CodexCLI.app/Contents/MacOS/codex"
    )
    if bundled.is_file():
        return str(bundled)
    return shutil.which("codex")


def identifier(value: Any) -> str | None:
    if not isinstance(value, str) or not value or len(value) > 256:
        return None
    if any(ord(character) < 32 for character in value):
        return None
    return value


def ensure_private_directory(path: Path) -> None:
    if path.is_symlink():
        raise OSError("private output path cannot be a symbolic link")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.is_dir():
        raise OSError("private output path is not a directory")
    os.chmod(path, 0o700)


def metadata_path(session_id: str, parent_id: str | None) -> Path:
    identity = "\0".join((APP_ID, parent_id or "", session_id))
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
    return private_root() / "metadata" / "codex_app_server" / f"{digest}.json"


def read_metadata(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(value, dict):
            return value
    except (OSError, UnicodeError, json.JSONDecodeError):
        pass
    return {}


def atomic_private_write(directory: Path, filename: str, content: str) -> Path:
    ensure_private_directory(directory)
    fd, temporary_name = tempfile.mkstemp(prefix=".codex-status-", dir=directory)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            fd = -1
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        destination = directory / filename
        os.replace(temporary_path, destination)
        os.chmod(destination, 0o600)
        return destination
    except Exception:
        if fd >= 0:
            os.close(fd)
        try:
            temporary_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def emit_event(
    session_id: str,
    parent_id: str | None,
    turn_id: str,
    state: str,
) -> bool:
    if not identifier(session_id) or not identifier(turn_id):
        return False

    root = private_root()
    ensure_private_directory(root)
    metadata_dir = root / "metadata" / "codex_app_server"
    ensure_private_directory(metadata_dir)
    path = metadata_path(session_id, parent_id)
    lock_path = path.with_suffix(".lock")
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    acquired = False
    try:
        os.fchmod(lock_fd, 0o600)
        deadline = time.monotonic() + 0.1
        while True:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                time.sleep(min(0.005, remaining))

        previous = read_metadata(path)
        previous_sequence = previous.get("sequence", 0)
        if not isinstance(previous_sequence, int) or previous_sequence < 0:
            previous_sequence = 0
        if previous.get("turnID") == turn_id and previous.get("state") == state:
            return False

        sequence = previous_sequence + 1
        observed_at = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        event: dict[str, Any] = {
            "id": str(uuid.uuid4()),
            "appID": APP_ID,
            "sessionID": session_id,
            "turnID": turn_id,
            "state": state,
            "evidence": "explicit",
            "observedAt": observed_at,
            "sequence": sequence,
            "source": SOURCE,
        }
        if parent_id:
            event["parentSessionID"] = parent_id

        event_dir = root / "events"
        atomic_private_write(
            event_dir,
            f"{event['id']}.json",
            json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n",
        )
        state_record = json.dumps(
            {"turnID": turn_id, "state": state, "sequence": sequence},
            ensure_ascii=False,
            separators=(",", ":"),
        ) + "\n"
        atomic_private_write(metadata_dir, path.name, state_record)
        return True
    finally:
        try:
            if acquired:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)


def state_from_status(status: Any, turn_status: Any) -> str:
    if not isinstance(status, dict):
        return "unknown"
    kind = status.get("type")
    if kind == "active":
        flags = status.get("activeFlags")
        if isinstance(flags, list):
            if "waitingOnApproval" in flags:
                return "waitingApproval"
            if "waitingOnUserInput" in flags:
                return "waitingInput"
        return "running" if turn_status == "inProgress" else "unknown"
    if kind == "systemError":
        return "failed"
    if kind == "idle":
        if turn_status == "completed":
            return "responseEnded"
        if turn_status == "failed":
            return "failed"
        if turn_status == "interrupted":
            return "cancelled"
        return "unknown"
    return "unknown"


class AppServerProxy:
    """Small JSON-RPC client over the existing app-server control socket."""

    def __init__(self, process: subprocess.Popen[bytes]):
        self.process = process
        if process.stdout is None or process.stdin is None:
            raise StatusBridgeError("app-server proxy did not expose stdio")
        self.stdout_fd = process.stdout.fileno()
        self.stdin = process.stdin
        self.buffer = bytearray()
        self.request_id = 0

    def close(self) -> None:
        try:
            if self.process.stdin:
                self.process.stdin.close()
        except OSError:
            pass
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=1.0)

    def send(self, message: dict[str, Any]) -> None:
        if self.process.poll() is not None:
            raise StatusBridgeError("app-server proxy disconnected")
        if self.stdin.closed:
            raise StatusBridgeError("app-server proxy disconnected")
        encoded = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        try:
            self.stdin.write(encoded)
            self.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise StatusBridgeError("app-server proxy disconnected") from error

    def read_line(self, timeout: float) -> bytes | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            newline = self.buffer.find(b"\n")
            if newline >= 0:
                line = bytes(self.buffer[:newline]).rstrip(b"\r")
                del self.buffer[: newline + 1]
                if len(line) > MAX_RPC_LINE_BYTES:
                    continue
                return line
            if len(self.buffer) > MAX_RPC_LINE_BYTES:
                # Drop an oversized response without logging or persisting it.
                self.buffer.clear()
                raise StatusBridgeError("app-server response exceeded the local size limit")
            if self.process.poll() is not None:
                raise StatusBridgeError("app-server proxy disconnected")
            remaining = deadline - time.monotonic()
            ready, _, _ = select.select([self.stdout_fd], [], [], max(0.0, remaining))
            if not ready:
                return None
            chunk = os.read(self.stdout_fd, 65536)
            if not chunk:
                raise StatusBridgeError("app-server proxy disconnected")
            self.buffer.extend(chunk)
        return None

    def read_response(self, request_id: int, timeout: float = REQUEST_TIMEOUT_SECONDS) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self.read_line(deadline - time.monotonic())
            if line is None:
                continue
            try:
                message = json.loads(line)
            except (UnicodeError, json.JSONDecodeError):
                continue
            if not isinstance(message, dict) or message.get("id") != request_id:
                # Notifications are not written anywhere. Server-initiated
                # approval requests are intentionally ignored and never answered.
                continue
            return message
        raise StatusBridgeError("app-server request timed out")

    def request(self, method: str, params: dict[str, Any], timeout: float = REQUEST_TIMEOUT_SECONDS) -> dict[str, Any]:
        if method not in ALLOWED_METHODS:
            raise StatusBridgeError("refused a non-read-only app-server method")
        self.request_id += 1
        request_id = self.request_id
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        response = self.read_response(request_id, timeout)
        result = response.get("result")
        if not isinstance(result, dict):
            raise StatusBridgeError("app-server returned an unsupported response")
        return result

    def initialize(self) -> None:
        self.request_id += 1
        request_id = self.request_id
        self.send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": "initialize",
                "params": {
                    "clientInfo": {"name": "agent-watch-codex-status", "version": "0.1.0"},
                    "capabilities": {"experimentalApi": False},
                },
            }
        )
        response = self.read_response(request_id)
        if not isinstance(response.get("result"), dict) or "error" in response:
            raise StatusBridgeError("app-server initialization failed")
        self.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})


def loaded_thread_ids(client: AppServerProxy) -> list[str]:
    identifiers: list[str] = []
    cursor: str | None = None
    seen_cursors: set[str] = set()
    while len(identifiers) < MAX_LOADED_THREADS:
        params: dict[str, Any] = {"limit": 100}
        if cursor:
            params["cursor"] = cursor
        result = client.request("thread/loaded/list", params)
        data = result.get("data")
        if not isinstance(data, list):
            break
        identifiers.extend(
            thread_id
            for value in data
            if (thread_id := identifier(value)) is not None
        )
        next_cursor = result.get("nextCursor")
        if not isinstance(next_cursor, str) or not next_cursor or next_cursor in seen_cursors:
            break
        seen_cursors.add(next_cursor)
        cursor = next_cursor
    return list(dict.fromkeys(identifiers[:MAX_LOADED_THREADS]))


def read_thread_status(client: AppServerProxy, thread_id: str) -> tuple[str | None, str | None, str, str | None]:
    """Return only parent ID, turn ID/status, and normalized thread state."""
    try:
        thread_result = client.request("thread/read", {"threadId": thread_id, "includeTurns": False})
        thread = thread_result.get("thread")
        if not isinstance(thread, dict):
            return None, None, "unknown", None
        session_id = identifier(thread.get("id")) or thread_id
        parent_id = identifier(thread.get("parentThreadId"))
        raw_status = thread.get("status")
        status = None
        if isinstance(raw_status, dict):
            status = {"type": raw_status.get("type"), "activeFlags": raw_status.get("activeFlags")}
        if isinstance(status, dict) and status.get("type") == "notLoaded":
            return session_id, parent_id, "unknown", None
        del thread_result, thread
    except StatusBridgeError:
        return None, None, "unknown", None

    turn_id = None
    turn_status = None
    try:
        turns_result = client.request(
            "thread/turns/list",
            {
                "threadId": thread_id,
                "limit": 1,
                "sortDirection": "desc",
                "itemsView": "notLoaded",
            },
        )
        turns = turns_result.get("data")
        if isinstance(turns, list) and turns and isinstance(turns[0], dict):
            turn_id = identifier(turns[0].get("id"))
            turn_status = turns[0].get("status") if isinstance(turns[0].get("status"), str) else None
        del turns_result, turns
    except StatusBridgeError:
        pass

    state = state_from_status(status, turn_status)
    return session_id, parent_id, state, turn_id


def collect_snapshot(client: AppServerProxy) -> tuple[int, dict[str, int]]:
    thread_ids = loaded_thread_ids(client)
    counts: dict[str, int] = {}
    for thread_id in thread_ids:
        session_id, parent_id, state, turn_id = read_thread_status(client, thread_id)
        if not session_id:
            continue
        if turn_id:
            try:
                emit_event(session_id, parent_id, turn_id, state)
            except OSError:
                # The observer stays detached from the Codex approval/model flow.
                pass
        counts[state] = counts.get(state, 0) + 1
    return len(thread_ids), counts


def print_summary(loaded_count: int, counts: dict[str, int]) -> None:
    if not counts:
        print(f"Loaded threads: {loaded_count}; states: none")
        return
    order = ("running", "waitingApproval", "waitingInput", "responseEnded", "failed", "cancelled", "unknown")
    summary = ", ".join(f"{state}={counts[state]}" for state in order if counts.get(state, 0))
    print(f"Loaded threads: {loaded_count}; states: {summary}")


def control_socket_is_present(path: Path) -> bool:
    try:
        info = path.lstat()
        return stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid()
    except OSError:
        return False


def run(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Read loaded Codex app-server thread status; does not start a daemon or a model turn."
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--watch", action="store_true", help="poll the existing app-server until interrupted")
    mode.add_argument("--once", action="store_true", help="take one status snapshot (the default)")
    parser.add_argument("--interval", type=float, default=DEFAULT_INTERVAL_SECONDS)
    options = parser.parse_args(arguments)

    if options.interval < 0.5 or options.interval > 60:
        print("Polling interval must be between 0.5 and 60 seconds.", file=sys.stderr)
        return 2
    socket_path = default_control_socket()
    if not control_socket_is_present(socket_path):
        print(
            "No proxyable Codex app-server daemon is available; no daemon was started.",
            file=sys.stderr,
        )
        return 3

    executable = codex_executable()
    if executable is None:
        print("Codex CLI was not found; no process was started.", file=sys.stderr)
        return 3

    try:
        process = subprocess.Popen(
            [executable, "app-server", "proxy", "--sock", str(socket_path)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
        )
    except OSError:
        print("Could not connect to the existing Codex app-server proxy socket.", file=sys.stderr)
        return 3

    client = AppServerProxy(process)
    try:
        client.initialize()
        while True:
            loaded_count, counts = collect_snapshot(client)
            print_summary(loaded_count, counts)
            if not options.watch:
                return 0
            time.sleep(options.interval)
    except KeyboardInterrupt:
        return 0
    except StatusBridgeError:
        print("Codex app-server status RPC is unavailable; no task or approval request was sent.", file=sys.stderr)
        return 4
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(run())
