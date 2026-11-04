import SwiftUI
import AppKit
import AgentWatchCore

@main
struct AgentWatchMonitorApp: App {
    @StateObject private var monitor = MonitorModel()
    var body: some Scene {
        WindowGroup("Agent Watch", id: "dashboard") {
            MonitorDashboard(monitor: monitor)
        }.defaultSize(width: 920, height: 680)
        MenuBarExtra {
            MenuPanel(monitor: monitor)
        } label: {
            Label(monitor.barText, systemImage: monitor.attentionCount > 0 ? "bell.badge.fill" : monitor.completionCount > 0 ? "checkmark.circle.fill" : "binoculars")
                .help("Agent Watch · " + monitor.barText)
        }.menuBarExtraStyle(.window)
    }
}

struct MenuPanel: View {
    @ObservedObject var monitor: MonitorModel
    @Environment(\.openWindow) private var openWindow
    private var recentSessions: [SessionSnapshot] {
        Array(monitor.sessions.filter { !$0.stale && $0.state != .unknown }.sorted {
            if $0.state.needsAttention != $1.state.needsAttention { return $0.state.needsAttention }
            return $0.updatedAt > $1.updatedAt
        }.prefix(8))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Watch").font(.headline)
            Text("\(monitor.activeCount) 个运行中 · \(monitor.attentionCount) 个需要处理")
            if monitor.completionCount > 0 {
                Text("\(monitor.completionCount) 个新结束轮次")
                Button("已看过结束提醒") { monitor.markCompletionsRead() }
            }
            ForEach(recentSessions) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appName(session.appID) + " · " + session.state.label).font(.caption)
                        Text(monitor.stateSince[session.id] ?? session.updatedAt, style: .relative)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开应用") { monitor.openApp(session.appID) }.disabled(session.appID == "demo")
                }
            }
            Button("打开监控面板") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }
            Button("显示悬浮小面板") { monitor.showFloatingPanel() }
            Button(monitor.paused ? "继续监控" : "暂停监控") { monitor.paused.toggle() }
            Divider()
            Button("退出 Agent Watch") { NSApp.terminate(nil) }
        }.padding().frame(width: 310)
    }
}

struct MonitorDashboard: View {
    @ObservedObject var monitor: MonitorModel
    @State private var selected = "all"
    @State private var pinned = false
    @State private var showDemo = false
    var filtered: [SessionSnapshot] {
        monitor.sessions.filter { selected == "all" || liveApps.first(where: { $0.id == selected })?.contains($0.appID) == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Agent Watch", systemImage: "binoculars.fill").font(.title.bold())
                Spacer()
                if monitor.demo { Text("含演示数据").foregroundStyle(.orange).bold() }
                Button(monitor.paused ? "继续" : "暂停") { monitor.paused.toggle() }
                Button("悬浮小面板") { monitor.showFloatingPanel() }
                Toggle("置顶", isOn: $pinned).toggleStyle(.switch).frame(width: 85)
                    .onChange(of: pinned) { _, value in NSApp.keyWindow?.level = value ? .floating : .normal }
            }
            HStack(spacing: 24) {
                Text("运行中 \(monitor.activeCount)").foregroundStyle(.blue)
                Text("需要处理 \(monitor.attentionCount)").foregroundStyle(.orange)
                if monitor.completionCount > 0 {
                    Button("新结束 \(monitor.completionCount) · 标记已读") { monitor.markCompletionsRead() }
                }
                Text("观察到 \(monitor.sessions.count) 个会话 / 窗口").foregroundStyle(.secondary)
                Spacer()
                if let date = monitor.lastScan { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
            }
            Text(monitor.paused ? "监控已暂停，显示的是最后一次结果" : monitor.statusMessage).font(.callout).foregroundStyle(.secondary)
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("全部应用") { selected = "all" }.buttonStyle(.borderedProminent)
                        ForEach(liveApps) { app in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Button(app.name) { selected = app.id }; Spacer(); Circle().fill(monitor.runningApps.contains(app.id) ? Color.green : Color.gray).frame(width: 7, height: 7) }
                                Text(app.capability).font(.caption2).foregroundStyle(.secondary)
                                if let health = monitor.recordsHealth(for: app.id) {
                                    Text(health).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(monitor.sessions.contains(where: { app.contains($0.appID) && $0.evidence == .explicit && !$0.stale })
                                     ? "已收到近期会话事件" : monitor.runningApps.contains(app.id) ? diagnostic(monitor.diagnostics[app.id]) : "应用未运行").font(.caption).foregroundStyle(.secondary)
                            }.padding(8).background(selected == app.id ? Color.accentColor.opacity(0.10) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }.padding(8)
                }.frame(minWidth: 215, idealWidth: 250, maxWidth: 290)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if filtered.isEmpty {
                            Text("尚无可确认的会话信号").font(.headline).padding(.top, 30)
                            Text("应用打开不代表任务在运行。事件接入尚未到达，或窗口未暴露可识别的状态时，会显示未知。").foregroundStyle(.secondary)
                        }
                        ForEach(filtered) { session in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(appName(session.appID)).font(.headline)
                                    Spacer()
                                    Text(session.state.label).foregroundStyle(session.state.needsAttention ? .orange : session.state == .running ? .blue : .secondary)
                                }
                                Text(session.source.hasPrefix("ax") ? "窗口观察 · 仅当前可访问的窗口" : session.appID == "demo" ? "本地演示 · 不代表真实应用接入" : "事件会话 · " + String(session.sessionID.prefix(12))).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Text(session.evidence == .inferred ? "推断信号" : "明确事件").font(.caption)
                                    if session.stale { Text([SessionState.responseEnded, .failed, .cancelled].contains(session.state) ? "历史记录" : "信息已过期").font(.caption).foregroundStyle(.orange) }
                                    if session.parentSessionID != nil { Text("子任务").font(.caption) }
                                    Spacer()
                                    Text(monitor.stateSince[session.id] ?? session.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                                    Button("打开应用") { monitor.openApp(session.appID) }.disabled(session.appID == "demo")
                                }
                            }.padding(12).background(Color.secondary.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(12)
                }.frame(minWidth: 380)
            }
            if let notice = monitor.recentNotices.first { Text("最近提醒：" + notice).font(.callout).foregroundStyle(.orange) }
            Divider()
            HStack {
                Button("辅助功能权限") { monitor.grantAccessibility() }
                Button(monitor.notificationsEnabled ? "通知已开启" : "开启系统通知") { monitor.grantNotifications() }
                Button("导出状态") { monitor.exportReport() }
                Spacer()
                Toggle("窗口观察", isOn: $monitor.windowObservation)
                Toggle("其他推断提醒", isOn: $monitor.notifyInferred)
                Button("演示") { showDemo.toggle() }
            }.font(.caption)
            Toggle("Gemini 回复结束提醒（界面推断）", isOn: $monitor.notifyWindowCompletions)
                .font(.caption)
                .help("只在连续观察到运行和新回复的完整结束控件后提醒；不可观察时保持未知。")
            if showDemo {
                HStack {
                    Text("仅测试面板和提醒：").font(.caption)
                    ForEach([SessionState.running, .waitingApproval, .waitingInput, .responseEnded, .failed], id: \.self) { state in
                        Button(state.label) { monitor.setDemo(state) }
                    }
                    Button("清除演示") { monitor.clearDemo(); showDemo = false }
                }
            }
        }.padding(20).frame(minWidth: 760, minHeight: 520)
    }

    private func diagnostic(_ code: String?) -> String {
        guard let code else { return "等待采集" }
        if code.contains("permission") || code.contains("not_trusted") { return "需要辅助功能权限" }
        if code.contains("disabled") { return "窗口观察已关闭" }
        if code.contains("unsupported") || code.contains("mismatch") { return "客户端版本或界面结构尚未验证" }
        if code.contains("budget") || code.contains("partial") { return "部分可读，状态未必可判定" }
        if code.contains("unavailable") || code.contains("error") { return "暂时无法读取窗口" }
        return "窗口观察中 · 任务信号待确认"
    }
}
