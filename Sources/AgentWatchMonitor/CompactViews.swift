import AppKit
import SwiftUI
import AgentWatchCore

struct MenuPanel: View {
    @ObservedObject var monitor: MonitorModel
    let openDashboard: () -> Void
    @AppStorage("appearance", store: WatchPreferences.store) private var appearance = "system"

    private var recentSessions: [SessionSnapshot] {
        Array(monitor.sessions.sorted { left, right in
            let leftNeedsAttention = !left.stale && left.state.needsAttention
            let rightNeedsAttention = !right.stale && right.state.needsAttention
            if leftNeedsAttention != rightNeedsAttention { return leftNeedsAttention }
            if left.stale != right.stale { return !left.stale }
            return left.updatedAt > right.updatedAt
        }.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Watch").font(.headline)
                    Text(monitor.paused ? "监控已暂停 · 保留最近结果" : "实时会话概览")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if monitor.paused {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.secondary)
                        .help("监控已暂停")
                }
            }

            HStack(spacing: 8) {
                MetricTile(title: "运行中", value: monitor.activeCount, symbol: "circle.fill", color: SessionState.running.uiColor)
                MetricTile(title: "需处理", value: monitor.attentionCount, symbol: "circle.fill", color: WatchTheme.accent)
                MetricTile(title: "未读结束", value: monitor.completionCount, symbol: "circle.fill",
                           color: SessionState.responseEnded.uiColor)
            }

            HStack {
                Text("近期会话").font(.subheadline.weight(.semibold))
                Spacer()
                if monitor.completionCount > 0 {
                    Button("全部已读") { monitor.markCompletionsRead() }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    if recentSessions.isEmpty {
                        ContentUnavailableView {
                            Label("暂无会话", systemImage: "rectangle.stack")
                        } description: {
                            Text("有新的任务信号时会显示在这里。")
                        }
                        .padding(.vertical, 14)
                    }
                    ForEach(recentSessions) { session in
                        CompactSessionCard(monitor: monitor, session: session)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(minHeight: 100, maxHeight: 310)

            HStack(spacing: 8) {
                Button(action: openDashboard) {
                    Label("打开监控面板", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(InkButtonStyle())

                Button {
                    monitor.paused.toggle()
                } label: {
                    Image(systemName: monitor.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 34, height: 30)
                        .background(WatchTheme.selection, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(monitor.paused ? "继续监控" : "暂停监控")
                .accessibilityLabel(monitor.paused ? "继续监控" : "暂停监控")
            }

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("退出 Agent Watch", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 350)
        .background(WatchTheme.canvas)
        .preferredColorScheme(watchColorScheme(for: appearance))
    }
}

struct CompactSessionCard: View {
    @ObservedObject var monitor: MonitorModel
    let session: SessionSnapshot

    private var observedAt: Date {
        monitor.stateSince[session.id] ?? session.updatedAt
    }

    private var historicalTerminal: Bool {
        session.stale && [.responseEnded, .failed, .cancelled].contains(session.state)
    }

    private var showsStripe: Bool { !session.stale && session.state != .unknown }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                AppBadge(appID: session.appID, size: 28)
                Text(appName(session.appID))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if session.parentSessionID != nil {
                    CompactTag(title: "子任务", color: .secondary)
                }
                Spacer(minLength: 0)
                Button {
                    monitor.openApp(session.appID)
                } label: {
                    Label("打开", systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(session.appID == "demo")
                .help("打开应用；暂不支持定位到具体会话")
            }

            HStack(spacing: 6) {
                StatePill(state: session.state, stale: session.stale)
                if session.stale {
                    CompactTag(title: historicalTerminal ? "历史结果：\(session.state.label)" : "最近记录：\(session.state.label)", color: .secondary)
                } else if session.state == .responseEnded {
                    CompactTag(title: "只表示本轮结束", color: .secondary)
                }
                if session.evidence == .inferred {
                    CompactTag(title: "推断", color: WatchTheme.accent)
                }
            }

            HStack(spacing: 4) {
                Text("ID \(session.sessionID.prefix(8))")
                    .foregroundStyle(.tertiary)
                Text(session.stale ? "最后观察" : session.state == .responseEnded ? "本轮时间" : "状态用时")
                    .foregroundStyle(.secondary)
                Text(observedAt, style: .relative)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.caption2)
        }
        .padding(10)
        .padding(.leading, showsStripe ? 3 : 0)
        .background(WatchTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            if showsStripe {
                Capsule().fill(session.state.uiColor).frame(width: 3).padding(.vertical, 12).padding(.leading, 5)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(!session.stale && session.state.needsAttention ? WatchTheme.accent.opacity(0.4) : WatchTheme.border,
                        lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct CompactTag: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.09), in: Capsule())
            .lineLimit(1)
    }
}
