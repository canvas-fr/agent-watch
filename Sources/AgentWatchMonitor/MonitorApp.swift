import SwiftUI
import AppKit
import AgentWatchCore

@main
struct AgentWatchMonitorApp: App {
    @StateObject private var monitor = MonitorModel(preview: CommandLine.arguments.contains("--render-previews"))
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBar

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
            DashboardScene(monitor: monitor, menuBar: menuBar)
        }.defaultSize(width: 1080, height: 760)
        .commands { WatchCommands(monitor: monitor) }
    }
}

private struct DashboardScene: View {
    @ObservedObject var monitor: MonitorModel
    let menuBar: MenuBarController
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appearance", store: WatchPreferences.store) private var appearance = "system"

    var body: some View {
        MonitorDashboard(monitor: monitor)
            .preferredColorScheme(watchColorScheme(for: appearance))
            .onAppear {
                guard !CommandLine.arguments.contains("--render-previews") else { return }
                menuBar.install(monitor: monitor) { [openWindow] in
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
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
