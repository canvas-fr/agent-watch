import AppKit
@preconcurrency import ApplicationServices
import SwiftUI
import UserNotifications
import AgentWatchCore

@MainActor
final class MonitorModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var sessions: [SessionSnapshot] = []
    @Published var diagnostics: [String: String] = [:]
    @Published var runningApps = Set<String>()
    @Published var lastScan: Date?
    @Published var paused = false
    @Published var windowObservation = true
    @Published var notifyInferred = false
    @Published var notifyWindowCompletions = true
    @Published var notificationsEnabled = false
    @Published var statusMessage = "等待首次采集"
    @Published var recentNotices: [String] = []
    @Published var demo = false
    @Published var stateSince: [String: Date] = [:]
    @Published private var completions = CompletionInbox()
    private var store = SessionStore()
    private let collector: MonitorCollector
    private let supportDirectory: URL
    private var task: Task<Void, Never>?
    private var windowTask: Task<Void, Never>?
    private let windowCollector = WindowCollector()
    private var metadataTask: Task<Void, Never>?
    private let metadataSources = MetadataSources()
    private var geminiTask: Task<Void, Never>?
    private let geminiCollector = GeminiCollector()
    private let floatingPanel = FloatingPanelController()
    private var demoTurn = UUID().uuidString

    override init() {
        supportDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Watch")
        collector = MonitorCollector(directory: supportDirectory.appendingPathComponent("events"))
        super.init()
        let completionPath = supportDirectory.appendingPathComponent("completions.json")
        if let data = try? Data(contentsOf: completionPath), data.count < 100_000,
           let saved = try? JSONDecoder().decode(CompletionInbox.self, from: data) {
            completions = saved
            completions.remove(appID: "demo")
        }
        let enginePath = supportDirectory.appendingPathComponent("engine.json")
        if let size = try? enginePath.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 8_000_000,
           let data = try? Data(contentsOf: enginePath), let saved = try? JSONDecoder().decode(SessionStore.self, from: data) {
            store = saved
            store.remove(appID: "demo")
            let invalidated = store.invalidatePrematureStopCompletions()
            if !invalidated.isEmpty {
                for receipt in invalidated {
                    completions.remove(appID: receipt.appID, sessionID: receipt.sessionID, turnID: receipt.turnID)
                }
            }
            store.removeInferred()
            store.expire(now: Date())
            sessions = store.sessions.filter { !($0.evidence == .inferred && $0.stale) }
        }
        UNUserNotificationCenter.current().delegate = self
        demo = CommandLine.arguments.contains("--demo")
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsEnabled = settings.authorizationStatus == .authorized
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.paused { await self.scan() }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        windowTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.paused && self.windowObservation {
                    let scan = await self.windowCollector.collect()
                    if !self.paused && self.windowObservation {
                        self.diagnostics.merge(scan.diagnostics) { _, new in new }
                        self.ingest(scan.events)
                        _ = self.persistSnapshot()
                    }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        metadataTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.paused {
                    let health = await self.metadataSources.collect()
                    if !self.paused {
                        self.diagnostics.merge(health) { _, new in new }
                    }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        geminiTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.paused && self.windowObservation {
                    let scan = await self.geminiCollector.collect()
                    if !self.paused && self.windowObservation {
                        self.diagnostics.merge(scan.diagnostics) { _, new in new }
                        self.ingest(scan.events)
                        _ = self.persistSnapshot()
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    var attentionCount: Int { sessions.filter { $0.state.needsAttention && !$0.stale }.count }
    var activeCount: Int { sessions.filter { $0.state == .running && !$0.stale }.count }
    var completionCount: Int { completions.count }
    var barText: String { statusBarText(sessions: sessions, unreadCompletions: completions.count, paused: paused) }

    func recordsHealth(for appID: String) -> String? {
        if appID == "claude" {
            let parts = [("Code", "claude_code_records"), ("Cowork", "claude_records")].compactMap { name, key in
                diagnostics[key].map { name + " · " + recordsStatus($0) }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        guard appID == "codex", let code = diagnostics["codex_records"] else { return nil }
        return recordsStatus(code)
    }

    private func recordsStatus(_ code: String) -> String {
        switch code {
        case "ok", "schema_confirmed", "schema_compatible", "no_status_signal": return "本地任务记录可读"
        case "no_records": return "等待本地任务记录"
        case "busy": return "正在检查任务记录"
        case "python_unavailable": return "读取任务记录需要 Python 3"
        case "adapter_unavailable": return "本地接入组件缺失"
        case "timeout", "scan_limited": return "正在分批读取任务记录"
        case "partial": return "部分任务记录暂不可读"
        default: return "任务记录暂不可读 · 请查看诊断报告"
        }
    }

    func markCompletionsRead() {
        completions.markAllRead()
        _ = persistSnapshot()
    }

    func showFloatingPanel() { floatingPanel.show(monitor: self) }

    func scan() async {
        let observed = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        runningApps = Set(liveApps.filter { app in
            let identities = app.id == "doubao" ? Array(app.bundleIDs.prefix(1)) : app.bundleIDs
            return !identities.filter(observed.contains).isEmpty
        }.map(\.id))
        let batch = await collector.collect(windowsEnabled: false)
        guard !paused else { return }
        diagnostics["events"] = batch.diagnostics["events"]
        if !windowObservation {
            for app in liveApps { diagnostics[app.id] = "window_observation_disabled" }
        }
        ingest(batch.events)
        lastScan = Date()
        statusMessage = AXIsProcessTrusted() ? "持续采集中 · 窗口规则为推断，隐藏会话需事件接入" : "事件接收已运行 · 窗口观察需要辅助功能权限"
        if persistSnapshot() { await collector.acknowledge(batch.consumedFiles) }
    }

    private func ingest(_ events: [MonitorEvent]) {
        let now = Date()
        for event in events {
            if let notice = store.apply(event, now: now) {
                if notice.state == .responseEnded && shouldRecordCompletion(notice, source: event.source) {
                    completions.record(appID: notice.appID, sessionID: notice.sessionID, turnID: event.turnID)
                }
                if now.timeIntervalSince(event.observedAt) <= 30 {
                    deliver(notice, turnID: event.turnID, source: event.source)
                }
            }
        }
        store.expire(now: now)
        let before = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        sessions = store.sessions.filter { !($0.evidence == .inferred && $0.stale) }
        demo = sessions.contains { $0.appID == "demo" }
        for session in sessions {
            if stateSince[session.id] == nil || before[session.id]?.state != session.state || before[session.id]?.turnID != session.turnID {
                stateSince[session.id] = min(session.updatedAt, now)
            }
        }
        let activeIDs = Set(sessions.map(\.id))
        stateSince = stateSince.filter { activeIDs.contains($0.key) }
    }

    private func shouldRecordCompletion(_ notice: MonitorNotice, source: String) -> Bool {
        if notice.appID == "gemini" && notice.evidence == .inferred && source.hasPrefix("ax:gemini:") {
            return notifyWindowCompletions
        }
        return true
    }

    func grantAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        statusMessage = trusted ? "已有辅助功能权限" : "请在系统设置中为当前 Agent Watch 开启辅助功能权限"
    }

    func grantNotifications() {
        Task {
            do {
                notificationsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                statusMessage = notificationsEnabled ? "系统通知已开启" : "通知未授权；仍可查看菜单栏和面板提醒"
            } catch { statusMessage = "系统通知暂不可用；面板提醒仍可使用" }
        }
    }

    func openApp(_ appID: String) {
        guard let definition = liveApps.first(where: { $0.contains(appID) }),
              let url = definition.bundleIDs.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func setDemo(_ state: SessionState) {
        demo = true
        if state == .running { demoTurn = UUID().uuidString }
        let event = MonitorEvent(id: UUID().uuidString, appID: "demo", sessionID: "demo-session", turnID: demoTurn,
            state: state, evidence: .explicit, observedAt: Date(), source: "demo_only")
        if let notice = store.apply(event) { deliver(notice, turnID: event.turnID) }
        sessions = store.sessions
        _ = persistSnapshot()
    }

    func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "agent-watch-status.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { try snapshotData().write(to: url, options: .atomic); statusMessage = "状态报告已导出" }
            catch { statusMessage = "报告导出失败" }
        }
    }

    func clearDemo() {
        store.remove(appID: "demo")
        sessions = store.sessions
        demo = false
        completions.remove(appID: "demo")
        recentNotices.removeAll { $0.hasPrefix("演示会话") }
        _ = persistSnapshot()
    }

    private func deliver(_ notice: MonitorNotice, turnID: String, source: String = "") {
        if notice.state == .responseEnded && !shouldRecordCompletion(notice, source: source) { return }
        let verifiedWindowEnd = notifyWindowCompletions && notice.appID == "gemini"
            && notice.state == .responseEnded && source.hasPrefix("ax:gemini:")
        if notice.evidence == .inferred && !notifyInferred && !verifiedWindowEnd { return }
        if notice.state == .responseEnded && shouldRecordCompletion(notice, source: source) {
            completions.record(appID: notice.appID, sessionID: notice.sessionID, turnID: turnID)
        }
        let message = appName(notice.appID) + " · " + notice.state.label + (notice.evidence == .inferred ? "（推断）" : "")
        recentNotices.insert(message, at: 0)
        recentNotices = Array(recentNotices.prefix(20))
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Agent Watch"
        content.body = message
        content.sound = .default
        content.userInfo = ["appID": notice.appID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let appID = response.notification.request.content.userInfo["appID"] as? String else { return }
        await openApp(appID)
    }

    private struct Export: Encodable {
        let version: String
        let collectedAt: Date
        let demoIncluded: Bool
        let statusBar: String
        let unreadCompletions: Int
        let sessions: [SessionSnapshot]
        let diagnostics: [String: String]
    }

    private func snapshotData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Export(version: "0.3.2-preview", collectedAt: Date(), demoIncluded: demo,
                                         statusBar: barText, unreadCompletions: completionCount,
                                         sessions: sessions, diagnostics: diagnostics))
    }

    private func persistSnapshot() -> Bool {
        let path = supportDirectory.appendingPathComponent("status.json")
        let engine = supportDirectory.appendingPathComponent("engine.json")
        let completionPath = supportDirectory.appendingPathComponent("completions.json")
        do {
            try JSONEncoder().encode(completions).write(to: completionPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: completionPath.path)
            try JSONEncoder().encode(store).write(to: engine, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: engine.path)
            try snapshotData().write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return true
        } catch { statusMessage = "本地状态保存失败；待处理事件已保留"; return false }
    }
}
