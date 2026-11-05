import AppKit
@preconcurrency import ApplicationServices
import SwiftUI
import UserNotifications
import AgentWatchCore

struct FloatingAlertKey: Hashable {
    let appID: String
    let sessionID: String
    let turnID: String
    let state: SessionState
}

extension FloatingAlertKey {
    init(_ session: SessionSnapshot) {
        self.init(appID: session.appID, sessionID: session.sessionID, turnID: session.turnID, state: session.state)
    }
}

@MainActor
final class MonitorModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var sessions: [SessionSnapshot] = []
    @Published var diagnostics: [String: String] = [:]
    @Published private(set) var runningBundleIDs = Set<String>()
    @Published var lastScan: Date?
    @Published var paused = false {
        didSet {
            if paused { dismissFloatingAlerts(floatingAlerts) }
        }
    }
    @Published var dashboardPage = "all"
    // Experimental switches stay off by default and keep the user's choice across launches.
    @Published var windowObservation = WatchPreferences.store.bool(forKey: "windowObservation") {
        didSet { WatchPreferences.store.set(windowObservation, forKey: "windowObservation") }
    }
    @Published var notifyInferred = WatchPreferences.store.bool(forKey: "notifyInferred") {
        didSet { WatchPreferences.store.set(notifyInferred, forKey: "notifyInferred") }
    }
    @Published var notifyWindowCompletions = WatchPreferences.store.bool(forKey: "notifyWindowCompletions") {
        didSet { WatchPreferences.store.set(notifyWindowCompletions, forKey: "notifyWindowCompletions") }
    }
    /// Claude Code turn ends come from its Stop hook; on by default because records cannot confirm them.
    @Published var notifyClaudeCodeEnds = WatchPreferences.store.object(forKey: "notifyClaudeCodeEnds") as? Bool ?? true {
        didSet { WatchPreferences.store.set(notifyClaudeCodeEnds, forKey: "notifyClaudeCodeEnds") }
    }
    @Published private(set) var hookStatus: [HookTarget: HookStatus] = [:]
    @Published private(set) var hookBusy = Set<HookTarget>()
    @Published var notificationsEnabled = false
    @Published var statusMessage = "等待首次采集"
    @Published var recentNotices: [String] = []
    @Published var demo = false
    @Published var stateSince: [String: Date] = [:]
    /// Observed running time of turns that just ended, keyed by session ID.
    @Published private(set) var turnDurations: [String: TimeInterval] = [:]
    @Published var completionChime = WatchPreferences.store.object(forKey: "completionChime") as? Bool ?? true {
        didSet { WatchPreferences.store.set(completionChime, forKey: "completionChime") }
    }
    @Published private(set) var floatingAlerts = Set<FloatingAlertKey>()
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
    private var demoTurn = UUID().uuidString
    private var lastChime = Date.distantPast
    private let isPreview: Bool
    private var engineCache = SnapshotFileCache()
    private var completionCache = SnapshotFileCache()

    override convenience init() { self.init(preview: false) }

    init(preview: Bool) {
        isPreview = preview
        supportDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Watch")
        collector = MonitorCollector(directory: supportDirectory.appendingPathComponent("events"))
        super.init()
        // Development previews use synthetic metadata and never start collectors,
        // touch user state, request permissions, or send system notifications.
        if preview {
            let now = Date()
            sessions = [
                ("claude_code", "review-session", SessionState.waitingApproval, EvidenceKind.explicit, 132.0),
                ("codex", "build-session", .running, .explicit, 248.0),
                ("dsh", "question-session", .waitingInput, .explicit, 64.0),
                ("antigravity", "complete-session", .responseEnded, .explicit, 37.0),
                ("gemini", "window-session", .unknown, .inferred, 18.0)
            ].map { app, session, state, evidence, elapsed in
                SessionSnapshot(appID: app, sessionID: session, turnID: "preview-turn", state: state,
                    evidence: evidence, updatedAt: now.addingTimeInterval(-elapsed), source: "synthetic_preview",
                    parentSessionID: nil, stale: false)
            }
            runningBundleIDs = ["com.anthropic.claudefordesktop", "com.openai.codex", "com.deepseek.dsh",
                                "com.google.antigravity", "com.google.GeminiMacOS"]
            completions.record(appID: "antigravity", sessionID: "complete-session", turnID: "preview-turn")
            demo = true
            lastScan = now
            statusMessage = "界面预览 · 合成数据，未运行采集器"
            hookStatus = [.claudeCode: .installed, .codex: .notInstalled, .workbuddy: .needsUpdate]
            return
        }
        let completionPath = supportDirectory.appendingPathComponent("completions.json")
        if let data = try? Data(contentsOf: completionPath), data.count < 100_000,
           let saved = try? JSONDecoder().decode(CompletionInbox.self, from: data) {
            completions = saved
            completions.remove(appID: "demo")
            completions.remove(appID: "doubao")
        }
        let enginePath = supportDirectory.appendingPathComponent("engine.json")
        if let size = try? enginePath.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 64 * 1024 * 1024,
           let data = try? Data(contentsOf: enginePath), let saved = try? JSONDecoder().decode(SessionStore.self, from: data) {
            store = saved
            store.remove(appID: "demo")
            store.remove(appID: "doubao")
            let invalidated = store.invalidateUnconfirmedCompletions()
            if !invalidated.isEmpty {
                for receipt in invalidated {
                    completions.remove(appID: receipt.appID, sessionID: receipt.sessionID, turnID: receipt.turnID)
                }
            }
            store.removeWindowObservations()
            store.expire(now: Date())
            sessions = store.sessions.filter { !($0.isWindowObservation && $0.stale) }
        }
        UNUserNotificationCenter.current().delegate = self
        // The first launch opens on the integrations page, where the setup checklist lives.
        if !WatchPreferences.store.bool(forKey: "onboardingSeen") {
            dashboardPage = "integrations"
            WatchPreferences.store.set(true, forKey: "onboardingSeen")
        }
        refreshHookStatus()
        demo = CommandLine.arguments.contains("--demo")
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsEnabled = settings.authorizationStatus == .authorized
            diagnostics["notifications"] = Self.notificationStatus(settings.authorizationStatus)
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshRunningApps()
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
        // Explicit startup options support the normal OS permission flow;
        // they request consent and never grant access programmatically.
        if CommandLine.arguments.contains("--request-accessibility")
            || CommandLine.arguments.contains("--request-notifications") {
            Task { [weak self] in
                await Task.yield()
                guard let self else { return }
                if CommandLine.arguments.contains("--request-accessibility") { self.grantAccessibility() }
                if CommandLine.arguments.contains("--request-notifications") { self.grantNotifications() }
            }
        }
    }

    var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    var attentionCount: Int { sessions.filter { $0.state.needsAttention && !$0.stale }.count }
    var activeCount: Int { sessions.filter { $0.state == .running && !$0.stale }.count }
    var completionCount: Int { completions.count }
    var barText: String { statusBarText(sessions: sessions, unreadCompletions: completions.count, paused: paused) }
    var runningApps: Set<String> {
        Set(liveApps.filter { $0.bundleIDs.contains(where: runningBundleIDs.contains) }.map(\.id))
    }

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
        floatingAlerts = floatingAlerts.filter { $0.state != .responseEnded }
        _ = persistSnapshot()
    }

    func dismissFloatingAlerts(_ displayed: Set<FloatingAlertKey>) {
        if !floatingAlerts.isDisjoint(with: displayed) { floatingAlerts.subtract(displayed) }
    }

    private func refreshRunningApps() {
        let observed = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier)
        let opened = Set(liveApps.flatMap(\.bundleIDs)).intersection(observed)
        guard opened != runningBundleIDs else { return }
        let closed = runningBundleIDs.subtracting(opened)
        runningBundleIDs = opened
        if !closed.isEmpty && !floatingAlerts.isEmpty {
            let ended = sessions.compactMap { session -> FloatingAlertKey? in
                guard let bundleID = desktopBundleID(for: session), closed.contains(bundleID) else { return nil }
                return FloatingAlertKey(session)
            }
            floatingAlerts.subtract(ended)
        }
    }

    func scan() async {
        let batch = await collector.collect(windowsEnabled: false)
        guard !paused else { return }
        diagnostics["events"] = batch.diagnostics["events"]
        if !windowObservation {
            for app in liveApps { diagnostics[app.id] = "window_observation_disabled" }
        }
        ingest(batch.events)
        lastScan = Date()
        statusMessage = !windowObservation ? "事件与本地记录采集中 · 实验窗口观察未启用"
            : AXIsProcessTrusted() ? "持续采集中 · 窗口规则为推断，隐藏会话需事件接入" : "事件接收已运行 · 窗口观察需要辅助功能权限"
        if persistSnapshot() { await collector.acknowledge(batch.consumedFiles) }
    }

    private func ingest(_ events: [MonitorEvent]) {
        let now = Date()
        var alerts = floatingAlerts
        for event in events {
            if let notice = store.apply(event, now: now) {
                if notice.state == .responseEnded && shouldRecordCompletion(notice, source: event.source) {
                    completions.record(appID: notice.appID, sessionID: notice.sessionID, turnID: event.turnID)
                }
                if now.timeIntervalSince(event.observedAt) <= 30,
                   allowsNotice(appID: notice.appID, state: notice.state, evidence: notice.evidence, source: event.source) {
                    if Self.floatingStates.contains(notice.state) {
                        alerts.insert(FloatingAlertKey(appID: event.appID, sessionID: event.sessionID,
                                                       turnID: event.turnID, state: notice.state))
                    }
                    let snapshot = store.sessions.first { $0.appID == notice.appID && $0.sessionID == notice.sessionID }
                    deliver(notice, bundleID: snapshot.flatMap(desktopBundleID(for:)))
                }
            }
        }
        store.expire(now: now)
        let before = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        sessions = store.sessions.filter { !($0.isWindowObservation && $0.stale) }
        demo = sessions.contains { $0.appID == "demo" }
        var durations = turnDurations
        for session in sessions where session.state == .responseEnded {
            guard let previous = before[session.id], previous.state == .running,
                  previous.turnID == session.turnID, let start = stateSince[session.id] else { continue }
            durations[session.id] = max(0, session.updatedAt.timeIntervalSince(start))
        }
        let endedIDs = Set(sessions.filter { $0.state == .responseEnded }.map(\.id))
        durations = durations.filter { endedIDs.contains($0.key) }
        if durations != turnDurations { turnDurations = durations }
        for session in sessions {
            if stateSince[session.id] == nil || before[session.id]?.state != session.state || before[session.id]?.turnID != session.turnID {
                stateSince[session.id] = min(session.updatedAt, now)
            }
        }
        let activeIDs = Set(sessions.map(\.id))
        stateSince = stateSince.filter { activeIDs.contains($0.key) }

        let currentAlerts = sessions.filter { session in
            !session.stale && Self.floatingStates.contains(session.state)
                && allowsNotice(appID: session.appID, state: session.state, evidence: session.evidence, source: session.source)
        }
        if !notifyInferred {
            for session in currentAlerts where session.state.isWaiting && now.timeIntervalSince(session.updatedAt) <= 30 {
                let previous = before[session.id]
                if previous?.state == session.state && previous?.evidence == .inferred && previous?.turnID == session.turnID {
                    alerts.insert(FloatingAlertKey(session))
                }
            }
        }
        let activeAlerts = paused ? [] : alerts.intersection(currentAlerts.map(FloatingAlertKey.init))
        if activeAlerts != floatingAlerts { floatingAlerts = activeAlerts }
    }

    private func shouldRecordCompletion(_ notice: MonitorNotice, source: String) -> Bool {
        if isInferredGeminiWindow(appID: notice.appID, evidence: notice.evidence, source: source) {
            return notifyWindowCompletions
        }
        return true
    }

    /// States that bring up the notch notice.
    private static let floatingStates: Set<SessionState> = [.waitingApproval, .waitingInput, .responseEnded]

    private func allowsNotice(appID: String, state: SessionState, evidence: EvidenceKind, source: String) -> Bool {
        if state == .responseEnded && isInferredGeminiWindow(appID: appID, evidence: evidence, source: source) {
            return notifyWindowCompletions
        }
        if state == .responseEnded && source == claudeCodeInferredStopSource {
            return notifyClaudeCodeEnds
        }
        return evidence == .explicit || notifyInferred
    }

    private func isInferredGeminiWindow(appID: String, evidence: EvidenceKind, source: String) -> Bool {
        appID == "gemini" && evidence == .inferred && source.hasPrefix("ax:gemini:")
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
                diagnostics["notifications"] = notificationsEnabled ? "authorized" : "not_authorized"
                statusMessage = notificationsEnabled ? "系统通知已开启" : "通知未授权；仍可查看菜单栏和面板提醒"
            } catch {
                diagnostics["notifications"] = "authorization_request_failed_code_\((error as NSError).code)"
                statusMessage = "系统通知暂不可用；面板提醒仍可使用"
            }
        }
    }

    /// Turns on experimental window observation and asks the system for the permission it needs.
    func enableWindowObservation() {
        windowObservation = true
        if !AXIsProcessTrusted() { grantAccessibility() }
    }

    func refreshHookStatus() {
        guard !isPreview else { return }
        Task {
            for target in HookTarget.allCases where !hookBusy.contains(target) {
                let status = await HookInstaller.status(of: target)
                if hookStatus[target] != status { hookStatus[target] = status }
            }
        }
    }

    /// Installs or removes one agent's event bridge after the user confirmed it in the interface.
    func setHook(_ target: HookTarget, installed: Bool) {
        guard !isPreview, !hookBusy.contains(target) else { return }
        hookBusy.insert(target)
        Task {
            let succeeded = await HookInstaller.apply(target, uninstall: !installed)
            hookStatus[target] = await HookInstaller.status(of: target)
            hookBusy.remove(target)
            statusMessage = !succeeded ? target.label + " 接入未完成；可在终端运行 adapters/manage_hooks.py 查看原因"
                : installed ? target.label + " 已接入。" + target.followUp : target.label + " 已移除接入"
        }
    }

    func openApp(_ appID: String) {
        guard let definition = liveApps.first(where: { $0.contains(appID) }),
              let url = definition.bundleIDs.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func openRunningApp(bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated }),
              let url = app.bundleURL else { return }
        // Bring the agent's windows forward right away; opening through Launch Services
        // also unhides the app when the direct activation is not honored.
        app.unhide()
        app.activate(options: [.activateAllWindows])
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func setDemo(_ state: SessionState) {
        demo = true
        if state == .running { demoTurn = UUID().uuidString }
        let event = MonitorEvent(id: UUID().uuidString, appID: "demo", sessionID: "demo-session", turnID: demoTurn,
            state: state, evidence: .explicit, observedAt: Date(), source: "demo_only")
        ingest([event])
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
        floatingAlerts = floatingAlerts.filter { $0.appID != "demo" }
        recentNotices.removeAll { $0.hasPrefix("演示会话") }
        _ = persistSnapshot()
    }

    private func deliver(_ notice: MonitorNotice, bundleID: String?) {
        let iconFile = notice.state.isWaiting ? notificationIcon(appID: notice.appID, bundleID: bundleID) : nil
        let message = appName(notice.appID) + " · " + notice.state.label + (notice.evidence == .inferred ? "（推断）" : "")
        recentNotices.insert(message, at: 0)
        recentNotices = Array(recentNotices.prefix(20))
        // The chime replaces the system notification sound for completions so it plays once.
        let chimes = notice.state == .responseEnded && completionChime
        if chimes && Date().timeIntervalSince(lastChime) > 1 {
            lastChime = Date()
            NSSound(named: "Glass")?.play()
        }
        Task { [weak self] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            self.notificationsEnabled = settings.authorizationStatus == .authorized
            self.diagnostics["notifications"] = Self.notificationStatus(settings.authorizationStatus)
            guard self.notificationsEnabled else {
                self.diagnostics["notification_last_request"] = "not_requested_without_authorization"
                _ = self.persistSnapshot()
                return
            }
            let content = UNMutableNotificationContent()
            // The agent leads the title so a glance tells which one needs attention.
            content.title = appName(notice.appID)
            content.subtitle = notice.state.label + (notice.evidence == .inferred ? "（推断）" : "")
            content.body = switch notice.state {
            case .waitingApproval: "点按切换到该应用进行授权"
            case .waitingInput: "点按切换到该应用回答问题"
            default: "点按切换到该应用"
            }
            content.sound = chimes ? nil : .default
            content.threadIdentifier = notice.appID
            content.userInfo = ["appID": notice.appID, "bundleID": bundleID ?? ""]
            if let iconFile, let attachment = try? UNNotificationAttachment(identifier: "agent-icon", url: iconFile) {
                content.attachments = [attachment]
            }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await center.add(request)
                self.diagnostics["notification_last_request"] = "accepted_by_system"
            } catch {
                self.diagnostics["notification_last_request"] = "failed_code_\((error as NSError).code)"
            }
            _ = self.persistSnapshot()
        }
    }

    private static func notificationStatus(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "not_determined"
        default: return "limited_or_unknown"
        }
    }

    /// Writes the agent's icon to a temporary PNG; the notification store takes ownership of the file.
    private func notificationIcon(appID: String, bundleID: String?) -> URL? {
        guard let icon = AppIconCache.icon(appID: appID, bundleID: bundleID),
              let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-watch-\(UUID().uuidString).png")
        return (try? png.write(to: url, options: .atomic)) != nil ? url : nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let bundleID = info["bundleID"] as? String, !bundleID.isEmpty {
            await openRunningApp(bundleID: bundleID)
        } else if let appID = info["appID"] as? String {
            await openApp(appID)
        }
    }

    private struct Export: Encodable {
        let version: String
        let collectedAt: Date
        let demoIncluded: Bool
        let statusBar: String
        let unreadCompletions: Int
        let accessibilityTrusted: Bool
        let notificationsEnabled: Bool
        let paused: Bool
        let windowObservation: Bool
        let notifyWindowCompletions: Bool
        let sessions: [SessionSnapshot]
        let diagnostics: [String: String]
    }

    private func snapshotData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Export(version: "0.4.0-preview", collectedAt: Date(), demoIncluded: demo,
                                         statusBar: barText, unreadCompletions: completionCount,
                                         accessibilityTrusted: AXIsProcessTrusted(), notificationsEnabled: notificationsEnabled,
                                         paused: paused, windowObservation: windowObservation,
                                         notifyWindowCompletions: notifyWindowCompletions,
                                         sessions: sessions, diagnostics: diagnostics))
    }

    private func persistSnapshot() -> Bool {
        let path = supportDirectory.appendingPathComponent("status.json")
        let engine = supportDirectory.appendingPathComponent("engine.json")
        let completionPath = supportDirectory.appendingPathComponent("completions.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try completionCache.write(encoder.encode(completions), to: completionPath)
            var persistent = store
            persistent.remove(appID: "demo")
            try engineCache.write(encoder.encode(persistent.persistentCopy()), to: engine)
            try snapshotData().write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return true
        } catch { statusMessage = "本地状态保存失败；待处理事件已保留"; return false }
    }

}
