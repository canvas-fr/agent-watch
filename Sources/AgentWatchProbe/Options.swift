import Foundation

enum ProbeError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self { case .usage(let message): return message }
    }
}

struct ProbeOptions {
    var format = "markdown"
    var output: String?
    var appID: String?
    var accessibility = false
    var help = false

    static func parse(_ arguments: [String]) throws -> ProbeOptions {
        var options = ProbeOptions()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--help", "-h": options.help = true
            case "--accessibility": options.accessibility = true
            case "--format", "--output", "--app":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw ProbeError.usage("\(option) 缺少参数。")
                }
                switch option {
                case "--format": options.format = arguments[index]
                case "--output": options.output = arguments[index]
                default: options.appID = arguments[index]
                }
            default: throw ProbeError.usage("未知参数：\(option)。使用 --help 查看说明。")
            }
            index += 1
        }
        guard ["markdown", "json"].contains(options.format) else {
            throw ProbeError.usage("--format 只支持 markdown 或 json。")
        }
        if let appID = options.appID, !AppCatalog.applications.contains(where: { $0.id == appID }) {
            throw ProbeError.usage("未知应用：\(appID)。支持：\(AppCatalog.applications.map(\.id).joined(separator: ", "))。")
        }
        return options
    }

    static let usage = """
    Agent Watch — 第 0 阶段只读探测

    用法：agent-watch-probe [--app ID] [--accessibility] [--format markdown|json] [--output PATH]

      --app ID          仅探测一个应用，默认探测全部八个。
      --accessibility   尝试读取辅助功能角色统计；缺少系统授权时仅报告缺失，不弹窗。
      --format FORMAT   markdown（默认）或 json。
      --output PATH     将报告写入指定的新文件；默认输出到终端，拒绝覆盖已有文件。
      --help            显示帮助。

    应用 ID：doubao, antigravity, gemini, codex, claude, dsh, devin, workbuddy
    本原型不读取聊天正文或截图、不更改应用配置、不激活应用，也不推断任务正在运行或完成。
    """
}
