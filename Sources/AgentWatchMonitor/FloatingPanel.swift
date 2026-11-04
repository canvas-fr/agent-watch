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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 440),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
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
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 12,
                                     y: frame.maxY - panel.frame.height - 12))
    }
}

private struct FloatingPanelContent: View {
    @ObservedObject var monitor: MonitorModel
    let alignToEdge: () -> Void

    private var rows: [SessionSnapshot] {
        Array(monitor.sessions.filter { !$0.stale && $0.state != .unknown }
            .sorted { left, right in
                if left.state.needsAttention != right.state.needsAttention { return left.state.needsAttention }
                return left.updatedAt > right.updatedAt
            }.prefix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(monitor.barText).font(.headline)
                Spacer()
                Button("贴边", action: alignToEdge).font(.caption)
            }
            if monitor.paused { Text("已暂停，显示最后一次结果").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if rows.isEmpty { Text("暂无近期可确认的活动").foregroundStyle(.secondary).padding(.vertical) }
                    ForEach(rows) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(appName(session.appID)).fontWeight(.medium)
                                Spacer()
                                Button("打开应用") { monitor.openApp(session.appID) }.disabled(session.appID == "demo")
                            }
                            HStack {
                                Text(session.state.label)
                                    .foregroundStyle(session.state.needsAttention ? .orange : .secondary)
                                if session.evidence == .inferred { Text("推断").foregroundStyle(.secondary) }
                                if session.parentSessionID != nil { Text("子任务").foregroundStyle(.secondary) }
                                Spacer()
                                Text(monitor.stateSince[session.id] ?? session.updatedAt, style: .relative)
                                    .foregroundStyle(.secondary)
                            }.font(.caption)
                        }.padding(8).background(Color.secondary.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack {
                Button(monitor.paused ? "继续监控" : "暂停监控") { monitor.paused.toggle() }
                Spacer()
                if monitor.completionCount > 0 { Button("结束提醒已读") { monitor.markCompletionsRead() } }
            }.font(.caption)
        }.padding(12).frame(minWidth: 285, minHeight: 195)
    }
}
