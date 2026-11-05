import AppKit
import SwiftUI
import AgentWatchCore

struct NotchHoverRegion {
    let housing: NSRect

    @MainActor
    init?(screen: NSScreen) {
        self.init(screenFrame: screen.frame, safeTop: screen.safeAreaInsets.top,
                  left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
    }

    init?(screenFrame: NSRect, safeTop: CGFloat, left: NSRect?, right: NSRect?) {
        guard safeTop > 0, let left, let right,
              !left.isEmpty, !right.isEmpty, left.maxX < right.minX else { return nil }
        housing = NSRect(x: left.maxX, y: screenFrame.maxY - safeTop,
                         width: right.minX - left.maxX, height: safeTop)
    }

    func contains(_ point: NSPoint) -> Bool {
        // The small band below the housing lets the pointer stay in view.
        let band: CGFloat = 10
        let target = NSRect(x: housing.minX, y: housing.minY - band,
                            width: housing.width, height: housing.height + band)
        return NSMouseInRect(point, target, false)
    }
}

struct HoverAppStatus: Identifiable, Equatable {
    struct Notice: Equatable {
        let state: SessionState
        let title: String
        let keys: Set<FloatingAlertKey>
        var duration: TimeInterval? = nil
        /// Earliest moment one of the waiting sessions entered approval.
        var since: Date? = nil
        /// Session-level name when it is more specific than the app, such as Claude Code.
        var agentName: String? = nil
    }

    let id: String
    let appID: String
    let name: String
    let runningEvidence: EvidenceKind?
    let approval: String?
    let notice: Notice?

    static func current(bundleIDs: Set<String>, sessions: [SessionSnapshot],
                        alerts: Set<FloatingAlertKey> = [], durations: [String: TimeInterval] = [:],
                        since: [String: Date] = [:]) -> [Self] {
        let fresh = sessions.filter { !$0.stale }
        let byBundle = Dictionary(grouping: fresh, by: desktopBundleID(for:))
        var apps = liveApps.flatMap { app in
            app.bundleIDs.filter(bundleIDs.contains).map { bundleID in
                let name = switch bundleID {
                case "com.openai.chat": "ChatGPT"
                case "com.openai.codex": "Codex"
                default: app.name
                }
                let matching = byBundle[bundleID] ?? []
                let running = matching.filter { $0.state == .running }
                let waiting = matching.filter { $0.state == .waitingApproval }
                let evidence = running.first(where: { $0.evidence == .explicit })?.evidence ?? running.first?.evidence
                return Self(id: bundleID, appID: app.id, name: name, runningEvidence: evidence,
                            approval: approvalLabel(waiting),
                            notice: notice(for: matching, catalogID: app.id, alerts: alerts,
                                           durations: durations, since: since))
            }
        }
        if let demo = notice(for: fresh.filter({ $0.appID == "demo" }), catalogID: "demo", alerts: alerts,
                             durations: durations, since: since) {
            apps.append(Self(id: "demo", appID: "demo", name: appName("demo"), runningEvidence: nil,
                             approval: nil, notice: demo))
        }
        return apps
    }

    private static func notice(for sessions: [SessionSnapshot], catalogID: String, alerts: Set<FloatingAlertKey>,
                               durations: [String: TimeInterval], since: [String: Date]) -> Notice? {
        guard !alerts.isEmpty else { return nil }
        let matching = sessions.filter { alerts.contains(FloatingAlertKey($0)) }
        let keys = Set(matching.map(FloatingAlertKey.init))
        let waiting = matching.filter { $0.state == .waitingApproval }
        if let approval = approvalLabel(waiting) {
            return Notice(state: .waitingApproval, title: approval, keys: keys,
                          since: waiting.map { since[$0.id] ?? $0.updatedAt }.min(),
                          agentName: agentName(waiting, catalogID: catalogID))
        }
        let finished = matching.filter { $0.state == .responseEnded }
        guard !finished.isEmpty else { return nil }
        let title = finished.contains { $0.evidence == .explicit } ? "本轮已结束" : "推断已结束"
        return Notice(state: .responseEnded, title: title, keys: keys,
                      duration: finished.compactMap { durations[$0.id] }.max(),
                      agentName: agentName(finished, catalogID: catalogID))
    }

    private static func agentName(_ sessions: [SessionSnapshot], catalogID: String) -> String? {
        let ids = Set(sessions.map(\.appID))
        guard ids.count == 1, let id = ids.first, id != catalogID else { return nil }
        return appName(id)
    }

    private static func approvalLabel(_ sessions: [SessionSnapshot]) -> String? {
        guard !sessions.isEmpty else { return nil }
        return sessions.contains { $0.evidence == .explicit } ? "等待授权" : "推断待授权"
    }
}

struct StripActions {
    let openApp: (String) -> Void
    let dismiss: () -> Void
}

@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?
    private var hiding = false
    private var hideGeneration = 0

    func show(apps: [HoverAppStatus], paused: Bool, below anchor: NSRect, in visibleFrame: NSRect,
              actions: StripActions, showsNotices: Bool = false) {
        guard !apps.isEmpty else {
            hide()
            return
        }

        let bounds = visibleFrame.insetBy(dx: 8, dy: 0)
        let content = HoverStatusStrip(apps: apps, paused: paused, maximumWidth: bounds.width,
                                       actions: actions, showsNotices: showsNotices)
        let size = content.size
        let frame = NSRect(
            x: min(max(anchor.midX - size.width / 2, bounds.minX), bounds.maxX - size.width),
            y: min(anchor.minY, bounds.maxY) - size.height - 6,
            width: size.width, height: size.height
        )
        let panel = panel ?? makePanel(frame: frame)
        if let hosting = panel.contentView as? HoverStatusHostingView {
            let previous = hosting.rootView
            if previous.apps != apps || previous.paused != paused || previous.size != size
                || previous.showsNotices != showsNotices {
                hosting.rootView = content
            }
        } else {
            panel.contentView = HoverStatusHostingView(rootView: content)
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible || hiding {
            hiding = false
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible, !hiding else { return }
        hiding = true
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.finishHiding(generation) }
        })
    }

    private func finishHiding(_ generation: Int) {
        // A show() during the fade cancels the pending order-out.
        guard hiding, generation == hideGeneration, let panel else { return }
        hiding = false
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    func contains(_ point: NSPoint) -> Bool {
        guard let panel, panel.isVisible, !hiding else { return false }
        return NSMouseInRect(point, panel.frame, false)
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.panel = panel
        return panel
    }
}

private final class HoverStatusHostingView: NSHostingView<HoverStatusStrip> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct HoverStatusStrip: View {
    let apps: [HoverAppStatus]
    let paused: Bool
    let maximumWidth: CGFloat
    let actions: StripActions
    var showsNotices = false
    @AppStorage("appearance", store: WatchPreferences.store) private var appearance = "system"
    @State private var hoveredApp: String?

    private let rowHeight: CGFloat = 64
    private let headerHeight: CGFloat = 34
    private let footerHeight: CGFloat = 24

    var size: NSSize {
        let appWidth: CGFloat = showsNotices ? (waitingSince != nil ? 240 : 204) : 172
        let minimumWidth: CGFloat = showsNotices ? 320 : 0
        let extra: CGFloat = showsNotices ? headerHeight + (waitingSince != nil ? footerHeight : 6) : 0
        return NSSize(width: min(maximumWidth, max(minimumWidth, CGFloat(apps.count) * appWidth + 16)),
                      height: rowHeight + extra)
    }

    private var noticeState: SessionState? {
        let states = Set(apps.compactMap { $0.notice?.state })
        return states.count == 1 ? states.first : nil
    }

    /// Approval notices stay until handled, so they show how long the agent has been blocked.
    private var waitingSince: Date? {
        apps.compactMap { $0.notice?.state == .waitingApproval ? $0.notice?.since : nil }.min()
    }

    private func displayName(_ app: HoverAppStatus) -> String {
        (showsNotices ? app.notice?.agentName : nil) ?? app.name
    }

    private var noticeHeading: (String, Color) {
        let single = apps.count == 1 ? apps.first.map(displayName) : nil
        switch noticeState {
        case .waitingApproval:
            return (single.map { $0 + " 需要你授权" } ?? "\(apps.count) 个应用等待授权", WatchTheme.accent)
        case .responseEnded:
            return (single.map { $0 + " 本轮结束" } ?? "\(apps.count) 个应用本轮结束", SessionState.responseEnded.uiColor)
        default: return ("\(apps.count) 个应用有新提醒", WatchTheme.accent)
        }
    }

    /// Changes whenever a new set of alerts is shown, which replays the entrance.
    private var noticeID: String {
        guard showsNotices else { return "" }
        return apps.compactMap(\.notice).flatMap(\.keys)
            .map { [$0.appID, $0.sessionID, $0.turnID, $0.state.rawValue].joined(separator: "|") }
            .sorted().joined(separator: ",")
    }

    var body: some View {
        let compact = size.width < CGFloat(apps.count) * 138 + 16
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let tint = noticeHeading.1
        VStack(spacing: 0) {
            if showsNotices { noticeHeader }
            HStack(spacing: 6) {
                ForEach(apps) { app in
                    appTile(app, compact: compact)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            if showsNotices {
                if waitingSince != nil { waitingFooter } else { Spacer(minLength: 0) }
            }
        }
        .frame(width: size.width, height: size.height)
        .background {
            shape.fill(WatchTheme.canvas)
            if showsNotices {
                shape.fill(LinearGradient(colors: [tint.opacity(0.13), tint.opacity(0)],
                                          startPoint: .top, endPoint: .center))
            }
        }
        .overlay {
            if waitingSince != nil {
                BreathingBorder(shape: shape, color: tint)
            } else {
                shape.strokeBorder(showsNotices ? tint.opacity(0.32) : WatchTheme.border, lineWidth: 1)
            }
        }
        .clipShape(shape)
        .modifier(NoticeEntrance(enabled: showsNotices))
        .id(noticeID)
        .preferredColorScheme(watchColorScheme(for: appearance))
    }

    private var noticeHeader: some View {
        let (heading, color) = noticeHeading
        return HStack(spacing: 8) {
            NoticeMark(state: noticeState, color: color)
            Text(heading)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer()
            Button(action: actions.dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("收起提醒")
            .help("收起提醒")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.top, 4)
        .frame(height: headerHeight)
    }

    private var waitingFooter: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.down.right")
            Text(apps.count == 1 ? "点按切换过去授权" : "点按对应应用切换过去授权")
            Spacer()
            Text("授权后自动收起").foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .frame(height: footerHeight)
    }

    @ViewBuilder
    private func appTile(_ app: HoverAppStatus, compact: Bool) -> some View {
        let (title, color) = status(for: app)
        let notice = showsNotices ? app.notice : nil
        let highlighted = notice == nil && !paused && app.approval != nil
        let label = HStack(spacing: compact ? 7 : 10) {
            ZStack(alignment: .bottomTrailing) {
                appIcon(app, size: compact ? 26 : 34)
                if let notice {
                    Image(systemName: notice.state.uiSymbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(notice.state.uiColor, in: Circle())
                        .overlay { Circle().strokeBorder(WatchTheme.surface, lineWidth: 1.5) }
                        .offset(x: 4, y: 4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(app))
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 5) {
                    if notice == nil {
                        PulsingDot(color: color, size: 6,
                                   pulsing: !paused && (app.runningEvidence == .explicit || app.approval != nil))
                    }
                    Text(title)
                        .font(.system(size: compact ? 11 : 12, weight: notice == nil ? .regular : .medium))
                        .foregroundStyle(notice == nil && !highlighted ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                    if let duration = notice?.duration, !compact {
                        Text("· 用时 " + turnDurationText(duration))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if notice?.state == .waitingApproval, let since = notice?.since {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text("· 已等 " + turnDurationText(context.date.timeIntervalSince(since)))
                                .monospacedDigit()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        if app.appID != "demo" {
            Button {
                actions.openApp(app.id)
            } label: {
                HStack(spacing: 6) {
                    label.frame(maxWidth: .infinity, alignment: .leading)
                    if showsNotices && !compact {
                        if apps.count == 1 && size.width >= 244 {
                            Text(notice?.state == .waitingApproval ? "去授权" : "打开")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11)
                                .frame(height: 24)
                                .background(color, in: Capsule())
                        } else {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, compact ? 6 : 9)
                .padding(.trailing, compact ? 6 : 10)
                .frame(height: 50)
                .background {
                    shape.fill(WatchTheme.surface)
                    if highlighted { shape.fill(WatchTheme.accent.opacity(0.08)) }
                    if hoveredApp == app.id { shape.fill(Color.primary.opacity(0.05)) }
                }
                .overlay { shape.strokeBorder(highlighted ? WatchTheme.accent.opacity(0.3) : Color.primary.opacity(0.05)) }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { hoveredApp = app.id } else if hoveredApp == app.id { hoveredApp = nil }
            }
            .accessibilityLabel(displayName(app) + "，" + title + "，切换到应用")
            .help("切换到 " + app.name)
        } else {
            label
                .padding(.horizontal, 9)
                .frame(height: 50)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WatchTheme.surface, in: shape)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(app.name + "，" + title)
        }
    }

    @ViewBuilder
    private func appIcon(_ app: HoverAppStatus, size: CGFloat) -> some View {
        AppBadge(appID: app.appID, size: size, bundleID: app.appID == "demo" ? nil : app.id)
            .accessibilityHidden(true)
    }

    private func status(for app: HoverAppStatus) -> (String, Color) {
        if paused { return ("已暂停", .secondary) }
        if showsNotices, let notice = app.notice {
            return (notice.title, notice.state.uiColor)
        }
        if let approval = app.approval {
            return (approval, WatchTheme.accent)
        }
        switch app.runningEvidence {
        case .explicit: return ("运行中", SessionState.running.uiColor)
        case .inferred: return ("推断运行", WatchTheme.accent)
        case nil: return ("无运行信号", .secondary.opacity(0.45))
        }
    }
}

/// Drops the notice card in from the camera housing.
private struct NoticeEntrance: ViewModifier {
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = WatchPreferences.rendersPreviews

    func body(content: Content) -> some View {
        let settled = entered || !enabled || reduceMotion
        content
            .scaleEffect(settled ? 1 : 0.9, anchor: .top)
            .offset(y: settled ? 0 : -8)
            .opacity(settled ? 1 : 0)
            .onAppear {
                guard enabled, !entered else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) { entered = true }
            }
    }
}

/// A slow glow on the outline while an agent is blocked on approval.
private struct BreathingBorder: View {
    let shape: RoundedRectangle
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        shape.strokeBorder(color.opacity(bright ? 0.75 : 0.3), lineWidth: bright ? 1.5 : 1)
            .onAppear {
                guard !reduceMotion && !WatchPreferences.rendersPreviews else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

/// Completion draws a ring and pops a checkmark; approval waves the hand.
private struct NoticeMark: View {
    let state: SessionState?
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var played = WatchPreferences.rendersPreviews

    var body: some View {
        Group {
            if state == .responseEnded {
                ZStack {
                    Circle().fill(color.opacity(0.14))
                    Circle()
                        .trim(from: 0, to: played ? 1 : 0)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.15), value: played)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(color)
                        .scaleEffect(played ? 1 : 0.2)
                        .opacity(played ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.5).delay(0.5), value: played)
                }
            } else {
                Image(systemName: state == .waitingApproval ? "hand.raised.fill" : "bell.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .symbolEffect(.bounce, options: .repeat(2), value: played)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
        .onAppear { played = true }
    }
}
