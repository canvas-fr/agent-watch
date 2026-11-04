import SwiftUI
import AppKit
import AgentWatchCore

@main
struct AgentWatchMonitorApp: App {
    @StateObject private var monitor = MonitorModel(preview: CommandLine.arguments.contains("--render-previews"))
    @AppStorage("appearance", store: WatchPreferences.store) private var appearance = "system"

    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"),
           CommandLine.arguments.indices.contains(index + 1) {
            let directory = CommandLine.arguments[index + 1]
            DispatchQueue.main.async {
                do { try PreviewRenderer.render(to: URL(fileURLWithPath: directory)); exit(0) }
                catch { print("Preview rendering failed: \(error)"); exit(1) }
            }
        }
    }

    var body: some Scene {
        WindowGroup("Agent Watch", id: "dashboard") {
            MonitorDashboard(monitor: monitor)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }.defaultSize(width: 1080, height: 760)
        .commands { WatchCommands(monitor: monitor) }
        MenuBarExtra {
            MenuPanel(monitor: monitor)
        } label: {
            Label(monitor.barText, systemImage: monitor.paused ? "pause.circle" : monitor.attentionCount > 0 ? "bell.badge.fill" : monitor.completionCount > 0 ? "checkmark.circle.fill" : monitor.activeCount > 0 ? "waveform.path" : "binoculars")
                .help("Agent Watch · " + monitor.barText)
        }.menuBarExtraStyle(.window)
    }
}

private struct WatchCommands: Commands {
    @ObservedObject var monitor: MonitorModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                monitor.dashboardPage = "settings"
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }.keyboardShortcut(",", modifiers: .command)
        }
    }
}
