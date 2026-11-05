import AppKit
import SwiftUI
import AgentWatchCore

/// Renders only synthetic development views. No screen capture or user data.
@MainActor
enum PreviewRenderer {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let monitor = MonitorModel(preview: true)
        let actions = StripActions(openApp: { _ in }, dismiss: {})
        let apps = HoverAppStatus.current(bundleIDs: monitor.runningBundleIDs, sessions: monitor.sessions)
        let strip = HoverStatusStrip(apps: apps, paused: false, maximumWidth: 1080, actions: actions)
        let alertKeys = Set(monitor.sessions.filter { $0.state == .waitingApproval }.map(FloatingAlertKey.init))
        let notices = HoverAppStatus.current(bundleIDs: monitor.runningBundleIDs, sessions: monitor.sessions, alerts: alertKeys)
        let pending = notices.filter { $0.notice?.state == .waitingApproval }
        let completed = SessionSnapshot(appID: "codex", sessionID: "finished-preview", turnID: "preview-turn",
                                        state: .responseEnded, evidence: .explicit, updatedAt: Date(),
                                        source: "synthetic_preview", parentSessionID: nil, stale: false)
        let finished = HoverAppStatus.current(bundleIDs: ["com.openai.codex"], sessions: [completed],
                                               alerts: [FloatingAlertKey(completed)], durations: [completed.id: 192])
        let approvalStrip = HoverStatusStrip(apps: pending, paused: false, maximumWidth: 1080, actions: actions,
                                             showsNotices: true)
        let completionStrip = HoverStatusStrip(apps: finished, paused: false, maximumWidth: 1080, actions: actions,
                                               showsNotices: true)
        let codexWaiting = SessionSnapshot(appID: "codex", sessionID: "approval-preview", turnID: "preview-turn",
                                           state: .waitingApproval, evidence: .explicit, updatedAt: Date().addingTimeInterval(-9),
                                           source: "synthetic_preview", parentSessionID: nil, stale: false)
        let multiSessions = monitor.sessions + [codexWaiting]
        let multiAlerts = Set(multiSessions.filter { $0.state == .waitingApproval }.map(FloatingAlertKey.init))
        let multiPending = HoverAppStatus.current(bundleIDs: monitor.runningBundleIDs, sessions: multiSessions,
                                                  alerts: multiAlerts).filter { $0.notice != nil }
        let multiStrip = HoverStatusStrip(apps: multiPending, paused: false, maximumWidth: 1080, actions: actions,
                                          showsNotices: true)
        try save(multiStrip, size: multiStrip.size, to: directory.appendingPathComponent("approval-multiple.png"))
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            try save(MonitorDashboard(monitor: monitor).environment(\.colorScheme, scheme),
                     size: NSSize(width: 1080, height: 760), to: directory.appendingPathComponent("dashboard-\(name).png"))
            try save(strip.environment(\.colorScheme, scheme), size: strip.size,
                     to: directory.appendingPathComponent("hover-\(name).png"),
                     appearance: scheme == .dark ? .darkAqua : .aqua)
            try save(approvalStrip.environment(\.colorScheme, scheme), size: approvalStrip.size,
                     to: directory.appendingPathComponent("approval-\(name).png"),
                     appearance: scheme == .dark ? .darkAqua : .aqua)
            try save(completionStrip.environment(\.colorScheme, scheme), size: completionStrip.size,
                     to: directory.appendingPathComponent("completion-\(name).png"),
                     appearance: scheme == .dark ? .darkAqua : .aqua)
        }
        let compactStrip = HoverStatusStrip(apps: apps.filter { ["codex", "claude", "antigravity"].contains($0.appID) },
                                            paused: false, maximumWidth: 330, actions: actions)
        try save(compactStrip, size: compactStrip.size, to: directory.appendingPathComponent("hover-compact.png"))
        let compactApproval = HoverStatusStrip(apps: pending, paused: false, maximumWidth: 246,
                                               actions: actions, showsNotices: true)
        try save(compactApproval, size: compactApproval.size, to: directory.appendingPathComponent("approval-compact.png"))
        try save(MonitorDashboard(monitor: monitor).environment(\.colorScheme, .light),
                 size: NSSize(width: 860, height: 600), to: directory.appendingPathComponent("dashboard-compact.png"))
        try save(MenuPanel(monitor: monitor, openDashboard: {}).environment(\.colorScheme, .light),
                 size: NSSize(width: 350, height: 650), to: directory.appendingPathComponent("menu-panel.png"))
        monitor.dashboardPage = "settings"
        try save(MonitorDashboard(monitor: monitor).environment(\.colorScheme, .light),
                 size: NSSize(width: 1080, height: 760), to: directory.appendingPathComponent("settings.png"))
        monitor.dashboardPage = "integrations"
        try save(MonitorDashboard(monitor: monitor).environment(\.colorScheme, .light),
                 size: NSSize(width: 860, height: 600), to: directory.appendingPathComponent("integrations.png"))
    }

    private static func save<Content: View>(_ content: Content, size: NSSize, to destination: URL,
                                            appearance: NSAppearance.Name = .aqua) throws {
        let hosting = NSHostingView(rootView: content.environment(\.controlActiveState, .active))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.appearance = NSAppearance(named: appearance)
        hosting.layoutSubtreeIfNeeded()
        // Give SwiftUI one rendering pass without showing or activating a window.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: destination, options: .atomic)
        window.close()
    }
}
