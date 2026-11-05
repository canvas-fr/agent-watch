# Agent Watch — 安装与首次使用

## 系统要求

- Apple 芯片 Mac（arm64）
- macOS 14 或更高版本
- 本地任务读取与事件桥需要另行安装 Python 3

## 安装

打开 DMG，将 `Agent Watch.app` 拖入 `Applications`，然后推出磁盘映像。DMG 中的 `Applications` 快捷方式会打开该目录。

首次使用前，请从同版本源码 ZIP 的 `Agent-Watch-0.4.0-preview.9/adapters/` 查阅对应应用的指南，并按步骤手动安装需要的事件桥。Agent Watch 不会自动修改 Codex、Claude、WorkBuddy 或其他目标应用的配置；请在应用配置变更前先检查指南和变更内容。

本地任务读取和事件桥需要外部 Python 3。各客户端的要求与验收范围见同版本源码 ZIP 中的 `Agent-Watch-0.4.0-preview.9/README.md`、`docs/ACCEPTANCE.zh-CN.md` 及 `adapters/`。

## 预览版与签名

本软件为预览版。默认 ad hoc 包没有 Developer ID 签名或公证，不宣称通过 Gatekeeper 验证。若使用了可选的 Developer ID 与公证流程，请查看该软件包对应的 manifest 状态。

DMG 根目录附有 `LICENSE.txt`，包含 Apache License 2.0 条款。

## English

Requirements: Apple silicon Mac (arm64), macOS 14 or later, and separately installed Python 3 for local task readers and event bridges.

Open the DMG, drag `Agent Watch.app` to `Applications`, and eject the disk image. Before first use, consult the relevant guide under `Agent-Watch-0.4.0-preview.9/adapters/` in the matching source ZIP and manually install the bridges you need. Agent Watch does not automatically edit Codex, Claude, WorkBuddy, or other target application configuration. Review the instructions and changes before applying them.

The default ad hoc preview is not Developer ID signed or notarized; Gatekeeper approval is not claimed. If the optional Developer ID and notarization flow was used, check the package manifest. `LICENSE.txt` contains the Apache License 2.0 terms.
