import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let lingerDuration: Duration = .seconds(3)

    private struct HoverAnchor: Equatable {
        let rect: NSRect
        let visibleFrame: NSRect
    }

    private var statusItem: NSStatusItem?
    private var monitor: MonitorModel?
    private var observation: AnyCancellable?
    private var openDashboard: (() -> Void)?
    private let details = NSPopover()
    private let floating = FloatingPanelController()
    private var hoverTimer: Timer?
    private var hoverAnchor: HoverAnchor?
    private var hideAfter: ContinuousClock.Instant?
    private var displayedAlerts = Set<FloatingAlertKey>()
    private var statusKey = ""

    func install(monitor: MonitorModel, openDashboard: @escaping () -> Void) {
        self.openDashboard = openDashboard
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        self.monitor = monitor

        let hosting = NSHostingController(rootView: MenuPanel(monitor: monitor) { [weak self] in
            self?.details.performClose(nil)
            self?.openDashboard?()
        })
        hosting.sizingOptions.insert(.preferredContentSize)
        details.contentViewController = hosting
        details.behavior = .transient
        details.delegate = self

        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggleDetails)
            button.setAccessibilityHelp("点按查看会话详情。将指针移到屏幕刘海可查看运行状态。")
        }

        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateHoverTarget(at: NSEvent.mouseLocation)
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer

        // Coalesce synchronous model changes and read the new values after publication.
        observation = monitor.objectWillChange
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
        refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        hoverTimer?.invalidate()
    }

    func popoverDidClose(_ notification: Notification) {
        refreshFloatingPanel()
    }

    private func updateHoverTarget(at point: NSPoint, now: ContinuousClock.Instant = .now) {
        guard !details.isShown else { return }
        if let next = anchor(at: point) {
            extendLinger(from: now)
            if next != hoverAnchor {
                hoverAnchor = next
                refreshFloatingPanel(now: now)
            }
        } else if floating.contains(point) {
            extendLinger(from: now)
        } else if let hideAfter, now >= hideAfter {
            refreshFloatingPanel(now: now)
        }
    }

    private func anchor(at point: NSPoint) -> HoverAnchor? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return nil }
        if let notch = NotchHoverRegion(screen: screen) {
            guard notch.contains(point) else { return nil }
            return HoverAnchor(rect: notch.housing, visibleFrame: screen.visibleFrame)
        }

        // Displays without a camera housing use the status item as the hover target.
        guard statusItem?.isVisible == true, let button = statusItem?.button,
              let window = button.window, window.isVisible else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard NSMouseInRect(point, rect, false) else { return nil }
        return HoverAnchor(rect: rect, visibleFrame: screen.visibleFrame)
    }

    @objc private func toggleDetails() {
        guard let button = statusItem?.button else { return }
        hoverAnchor = nil
        floating.hide()
        if details.isShown {
            details.performClose(nil)
        } else {
            details.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func refresh() {
        guard let monitor else { return }
        let title = monitor.barText
        let symbol: String
        var tint: NSColor?
        // While an agent is blocked, the menu bar shows that agent's own icon.
        let blocked = monitor.paused ? nil : monitor.sessions
            .filter { !$0.stale && $0.state.needsAttention }
            .max { $0.updatedAt < $1.updatedAt }
        let blockedBundle = blocked.flatMap(desktopBundleID(for:))
        if monitor.paused { symbol = "pause.circle" }
        else if monitor.attentionCount > 0 { symbol = "bell.badge.fill"; tint = .systemOrange }
        else if monitor.completionCount > 0 { symbol = "checkmark.circle.fill"; tint = .systemGreen }
        else if monitor.activeCount > 0 { symbol = "waveform.path" }
        else { symbol = "binoculars" }
        let key = [title, symbol, blockedBundle ?? ""].joined(separator: "|")
        if let button = statusItem?.button, key != statusKey {
            statusKey = key
            button.title = title
            if let blocked, let icon = AppIconCache.icon(appID: blocked.appID, bundleID: blockedBundle) {
                button.image = Self.badged(icon, color: .systemOrange)
            } else if let tint, let tinted = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(hierarchicalColor: tint)) {
                // Unread results keep a color cue in the menu bar until handled.
                tinted.isTemplate = false
                button.image = tinted
            } else {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            let agent = blocked.map { " · " + appName($0.appID) + " " + $0.state.label } ?? ""
            button.setAccessibilityLabel("Agent Watch · " + title + agent)
        }
        refreshFloatingPanel()
    }

    /// An application icon with a status dot, sized for the menu bar.
    private static func badged(_ icon: NSImage, color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
            let dot = NSBezierPath(ovalIn: NSRect(x: 11, y: 0, width: 7, height: 7))
            NSColor.black.withAlphaComponent(0.35).setStroke()
            dot.lineWidth = 1
            color.setFill()
            dot.fill()
            dot.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func refreshFloatingPanel(now: ContinuousClock.Instant = .now) {
        guard !details.isShown else {
            floating.hide()
            return
        }
        guard let monitor, hoverAnchor != nil || !monitor.floatingAlerts.isEmpty else {
            dismissPanel()
            return
        }
        let apps = HoverAppStatus.current(bundleIDs: monitor.runningBundleIDs, sessions: monitor.sessions,
                                          alerts: monitor.floatingAlerts, durations: monitor.turnDurations,
                                          since: monitor.stateSince)
        let notices = apps.filter { $0.notice != nil }
        let noticeAnchor = notices.isEmpty ? nil : notificationAnchor()
        // Approval requests and questions block the agent, so they stay until handled or dismissed.
        let persistent = notices.contains { $0.notice?.state.isWaiting == true }
        if let noticeAnchor {
            let keys = Set(notices.compactMap(\.notice).flatMap(\.keys))
            if !keys.isSubset(of: displayedAlerts) {
                extendLinger(from: now)
            }
            displayedAlerts = keys
            if hoverAnchor == nil { hoverAnchor = noticeAnchor }
        } else {
            displayedAlerts.removeAll()
        }
        guard let anchor = noticeAnchor ?? hoverAnchor, let hideAfter, persistent || now < hideAfter else {
            dismissPanel()
            return
        }
        let actions = StripActions(
            openApp: { [weak self, weak monitor] bundleID in
                self?.dismissPanel()
                monitor?.openRunningApp(bundleID: bundleID)
            },
            dismiss: { [weak self] in self?.dismissPanel() }
        )
        floating.show(apps: noticeAnchor == nil ? apps : notices, paused: monitor.paused,
                      below: anchor.rect, in: anchor.visibleFrame, actions: actions, showsNotices: noticeAnchor != nil)
    }

    private func extendLinger(from now: ContinuousClock.Instant) {
        hideAfter = now.advanced(by: Self.lingerDuration)
    }

    private func dismissPanel() {
        let alerts = displayedAlerts
        displayedAlerts.removeAll()
        hoverAnchor = nil
        hideAfter = nil
        floating.hide()
        monitor?.dismissFloatingAlerts(alerts)
    }

    private func notificationAnchor() -> HoverAnchor? {
        for screen in NSScreen.screens {
            if let notch = NotchHoverRegion(screen: screen) {
                return HoverAnchor(rect: notch.housing, visibleFrame: screen.visibleFrame)
            }
        }
        guard let screen = NSScreen.main else { return nil }
        let frame = screen.visibleFrame
        return HoverAnchor(rect: NSRect(x: frame.midX, y: frame.maxY, width: 0, height: 0), visibleFrame: frame)
    }
}
