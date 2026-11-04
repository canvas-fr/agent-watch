import Foundation
import AgentWatchCore

struct LiveApp: Identifiable, Sendable {
    let id: String
    let name: String
    let bundleIDs: [String]
    let capability: String
    var target: WindowTarget { WindowTarget(appID: id, bundleIDs: bundleIDs) }
    func contains(_ appID: String) -> Bool { id == appID || (id == "claude" && appID == "claude_code") }
}

let liveApps: [LiveApp] = [
    .init(id: "antigravity", name: "Antigravity", bundleIDs: ["com.google.antigravity"], capability: "官方事件 / 窗口观察"),
    .init(id: "gemini", name: "Gemini", bundleIDs: ["com.google.GeminiMacOS"], capability: "实验 · 窗口结束推断，默认关闭"),
    .init(id: "codex", name: "ChatGPT / Codex", bundleIDs: ["com.openai.codex", "com.openai.chat"], capability: "Codex 事件接入 / 窗口观察"),
    .init(id: "claude", name: "Claude", bundleIDs: ["com.anthropic.claudefordesktop"], capability: "Code 事件 / 本地 Chat、Cowork 记录"),
    .init(id: "dsh", name: "DeepSeek Harness", bundleIDs: ["com.deepseek.dsh"], capability: "会话事件 / 窗口观察"),
    .init(id: "devin", name: "Devin", bundleIDs: ["com.exafunction.windsurf"], capability: "实验 · Local 运行与授权，结束未知"),
    .init(id: "workbuddy", name: "WorkBuddy", bundleIDs: ["com.tencent.workbuddy.mac"], capability: "会话事件 / 窗口观察")
]

func appName(_ id: String) -> String {
    if id == "demo" { return "演示会话" }
    if id == "claude_code" { return "Claude Code" }
    return liveApps.first { $0.id == id }?.name ?? "未知应用"
}

extension SessionState {
    var label: String {
        switch self {
        case .unknown: return "状态未知"
        case .running: return "运行中"
        case .waitingApproval: return "等待授权"
        case .waitingInput: return "等待回答"
        case .responseEnded: return "本轮已结束"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
    var needsAttention: Bool { self == .waitingApproval || self == .waitingInput || self == .failed }
}
