import Foundation

/// Agents whose event bridge `adapters/manage_hooks.py` can install.
enum HookTarget: String, CaseIterable, Sendable {
    case claudeCode = "claude_code", codex, workbuddy

    /// Maps a monitored app in the catalog to its bridge target.
    init?(catalogID: String) {
        switch catalogID {
        case "claude": self = .claudeCode
        case "codex": self = .codex
        case "workbuddy": self = .workbuddy
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .workbuddy: return "WorkBuddy"
        }
    }

    var configPath: String {
        switch self {
        case .claudeCode: return "~/.claude/settings.json"
        case .codex: return "~/.codex/hooks.json"
        case .workbuddy: return "~/.workbuddy/settings.json"
        }
    }

    /// What the user still has to do in the agent after installing.
    var followUp: String {
        switch self {
        case .claudeCode: return "接入后新开一个 Claude Code 会话即可生效。"
        case .codex: return "接入后需在 Codex 中确认信任新的 hooks，再新开会话。"
        case .workbuddy: return "接入后退出并重新打开 WorkBuddy 即可生效。"
        }
    }
}

enum HookStatus: Equatable, Sendable {
    case installed, notInstalled, needsUpdate
    /// The bridge cannot be inspected; the value is a short user-facing reason.
    case unavailable(String)
}

/// Runs the bundled hook manager. Every run either previews or applies one explicit change;
/// the manager backs up the target file and only touches entries marked as Agent Watch.
enum HookInstaller {
    private static let unchanged = "no configuration or bridge change needed"

    static func status(of target: HookTarget) async -> HookStatus {
        guard case .success(let install) = await run(target, apply: false, uninstall: false) else {
            return .unavailable(failureReason())
        }
        if install.contains(unchanged) { return .installed }
        guard case .success(let removal) = await run(target, apply: false, uninstall: true) else {
            return .unavailable(failureReason())
        }
        // Nothing to remove means nothing of ours is present yet.
        return removal.contains(unchanged) ? .notInstalled : .needsUpdate
    }

    static func apply(_ target: HookTarget, uninstall: Bool) async -> Bool {
        if case .success = await run(target, apply: true, uninstall: uninstall) { return true }
        return false
    }

    private static func failureReason() -> String {
        MetadataSources.pythonInterpreter() == nil ? "需要先安装 Python 3" : "无法读取接入配置"
    }

    private static func run(_ target: HookTarget, apply: Bool, uninstall: Bool) async -> Result<String, HookError> {
        guard let python = MetadataSources.pythonInterpreter(),
              let script = Bundle.main.resourceURL?.appendingPathComponent("adapters/manage_hooks.py"),
              FileManager.default.isReadableFile(atPath: script.path) else { return .failure(.unavailable) }
        var arguments = ["-B", "-E", "-s", script.path, "--app", target.rawValue]
        if uninstall { arguments.append("--uninstall") }
        if apply { arguments.append("--apply") }
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = python
            process.arguments = arguments
            process.currentDirectoryURL = script.deletingLastPathComponent()
            process.environment = ["HOME": NSHomeDirectory()]
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            do { try process.run() } catch { return .failure(.unavailable) }
            // The manager prints a few short summary lines; cap what is kept.
            let data = pipe.fileHandleForReading.readDataToEndOfFile().prefix(8_192)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .failure(.failed) }
            return .success(String(decoding: data, as: UTF8.self))
        }.value
    }

    private enum HookError: Error { case unavailable, failed }
}
