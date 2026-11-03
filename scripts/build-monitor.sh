#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${AGENT_WATCH_BUILD_DIR:-$project_dir/.build}"
app_path="${1:-$project_dir/dist/Agent Watch.app}"
if [ -e "$app_path" ]; then
  echo "Refusing to overwrite existing app: $app_path" >&2
  exit 1
fi
swift build --package-path "$project_dir" --scratch-path "$build_dir" --product AgentWatch
binary_dir="$(swift build --package-path "$project_dir" --scratch-path "$build_dir" --show-bin-path)"
mkdir -p "$(dirname "$app_path")" "$build_dir"
stage="$(mktemp -d "$build_dir/app-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Agent Watch.app/Contents/MacOS"
cp "$binary_dir/AgentWatch" "$stage/Agent Watch.app/Contents/MacOS/AgentWatch"
python3 - "$stage/Agent Watch.app" <<'PY'
import plistlib
from pathlib import Path
import sys
root=Path(sys.argv[1])
with (root/'Contents/Info.plist').open('wb') as stream:
    plistlib.dump({'CFBundleIdentifier':'local.agentwatch.monitor','CFBundleName':'Agent Watch',
      'CFBundleDisplayName':'Agent Watch','CFBundleExecutable':'AgentWatch',
      'CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.2.1','CFBundleVersion':'3',
      'LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True},stream)
PY
codesign --force --sign "${AGENT_WATCH_SIGN_IDENTITY:--}" "$stage/Agent Watch.app"
codesign --verify --strict "$stage/Agent Watch.app"
mv "$stage/Agent Watch.app" "$app_path"
echo "Built $app_path"
