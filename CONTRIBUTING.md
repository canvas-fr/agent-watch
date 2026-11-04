# Contributing

The current milestone is a macOS monitoring preview. Keep application presence separate from task lifecycle evidence, and preserve the compatibility limits in the README. Gemini and Devin remain experimental; Doubao is outside the current app scope.

Before changing an adapter, describe the exact desktop application version and mode, the status source, the required permissions, and the background scenarios covered. Command-line support does not establish desktop support. Use the acceptance record in `docs/ACCEPTANCE.zh-CN.md`.

Use synthetic test conversations. Do not attach real chat transcripts, screenshots, authentication material, personal paths, or unredacted diagnostics to issues. Candidate path metadata is discovery evidence, not proof that an adapter is supported.

Build and check locally with Swift 6 on macOS 14 or later:

```sh
swift build
bash scripts/check.sh
swift run agent-watch-probe --help
```

Changes that collect additional fields or add permissions must document them. Keep user content out of normal reports. Runtime failures must not interrupt another application. Event replay tests cover duplicate and out-of-order records; preserve these boundaries when extending adapters.

For interface changes, reuse the shared design components and inspect light/dark and compact layouts with the synthetic preview renderer. Do not include real conversation data in screenshots. For release artifacts, follow `docs/RELEASING.md`; a clean commit, verified archives, checksums, and an accurate signing status are required.

Project code is Apache-2.0. Identify the source and license of any reused code or assets before including them. Do not assume application logos or third-party pet artwork are covered by a source repository's code license.
