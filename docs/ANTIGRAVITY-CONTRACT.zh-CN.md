# Antigravity Stop 与交互等待契约核对

核对日期：2026-11-04

## 本机 bundle 身份

本机 `/Applications/Antigravity.app` 的 macOS 应用清单版本字段 `CFBundleShortVersionString` 与 `CFBundleVersion` 均为 `2.28.2`。

| 文件 | SHA-256（Secure Hash Algorithm 256-bit，256 位安全哈希算法） |
| --- | --- |
| `/Applications/Antigravity.app/Contents/Resources/bin/language_server` | `8b660ea42c9e24b7a6be339bfa573d25b19d0770dba6e5185c205f2ad1da26d6` |
| `/Applications/Antigravity.app/Contents/Resources/app.asar` | `046fa2ba9abe96bc915eb7ed12887c067396a8a12148842ab4f4e2cd05a68feb` |

下文中本机语义来自已安装 `language_server` 的内嵌 Hook Contract 字符串（Stop 合同约在文件偏移 `53,226,543` 字节）。完整枚举名来自同一二进制中的 `ExecutorTerminationReason` Protocol Buffers（protobuf，协议缓冲区）描述符（约在偏移 `56,977,450` 字节）。这些偏移与上表 SHA-256 一起可用于复核。

## Stop terminationReason

内嵌 Hook Contract 说明：`terminationReason` 是 `ExecutorTerminationReason` 枚举名去掉 `EXECUTOR_TERMINATION_REASON_` 前缀后的字符串。合同明确把 `NO_TOOL_CALL` 定义为正常轮次结束：模型未调用工具即完成。

| Hook 值 | 本机内嵌语义 |
| --- | --- |
| `NO_TOOL_CALL` | 正常轮次结束；模型完成时没有调用工具。 |
| `MAX_INVOCATIONS` | 达到最大模型调用次数。 |
| `MAX_FORCED_INVOCATIONS` | 达到强制继续调用的上限。 |
| `MAX_TOKEN_BUDGET_EXCEEDED` | 超出模型 token 预算。 |
| `ERROR` | 因执行错误终止。 |
| `USER_CANCELED` | 用户取消。 |
| `TERMINAL_STEP_TYPE` | 在终止类型的 step 上停止。 |
| `TERMINAL_CUSTOM_HOOK` | 被自定义 `PostInvocation` hook 终止。 |
| `INJECTED_RESPONSE` | 在注入响应后终止。 |

本机 protobuf 描述符另有 `UNSPECIFIED`、`EARLY_CONTINUE`、`HALTED_STEP`。它们在枚举描述符中存在，但未出现在内嵌 Stop Hook Contract 的值及语义说明中；仅凭描述符不能断定 Hook 会在何种情形发出这些值，适配器应保留未知处理。

枚举语义不等于监控器状态分类。比如本机合同只说三个 `MAX_*` 值代表相应上限或预算已达到，并没有把它们定义为主机的 `failed` 状态；该分类属于适配器策略。

`USER_CANCELED` 的枚举存在也不等于取消操作一定会派发 `Stop` Hook；该点需由真实取消路径验证。

## 官方网页与本机合同的差异

[Google 官方 Hooks 文档的 Stop 段落](https://antigravity.google/docs/hooks?tab=ide)把 `terminationReason` 描述为字符串，并仅以 `model_stop`、`max_steps_exceeded`、`error` 举例。网页措辞为示例，并未给出闭合枚举。本机合同则给出带大写的 `ExecutorTerminationReason` 值及上述语义。

因此名称与粒度存在差异：网页的正常结束示例是 `model_stop`，本机合同中的正常结束值是 `NO_TOOL_CALL`；网页的上限示例是 `max_steps_exceeded`，本机列出模型调用次数上限和 token 预算等值；网页示例 `error` 对应本机合同里的 `ERROR`。不应把网页示例误当成完整枚举，也不应将未见过的值直接判定为成功或失败。

官方文档还说明 `fullyIdle=true` 表示 agent 与后台或异步任务均已结束，`false` 表示仍有后台任务。这一字段应与停止原因分别处理：`NO_TOOL_CALL` 表示本轮正常结束原因；仅当同时 `fullyIdle=true` 时，才表示整个任务已空闲。

## PreToolUse 与等待输入

官方 Hooks 文档的 Supported tools 列表包含 `ask_question`（向用户提出多选问题）和 `ask_permission`（请求额外的权限范围）。`PreToolUse` 在工具执行前触发，输入包含 `toolCall.name`；hook 可按工具名匹配。监控等待输入时只需读取白名单中的工具名，不必解析或保存 `toolCall.args`。`PostToolUse` 在工具完成后触发，可用于结束该交互等待标记。

本次真实交互中，`ask_question` 显示了选择界面；监控记录到 `waitingInput`，来源为 `antigravity:PreToolUse:ask_question`。观察记录只保留工具名，没有保存参数。选择后已观察到恢复 `running`，随后同一观察轮次收到 `Stop:NO_TOOL_CALL` 并转为 `responseEnded`。

工具可能使用先前授权，因此不把 `ask_permission` 映射成 `waitingApproval`：单凭工具名无法证明出现了待审批提示。官方事件表没有单独的批准或拒绝结果事件；`PreToolUse` 只能作为交互开始的信号，不能单独证明用户是否已批准。

## 原生取消的观测与源码边界

同一专用测试会话中，点击原生 Cancel（Control-C）后，界面明确提示 agent execution 已由用户取消；33 秒后监控端仍只有 `PreInvocation` 对应的 `running`，没有观察到 `Stop`。120 秒新鲜度阈值后，监控转为陈旧的 `unknown`，没有误报完成。这是一次真实取消负例；静态枚举里的 `USER_CANCELED` 不能据此视为已验证可用的取消回调。

本次静态检查不能从源码确认取消路径是否会跳过 `Stop` 派发。`app.asar` 中可读到的是 Electron 主进程与进程间通信（Inter-Process Communication，IPC）外壳；实际 agent 服务是已编译的 Mach-O `language_server`，其中可核对 Hook Contract 和 Protocol Buffers 枚举，但没有可追踪的取消处理到 Hook 派发的源码控制流。因此“33 秒未见 Stop”是该次运行观测，不能从现有静态源码推广成“所有取消都不派发 Stop”。未读取用户 transcript、聊天正文或运行日志。

## 对照观测

在无关项目的新会话中，固定短回复的元数据捕获为 `terminationReason=NO_TOOL_CALL`、`fullyIdle=true`、`executionNum=0`，与本机内嵌合同的正常结束语义一致。该观察不包含或引用会话正文。

静态检查仅读取已安装应用 bundle 中的代码、元数据和公开 Hook 文档；没有读取会话 transcript、聊天正文或凭据，也没有修改 Antigravity 配置。本文只记录当前 `2.28.2` 安装包证据；后续版本应重新核对版本与哈希。
