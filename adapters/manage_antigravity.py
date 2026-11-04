#!/usr/bin/env python3
"""Dry-run-first installer for Antigravity's documented desktop hooks."""

from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import sys
import tempfile
import uuid
from typing import Any


APP_LABEL = "Antigravity desktop"
HOOK_GROUP_BASE = "agent-watch-antigravity"
OWNER_OPTION = "--agent-watch-owner"
OWNER_PREFIX = "antigravity-v1:"
HOOK_EVENTS = ("PreInvocation", "Stop", "PreToolUse", "PostToolUse")
TOOL_EVENTS = frozenset({"PreToolUse", "PostToolUse"})
HOOK_TIMEOUT_SECONDS = 1
SCRIPT_NAME = "antigravity.py"
BRIDGE_OWNER_MARKER = b"# agent-watch-bridge-owner: antigravity-v1"


def config_path(home: Path) -> Path:
    return home / ".gemini" / "config" / "hooks.json"


def display_config() -> str:
    return "~/.gemini/config/hooks.json"


def bridge_root(home: Path) -> Path:
    return home / "Library" / "Application Support" / "Agent Watch"


def bridge_script_path(home: Path) -> Path:
    return bridge_root(home) / "bridge" / SCRIPT_NAME


def display_home_path(home: Path, path: Path) -> str:
    return "~/" + str(path.relative_to(home))


def check_no_symlink_parents(home: Path, path: Path) -> None:
    if home.is_symlink():
        raise ValueError("home path is a symbolic link")
    current = home
    for component in path.relative_to(home).parts[:-1]:
        current = current / component
        if current.is_symlink():
            raise ValueError("parent path is a symbolic link")


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def reject_non_json_constant(value: str) -> None:
    raise ValueError("configuration contains a non-JSON constant")


def load_document(path: Path) -> tuple[dict[str, Any], bytes | None]:
    if path.is_symlink():
        raise ValueError("configuration path is a symbolic link")
    if not path.exists():
        return {}, None
    if not path.is_file():
        raise ValueError("configuration path is not a regular file")
    raw = path.read_bytes()
    try:
        document = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=unique_object,
            parse_constant=reject_non_json_constant,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("configuration is not valid UTF-8 JSON") from error
    if not isinstance(document, dict):
        raise ValueError("configuration root must be a JSON object")
    return document, raw


def serialized_document(document: dict[str, Any]) -> bytes:
    return (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def owner_value(script_digest: str) -> str:
    return OWNER_PREFIX + script_digest[:16]


def command_for(
    event_name: str,
    script_path: Path,
    python_executable: Path,
    script_digest: str,
) -> str:
    arguments = [
        str(python_executable),
        str(script_path),
        "--event",
        event_name,
        OWNER_OPTION,
        owner_value(script_digest),
    ]
    return shlex.join(arguments)


def handler_for(command: str) -> dict[str, Any]:
    return {"type": "command", "command": command, "timeout": HOOK_TIMEOUT_SECONDS}


def handler_is_owned(handler: Any) -> bool:
    if not isinstance(handler, dict) or not isinstance(handler.get("command"), str):
        return False
    try:
        arguments = shlex.split(handler["command"])
    except ValueError:
        return False
    if len(arguments) < 2 or Path(arguments[1]).name != SCRIPT_NAME:
        return False
    for index, argument in enumerate(arguments[:-1]):
        if argument == OWNER_OPTION and arguments[index + 1].startswith(OWNER_PREFIX):
            return True
    return False


def has_owned_handler(group: Any) -> bool:
    if not isinstance(group, dict):
        return False
    for event_name in HOOK_EVENTS:
        handlers = group.get(event_name)
        if isinstance(handlers, list):
            for handler in handlers:
                if handler_is_owned(handler):
                    return True
                if event_name in TOOL_EVENTS and isinstance(handler, dict):
                    nested = handler.get("hooks")
                    if isinstance(nested, list) and any(handler_is_owned(item) for item in nested):
                        return True
    return False


def select_group_name(document: dict[str, Any]) -> str:
    for name, group in document.items():
        if has_owned_handler(group):
            return name
    candidate = HOOK_GROUP_BASE
    suffix = 2
    while candidate in document:
        candidate = f"{HOOK_GROUP_BASE}-{suffix}"
        suffix += 1
    return candidate


def remove_owned_handlers(document: dict[str, Any]) -> int:
    removed = 0
    for group in document.values():
        if not isinstance(group, dict):
            continue
        for event_name in HOOK_EVENTS:
            handlers = group.get(event_name)
            if not isinstance(handlers, list):
                continue
            kept = []
            for handler in handlers:
                if handler_is_owned(handler):
                    removed += 1
                elif event_name in TOOL_EVENTS and isinstance(handler, dict) and isinstance(handler.get("hooks"), list):
                    nested = handler["hooks"]
                    remaining = [item for item in nested if not handler_is_owned(item)]
                    removed += len(nested) - len(remaining)
                    if len(remaining) == len(nested):
                        kept.append(handler)
                    elif remaining or set(handler).difference({"matcher", "hooks"}):
                        kept.append({**handler, "hooks": remaining})
                else:
                    kept.append(handler)
            if kept != handlers:
                group[event_name] = kept
    return removed


def install_handlers(
    document: dict[str, Any],
    script_path: Path,
    python_executable: Path,
    script_digest: str,
) -> tuple[str, int, int]:
    group_name = select_group_name(document)
    removed = remove_owned_handlers(document)
    group = document.get(group_name)
    if group is None:
        group = {"enabled": True}
        document[group_name] = group
    if not isinstance(group, dict):
        raise ValueError("selected hook group must be a JSON object")

    added = 0
    for event_name in HOOK_EVENTS:
        handlers = group.setdefault(event_name, [])
        if not isinstance(handlers, list):
            raise ValueError(f"{event_name} hooks must be a JSON array")
        command = command_for(event_name, script_path, python_executable, script_digest)
        handler = handler_for(command)
        if event_name in TOOL_EVENTS:
            handlers.append({"matcher": "^ask_question$", "hooks": [handler]})
        else:
            handlers.append(handler)
        added += 1
    return group_name, added, removed


def ensure_directory(path: Path, private: bool) -> None:
    if path.is_symlink():
        raise ValueError("Agent Watch bridge path cannot be a symbolic link")
    path.mkdir(parents=True, exist_ok=True, mode=0o700 if private else 0o755)
    if not path.is_dir():
        raise ValueError("Agent Watch bridge path is not a directory")
    if private:
        os.chmod(path, 0o700)


def bridge_needs_update(home: Path, source_bytes: bytes) -> bool:
    root = bridge_root(home)
    directory = root / "bridge"
    target = bridge_script_path(home)
    check_no_symlink_parents(home, target)
    needs_update = False
    for path in (root, directory):
        if path.is_symlink():
            raise ValueError("Agent Watch bridge path cannot be a symbolic link")
        if not path.exists():
            return True
        if not path.is_dir():
            raise ValueError("Agent Watch bridge path is not a directory")
        if stat.S_IMODE(path.stat().st_mode) != 0o700:
            needs_update = True
    if target.is_symlink():
        raise ValueError("Agent Watch bridge script cannot be a symbolic link")
    if not target.exists():
        return True
    if not target.is_file():
        raise ValueError("Agent Watch bridge script is not a regular file")
    if target.stat().st_size == len(source_bytes) and target.read_bytes() == source_bytes:
        return needs_update or stat.S_IMODE(target.stat().st_mode) != 0o600
    if not bridge_is_owned(target):
        raise ValueError("stable bridge path contains an unowned file")
    return True


def bridge_is_owned(path: Path) -> bool:
    with path.open("rb") as existing:
        return BRIDGE_OWNER_MARKER in existing.read(512)


def install_bridge_copy(home: Path, source_bytes: bytes) -> bool:
    root = bridge_root(home)
    directory = root / "bridge"
    target = bridge_script_path(home)
    check_no_symlink_parents(home, target)
    ensure_directory(root, private=True)
    ensure_directory(directory, private=True)
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise ValueError("Agent Watch bridge script is not a regular file")
    if (
        target.exists()
        and target.stat().st_size == len(source_bytes)
        and target.read_bytes() == source_bytes
        and stat.S_IMODE(target.stat().st_mode) == 0o600
    ):
        return False
    if target.exists() and not bridge_is_owned(target):
        raise ValueError("stable bridge path contains an unowned file")

    descriptor, temporary_name = tempfile.mkstemp(prefix=".agent-watch-bridge-", dir=directory)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            output.write(source_bytes)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, target)
        os.chmod(target, 0o600)
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        return True
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def backup_path(path: Path) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return path.with_name(f"{path.name}.agent-watch-backup-{timestamp}-{uuid.uuid4().hex[:8]}")


def create_backup(path: Path, original: bytes) -> Path:
    destination = backup_path(path)
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            output.write(original)
            output.flush()
            os.fsync(output.fileno())
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        destination.unlink(missing_ok=True)
        raise
    return destination


def atomic_write_config(path: Path, data: bytes, original_mode: int | None) -> None:
    if path.is_symlink():
        raise ValueError("configuration path is a symbolic link")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".agent-watch-config-", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, original_mode if original_mode is not None else 0o600)
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        temporary_path.unlink(missing_ok=True)
        raise


def run(
    home: Path,
    apply: bool,
    uninstall: bool,
    source_path: Path,
    python_executable: Path,
) -> tuple[str, Path | None, bool]:
    path = config_path(home)
    check_no_symlink_parents(home, path)
    document, original_bytes = load_document(path)
    original_document = copy.deepcopy(document)
    original_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else None

    if uninstall:
        removed = remove_owned_handlers(document)
        config_changed = document != original_document
        bridge_changed = False
        description = f"remove {removed} Agent Watch hook handler(s)"
    else:
        source_bytes = source_path.read_bytes()
        destination = bridge_script_path(home)
        script_digest = hashlib.sha256(source_bytes).hexdigest()
        group_name, added, removed = install_handlers(
            document,
            destination,
            python_executable,
            script_digest,
        )
        config_changed = document != original_document
        bridge_changed = bridge_needs_update(home, source_bytes)
        config_summary = f"add {added} hook handler(s), replace {removed} stale handler(s)"
        if not config_changed:
            config_summary = "hook configuration already current"
        bridge_summary = (
            f"install/update bridge at {display_home_path(home, destination)}"
            if bridge_changed
            else f"use stable bridge at {display_home_path(home, destination)}"
        )
        description = f"{config_summary}; {bridge_summary}; hook group {group_name}"

    if not config_changed and not bridge_changed:
        return "no configuration or bridge change needed", None, False
    new_bytes = serialized_document(document) if config_changed else None
    if not apply:
        return description, None, False

    if config_changed:
        if path.exists() or path.is_symlink():
            if original_bytes is None or path.is_symlink() or not path.is_file() or path.read_bytes() != original_bytes:
                raise ValueError("configuration changed during inspection")
        elif original_bytes is not None:
            raise ValueError("configuration changed during inspection")

    bridge_installed = install_bridge_copy(home, source_bytes) if not uninstall and bridge_changed else False
    backup = create_backup(path, original_bytes) if config_changed and original_bytes is not None else None
    if config_changed:
        atomic_write_config(path, new_bytes or b"{}\n", original_mode)
    return description, backup, bridge_installed


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Install or remove Antigravity hooks; defaults to dry-run.")
    parser.add_argument("--apply", action="store_true", help="write the planned configuration change")
    parser.add_argument("--uninstall", action="store_true", help="remove only Agent Watch marked handlers")
    parser.add_argument("--home", type=Path, help=argparse.SUPPRESS)
    options = parser.parse_args(arguments)

    home = options.home or Path.home()
    source_path = Path(__file__).with_name(SCRIPT_NAME).resolve()
    try:
        python_executable = Path(sys.executable).resolve(strict=True)
        description, backup, bridge_installed = run(
            home,
            options.apply,
            options.uninstall,
            source_path,
            python_executable,
        )
    except Exception:
        # Avoid printing configuration content, command strings, or paths.
        print("Unable to inspect or update the Antigravity hook configuration.", file=sys.stderr)
        return 2

    label = "Applied" if options.apply else "Dry run"
    print(f"{label}: {description} for {APP_LABEL} ({display_config()}).")
    if not options.apply and description != "no configuration or bridge change needed":
        print("No files were changed. Add --apply to write this change.")
    if options.apply and bridge_installed:
        print(f"Event bridge installed: {display_home_path(home, bridge_script_path(home))}")
    if backup is not None:
        print(f"Backup: {display_home_path(home, backup)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
