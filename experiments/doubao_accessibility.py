#!/usr/bin/env python3
"""Prepare a one-launch CEF accessibility experiment; dry-run by default."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import plistlib
import subprocess

APP = Path('/Applications/Doubao.app')
FLAG = '--force-renderer-accessibility'
EXPECTED_VERSION = '2.24.10'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='launch only after Doubao and its browser have already exited')
    options = parser.parse_args()
    try:
        info_file = APP / 'Contents/Info.plist'
        if APP.is_symlink() or info_file.is_symlink() or info_file.stat().st_size > 256 * 1024:
            raise ValueError('bundle_unavailable')
        info = plistlib.loads(info_file.read_bytes())
        if info.get('CFBundleIdentifier') != 'com.bot.neotix.doubao':
            raise ValueError('bundle_identity_mismatch')
        if info.get('CFBundleShortVersionString') != EXPECTED_VERSION:
            raise ValueError('version_not_verified')
        validation = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(APP)],
                                    capture_output=True, timeout=10)
        if validation.returncode:
            raise ValueError('bundle_signature_invalid')
        target_executables = {str(APP / 'Contents/MacOS' / info['CFBundleExecutable'])}
        browser = APP / 'Contents/Helpers/Doubao Browser.app'
        browser_info = plistlib.loads((browser / 'Contents/Info.plist').read_bytes())
        if browser_info.get('CFBundleIdentifier') != 'com.bot.neotix.doubao.browser':
            raise ValueError('browser_identity_mismatch')
        target_executables.add(str(browser / 'Contents/MacOS' / browser_info['CFBundleExecutable']))
        listing = subprocess.check_output(['/bin/ps', '-A', '-o', 'pid=,comm='], text=True, timeout=10)
        running = []
        for line in listing.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) == 2 and fields[1] in target_executables:
                running.append(int(fields[0]))
        plan = {'experiment': 'doubao_cef_accessibility', 'appVersion': EXPECTED_VERSION,
                'flag': FLAG, 'applyRequested': options.apply, 'existingProcessPIDs': running,
                'modifiesAppOrConfiguration': False,
                'forwardingToEmbeddedCEF': 'not_verified', 'status': 'dry_run'}
        if options.apply:
            if running:
                plan['status'] = 'refused_while_app_running'
                print(json.dumps(plan, ensure_ascii=False))
                return 2
            # No force-new-instance flag: a concurrent user launch must never
            # create a second profile writer. Existing instances may ignore args.
            opened = subprocess.run(['/usr/bin/open', str(APP), '--args', FLAG],
                                    capture_output=True, timeout=15)
            plan['status'] = 'launch_requested_not_verified' if opened.returncode == 0 else 'launch_failed'
            print(json.dumps(plan, ensure_ascii=False))
            return 0 if opened.returncode == 0 else 1
        print(json.dumps(plan, ensure_ascii=False))
        return 0
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException, subprocess.SubprocessError):
        print(json.dumps({'experiment': 'doubao_cef_accessibility', 'status': 'preflight_failed'}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
