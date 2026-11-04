import AppKit
import SwiftUI

/// Renders only synthetic development views. No screen capture or user data.
@MainActor
enum PreviewRenderer {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let monitor = MonitorModel(preview: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            try save(MonitorDashboard(monitor: monitor).environment(\.colorScheme, scheme),
                     size: NSSize(width: 1080, height: 760), to: directory.appendingPathComponent("dashboard-\(name).png"))
        }
        try save(MonitorDashboard(monitor: monitor).environment(\.colorScheme, .light),
                 size: NSSize(width: 860, height: 600), to: directory.appendingPathComponent("dashboard-compact.png"))
        try save(MenuPanel(monitor: monitor).environment(\.colorScheme, .light),
                 size: NSSize(width: 350, height: 650), to: directory.appendingPathComponent("menu-panel.png"))
        monitor.dashboardPage = "settings"
        try save(MonitorDashboard(monitor: monitor).environment(\.colorScheme, .light),
                 size: NSSize(width: 1080, height: 760), to: directory.appendingPathComponent("settings.png"))
        monitor.dashboardPage = "integrations"
        try save(MonitorDashboard(monitor: monitor).environment(\.colorScheme, .light),
                 size: NSSize(width: 860, height: 600), to: directory.appendingPathComponent("integrations.png"))
    }

    private static func save<Content: View>(_ content: Content, size: NSSize, to destination: URL) throws {
        let hosting = NSHostingView(rootView: content.environment(\.controlActiveState, .active))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.appearance = NSAppearance(named: .aqua)
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
