#!/usr/bin/env bash
set -euo pipefail

# Build a release candidate from one clean Git commit without touching the
# developer's existing app bundle or reusing a previous build directory.
project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
version="0.4.0"
build_number="8"
release_label="${version}-preview.${build_number}"
build_triple="arm64-apple-macosx14.0"
source_ref="HEAD"
output_dir=""
sign_mode="ad-hoc"
requested_identity="${AGENT_WATCH_SIGN_IDENTITY:-}"
notarize=0

usage() {
  cat <<'USAGE'
Usage: scripts/package-release.sh [options]

Options:
  --source-ref REF       Git commit/ref to package (must equal clean HEAD)
  --output-dir PATH      New, non-existing output directory
  --sign MODE            ad-hoc (default) or developer-id
  --identity VALUE       Developer ID Application identity name or hash
  --notarize             Submit and staple both the app and DMG
  -h, --help             Show this help

Developer ID notarization uses the keychain profile named by
AGENT_WATCH_NOTARY_PROFILE. Signing identity and profile values are never
printed or written to the manifest.
USAGE
}

die() {
  printf 'package-release: %s\n' "$1" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --source-ref)
      (($# >= 2)) || die "--source-ref needs a value"
      source_ref="$2"
      shift 2
      ;;
    --output-dir)
      (($# >= 2)) || die "--output-dir needs a value"
      output_dir="$2"
      shift 2
      ;;
    --sign)
      (($# >= 2)) || die "--sign needs a value"
      sign_mode="$2"
      shift 2
      ;;
    --identity)
      (($# >= 2)) || die "--identity needs a value"
      requested_identity="$2"
      shift 2
      ;;
    --notarize)
      notarize=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option; use --help"
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "release packaging requires macOS"
[[ "$sign_mode" == "ad-hoc" || "$sign_mode" == "developer-id" ]] || die "--sign must be ad-hoc or developer-id"
if ((notarize)) && [[ "$sign_mode" != "developer-id" ]]; then
  die "--notarize requires --sign developer-id"
fi

source_commit="$(git -C "$project_dir" rev-parse --verify "${source_ref}^{commit}" 2>/dev/null)" \
  || die "source ref does not resolve to a commit"
head_commit="$(git -C "$project_dir" rev-parse HEAD)"
[[ "$source_commit" == "$head_commit" ]] || die "source ref must identify the checked-out HEAD"
[[ -z "$(git -C "$project_dir" status --porcelain --untracked-files=all)" ]] \
  || die "source tree must be clean; commit or remove pending files before packaging"
commit_short="${source_commit:0:12}"

if [[ -z "$output_dir" ]]; then
  output_dir="$project_dir/../release-candidates/Agent-Watch-${release_label}-${commit_short}"
fi
output_dir="$(python3 - "$output_dir" "$project_dir" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]).expanduser().resolve(strict=False)
project = Path(sys.argv[2]).resolve()
if any(part.endswith(".app") for part in path.parts):
    raise SystemExit("package-release: output path cannot be inside an app bundle")
if path == project or project in path.parents:
    raise SystemExit("package-release: output directory must be outside the source checkout")
print(path)
PY
)" || die "invalid output directory"
protected_app="$(cd "$project_dir/.." && pwd -P)/Agent Watch.app"
[[ "$output_dir" != "$protected_app" ]] || die "refusing to use the existing Agent Watch.app path"
[[ ! -e "$output_dir" ]] || die "output directory already exists; choose a new path"

identity="-"
if [[ "$sign_mode" == "developer-id" ]]; then
  if ((notarize)) && [[ -z "${AGENT_WATCH_NOTARY_PROFILE:-}" ]]; then
    die "set AGENT_WATCH_NOTARY_PROFILE to a configured notarytool keychain profile"
  fi
  identity="$(python3 - "$requested_identity" <<'PY'
import re
import subprocess
import sys

requested = sys.argv[1].strip()
result = subprocess.run(
    ["security", "find-identity", "-v", "-p", "codesigning"],
    text=True,
    capture_output=True,
    check=False,
)
if result.returncode != 0:
    print("package-release: could not inspect available signing identities", file=sys.stderr)
    raise SystemExit(1)

records = []
for line in result.stdout.splitlines():
    match = re.match(r'\s*\d+\)\s+([A-Fa-f0-9]+)\s+"([^"]+)"', line)
    if match and match.group(2).startswith("Developer ID Application:"):
        records.append((match.group(1), match.group(2)))

if requested:
    matches = [
        digest for digest, label in records
        if requested.casefold() == digest.casefold() or requested == label
    ]
else:
    matches = [digest for digest, _ in records]

if len(matches) != 1:
    print("package-release: provide one valid Developer ID Application identity", file=sys.stderr)
    raise SystemExit(1)
print(matches[0])
PY
)" || exit 1
fi

release_parent="$(dirname "$output_dir")"
mkdir -p "$release_parent"
work_dir="$(mktemp -d "$release_parent/.agent-watch-${release_label}.XXXXXXXX")"
artifact_dir="$work_dir/artifacts"
build_dir="$work_dir/build"
app_path="$work_dir/stage/Agent Watch.app"
mount_point="$work_dir/mounted-dmg"
dmg_mounted=0
cleanup() {
  if ((dmg_mounted)); then
    hdiutil detach -quiet "$mount_point" >/dev/null 2>&1 || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT
mkdir -p "$artifact_dir" "$(dirname "$app_path")" "$mount_point"

app_zip_name="Agent-Watch-${release_label}-arm64.zip"
dmg_name="Agent-Watch-${release_label}-arm64.dmg"
source_zip_name="Agent-Watch-${release_label}-source.zip"
app_zip="$artifact_dir/$app_zip_name"
dmg="$artifact_dir/$dmg_name"
source_zip="$artifact_dir/$source_zip_name"
source_prefix="Agent-Watch-${release_label}"

export AGENT_WATCH_BUILD_DIR="$build_dir"
export AGENT_WATCH_BUILD_TRIPLE="$build_triple"
export AGENT_WATCH_BUILD_CONFIGURATION=release
export AGENT_WATCH_APP_VERSION="$version"
export AGENT_WATCH_BUILD_NUMBER="$build_number"
export AGENT_WATCH_SIGN_IDENTITY="$identity"
bash "$project_dir/scripts/build-monitor.sh" "$app_path"

python3 - "$app_path" "$version" "$build_number" <<'PY'
import plistlib
import sys
from pathlib import Path

with (Path(sys.argv[1]) / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
if info.get("CFBundleShortVersionString") != sys.argv[2] or info.get("CFBundleVersion") != sys.argv[3]:
    raise SystemExit("package-release: app bundle version metadata does not match this release")
if info.get("LSMinimumSystemVersion") != "14.0":
    raise SystemExit("package-release: app bundle minimum macOS version is unexpected")
PY
codesign --verify --deep --strict "$app_path"
if [[ " $(lipo -archs "$app_path/Contents/MacOS/AgentWatch") " != *" arm64 "* ]]; then
  die "built app does not contain the required arm64 architecture"
fi

if ((notarize)); then
  upload_zip="$work_dir/notary-app-upload.zip"
  ditto -c -k --norsrc --keepParent "$app_path" "$upload_zip"
  if ! xcrun notarytool submit "$upload_zip" \
    --keychain-profile "$AGENT_WATCH_NOTARY_PROFILE" --wait --output-format json \
    >"$work_dir/notary-app-result.json" 2>"$work_dir/notary-app-error.log"; then
    die "app notarization submission failed; no release artifacts were published"
  fi
  app_notary_status="$(python3 - "$work_dir/notary-app-result.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream).get("status", ""))
PY
)"
  [[ "$app_notary_status" == "Accepted" ]] || die "app notarization was not accepted"
  xcrun stapler staple "$app_path" >/dev/null 2>&1 || die "could not staple the app ticket"
  xcrun stapler validate "$app_path" >/dev/null 2>&1 || die "app ticket validation failed"
fi

ditto -c -k --norsrc --keepParent "$app_path" "$app_zip"
python3 - "$app_zip" <<'PY'
from pathlib import PurePosixPath
from zipfile import ZipFile
import sys

archive = ZipFile(sys.argv[1])
names = archive.namelist()
if not names:
    raise SystemExit("package-release: app ZIP is empty")
roots = {name.split("/", 1)[0] for name in names}
if roots != {"Agent Watch.app"}:
    raise SystemExit("package-release: app ZIP root must be Agent Watch.app")
for name in names:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or ".git" in path.parts:
        raise SystemExit("package-release: app ZIP contains an invalid path")
if "Agent Watch.app/Contents/Info.plist" not in names:
    raise SystemExit("package-release: app ZIP is missing its bundle metadata")
PY
mkdir -p "$work_dir/unpacked-app"
ditto -x -k --norsrc "$app_zip" "$work_dir/unpacked-app"
codesign --verify --deep --strict "$work_dir/unpacked-app/Agent Watch.app"

git -C "$project_dir" archive --format=zip --prefix="$source_prefix/" "$source_commit" > "$source_zip"
python3 - "$source_zip" "$source_prefix" <<'PY'
from zipfile import ZipFile
import sys

archive = ZipFile(sys.argv[1])
prefix = sys.argv[2] + "/"
names = archive.namelist()
if not names or any(not name.startswith(prefix) for name in names):
    raise SystemExit("package-release: source ZIP has an unexpected root")
if any(".git" in name.split("/") for name in names):
    raise SystemExit("package-release: source ZIP unexpectedly contains .git")
required = {
    prefix + "Package.swift",
    prefix + "LICENSE",
    prefix + "Resources/AgentWatch.icns",
    prefix + "scripts/package-release.sh",
    prefix + "docs/INSTALLATION.md",
    prefix + "docs/RELEASE-NOTES-0.4.0-preview.8.md",
}
if not required.issubset(set(names)):
    raise SystemExit("package-release: source ZIP is missing required source files")
PY

notes_source="$project_dir/docs/RELEASE-NOTES-0.4.0-preview.8.md"
[[ -f "$notes_source" ]] || die "release notes are missing"
[[ -f "$project_dir/docs/INSTALLATION.md" && -f "$project_dir/LICENSE" ]] \
  || die "DMG installation README or license is missing"

mkdir -p "$work_dir/dmg-root"
ditto "$app_path" "$work_dir/dmg-root/Agent Watch.app"
cp "$project_dir/docs/INSTALLATION.md" "$work_dir/dmg-root/README.md"
cp "$project_dir/LICENSE" "$work_dir/dmg-root/LICENSE.txt"
ln -s /Applications "$work_dir/dmg-root/Applications"
[[ -L "$work_dir/dmg-root/Applications" && "$(readlink "$work_dir/dmg-root/Applications")" == "/Applications" ]] \
  || die "DMG Applications link was not created correctly"
hdiutil create -volname "Agent Watch ${version}" -srcfolder "$work_dir/dmg-root" \
  -format UDZO "$dmg" >/dev/null
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_point" "$dmg"
dmg_mounted=1
if [[ ! -d "$mount_point/Agent Watch.app" || ! -f "$mount_point/README.md" || \
      ! -f "$mount_point/LICENSE.txt" || ! -L "$mount_point/Applications" || \
      "$(readlink "$mount_point/Applications")" != "/Applications" ]]; then
  die "DMG content check failed"
fi
codesign --verify --deep --strict "$mount_point/Agent Watch.app"
hdiutil detach -quiet "$mount_point"
dmg_mounted=0
hdiutil verify "$dmg" >/dev/null

disk_image_signature_verified=false
if [[ "$sign_mode" == "developer-id" ]]; then
  codesign --force --sign "$identity" --timestamp "$dmg" >/dev/null 2>&1 \
    || die "could not sign the disk image"
  codesign --verify --strict "$dmg" >/dev/null 2>&1 \
    || die "disk image signature verification failed"
  disk_image_signature_verified=true
fi

notarization_status="not_requested"
if ((notarize)); then
  if ! xcrun notarytool submit "$dmg" \
    --keychain-profile "$AGENT_WATCH_NOTARY_PROFILE" --wait --output-format json \
    >"$work_dir/notary-dmg-result.json" 2>"$work_dir/notary-dmg-error.log"; then
    die "DMG notarization submission failed; no release artifacts were published"
  fi
  dmg_notary_status="$(python3 - "$work_dir/notary-dmg-result.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream).get("status", ""))
PY
)"
  [[ "$dmg_notary_status" == "Accepted" ]] || die "DMG notarization was not accepted"
  xcrun stapler staple "$dmg" >/dev/null 2>&1 || die "could not staple the DMG ticket"
  xcrun stapler validate "$dmg" >/dev/null 2>&1 || die "DMG ticket validation failed"
  notarization_status="accepted_and_stapled"
  hdiutil verify "$dmg" >/dev/null
  codesign --verify --strict "$dmg" >/dev/null 2>&1 \
    || die "disk image signature verification failed after stapling"
fi

cp "$notes_source" "$artifact_dir/RELEASE-NOTES.md"

swift_version="$(swift --version | sed -n '1p')"
macos_version="$(sw_vers -productVersion)"
source_date="$(git -C "$project_dir" show -s --format=%cI "$source_commit")"
python3 - "$artifact_dir/release-manifest.json" \
  "$version" "$build_number" "$source_commit" "$source_ref" "$source_date" \
  "$build_triple" "$macos_version" "$swift_version" "$sign_mode" \
  "$notarization_status" "$disk_image_signature_verified" \
  "$dmg_name" "$dmg" "$app_zip_name" "$app_zip" "$source_zip_name" "$source_zip" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

(
    manifest_path, version, build_number, commit, source_ref, source_date,
    triple, macos_version, swift_version, sign_mode, notarization_status,
    disk_image_signature_verified, dmg_name, dmg_path, app_zip_name, app_zip_path,
    source_zip_name, source_zip_path,
) = sys.argv[1:]

def artifact(name, path):
    digest = hashlib.sha256(Path(path).read_bytes()).hexdigest()
    return {"file": name, "sha256": digest}

manifest = {
    "product": "Agent Watch",
    "version": version,
    "build_number": int(build_number),
    "release_channel": "preview",
    "source": {
        "commit": commit,
        "ref": source_ref,
        "commit_date": source_date,
        "archive_excludes_git_directory": True,
    },
    "build_environment": {
        "configuration": "release",
        "target": triple,
        "minimum_macos": "14.0",
        "builder_macos": macos_version,
        "swift": swift_version,
    },
    "signature": {
        "mode": sign_mode.replace("-", "_"),
        "app_bundle_verified": True,
        "disk_image_signature_verified": disk_image_signature_verified == "true",
    },
    "notarization": {
        "status": notarization_status,
        "app_stapled": notarization_status == "accepted_and_stapled",
        "dmg_stapled": notarization_status == "accepted_and_stapled",
    },
    "artifacts": [
        artifact(dmg_name, dmg_path),
        artifact(app_zip_name, app_zip_path),
        artifact(source_zip_name, source_zip_path),
    ],
}
Path(manifest_path).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

(
  cd "$artifact_dir"
  shasum -a 256 "$dmg_name" "$app_zip_name" "$source_zip_name" \
    release-manifest.json RELEASE-NOTES.md > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt >/dev/null
)

[[ ! -e "$output_dir" ]] || die "output directory appeared during packaging; refusing to overwrite"
mv "$artifact_dir" "$output_dir"
printf 'Release candidate created: %s\n' "$output_dir"
printf 'Notarization status: %s\n' "$notarization_status"
