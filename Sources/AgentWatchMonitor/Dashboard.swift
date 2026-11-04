import SwiftUI
import AppKit
import AgentWatchCore

private enum SessionFilter: String, CaseIterable {
    case all = "全部", attention = "待处理", running = "运行中", ended = "已结束", unknown = "未知"
    func includes(_ session: SessionSnapshot) -> Bool {
        switch self {
        case .all: return true
        case .attention: return !session.stale && session.state.needsAttention
        case .running: return !session.stale && session.state == .running
        case .ended: return [.responseEnded, .cancelled].contains(session.state)
        case .unknown: return session.state == .unknown || (session.stale && ![.responseEnded, .failed, .cancelled].contains(session.state))
        }
    }
}

struct MonitorDashboard: View {
    @ObservedObject var monitor: MonitorModel
    private var selected: String {
        get { monitor.dashboardPage }
        nonmutating set { monitor.dashboardPage = newValue }
    }
    @State private var filter = SessionFilter.all
    @State private var query = ""
    @State private var pinned = false
    @AppStorage("appearance", store: WatchPreferences.store) private var appearance = "system"

    private var selectedApp: LiveApp? { liveApps.first { $0.id == selected } }
    private var title: String { selected == "settings" ? "设置" : selected == "integrations" ? "接入状态" : selectedApp?.name ?? "全部会话" }
    private var appSessions: [SessionSnapshot] { monitor.sessions.filter { selectedApp?.contains($0.appID) ?? true } }
    private var filtered: [SessionSnapshot] {
        appSessions.filter {
            filter.includes($0) && (query.isEmpty || appName($0.appID).localizedCaseInsensitiveContains(query) || $0.sessionID.localizedCaseInsensitiveContains(query))
        }.sorted {
            let leftPriority = !$0.stale && $0.state.needsAttention
            let rightPriority = !$1.stale && $1.state.needsAttention
            return leftPriority != rightPriority ? leftPriority : $0.updatedAt > $1.updatedAt
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(WatchTheme.border).frame(width: 1)
            VStack(spacing: 0) {
                pageHeader
                Rectangle().fill(WatchTheme.border).frame(height: 1)
                if selected == "settings" { settingsPage }
                else if selected == "integrations" { integrationsPage }
                else { sessionPage }
                footer
            }.background(WatchTheme.canvas)
        }.tint(WatchTheme.accent).frame(minWidth: 860, minHeight: 600)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 38, height: 38)
                    .background(WatchTheme.accent.gradient, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent Watch").font(.system(size: 16, weight: .semibold))
                    Text("你的智能体，一眼掌握").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 8).padding(.top, 10)
            VStack(spacing: 5) {
                navigationRow("全部会话", symbol: "square.grid.2x2", destination: "all", count: monitor.sessions.count)
                navigationRow("接入状态", symbol: "point.3.connected.trianglepath.dotted", destination: "integrations")
            }
            ScrollView {
              VStack(alignment: .leading, spacing: 6) {
                Text("监控应用").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.horizontal, 12)
                ForEach(liveApps) { app in
                    Button { selected = app.id; filter = .all; query = "" } label: {
                        HStack(spacing: 10) {
                            AppBadge(appID: app.id, size: 26)
                            Text(app.name).font(.system(size: 12, weight: selected == app.id ? .semibold : .regular)).lineLimit(1)
                            Spacer(minLength: 2)
                            if app.id == "gemini" || app.id == "devin" { Text("实验").font(.system(size: 9)).foregroundStyle(.secondary) }
                            Circle().fill(monitor.runningApps.contains(app.id) ? Color.green : Color.secondary.opacity(0.25)).frame(width: 5, height: 5)
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                            .background(selected == app.id ? WatchTheme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(app.capability)
                }
              }
            }.scrollIndicators(.hidden)
            VStack(spacing: 6) {
                navigationRow("设置", symbol: "slider.horizontal.3", destination: "settings")
                HStack(spacing: 6) {
                    Circle().fill(monitor.paused ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(monitor.paused ? "监控已暂停" : "本地监控已启动").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("0.4.0").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 12).padding(.top, 8)
            }
        }.padding(14).frame(width: 224).background(Color(nsColor: .windowBackgroundColor))
    }

    private func navigationRow(_ name: String, symbol: String, destination: String, count: Int? = nil) -> some View {
        Button { selected = destination; filter = .all; query = "" } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 26)
                Text(name).font(.system(size: 12, weight: selected == destination ? .semibold : .regular))
                Spacer()
                if let count { Text("\(count)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 10).padding(.vertical, 10)
                .foregroundStyle(selected == destination ? WatchTheme.accent : Color.primary)
                .background(selected == destination ? WatchTheme.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var pageHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 22, weight: .semibold))
                    if selectedApp?.id == "gemini" || selectedApp?.id == "devin" { Text("实验接入").font(.caption).foregroundStyle(.orange) }
                }
                Text(selected == "settings" ? "通知、外观与实验功能" : selected == "integrations" ? "查看各应用的信号来源和当前限制" : "留在手头的工作，让状态主动找你")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { monitor.paused.toggle() } label: { Label(monitor.paused ? "继续监控" : "暂停", systemImage: monitor.paused ? "play" : "pause") }
                .buttonStyle(.bordered)
            Button { monitor.showFloatingPanel() } label: { Label("悬浮面板", systemImage: "rectangle.inset.filled") }
                .buttonStyle(.borderedProminent)
        }.padding(.horizontal, 26).padding(.vertical, 22)
    }

    private var sessionPage: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                MetricTile(title: "运行中", value: appSessions.filter { !$0.stale && $0.state == .running }.count, symbol: "waveform.path", color: .blue)
                MetricTile(title: "需要处理", value: appSessions.filter { !$0.stale && $0.state.needsAttention }.count, symbol: "bell.badge", color: WatchTheme.accent)
                Button { monitor.markCompletionsRead() } label: {
                    MetricTile(title: "新结束 · 全部标为已读", value: monitor.completionCount, symbol: "checkmark.circle", color: .green)
                }.buttonStyle(.plain).help("清除所有应用的新结束标记")
            }
            if monitor.demo {
                Label("界面演示 · 合成会话数据，不代表真实任务", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(WatchTheme.accent).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                HStack(spacing: 3) {
                    ForEach(SessionFilter.allCases, id: \.self) { item in
                        Button { filter = item } label: {
                            Text(item.rawValue).font(.system(size: 11, weight: filter == item ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .foregroundStyle(filter == item ? Color.primary : .secondary)
                                .background(filter == item ? WatchTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }.padding(3).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("搜索应用或会话 ID", text: $query).textFieldStyle(.plain).font(.system(size: 11)).accessibilityLabel("搜索应用或会话标识")
                }.padding(8).frame(maxWidth: 185).background(WatchTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(WatchTheme.border))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if filtered.isEmpty { emptyState }
                    ForEach(filtered) { session in
                        SessionCard(session: session, since: monitor.stateSince[session.id] ?? session.updatedAt) { monitor.openApp(session.appID) }
                    }
                }.padding(.bottom, 8)
            }
            if let notice = monitor.recentNotices.first {
                HStack(spacing: 8) {
                    Image(systemName: "bell").foregroundStyle(WatchTheme.accent)
                    Text(notice).lineLimit(1); Spacer(); Text("最近提醒").foregroundStyle(.tertiary)
                }.font(.system(size: 11)).padding(12).background(WatchTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: query.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(query.isEmpty ? "这里暂时没有会话" : "没有匹配的会话").font(.system(size: 15, weight: .medium))
            Text(query.isEmpty ? "收到任务事件后，会话会自动出现在这里。\n应用正在运行，并不代表任务正在运行。" : "试试其他应用名称或会话标识。")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            if query.isEmpty { Button("查看接入状态") { selected = "integrations" }.buttonStyle(.bordered) }
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private var integrationsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("进程圆点仅表示应用已打开；收到近期会话事件才表示任务状态可观察。")
                    .font(.callout).foregroundStyle(.secondary).padding(.bottom, 4)
                ForEach(liveApps) { app in
                    HStack(alignment: .top, spacing: 14) {
                        AppBadge(appID: app.id, size: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(app.name).font(.system(size: 13, weight: .semibold))
                                if app.id == "gemini" || app.id == "devin" { Text("实验").font(.caption2).foregroundStyle(.orange) }
                            }
                            Text(app.capability).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(connectionStatus(app)).font(.system(size: 11)).foregroundStyle(.secondary)
                            if let health = monitor.recordsHealth(for: app.id) { Text(health).font(.system(size: 10)).foregroundStyle(.tertiary) }
                        }
                        Spacer()
                        Button("查看会话") { selected = app.id; filter = .all }.buttonStyle(.bordered).controlSize(.small)
                    }.padding(16).background(WatchTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(WatchTheme.border))
                }
                Text("预览版支持范围与客户端版本有关。Gemini 结束判断、Devin 最终结果仍有限制；豆包已移出本版。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }.padding(26)
        }
    }

    private func connectionStatus(_ app: LiveApp) -> String {
        if monitor.sessions.contains(where: { app.contains($0.appID) && $0.evidence == .explicit && !$0.stale }) { return "已收到近期会话事件" }
        guard monitor.runningApps.contains(app.id) else { return "应用未运行" }
        guard monitor.windowObservation else { return "应用已打开 · 等待任务事件（窗口观察已关闭）" }
        let code = monitor.diagnostics[app.id] ?? ""
        if code.contains("permission") || code.contains("not_trusted") { return "窗口观察需要辅助功能权限" }
        if code.contains("unsupported") || code.contains("mismatch") { return "当前版本或界面结构尚未验证" }
        if code.contains("unavailable") || code.contains("error") { return "窗口暂不可读 · 事件接入继续运行" }
        return "应用已打开 · 尚无可确认的任务信号"
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsSection("外观与窗口", symbol: "paintpalette") {
                    settingRow("外观", detail: "跟随系统，或固定使用浅色 / 深色") {
                        Picker("外观", selection: $appearance) {
                            Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                        }.labelsHidden().frame(width: 130)
                    }
                    Divider()
                    settingRow("主窗口置顶", detail: "悬浮面板始终保持在其他窗口上方") {
                        Toggle("主窗口置顶", isOn: $pinned).labelsHidden().toggleStyle(.switch)
                            .onChange(of: pinned) { _, value in NSApp.keyWindow?.level = value ? .floating : .normal }
                    }
                }
                settingsSection("通知与权限", symbol: "bell") {
                    settingRow("系统通知", detail: monitor.notificationsEnabled ? "系统已授权；横幅样式由系统设置管理" : "未授权时仍可查看菜单栏和面板") {
                        Button(monitor.notificationsEnabled ? "已开启" : "开启通知") { monitor.grantNotifications() }.buttonStyle(.bordered)
                    }
                    Divider()
                    settingRow("辅助功能权限", detail: "仅实验窗口观察需要；本地事件接入无需此权限") {
                        Button("检查权限") { monitor.grantAccessibility() }.buttonStyle(.bordered)
                    }
                }
                settingsSection("实验功能", symbol: "flask") {
                    settingRow("窗口观察", detail: "只读取可访问的状态控件；隐藏会话可能不可观察") {
                        Toggle("窗口观察", isOn: $monitor.windowObservation).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    settingRow("Gemini 结束提醒", detail: "界面推断，尚未通过完整实测；需同时开启窗口观察") {
                        Toggle("Gemini 结束提醒", isOn: $monitor.notifyWindowCompletions).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    settingRow("其他推断提醒", detail: "默认关闭；推断信号可能受应用版本影响") {
                        Toggle("其他推断提醒", isOn: $monitor.notifyInferred).labelsHidden().toggleStyle(.switch)
                    }
                }
                settingsSection("诊断与演示", symbol: "wrench.and.screwdriver") {
                    settingRow("导出状态报告", detail: "包含状态与诊断元数据，不包含聊天正文或截图") {
                        Button("导出…") { monitor.exportReport() }.buttonStyle(.bordered)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("测试面板与提醒").font(.system(size: 12, weight: .medium))
                        Text("以下按钮创建带演示标记的本地会话。").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            ForEach([SessionState.running, .waitingApproval, .waitingInput, .responseEnded, .failed], id: \.self) { state in
                                Button(state.label) { monitor.setDemo(state) }.buttonStyle(.bordered).controlSize(.small)
                            }
                            Button("清除") { monitor.clearDemo() }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }.padding(.vertical, 4)
                }
                Text("Agent Watch 0.4.0 Preview · Apache-2.0\n本轮回复结束不代表整个目标已完成。所有监控在本机进行，无遥测和模型调用。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(5)
            }.padding(26)
        }
    }

    private func settingsSection<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
            VStack(spacing: 12, content: content).padding(16).background(WatchTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WatchTheme.border))
        }
    }
    private func settingRow<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control().controlSize(.small)
        }
    }
    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(monitor.paused ? Color.orange : Color.green).frame(width: 5, height: 5)
            Text(monitor.paused ? "已暂停 · 显示最后一次结果" : monitor.statusMessage).lineLimit(1)
            Spacer()
            if let date = monitor.lastScan { Text(date, style: .time).monospacedDigit() }
            Image(systemName: "lock.shield").help("仅本机保存状态元数据")
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 26).padding(.vertical, 11)
            .background(WatchTheme.surface).overlay(alignment: .top) { Rectangle().fill(WatchTheme.border).frame(height: 1) }
    }
}

private struct SessionCard: View {
    let session: SessionSnapshot
    let since: Date
    let openApp: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AppBadge(appID: session.appID, size: 38)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(appName(session.appID)).font(.system(size: 13, weight: .semibold))
                    Text(session.appID == "demo" ? "演示" : "会话 " + String(session.sessionID.prefix(8))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    StatePill(state: session.state, stale: session.stale)
                }
                HStack(spacing: 8) {
                    Label(session.evidence == .inferred ? "推断信号" : "明确事件", systemImage: session.evidence == .inferred ? "sparkle.magnifyingglass" : "checkmark.shield")
                    Text(session.isWindowObservation ? "窗口观察" : "事件会话")
                    if session.state == .responseEnded { Text("仅当前轮次") }
                    if session.parentSessionID != nil { Text("子任务") }
                    if session.stale { Text([.responseEnded, .failed, .cancelled].contains(session.state) ? "历史记录" : "信息已过期") }
                    Spacer()
                    Text(since, style: .relative).monospacedDigit()
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button(action: openApp) { Image(systemName: "arrow.up.forward").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 28) }
                .buttonStyle(.bordered).disabled(session.appID == "demo").help("打开应用；暂不支持定位到具体会话").accessibilityLabel("打开" + appName(session.appID))
        }.padding(15).background(WatchTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(!session.stale && session.state.needsAttention ? WatchTheme.accent.opacity(0.4) : WatchTheme.border))
    }
}
