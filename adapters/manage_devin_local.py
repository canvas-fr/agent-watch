#!/usr/bin/env python3
"""Dry-run-first installer for Devin Local's documented CLI-format hooks."""

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


CONFIG_RELATIVE_PATH = Path(".config") / "devin" / "config.json"
APP_LABEL = "Devin Local"
HOOK_EVENTS = ("UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "Stop")
HOOK_TIMEOUT_SECONDS = 2
OWNERSHIP_MARKER = "--agent-watch-devin-local-managed-v1"
BRIDGE_OWNER_MARKER = b"# agent-watch-bridge-owner: devin-local-v1"


def config_path(home: Path) -> Path:
    return home / CONFIG_RELATIVE_PATH


def display_config() -> str:
    return "~/.config/devin/config.json"


def bridge_root(home: Path) -> Path:
    return home / "Library" / "Application Support" / "Agent Watch"


def bridge_script_path(home: Path) -> Path:
    return bridge_root(home) / "bridge" / "devin_local.py"


def display_user_path(home: Path, path: Path) -> str:
    return "~/" + str(path.relative_to(home))


def command_for(script_path: Path, python_executable: Path) -> str:
    return (
        f"{shlex.quote(str(python_executable))} {shlex.quote(str(script_path))} "
        f"{OWNERSHIP_MARKER}"
    )


def expected_group(command: str) -> dict[str, Any]:
    return {
        "matcher": "",
        "hooks": [
            {
                "type": "command",
                "command": command,
                "timeout": HOOK_TIMEOUT_SECONDS,
            }
        ],
    }


def handler_is_owned(handler: Any) -> bool:
    if not isinstance(handler, dict):
        return False
    command = handler.get("command")
    if not isinstance(command, str):
        return False
    try:
        return OWNERSHIP_MARKER in shlex.split(command)
    except ValueError:
        return False


def remove_managed_handlers(document: dict[str, Any]) -> int:
    hooks_root = document.get("hooks")
    if hooks_root is None:
        return 0
    if not isinstance(hooks_root, dict):
        raise ValueError("hooks must be a JSON object")

    removed = 0
    for event_name in list(hooks_root):
        groups = hooks_root[event_name]
        if not isinstance(groups, list):
            raise ValueError("each hooks event must be a JSON array")

        remaining_groups = []
        for group in groups:
            if not isinstance(group, dict):
                raise ValueError("each hook matcher group must be a JSON object")
            handlers = group.get("hooks")
            if not isinstance(handlers, list):
                raise ValueError("each hook matcher group must contain a JSON array")

            remaining_handlers = []
            for handler in handlers:
                if handler_is_owned(handler):
                    removed += 1
                else:
                    remaining_handlers.append(handler)

            if len(remaining_handlers) == len(handlers):
                remaining_groups.append(group)
            elif remaining_handlers:
                group["hooks"] = remaining_handlers
                remaining_groups.append(group)
            elif set(group).difference({"matcher", "hooks"}):
                group["hooks"] = []
                remaining_groups.append(group)

        if remaining_groups:
            hooks_root[event_name] = remaining_groups
        else:
            hooks_root.pop(event_name, None)

    if removed and not hooks_root:
        document.pop("hooks", None)
    return removed


def install_managed_handlers(document: dict[str, Any], command: str) -> tuple[int, int]:
    """Preserve user hooks and install exactly one owner-marked hook per event."""
    if not isinstance(document, dict):
        raise ValueError("configuration root must be a JSON object")
    hooks_root = document.setdefault("hooks", {})
    if not isinstance(hooks_root, dict):
        raise ValueError("hooks must be a JSON object")

    removed = remove_managed_handlers(document)
    hooks_root = document.setdefault("hooks", {})
    desired = expected_group(command)
    added = 0

    for event_name in HOOK_EVENTS:
        groups = hooks_root.setdefault(event_name, [])
        if not isinstance(groups, list):
            raise ValueError("each hooks event must be a JSON array")

        matching_group = next(
            (
                group
                for group in groups
                if isinstance(group, dict) and group.get("matcher", "") == ""
            ),
            None,
        )
        if matching_group is None:
            groups.append(desired)
        else:
            handlers = matching_group.get("hooks")
            if not isinstance(handlers, list):
                raise ValueError("each hook matcher group must contain a JSON array")
            handlers.append(desired["hooks"][0])
        added += 1

    return added, removed


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def reject_non_json_constant(value: str) -> None:
    raise ValueError(f"configuration contains a non-JSON constant: {value}")


def load_document(path: Path) -> tuple[dict[str, Any], bytes | None]:
    if path.parent.is_symlink() or path.parent.parent.is_symlink():
        raise ValueError("configuration directory is a symbolic link")
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
        # Devin supports JSON comments, but rewriting those comments would be
        # lossy. Refuse rather than silently remove user-authored comments.
        raise ValueError("configuration must be strict UTF-8 JSON for safe editing") from error
    if not isinstance(document, dict):
        raise ValueError("configuration root must be a JSON object")
    return document, raw


def serialized_document(document: dict[str, Any]) -> bytes:
    return (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def backup_path(path: Path) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    suffix = uuid.uuid4().hex[:8]
    return path.with_name(f"{path.name}.agent-watch-backup-{timestamp}-{suffix}")


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


def atomic_write(path: Path, contents: bytes, mode: int | None) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=".agent-watch-config-", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode if mode is not None else 0o600)
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            output.write(contents)
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


def ensure_config_parent(path: Path) -> None:
    for directory in (path.parent.parent, path.parent):
        if directory.is_symlink():
            raise ValueError("configuration directory is a symbolic link")
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        if not directory.is_dir():
            raise ValueError("configuration parent is not a directory")


def ensure_private_directory(path: Path) -> None:
    if path.is_symlink():
        raise ValueError("Agent Watch bridge path cannot be a symbolic link")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.is_dir():
        raise ValueError("Agent Watch bridge path is not a directory")
    os.chmod(path, 0o700)


def check_no_symlink_parents(home: Path, path: Path) -> None:
    if home.is_symlink():
        raise ValueError("home path is a symbolic link")
    current = home
    for component in path.relative_to(home).parts[:-1]:
        current = current / component
        if current.is_symlink():
            raise ValueError("parent path is a symbolic link")


def bridge_is_owned(path: Path) -> bool:
    with path.open("rb") as existing:
        return BRIDGE_OWNER_MARKER in existing.read(512)


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


def install_bridge_copy(home: Path, source_bytes: bytes) -> bool:
    target = bridge_script_path(home)
    check_no_symlink_parents(home, target)
    ensure_private_directory(bridge_root(home))
    ensure_private_directory(target.parent)
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise ValueError("Agent Watch bridge script is not a regular file")
    if target.exists() and target.read_bytes() == source_bytes and stat.S_IMODE(target.stat().st_mode) == 0o600:
        return False
    if target.exists() and not bridge_is_owned(target):
        raise ValueError("stable bridge path contains an unowned file")

    descriptor, temporary_name = tempfile.mkstemp(prefix=".agent-watch-bridge-", dir=target.parent)
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
        directory_fd = os.open(target.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        return True
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
    document, original_bytes = load_document(path)
    original_document = copy.deepcopy(document)
    original_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else None
    if not isinstance(document.get("hooks", {}), dict):
        raise ValueError("hooks must be a JSON object")

    source_bytes = source_path.read_bytes()
    if uninstall:
        removed = remove_managed_handlers(document)
        config_changed = document != original_document
        bridge_changed = False
        description = f"remove {removed} Agent Watch hook handler(s)"
    else:
        command = command_for(bridge_script_path(home), python_executable)
        added, replaced = install_managed_handlers(document, command)
        config_changed = document != original_document
        bridge_changed = bridge_needs_update(home, source_bytes)
        config_note = (
            f"add {added} hook handler(s), remove {replaced} stale duplicate(s)"
            if config_changed
            else "hook configuration already current"
        )
        bridge_note = (
            f"install/update stable bridge at {display_user_path(home, bridge_script_path(home))}"
            if bridge_changed
            else f"use stable bridge at {display_user_path(home, bridge_script_path(home))}"
        )
        description = f"{config_note}; {bridge_note}"

    if not config_changed and not (not uninstall and bridge_changed):
        return "no configuration or bridge change needed", None, False
    new_bytes = serialized_document(document) if config_changed else None
    if not apply:
        return description, None, False

    if config_changed:
        ensure_config_parent(path)
        if original_bytes is None:
            if path.exists() or path.is_symlink():
                raise ValueError("configuration changed during inspection")
        elif path.is_symlink() or not path.is_file() or path.read_bytes() != original_bytes:
            raise ValueError("configuration changed during inspection")
    backup = create_backup(path, original_bytes) if config_changed and original_bytes is not None else None
    bridge_installed = install_bridge_copy(home, source_bytes) if not uninstall else False
    if config_changed:
        atomic_write(path, new_bytes or b"{}\n", original_mode)
    return description, backup, bridge_installed


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Install or remove Devin Local lifecycle hooks; defaults to dry-run."
    )
    parser.add_argument("--apply", action="store_true", help="write the planned configuration change")
    parser.add_argument("--uninstall", action="store_true", help="remove only Agent Watch marked hooks")
    parser.add_argument("--home", type=Path, help=argparse.SUPPRESS)
    options = parser.parse_args(arguments)

    home = options.home or Path.home()
    source_path = Path(__file__).with_name("devin_local.py").resolve()
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
        print("Unable to inspect or update the selected Devin Local hook configuration.", file=sys.stderr)
        return 2

    mode_label = "Applied" if options.apply else "Dry run"
    print(f"{mode_label}: {description} for {APP_LABEL} ({display_config()}).")
    if not options.apply and description != "no configuration or bridge change needed":
        print("No files were changed. Add --apply to write this change.")
    if options.apply and bridge_installed:
        print(f"Event bridge installed: {display_user_path(home, bridge_script_path(home))}")
    if backup is not None:
        print(f"Backup: ~/{backup.relative_to(home)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
