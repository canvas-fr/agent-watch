#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${AGENT_WATCH_BUILD_DIR:-$project_dir/.build}"
app_path="${1:-$project_dir/dist/Agent Watch.app}"
if [ -e "$app_path" ]; then
  echo "Refusing to overwrite existing app: $app_path" >&2
  exit 1
fi
package_options=()
if [ "${AGENT_WATCH_NESTED_SANDBOX_UNAVAILABLE:-0}" = 1 ]; then
  package_options+=(--disable-sandbox)
fi
swift build "${package_options[@]}" --package-path "$project_dir" --scratch-path "$build_dir" --product AgentWatch
binary_dir="$(swift build "${package_options[@]}" --package-path "$project_dir" --scratch-path "$build_dir" --show-bin-path)"
mkdir -p "$(dirname "$app_path")" "$build_dir"
stage="$(mktemp -d "$build_dir/app-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Agent Watch.app/Contents/MacOS"
mkdir -p "$stage/Agent Watch.app/Contents/Resources/adapters"
cp "$binary_dir/AgentWatch" "$stage/Agent Watch.app/Contents/MacOS/AgentWatch"
cp "$project_dir/adapters/"*.py "$stage/Agent Watch.app/Contents/Resources/adapters/"
python3 - "$stage/Agent Watch.app" <<'PY'
import plistlib
from pathlib import Path
import sys
root=Path(sys.argv[1])
with (root/'Contents/Info.plist').open('wb') as stream:
    plistlib.dump({'CFBundleIdentifier':'local.agentwatch.monitor','CFBundleName':'Agent Watch',
      'CFBundleDisplayName':'Agent Watch','CFBundleExecutable':'AgentWatch',
      'CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.3.2','CFBundleVersion':'6',
      'LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True},stream)
PY
codesign --force --sign "${AGENT_WATCH_SIGN_IDENTITY:--}" "$stage/Agent Watch.app"
codesign --verify --strict "$stage/Agent Watch.app"
mv "$stage/Agent Watch.app" "$app_path"
echo "Built $app_path"
