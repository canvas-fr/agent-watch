# Agent Watch 0.4.0 Preview (Build 8)

面向 Apple 芯片 Mac，要求 macOS 14+。这是公开预览候选版，客户端支持范围沿用已记录的验收结果。

- 重做主界面：侧栏、状态卡片、应用与状态筛选、搜索、接入状态页和独立设置页。
- 菜单栏随运行、待处理和未读结束变化；菜单与贴边悬浮面板统一视觉，待处理会话优先。
- 支持跟随系统、浅色和深色；原创应用图标，不复用 CC Switch 的品牌素材。
- 补充 DMG、应用 ZIP、源码、校验值和发布清单的可复现打包流程。
- Python 3 需另行安装；事件桥依对应指南手动安装。豆包不在主应用范围，Gemini、Devin 仍为实验项。
- 默认临时签名，未经过 Apple 公证；具体签名状态以同目录 manifest 为准。

自动检查与合成视图预览不能替代真实客户端验收。“本轮结束”不表示整个目标已经完成。

This is a preview release for Apple silicon Macs running macOS 14 or later. It is not a claim that every listed client integration has passed native acceptance.

## What changed

- Updated the desktop interface using CC Switch as a visual reference.
- Doubao is not listed or monitored by the main Agent Watch app. Historical probe catalog and records remain separate and are not represented as current-app support.
- Gemini and Devin remain experimental integrations.
- Experimental window observation is disabled by default.

For integration evidence and limits, consult `Agent-Watch-0.4.0-preview.8/README.md` and `Agent-Watch-0.4.0-preview.8/docs/ACCEPTANCE.zh-CN.md` inside the source ZIP.

## Requirements and setup

Use an Apple silicon Mac running macOS 14 or later. Python 3 must be installed separately for local task readers and bridges. Bridges are installed manually by following the relevant guide under `adapters/`; Agent Watch does not automatically edit target application configuration. The DMG includes an installation README and the Apache License 2.0.

## Package and signing status

The release script creates an arm64 app ZIP, a DMG with an Applications shortcut, a source ZIP for the specified clean Git commit, a SHA-256 checksum list, and a JSON manifest. Ad hoc signing is the default. Developer ID signing and notarization are opt-in. The manifest records `not_requested` unless notarization was accepted and tickets were stapled and validated for both the app and DMG.
