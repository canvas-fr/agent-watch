# Gemini 与豆包桌面版：状态信号只读调查

检查日期：2026-11-04。目标是确认是否存在可支持可靠任务结束事件的公开来源；本报告不改变 Agent Watch 主程序、配置或系统权限。

## 结论

**本轮没有找到 Gemini 或豆包可供第三方稳定读取的轮次完成、失败、取消或等待状态接口，因此没有新增适配器或状态 fixture。** 继续将这两款应用标记为“状态未知 / 未验证”。不以进程空闲、窗口/控件消失、文件更新时间、内部符号或未解释的通知作为本轮结束证据。

## 本机安装包静态检查

| 应用 | 本机包版本 | 这轮检查到的线索 | 结论边界 |
| --- | --- | --- | --- |
| Gemini | `com.google.GeminiMacOS`，`1.138.0.1315` | 主程序二进制包含 `isGenerating`、`isStreaming`、`ROBINLastTurnState_Completed`、`ROBINLastTurnState_InProgress` 等内部字符串，也包含通用 `AXObserver`、`UNUserNotificationCenter` 和日志符号。App Intents 元数据可见 `ConversationsNeedingAttention`、`OpenConversationIntent` 等名称片段。 | 这些是应用实现/动作元数据，不是受支持的跨进程轮次事件协议。没有文档说明其状态值、身份、顺序或终态含义；本轮没有调用 App Intent、读取 AX 文本或接触日志。 |
| 豆包 | `com.bot.neotix.doubao`，`2.24.10` | 主程序中没有发现本次有限关键词清单中的 AX 状态通知、完成/轮次标记或通知中心接口名。静态网页资源中 `TaskStatus`、`turn{state` 等匹配位于 `local_webcontents/apps/doubao-office` 的办公子应用文件树。 | Office 子应用里的任务字段不能证明主聊天产品公开了生成状态。此前的只读 schema 调查也没有发现可见的 SQLite 任务生命周期列；对 IndexedDB 记录没有读取。 |

安装包字符串是版本绑定的静态线索。没有匹配到字符串不能证明二进制内部绝无类似功能；同样，发现内部状态符号也不能证明第三方可以安全或稳定订阅它。

## 可用系统机制的判定

### macOS 辅助功能（Accessibility，辅助功能）

这里所说的跨进程观察端是 ApplicationServices 的 `AXUIElement` / `AXObserver` API。AppKit 的 `NSAccessibilityProtocol` 是目标应用为自身控件提供属性、动作和通知的接口；它不会自动产生任务生命周期语义。[AXUIElement.h](https://developer.apple.com/documentation/applicationservices/axuielement_h)、[NSAccessibilityProtocol](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol)

苹果的 `AXObserver` 可以订阅目标应用中**目标辅助功能元素实际支持**的通知。系统定义的 `AXValueChanged` 只表示某元素的 `value` 属性改变，`AXLayoutChanged` 只表示界面布局改变；注册还可能返回“不支持此通知”。这能作为观察已验证状态控件变化的传输方式，但不替目标应用定义“正在生成”或“本轮完成”的含义。[AXObserverAddNotification](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)、[AXNotificationConstants](https://developer.apple.com/documentation/applicationservices/axnotificationconstants_h/miscellaneous_defines)

**目前没有证据表明 Gemini 或豆包会暴露稳定、专用且与会话/轮次绑定的状态元素。** 要把 AX 用作可靠适配器，后续必须先在授权的合成任务中验证一个固定状态属性及其明确枚举值（运行、等待用户、结束、失败、取消），并确认后台/最小化/多窗口下身份仍稳定。只有在该状态元素上订阅属性变化并读取其白名单值才值得继续；按钮消失、普通布局变化、控件数量变化均不足以结束任务。

### 统一日志（Unified Logging，统一日志）

Gemini 二进制里的通用 Logger/OSLog 字样并不构成日志事件接口。苹果将日志描述为诊断用途；应用可自定 subsystem/category、级别以及动态字段的隐私标记，动态字符串默认可能被隐藏，部分级别也不保证落盘。[生成日志消息](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)、[OSLogPrivacy](https://developer.apple.com/documentation/os/oslogprivacy)

因此，除非应用公开并承诺一个结构化任务事件类别、状态字段、身份/轮次键和兼容策略，否则 `log` / `OSLogStore` 读取只能视为脆弱的诊断观察。为避免采集用户对话或凭据，本轮没有读取系统日志。

### 通知中心（UserNotifications，用户通知）

苹果文档中的 `UNUserNotificationCenter` 用于管理当前应用或其扩展的通知；delegate 处理该应用运行期间收到的通知及其操作，不是跨应用的全局通知订阅器。[UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter)、[UNUserNotificationCenterDelegate](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate)

即使目标程序有推送/通知能力，也不能据此推断 Agent Watch 能取得另一应用的任务状态通知。读取通知中心数据库或未公开 IPC 不属于可依赖的公开路线；本轮没有读取系统或应用通知内容。

### App Intents（应用意图）

Gemini 包内出现的 `ConversationsNeedingAttention` 等名称片段可能是系统可发现的应用动作/数据标识，但本机元数据没有给出可供轮询的公开状态定义。本轮未执行这些动作。苹果将 App Intents（应用意图）定义为把应用动作和数据提供给 Siri、Spotlight、快捷指令等系统体验的机制，并未把它定义为第三方任务生命周期事件流。[App Intents](https://developer.apple.com/documentation/appintents)

## 官方与开源资料交叉检查

- Google 的 [Gemini for Mac 使用说明](https://support.google.com/gemini/answer/17011627?hl=en-6)描述桌面访问、生成式辅助和窗口共享等用户功能，没有给出本地任务事件 API、可订阅通知或轮次状态 schema。这是对公开帮助页的范围结论，不是对 Google 未公开接口的绝对证明。
- 豆包的[桌面版官方页面](https://www.doubao.com/download/desktop)描述桌面 AI 能力；[隐私说明](https://www.doubao.com/legal/privacy)描述任务模式在界面内展示执行动作。所查看的这些官方页面没有定义供第三方订阅的桌面任务事件协议。
- 开源项目 [doubao-desktop-pet README](https://github.com/pengchujin/doubao-desktop-pet/blob/main/README.md)自述豆包客户端没有开放状态接口，并采用进程/前台三态、外部 HTTP 上报和手动切换。其[探测代码](https://github.com/pengchujin/doubao-desktop-pet/blob/main/src/main/doubaoProbe.js)只探测进程和前台状态；其 [HTTP 服务](https://github.com/pengchujin/doubao-desktop-pet/blob/main/src/main/hookServer.js)是桌宠自身接收外部上报的服务，不是读取豆包事件的服务。这是第三方先例，不能替代官方声明或本机实测。

如果某个外部自动化脚本本身拥有明确的开始/结束生命周期，它可以按 Agent Watch 的 [事件协议](EVENTS.md)提交显式事件；这只代表该脚本托管的任务，不代表对普通手动 Gemini/豆包会话的自动监控。

## 本轮边界与后续准入条件

本轮只读取应用包元数据、静态二进制/资源中的有限信号名称，以及上述公开页面。豆包主程序有限扫描词为 `AXObserver`、`AXValueChangedNotification`、`UNUserNotificationCenter`、`NSDistributedNotificationCenter`、`DistributedNotification`、`OSLog`、`os_log`、`Logger`、`isGenerating`、`isStreaming`、`taskStatus`、`responseEnd`、`turnState`。没有读取聊天正文、标题、消息行、凭据、运行时网络令牌、应用数据库行、系统日志或通知正文，没有查询运行时 AX 文本，没有截屏或操作应用，也没有改配置、权限或主程序。旧 schema 调查的范围和未读数据边界见外部只读记录。

只有找到**有公开语义且与单一会话/轮次相关联**的信号，才可新增 fixture 或适配器。最低验收条件是合成任务能重复区分运行、等待用户、正常结束、失败与取消；标识与状态顺序稳定；后台、最小化和多窗口不会串线；观察中断后回到未知而不是补判完成。若 AX 后续只暴露动态 UI 变化而没有明确状态值，仍维持未知。
