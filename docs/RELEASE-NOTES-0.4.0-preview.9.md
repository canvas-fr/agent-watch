# Agent Watch 0.4.0 Preview (Build 9)

面向 Apple 芯片 Mac，要求 macOS 14+。这是公开预览候选版，客户端支持范围沿用已记录的验收结果。

- 新应用图标：刘海下方悬挂的状态条，三个圆点对应运行、待授权和本轮结束。
- 主界面改为中性配色，会话改为分组列表；各处直接使用本机已安装应用的图标，未安装时退回系统符号。
- 授权提醒标明是哪个智能体在等待、各自已等多久，点按即切换到对应应用；提醒一直保留到授权完成或手动收起。
- 本轮结束提醒从刘海下方弹入，显示观察到的本轮用时，可选播放完成提示音；悬浮条移开约 3 秒后收起。
- 有智能体等待处理时，菜单栏显示该智能体的图标并带橙色圆点；系统通知以智能体名称为标题并附带其图标。
- 「接入状态」页可一键为 Claude Code、Codex、WorkBuddy 安装或移除事件桥（自动备份）；首次打开显示快速开始清单；窗口观察等开关会记住选择。
- 等待回答也会弹出提醒；Claude Code 记录无法确认结束时，以 Stop 事件推断本轮结束（可在设置中关闭）。
- Python 3 需另行安装；DSH、Antigravity、Devin 的接入仍按对应指南手动完成。豆包不在主应用范围，Gemini、Devin 仍为实验项。
- 默认临时签名，未经过 Apple 公证；具体签名状态以同目录 manifest 为准。

自动检查与合成视图预览不能替代真实客户端验收。“本轮结束”不表示整个目标已经完成。

This is a preview release for Apple silicon Macs running macOS 14 or later. It is not a claim that every listed client integration has passed native acceptance.

## What changed

- New app icon: a status strip hanging below the camera housing, with dots for running, waiting for approval, and ended.
- Neutral interface palette and grouped session lists; monitored apps are shown with their own installed icons.
- Approval notices name the waiting agent, show how long each has waited, switch to that app when clicked, and stay until the request is handled or dismissed.
- Turn-end notices drop in from the camera housing, show the observed turn duration, and can play an optional chime. The strip closes about three seconds after the pointer leaves.
- While an agent is blocked, the menu bar shows that agent's icon with an orange dot. System notifications are titled with the agent's name and include its icon.
- The integrations page installs or removes the Claude Code, Codex, and WorkBuddy event bridges with one click (with backups). A first-run checklist covers notifications, window observation, and agent setup. Experimental switches persist across launches.
- Questions waiting for an answer also bring up the notice. When Claude Code session records cannot confirm a turn end, its Stop hook is used as an inferred end; this can be turned off in Settings.
- Doubao is not listed or monitored by the main Agent Watch app. Gemini and Devin remain experimental integrations. Experimental window observation is disabled by default.

For integration evidence and limits, consult `Agent-Watch-0.4.0-preview.9/README.md` and `Agent-Watch-0.4.0-preview.9/docs/ACCEPTANCE.zh-CN.md` inside the source ZIP.

## Requirements and setup

Use an Apple silicon Mac running macOS 14 or later. Python 3 must be installed separately for local task readers and bridges. Bridges are installed manually by following the relevant guide under `adapters/`; Agent Watch does not automatically edit target application configuration. The DMG includes an installation README and the Apache License 2.0.

## Package and signing status

The release script creates an arm64 app ZIP, a DMG with an Applications shortcut, a source ZIP for the specified clean Git commit, a SHA-256 checksum list, and a JSON manifest. Ad hoc signing is the default. Developer ID signing and notarization are opt-in. The manifest records `not_requested` unless notarization was accepted and tickets were stapled and validated for both the app and DMG.
