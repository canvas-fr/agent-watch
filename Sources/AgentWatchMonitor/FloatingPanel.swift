import AppKit
import SwiftUI
import AgentWatchCore

@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?

    func show(monitor: MonitorModel) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 440),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Agent Watch"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 310, height: 240)
        panel.maxSize = NSSize(width: 520, height: 800)
        panel.contentView = NSHostingView(rootView: FloatingPanelContent(
            monitor: monitor,
            alignToEdge: { [weak self] in self?.alignToEdge() }
        ))
        self.panel = panel
        if !panel.setFrameUsingName("Agent Watch floating panel") { alignToEdge() }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { alignToEdge() }
        panel.setFrameAutosaveName("Agent Watch floating panel")
        panel.orderFrontRegardless()
    }

    private func alignToEdge() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - panel.frame.width - 12,
            y: frame.maxY - panel.frame.height - 12
        ))
    }
}

private struct FloatingPanelContent: View {
    @ObservedObject var monitor: MonitorModel
    let alignToEdge: () -> Void
    @AppStorage("appearance", store: WatchPreferences.store) private var appearance = "system"

    private var sessions: [SessionSnapshot] {
        Array(monitor.sessions.sorted { left, right in
            let leftNeedsAttention = !left.stale && left.state.needsAttention
            let rightNeedsAttention = !right.stale && right.state.needsAttention
            if leftNeedsAttention != rightNeedsAttention { return leftNeedsAttention }
            if left.stale != right.stale { return !left.stale }
            return left.updatedAt > right.updatedAt
        }.prefix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "binoculars.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WatchTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(WatchTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Watch").font(.headline)
                    Text(monitor.paused ? "已暂停 · 最近结果" : monitor.barText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: alignToEdge) {
                    Label("贴边", systemImage: "arrow.up.right.and.arrow.down.left")
                }
                .buttonStyle(.borderless)
                .help("贴到屏幕右上角")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if sessions.isEmpty {
                        ContentUnavailableView {
                            Label("暂无会话", systemImage: "rectangle.stack")
                        } description: {
                            Text("有新的任务信号时会显示在这里。")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    ForEach(sessions) { session in
                        CompactSessionCard(monitor: monitor, session: session)
                    }
                }
                .padding(.vertical, 1)
            }

            HStack(spacing: 8) {
                Button {
                    monitor.paused.toggle()
                } label: {
                    Label(monitor.paused ? "继续监控" : "暂停监控",
                          systemImage: monitor.paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if monitor.completionCount > 0 {
                    Button("全部已读") { monitor.markCompletionsRead() }
                        .buttonStyle(.borderedProminent)
                        .tint(WatchTheme.accent)
                }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(minWidth: 286, idealWidth: 326, maxWidth: 496, minHeight: 195)
        .background(WatchTheme.canvas)
        .preferredColorScheme(watchColorScheme(for: appearance))
    }
}
