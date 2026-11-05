#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${AGENT_WATCH_BUILD_DIR:-$project_dir/.build}"
app_path="${1:-$project_dir/dist/Agent Watch.app}"
app_version="${AGENT_WATCH_APP_VERSION:-0.4.0}"
build_number="${AGENT_WATCH_BUILD_NUMBER:-9}"
build_triple="${AGENT_WATCH_BUILD_TRIPLE:-$(uname -m)-apple-macosx14.0}"
build_configuration="${AGENT_WATCH_BUILD_CONFIGURATION:-debug}"
sign_identity="${AGENT_WATCH_SIGN_IDENTITY:--}"
if [ -e "$app_path" ]; then
  echo "Refusing to overwrite existing app: $app_path" >&2
  exit 1
fi
icon_path="$project_dir/Resources/AgentWatch.icns"
if [ ! -s "$icon_path" ]; then
  echo "Missing application icon: $icon_path" >&2
  exit 1
fi
package_options=()
if [ "${AGENT_WATCH_NESTED_SANDBOX_UNAVAILABLE:-0}" = 1 ]; then
  package_options+=(--disable-sandbox)
fi
build_options=(--triple "$build_triple" --configuration "$build_configuration")
swift build "${package_options[@]}" "${build_options[@]}" --package-path "$project_dir" --scratch-path "$build_dir" --product AgentWatch
binary_dir="$(swift build "${package_options[@]}" "${build_options[@]}" --package-path "$project_dir" --scratch-path "$build_dir" --show-bin-path)"
mkdir -p "$(dirname "$app_path")" "$build_dir"
stage="$(mktemp -d "$build_dir/app-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Agent Watch.app/Contents/MacOS"
mkdir -p "$stage/Agent Watch.app/Contents/Resources/adapters"
cp "$binary_dir/AgentWatch" "$stage/Agent Watch.app/Contents/MacOS/AgentWatch"
cp "$icon_path" "$stage/Agent Watch.app/Contents/Resources/AgentWatch.icns"
cp "$project_dir/adapters/"*.py "$stage/Agent Watch.app/Contents/Resources/adapters/"
python3 - "$stage/Agent Watch.app" "$app_version" "$build_number" <<'PY'
import plistlib
from pathlib import Path
import sys
root=Path(sys.argv[1])
with (root/'Contents/Info.plist').open('wb') as stream:
    plistlib.dump({'CFBundleIdentifier':'local.agentwatch.monitor','CFBundleName':'Agent Watch',
      'CFBundleDisplayName':'Agent Watch','CFBundleExecutable':'AgentWatch',
      'CFBundleIconFile':'AgentWatch.icns',
      'CFBundlePackageType':'APPL','CFBundleShortVersionString':sys.argv[2],'CFBundleVersion':sys.argv[3],
      'LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True},stream)
PY
codesign_options=(--force --sign "$sign_identity")
if [ "$sign_identity" != "-" ]; then
  codesign_options+=(--options runtime --timestamp)
fi
codesign "${codesign_options[@]}" "$stage/Agent Watch.app"
codesign --verify --strict "$stage/Agent Watch.app"
mv "$stage/Agent Watch.app" "$app_path"
echo "Built $app_path"
