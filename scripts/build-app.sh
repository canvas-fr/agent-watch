#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-$project_dir/dist/Agent Watch Probe.app}"
build_dir="${AGENT_WATCH_BUILD_DIR:-$project_dir/.build}"
mkdir -p "$build_dir" "$(dirname "$app_path")"
if [ -e "$app_path" ]; then
  echo "Refusing to overwrite an existing application: $app_path" >&2
  exit 1
fi
mkdir -p "$app_path/Contents/MacOS"
swiftc -swift-version 6 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$build_dir/module-cache" \
  "$project_dir/Sources/AgentWatchProbe/Catalog.swift" \
  "$project_dir/Sources/AgentWatchProbe/Options.swift" \
  "$project_dir/Sources/AgentWatchProbe/Inventory.swift" \
  "$project_dir/Sources/AgentWatchProbe/Report.swift" \
  "$project_dir/Sources/AgentWatchProbe/AccessibilityProbe.swift" \
  "$project_dir/Sources/AgentWatchMac/AgentWatchApp.swift" \
  -o "$app_path/Contents/MacOS/AgentWatchProbe"
python3 - "$app_path" <<'PY'
from pathlib import Path
import plistlib
import sys

app = Path(sys.argv[1])
info = {
    'CFBundleIdentifier': 'local.agentwatch.probe',
    'CFBundleName': 'Agent Watch Probe',
    'CFBundleDisplayName': 'Agent Watch Probe',
    'CFBundleExecutable': 'AgentWatchProbe',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.1.0',
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '14.0',
    'NSHighResolutionCapable': True,
}
with (app / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump(info, stream)
PY
codesign --force --sign - "$app_path"
echo "Built local prototype: $app_path"
