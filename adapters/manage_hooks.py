#!/usr/bin/env python3
"""Dry-run-first hook installer for Agent Watch's local event bridge."""

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


APP_INFO = {
    "claude_code": {
        "label": "Claude Code",
        "config_dir": ".claude",
        "config_file": "settings.json",
        "events": [
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "Stop",
            "StopFailure",
            "SubagentStop",
        ],
        "notifications": ["permission_prompt", "idle_prompt"],
    },
    "codex": {
        "label": "Codex",
        "config_dir": ".codex",
        "config_file": "hooks.json",
        "events": [
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "Stop",
            "Interrupt",
            "SubagentStop",
        ],
        "notifications": [],
    },
    "workbuddy": {
        "label": "WorkBuddy desktop",
        "config_dir": ".workbuddy",
        "config_file": "settings.json",
        "events": [
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "PermissionRequest",
            "Stop",
            "StopFailure",
            "SubagentStop",
        ],
        "notifications": ["permission_prompt", "idle_prompt"],
    },
}

TIMEOUT_SECONDS = 1
MARKER_PREFIX = "# agent-watch-managed:v1:"


def marker_for(app_id: str) -> str:
    return MARKER_PREFIX + app_id


def config_path(app_id: str, home: Path) -> Path:
    info = APP_INFO[app_id]
    return home / info["config_dir"] / info["config_file"]


def display_config(app_id: str) -> str:
    info = APP_INFO[app_id]
    return f"~/{info['config_dir']}/{info['config_file']}"


def bridge_root(home: Path) -> Path:
    return home / "Library" / "Application Support" / "Agent Watch"


def bridge_script_path(home: Path) -> Path:
    return bridge_root(home) / "bridge" / "emit.py"


def display_user_path(home: Path, path: Path) -> str:
    return "~/" + str(path.relative_to(home))


def command_for(app_id: str, emit_script: Path, python_executable: Path, script_digest: str) -> str:
    # This is a shell command because all three hook systems launch commands.
    # Quote both absolute paths so spaces and non-ASCII names are safe.
    invocation = (
        f"{shlex.quote(str(python_executable))} {shlex.quote(str(emit_script))} "
        f"--app {app_id} {marker_for(app_id)}:{script_digest[:16]}"
    )
    if app_id == "claude_code":
        # Devin imports Claude configuration by default, and documents this
        # hook-runtime variable. Ignore imported hooks instead of mislabelling
        # them as Claude. Do not change the user's config-import preferences.
        return 'test -n "${DEVIN_PROJECT_DIR+x}" || ' + invocation
    return invocation


def expected_groups(app_id: str, command: str) -> list[tuple[str, str | None, dict[str, Any]]]:
    info = APP_INFO[app_id]
    handler = {"type": "command", "command": command, "timeout": TIMEOUT_SECONDS}
    groups: list[tuple[str, str | None, dict[str, Any]]] = []
    for event_name in info["events"]:
        groups.append((event_name, None, dict(handler)))
    for notification_type in info["notifications"]:
        groups.append(("Notification", notification_type, dict(handler)))
    return groups


def handler_is_owned(handler: Any, app_id: str) -> bool:
    if not isinstance(handler, dict):
        return False
    command = handler.get("command")
    return isinstance(command, str) and marker_for(app_id) in command


def group_matches(group: dict[str, Any], matcher: str | None) -> bool:
    if matcher is None:
        return "matcher" not in group
    return group.get("matcher") == matcher


def remove_managed_handlers(document: dict[str, Any], app_id: str) -> int:
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
            kept_handlers = []
            for handler in handlers:
                if handler_is_owned(handler, app_id):
                    removed += 1
                else:
                    kept_handlers.append(handler)
            if len(kept_handlers) == len(handlers):
                remaining_groups.append(group)
                continue

            if kept_handlers:
                group["hooks"] = kept_handlers
                remaining_groups.append(group)
            elif set(group).difference({"matcher", "hooks"}):
                # Keep any nonstandard metadata that was colocated with ours.
                group["hooks"] = []
                remaining_groups.append(group)

        if remaining_groups:
            hooks_root[event_name] = remaining_groups
        else:
            hooks_root.pop(event_name, None)
    if removed and not hooks_root:
        document.pop("hooks", None)
    return removed


def install_managed_handlers(
    document: dict[str, Any],
    app_id: str,
    emit_script: Path,
    python_executable: Path,
    script_digest: str,
) -> tuple[int, int]:
    """Merge our handlers while preserving other keys and handler order."""
    if not isinstance(document, dict):
        raise ValueError("configuration root must be a JSON object")
    hooks_root = document.setdefault("hooks", {})
    if not isinstance(hooks_root, dict):
        raise ValueError("hooks must be a JSON object")

    command = command_for(app_id, emit_script, python_executable, script_digest)
    desired = expected_groups(app_id, command)
    desired_by_group = {(event_name, matcher): handler for event_name, matcher, handler in desired}
    kept_managed: set[tuple[str, str | None]] = set()
    removed_old = 0

    # Remove stale, duplicate, or moved Agent Watch entries without rebuilding
    # unrelated matcher groups or changing their order.
    for event_name in list(hooks_root):
        event_groups = hooks_root[event_name]
        if not isinstance(event_groups, list):
            raise ValueError("each hooks event must be a JSON array")
        kept_groups = []
        for group in event_groups:
            if not isinstance(group, dict):
                raise ValueError("each hook matcher group must be a JSON object")
            handlers = group.get("hooks")
            if not isinstance(handlers, list):
                raise ValueError("each hook matcher group must contain a JSON array")
            matcher = group.get("matcher") if isinstance(group.get("matcher"), str) else None
            group_key = (event_name, matcher)
            expected_handler = desired_by_group.get(group_key)
            kept_handlers = []
            group_changed = False
            for handler in handlers:
                if not handler_is_owned(handler, app_id):
                    kept_handlers.append(handler)
                    continue

                expected_command = expected_handler["command"] if expected_handler else None
                is_current = (
                    expected_handler is not None
                    and isinstance(handler, dict)
                    and handler.get("type") == "command"
                    and handler.get("command") == expected_command
                    and group_key not in kept_managed
                )
                if is_current:
                    handler["timeout"] = TIMEOUT_SECONDS
                    kept_handlers.append(handler)
                    kept_managed.add(group_key)
                else:
                    removed_old += 1
                    group_changed = True

            if group_changed:
                if kept_handlers:
                    group["hooks"] = kept_handlers
                    kept_groups.append(group)
                elif set(group).difference({"matcher", "hooks"}):
                    group["hooks"] = []
                    kept_groups.append(group)
            else:
                kept_groups.append(group)

        if kept_groups:
            hooks_root[event_name] = kept_groups
        else:
            hooks_root.pop(event_name, None)

    if not hooks_root:
        document.pop("hooks", None)
        hooks_root = document.setdefault("hooks", {})
    added = 0

    for event_name, matcher, handler in desired:
        group_key = (event_name, matcher)
        event_groups = hooks_root.setdefault(event_name, [])
        if not isinstance(event_groups, list):
            raise ValueError("each hooks event must be a JSON array")

        matching_group = next(
            (group for group in event_groups if isinstance(group, dict) and group_matches(group, matcher)),
            None,
        )
        if matching_group is None:
            group: dict[str, Any] = {"hooks": [handler]}
            if matcher is not None:
                group["matcher"] = matcher
            event_groups.append(group)
            added += 1
            kept_managed.add(group_key)
            continue

        existing_handlers = matching_group.get("hooks")
        if not isinstance(existing_handlers, list):
            raise ValueError("each hook matcher group must contain a JSON array")
        # If a matching unowned hook already performs this exact command,
        # leave it alone instead of taking ownership of somebody else's entry.
        exact_command_exists = any(
            isinstance(existing, dict)
            and existing.get("type") == "command"
            and existing.get("command") == command
            for existing in existing_handlers
        )
        if not exact_command_exists:
            existing_handlers.append(handler)
            added += 1
            kept_managed.add(group_key)

    return added, removed_old


def load_document(path: Path) -> tuple[dict[str, Any], bytes | None]:
    if path.is_symlink():
        raise ValueError("configuration path is a symbolic link")
    if not path.exists():
        return {}, None
    if not path.is_file():
        raise ValueError("configuration path is not a regular file")
    raw = path.read_bytes()
    try:
        document = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("configuration file is not valid UTF-8 JSON") from error
    if not isinstance(document, dict):
        raise ValueError("configuration root must be a JSON object")
    return document, raw


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Reject duplicate JSON keys instead of silently dropping config data."""
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def serialized_document(document: dict[str, Any]) -> bytes:
    return (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def backup_path(path: Path) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return path.with_name(f"{path.name}.agent-watch-backup-{timestamp}-{uuid.uuid4().hex[:8]}")


def atomic_write_config(path: Path, data: bytes, original_mode: int | None) -> None:
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
        try:
            temporary_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def create_backup(path: Path, raw: bytes) -> Path:
    destination = backup_path(path)
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            destination.unlink(missing_ok=True)
        except OSError:
            pass
        raise
    return destination


def ensure_private_directory(path: Path) -> None:
    if path.is_symlink():
        raise ValueError("Agent Watch bridge path cannot be a symbolic link")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not path.is_dir():
        raise ValueError("Agent Watch bridge path is not a directory")
    os.chmod(path, 0o700)


def bridge_needs_update(home: Path, source_bytes: bytes) -> bool:
    root = bridge_root(home)
    directory = root / "bridge"
    target = bridge_script_path(home)
    for path in (root, directory):
        if path.is_symlink():
            raise ValueError("Agent Watch bridge path cannot be a symbolic link")
        if not path.exists():
            return True
        if not path.is_dir():
            raise ValueError("Agent Watch bridge path is not a directory")
        if stat.S_IMODE(path.stat().st_mode) != 0o700:
            return True
    if target.is_symlink():
        raise ValueError("Agent Watch bridge script cannot be a symbolic link")
    if not target.exists():
        return True
    if not target.is_file():
        raise ValueError("Agent Watch bridge script is not a regular file")
    return target.read_bytes() != source_bytes or stat.S_IMODE(target.stat().st_mode) != 0o600


def install_bridge_copy(home: Path, source_bytes: bytes) -> bool:
    """Atomically install the event script under the user's private data root."""
    target = bridge_script_path(home)
    root = bridge_root(home)
    ensure_private_directory(root)
    ensure_private_directory(target.parent)
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise ValueError("Agent Watch bridge script is not a regular file")
    if target.exists() and target.read_bytes() == source_bytes and stat.S_IMODE(target.stat().st_mode) == 0o600:
        return False

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
        try:
            temporary_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def run(
    app_id: str,
    home: Path,
    apply: bool,
    uninstall: bool,
    emit_source: Path,
    python_executable: Path,
) -> tuple[str, Path | None, bool]:
    path = config_path(app_id, home)
    document, original_bytes = load_document(path)
    original_document = copy.deepcopy(document)
    original_mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else None
    if not isinstance(document.get("hooks", {}), dict):
        raise ValueError("hooks must be a JSON object")

    if uninstall:
        removed = remove_managed_handlers(document, app_id)
        config_changed = document != original_document
        description = f"remove {removed} Agent Watch hook handler(s)"
        bridge_changed = False
    else:
        source_bytes = emit_source.read_bytes()
        destination = bridge_script_path(home)
        script_digest = hashlib.sha256(source_bytes).hexdigest()
        added, replaced = install_managed_handlers(
            document,
            app_id,
            destination,
            python_executable,
            script_digest,
        )
        config_changed = document != original_document
        bridge_changed = bridge_needs_update(home, source_bytes)
        config_summary = (
            f"add {added} hook handler(s), remove {replaced} stale duplicate(s)"
            if config_changed
            else "hook configuration already current"
        )
        bridge_summary = (
            f"install/update bridge at {display_user_path(home, destination)}"
            if bridge_changed
            else f"use stable bridge at {display_user_path(home, destination)}"
        )
        description = f"{config_summary}; {bridge_summary}"

    if not config_changed and not bridge_changed:
        return "no configuration or bridge change needed", None, False
    new_bytes = serialized_document(document) if config_changed else None
    if not apply:
        return description, None, False

    if config_changed:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if original_bytes is None:
            if path.exists() or path.is_symlink():
                raise ValueError("configuration changed during inspection")
        elif path.is_symlink() or not path.is_file() or path.read_bytes() != original_bytes:
            raise ValueError("configuration changed during inspection")
    backup = create_backup(path, original_bytes) if config_changed and original_bytes is not None else None
    bridge_installed = install_bridge_copy(home, source_bytes) if not uninstall else False
    if config_changed:
        atomic_write_config(path, new_bytes or b"{}\n", original_mode)
    return description, backup, bridge_installed


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Install or remove Agent Watch hooks; defaults to dry-run.")
    parser.add_argument("--app", required=True, choices=tuple(APP_INFO))
    parser.add_argument("--apply", action="store_true", help="write the planned configuration change")
    parser.add_argument("--uninstall", action="store_true", help="remove only Agent Watch marked hooks")
    parser.add_argument("--home", type=Path, help=argparse.SUPPRESS)
    options = parser.parse_args(arguments)

    home = options.home or Path.home()
    emit_source = Path(__file__).with_name("emit.py").resolve()
    try:
        python_executable = Path(sys.executable).resolve(strict=True)
        description, backup, bridge_installed = run(
            options.app,
            home,
            options.apply,
            options.uninstall,
            emit_source,
            python_executable,
        )
    except Exception:
        # Never print configuration text or low-level errors that may contain it.
        print("Unable to inspect or update the selected hook configuration.", file=sys.stderr)
        return 2

    mode_label = "Applied" if options.apply else "Dry run"
    print(f"{mode_label}: {description} for {APP_INFO[options.app]['label']} ({display_config(options.app)}).")
    if not options.apply and description != "no configuration or bridge change needed":
        print("No files were changed. Add --apply to write this change.")
    if options.apply and bridge_installed:
        print(f"Event bridge installed: {display_user_path(home, bridge_script_path(home))}")
    if backup is not None:
        # Keep the user's home directory out of ordinary terminal output.
        backup_display = "~/" + str(backup.relative_to(home))
        print(f"Backup: {backup_display}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
