# Agent Watch

[中文说明](README.md) · [Interface](docs/INTERFACE.zh-CN.md) · [Installation](docs/INSTALLATION.md) · [Release packaging](docs/RELEASING.md)

A local macOS monitor for desktop AI agents. **0.4.0 Preview, build 8**, targets Apple silicon and macOS 14+. Python 3 is required separately for local-record adapters and event bridges.

Agent Watch shows running sessions, permission requests, questions, ended turns, failures, cancellations, and unknown states in a dashboard, dynamic menu bar item, and floating panel. Notifications are deduplicated. An ended reply does not establish that the user's entire goal is complete. Opening a row currently activates its app, without selecting the exact chat.

The interface uses a sidebar, session cards, filters, search, an integration status page, and settings. Appearance follows the system or can be fixed to light/dark. UI screenshots in this repository use synthetic data.

Supported source paths include Codex local journals, Claude Code and Cowork metadata, DSH's observer plugin, WorkBuddy hooks, and Antigravity events. These have different evidence and coverage limits; see the [Chinese compatibility table](README.md#接入状态). Gemini and Devin are experimental. Doubao is excluded from the current app. Experimental window observation and inferred notifications are disabled by default. Process presence is never treated as task activity or completion.

```sh
bash scripts/check.sh
bash scripts/build-monitor.sh
open "dist/Agent Watch.app"
```

Install client-specific bridges manually using the relevant guide in `adapters/`. The application does not edit other clients' configuration automatically. Default builds use ad hoc signing and are not notarized. The release script supports an explicit Developer ID and notarization path and records the actual status in its manifest.

There is no telemetry, cloud account, or model invocation. Routine history contains lifecycle metadata, not chat text or screenshots. See [contribution requirements](CONTRIBUTING.md) before contributing an adapter.

Apache-2.0. Original project artwork is included; no third-party app logos or pet assets are distributed.
