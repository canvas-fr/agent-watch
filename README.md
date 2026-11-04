# Agent Watch

本地运行的 macOS 智能体监控器。当前版本为 **0.2.1 预览版**：已有持续采集、会话状态、菜单栏、监控面板、面板提醒、系统通知接入、状态导出和打开原应用入口。

**八款目标应用尚未全部通过真实任务验收。** “已安装适配器”“窗口可访问”和“实际识别任务状态”分别记录，不把候选规则当成已验证兼容。

## 当前能力

- 统一的运行、等待授权、等待回答、本轮结束、失败、取消和未知状态。
- 按应用/会话/轮次隔离，子任务单独展示；去重、乱序与终态回滚保护。
- 过期的进行中状态转为未知；确认过的结束结果保留为历史记录。未读结束标记持久化，直到手动标记已读。
- 状态栏动态显示运行、待处理、新结束；未读结束标记持久化，直到手动标记已读。可置顶面板及系统通知均可使用。
- 八款应用的窗口候选规则：只读取操作控件的短标签，不读取聊天静态文本、输入值或窗口标题；推断单独标注。窗口内不可见的其他会话不保证覆盖；窗口规则不会凭停止按钮消失宣布完成。
- Claude Code、Codex、WorkBuddy 的本地事件桥；另提供版本固定的 DSH 插件和 Codex 本地服务只读桥。
- 点击“打开应用”只激活对应应用；尚不能精确跳转到隐藏会话。

## 接入状态

| 目标 | 已实现路径 | 本机验证与限制 |
| --- | --- | --- |
| Claude Code | hooks 事件桥 | 已收到真实运行和 Stop 结束事件；其余转换仍需按具体客户端验收 |
| Claude Chat / Cowork | 窗口候选规则 | 未完成真实任务验收；不能沿用 Code 的支持结论 |
| Codex | hooks + 可选本地服务桥 | 已收到真实 PreToolUse 与 Stop 事件；新安装仍需客户端认可 hooks。当前本地服务桥无可代理 socket，未启动或替换服务 |
| WorkBuddy | hooks + 窗口候选规则 | 已在界面报告 V5.9.3 的客户端收到真实 UserPromptSubmit 与 Stop |
| DSH | 0.2.1-rc.5 只读插件 + 窗口候选规则 | 0.1.1 已通过原生管理器安装启用；独立验收已捕获等待回答及回答后的正常结束 |
| Gemini 桌面版 | 窗口候选规则 | 未找到可靠的轮次结束来源；[本轮调查](docs/GEMINI-DOUBAO-SIGNALS.zh-CN.md)记录内部状态符号与公开接口的区别 |
| 豆包 | 窗口候选规则 | 窗口结构可观察；尚无确认完成的来源，Office 子应用状态不能代表主聊天 |
| Antigravity | 桌面事件桥 + 问答工具观察 | 2.28.2 已实测运行、等待回答、回答后继续及正常结束；原生取消未收到 Stop，超时转未知 |
| Devin | 新 Local 事件桥 | 3.11.228 已实测运行、等待授权及拒绝后解除等待；Stop 与旧 post 回调均不能证明最终结束，保留未知；Cloud 未接入 |

## 构建和运行

需要 macOS 14+、Swift 6。事件桥和检查需要 Python 3；DSH fixture 需要 Node.js。

```sh
bash scripts/check.sh
bash scripts/build-monitor.sh
open "dist/Agent Watch.app"
```

构建目录可通过 `AGENT_WATCH_BUILD_DIR` 指定。若有合适的签名身份，可设置 `AGENT_WATCH_SIGN_IDENTITY`；默认仅本地临时签名，更新后 macOS 可能要求重新授权，见 [权限说明](docs/PERMISSIONS.zh-CN.md)。构建脚本拒绝覆盖已有应用。

窗口中开启辅助功能后才开始实际窗口观察；授权缺失时，已安装的事件桥仍可接收事件。首次使用“开启系统通知”会请求系统授权。推断提醒默认关闭，避免把未验证的窗口候选当成确定事件。演示按钮只注入明确标记的本地演示数据，不代表真实应用接入；可清除演示。

## 安装事件桥

```sh
python3 adapters/manage_hooks.py --app claude_code
python3 adapters/manage_hooks.py --app claude_code --apply
python3 adapters/manage_hooks.py --app codex --apply
python3 adapters/manage_hooks.py --app workbuddy --apply
```

安装程序先备份目标配置，只合并自己的条目。卸载时增加 `--uninstall --apply`，不会移除其他 hooks。稳定脚本副本位于 `~/Library/Application Support/Agent Watch/bridge/`，移动本仓库不影响已安装副本。数据和备份保留，便于恢复。详见 [事件桥说明](adapters/README.md)。

Codex 需通过其原生信任流程认可新 hooks；本机已实际收到运行与本轮结束事件，本项目没有关闭 hook 信任检查。已启动的会话是否热加载取决于客户端，配置成功不证明当前桌面会话已接入。

DSH 需要走 [原生插件安装流程](adapters/dsh/README.md)，普通依赖安装不能代替 manifest、版本和 patch 校验。Codex 服务桥可用 `python3 adapters/codex_status.py --once` 检查；没有受支持的运行中 daemon 时会退出，不创建服务或打开未知 socket。

Antigravity 的安装与范围见 [ANTIGRAVITY.md](adapters/ANTIGRAVITY.md)，新版 Devin Local 见 [DEVIN-LOCAL.md](adapters/DEVIN-LOCAL.md)。两者与旧 Cascade 使用独立桥。Devin 默认导入 Claude 配置；Claude 观察命令按 Devin 的运行时环境标记跳过导入调用，避免把同一会话归到 Claude。

## 隐私和状态协议

事件目录为 `~/Library/Application Support/Agent Watch/events/`，只接收受控元数据，目录0700、文件0600。没有云端账号、遥测或模型调用。hooks 输入会在内存中解析，仅保留会话/轮次/事件元数据；不会保存 prompt、工具参数或对话正文。

窗口观察只在操作控件上匹配短标签白名单，原始标签不落盘。它与第0阶段的纯角色探测器是两个不同程序；旧探测器仍保持原来的只读结构边界。

本轮结束不等于整个目标完成；子任务结束不替父任务宣布完成。进程存活不代表任务运行。默认仅在状态转换时提醒，信息超时显示未知。公开事件结构见 [协议与验收说明](docs/ADAPTERS.zh-CN.md)。

## 开发文档

[开发计划](docs/PLAN.zh-CN.md) · [验收矩阵](docs/ACCEPTANCE.zh-CN.md) · [贡献指南](CONTRIBUTING.md) · [权限排查](docs/PERMISSIONS.zh-CN.md)

## English

Agent Watch is a local-first macOS agent monitor. Version 0.2.1 is a preview with a menu-bar dashboard, a persistent session state machine, metadata-only hook ingestion, conservative window inference, notifications, and local status export.

**It has not passed end-to-end acceptance for all eight desktop products.** Claude Code, Codex, DSH and WorkBuddy activity/turn-end paths have been observed live. Antigravity 2.28.2 also passed a real question-and-answer lifecycle, while its native cancellation callback was not observed. Other integrations are explicitly marked as installed, fixture-tested, inferred, blocked, or unverified in the matrix above. CLI support never implies desktop support. Hidden conversations are not guaranteed by window observation.

Build with Swift 6 using `bash scripts/build-monitor.sh`, and check with `bash scripts/check.sh`. No third-party Swift package is required. Python 3 is used for hook bridges; Node.js is used for the DSH plugin checks. Existing access settings are not bypassed. See adapter documentation before enabling a source.

## License

Apache-2.0. System frameworks are used under their respective platform terms. No third-party pet artwork or application branding is distributed. Referenced projects are research leads, not affiliations or proof of compatibility.

开发优先级：先完成功能与逐应用验收；后续视觉参考 CC Switch。平时使用状态栏，点击再展开详情。
