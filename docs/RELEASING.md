# Release packaging

The current release candidate is **0.4.0 Preview, build 9**, for arm64 Macs on macOS 14 or later. The release script packages a clean, committed checkout into a DMG, an app ZIP, a source ZIP, SHA-256 checksums, a JSON manifest, and release notes. It does not publish artifacts to a server.

## Prepare the source

Commit the exact source that should ship. The selected `--source-ref` must resolve to the checked-out `HEAD`, and the worktree must be clean, including untracked files. This keeps the app build and source archive tied to the same commit. The source archive is created with `git archive`; it contains no `.git` directory.

Check that `docs/RELEASE-NOTES-0.4.0-preview.9.md` describes the final UI and scope. Confirm the README and acceptance matrix still describe the evidence accurately. The current scope excludes Doubao, treats Gemini and Devin as experimental, and leaves experimental window observation disabled by default.

## Build an ad hoc candidate

```sh
bash scripts/package-release.sh --source-ref HEAD
```

By default, artifacts are written to a new directory under `../release-candidates/` whose name includes the release label and commit. A pre-existing output directory is never replaced. To choose another path, pass `--output-dir /absolute/path/to/new-directory`.

The script creates a fresh temporary Swift build directory, targets `arm64-apple-macosx14.0`, uses the release configuration, includes `Resources/AgentWatch.icns`, and builds the app away from any existing `Agent Watch.app`. It does not overwrite `outputs/Agent Watch.app`. The DMG root contains the app, an Applications link, `README.md` with installation requirements, and `LICENSE.txt`. The script verifies the app signature, arm64 binary, ZIP root (`Agent Watch.app/`), source ZIP root, DMG contents and Applications link, disk image integrity, and SHA-256 entries before moving completed artifacts into the output directory.

`SHA256SUMS.txt` covers the DMG, app ZIP, source ZIP, manifest, and release notes. The manifest records the commit, build settings, verification results, artifact hashes, and signing/notarization status. It intentionally omits signing identity names and notarization profile names.

## Developer ID signing and notarization

Developer ID signing requires one valid `Developer ID Application` identity in the keychain. You can let the script select the sole available identity or provide its identity name/hash through `--identity` or `AGENT_WATCH_SIGN_IDENTITY`. The value is used without being printed or written to the manifest.

To sign the app and DMG without notarization:

```sh
bash scripts/package-release.sh --source-ref HEAD --sign developer-id
```

To submit both the app and DMG to Apple and staple/validate their tickets, configure a `notarytool` keychain profile and set its name in `AGENT_WATCH_NOTARY_PROFILE`:

```sh
bash scripts/package-release.sh --source-ref HEAD --sign developer-id --notarize
```

Notarization runs only when explicitly requested. Packaging stops without publishing a candidate directory if either submission is not accepted or stapling/validation fails. A package is described as notarized only when the manifest says `accepted_and_stapled`.

## Repeatability and boundaries

The source ZIP is bound to the selected commit, and the app build uses a clean scratch directory, a fixed architecture, a fixed minimum macOS target, and the Swift toolchain recorded in the manifest. Different macOS or Swift toolchain versions can change compiled bytes; Developer ID signatures and Apple timestamping also make signed outputs time-dependent. The manifest and checksums provide provenance and integrity for each produced candidate; they do not imply byte-for-byte equality across toolchains.

This script prepares reviewable local artifacts only. It does not create a Git tag, publish a release, upload files, or claim native-client acceptance beyond the evidence recorded in the project documentation.
