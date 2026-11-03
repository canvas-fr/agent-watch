import Foundation

/// A possible on-device source is a discovery lead, never proof of an adapter.
struct SourceCandidate: Codable, Sendable {
    let path: String
    let purpose: String
}

struct TargetApplication: Codable, Sendable {
    let id: String
    let name: String
    let bundleNames: [String]
    let knownBundleIDs: [String]
    let candidates: [SourceCandidate]
    let nextVerification: String
}

enum AppCatalog {
    static let applications: [TargetApplication] = [
        .init(id: "doubao", name: "豆包", bundleNames: ["Doubao.app"],
              knownBundleIDs: ["com.bot.neotix.doubao"],
              candidates: [.init(path: "~/Library/Application Support/Doubao", purpose: "候选应用数据目录；存在不代表可读取任务状态")],
              nextVerification: "用测试会话验证任务元数据与辅助功能状态，排除页面同步误报。"),
        .init(id: "antigravity", name: "Antigravity", bundleNames: ["Antigravity.app"],
              knownBundleIDs: ["com.google.antigravity"],
              candidates: [.init(path: "~/Library/Application Support/Antigravity", purpose: "候选应用数据目录；本轮仅检查目录元数据")],
              nextVerification: "验证桌面事件来源、多项目身份、授权请求和授权后的恢复。"),
        .init(id: "gemini", name: "Gemini 桌面版", bundleNames: ["Gemini.app"],
              knownBundleIDs: ["com.google.GeminiMacOS"], candidates: [],
              nextVerification: "优先验证后台、最小化、切换聊天后是否仍有明确状态控件；命令行版不计为桌面支持。"),
        .init(id: "codex", name: "ChatGPT／Codex", bundleNames: ["ChatGPT.app", "Codex.app"],
              knownBundleIDs: ["com.openai.codex", "com.openai.chat"],
              candidates: [
                .init(path: "~/.codex/hooks.json", purpose: "事件配置候选文件；本轮不读取或修改内容"),
                .init(path: "~/.codex/sessions", purpose: "会话目录存在性；本轮不读取或遍历对话")
              ],
              nextVerification: "分别验证 Codex 工作会话、普通 ChatGPT 聊天及后台任务；按实际包标识区分客户端。"),
        .init(id: "claude", name: "Claude", bundleNames: ["Claude.app"],
              knownBundleIDs: ["com.anthropic.claudefordesktop"],
              candidates: [
                .init(path: "~/.claude/settings.json", purpose: "事件配置候选文件；存在不证明桌面各模式触发回调"),
                .init(path: "~/Library/Application Support/Claude", purpose: "应用目录元数据；不读取聊天或扩展内容")
              ],
              nextVerification: "Code、Chat、Cowork 各模式分别验证，不将命令行回调的支持直接推广。"),
        .init(id: "dsh", name: "DeepSeek Harness", bundleNames: ["DeepSeek Harness.app"],
              knownBundleIDs: ["com.deepseek.dsh"], candidates: [],
              nextVerification: "验证桌面插件的会话、提问、授权事件，以及多会话和重连。"),
        .init(id: "devin", name: "Devin", bundleNames: ["Devin.app", "Windsurf.app"],
              knownBundleIDs: ["com.exafunction.windsurf"],
              candidates: [.init(path: "~/Library/Application Support/Windsurf", purpose: "历史名称候选目录；存在不证明当前 Devin 正在使用")],
              nextVerification: "按实际客户端版本验证桌面不同任务模式及其会话状态来源。"),
        .init(id: "workbuddy", name: "WorkBuddy", bundleNames: ["WorkBuddy.app"],
              knownBundleIDs: ["com.tencent.workbuddy.mac"],
              candidates: [
                .init(path: "~/.workbuddy-ai/settings.json", purpose: "当前事件配置候选路径；本轮不读取内容"),
                .init(path: "~/.workbuddy/settings.json", purpose: "旧版配置候选路径；存在不证明当前生效")
              ],
              nextVerification: "验证桌面状态回调、原生授权卡片和用户提问；不注册审批处理器。")
    ]
}

enum PrivatePath {
    static func expand(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }

    /// Keep local account names out of reports that users may later share.
    static func display(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        // Apps can be running from an arbitrary private project or mounted folder.
        if path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/") { return path }
        return "<outside-standard-applications>/" + url.lastPathComponent
    }
}
