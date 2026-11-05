# Agent Watch

[中文说明](README.md) · [Interface](docs/INTERFACE.zh-CN.md) · [Installation](docs/INSTALLATION.md) · [Release packaging](docs/RELEASING.md)

A local macOS monitor for desktop AI agents. **0.4.0 Preview, build 9**, targets Apple silicon and macOS 14+. Python 3 is required separately for local-record adapters and event bridges.

Agent Watch shows session activity and results in the dashboard and menu bar details. Move the pointer to the camera housing or just below it to see a compact status strip for supported apps that are open. On a display without a camera housing, hover over the Agent Watch menu bar item. Click the item for recent sessions. Notifications are deduplicated, and each completion describes a single turn. Opening a session row activates its app.

A new approval request or ended turn from an open app brings up the strip. Click an app icon to switch to that app. The strip stays open while the pointer is over it or the camera housing and closes about three seconds after the pointer leaves. An approval notice stays until the request is handled or dismissed; it names the waiting agent, shows how long it has waited, and switches to that app when clicked.

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
