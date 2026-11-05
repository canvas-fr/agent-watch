import AppKit
import SwiftUI
import AgentWatchCore

enum WatchTheme {
    static let accent = Color(red: 0.91, green: 0.43, blue: 0.25)
    static let canvas = Color(nsColor: NSColor(name: NSColor.Name("AgentWatchCanvas")) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 25 / 255, green: 26 / 255, blue: 28 / 255, alpha: 1)
        }
        return NSColor(srgbRed: 246 / 255, green: 247 / 255, blue: 249 / 255, alpha: 1)
    })
    static let surface = Color(nsColor: .textBackgroundColor)
    static let border = Color(nsColor: .separatorColor).opacity(0.48)
    /// Brand color for primary controls; the agents' own icons supply the color.
    static let ink = Color(nsColor: NSColor(name: NSColor.Name("AgentWatchInk")) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)
        }
        return NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
    })
    static let selection = Color.primary.opacity(0.07)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
}

/// Icons of the monitored applications, read from the local installation.
@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage?] = [:]

    static func icon(appID: String, bundleID: String?) -> NSImage? {
        let bundleIDs = bundleID.map { [$0] } ?? liveApps.first { $0.contains(appID) }?.bundleIDs ?? []
        guard !bundleIDs.isEmpty else { return nil }
        let key = bundleIDs.joined(separator: ",")
        if let cached = icons[key] { return cached }
        let icon = bundleIDs.lazy.compactMap { id -> NSImage? in
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first(where: { !$0.isTerminated }), let icon = running.icon { return icon }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }.first
        icons.updateValue(icon, forKey: key)
        return icon
    }
}

/// The Agent Watch mark: the camera housing with a status strip below it.
struct BrandMark: View {
    var size: CGFloat = 34

    var body: some View {
        let unit = size / 100
        // Same geometry as scripts/make-icon.swift, in a 100-unit tile.
        let tile = RoundedRectangle(cornerRadius: 22.5 * unit, style: .continuous)
        ZStack(alignment: .top) {
            tile.fill(LinearGradient(colors: [Color(red: 0.2, green: 0.21, blue: 0.25), Color(red: 0.07, green: 0.075, blue: 0.09)],
                                     startPoint: .top, endPoint: .bottom))
            UnevenRoundedRectangle(bottomLeadingRadius: 6.3 * unit, bottomTrailingRadius: 6.3 * unit, style: .continuous)
                .fill(Color.black)
                .frame(width: 39 * unit, height: 13.6 * unit)
            Capsule()
                .fill(Color(red: 0.03, green: 0.035, blue: 0.045))
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: max(0.5, 0.5 * unit)) }
                .frame(width: 78 * unit, height: 28 * unit)
                .overlay {
                    HStack(spacing: 6.6 * unit) {
                        ForEach([SessionState.running, .waitingApproval, .responseEnded], id: \.self) { state in
                            Circle().fill(state.uiColor).frame(width: 15 * unit, height: 15 * unit)
                        }
                    }
                }
                .offset(y: 27 * unit)
        }
        .frame(width: size, height: size)
        .clipShape(tile)
        .accessibilityHidden(true)
    }
}

struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(WatchTheme.canvas)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(WatchTheme.ink.opacity(configuration.isPressed ? 0.78 : 1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct AppBadge: View {
    let appID: String
    var size: CGFloat = 32
    var bundleID: String?

    init(appID: String, size: CGFloat = 32, bundleID: String? = nil) {
        self.appID = appID
        self.size = size
        self.bundleID = bundleID
    }

    private var symbol: String {
        switch appID {
        case "antigravity": return "sparkles"
        case "gemini": return "sun.max.fill"
        case "codex": return "terminal.fill"
        case "claude": return "bubble.left.and.bubble.right.fill"
        case "claude_code": return "chevron.left.forwardslash.chevron.right"
        case "dsh": return "brain.head.profile"
        case "devin": return "hammer.fill"
        case "workbuddy": return "person.2.fill"
        case "demo": return "flask.fill"
        default: return "app.fill"
        }
    }

    private var tint: Color {
        switch appID {
        case "antigravity": return Color(red: 0.39, green: 0.47, blue: 0.85)
        case "gemini": return Color(red: 0.34, green: 0.52, blue: 0.89)
        case "codex": return Color(red: 0.24, green: 0.57, blue: 0.43)
        case "claude", "claude_code": return Color(red: 0.77, green: 0.48, blue: 0.29)
        case "dsh": return Color(red: 0.48, green: 0.44, blue: 0.75)
        case "devin": return Color(red: 0.28, green: 0.58, blue: 0.54)
        case "workbuddy": return Color(red: 0.28, green: 0.53, blue: 0.83)
        case "demo": return WatchTheme.accent
        default: return Color.secondary
        }
    }

    var body: some View {
        Group {
            if let icon = AppIconCache.icon(appID: appID, bundleID: bundleID) {
                Image(nsImage: icon)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                // Symbol fallback when the application is not installed.
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .fill(tint.opacity(0.13))
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .padding(size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(appName(appID))
    }
}

struct StatePill: View {
    let state: SessionState
    var stale = false

    init(state: SessionState, stale: Bool = false) {
        self.state = state
        self.stale = stale
    }

    private var isHistoricalTerminal: Bool {
        stale && [.responseEnded, .failed, .cancelled].contains(state)
    }
    private var title: String { stale && !isHistoricalTerminal ? "当前未知" : state.label }
    private var color: Color { stale && !isHistoricalTerminal ? .secondary : state.uiColor }
    private var symbol: String { stale && !isHistoricalTerminal ? "questionmark.circle.fill" : state.uiSymbol }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.11), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

struct MetricTile: View {
    let title: String
    let value: Int
    let symbol: String
    let color: Color

    init(title: String, value: Int, symbol: String, color: Color) {
        self.title = title
        self.value = value
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text("\(value)")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WatchTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(WatchTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

extension SessionState {
    var uiColor: Color {
        switch self {
        case .unknown: return .secondary
        case .running: return Color(red: 0.24, green: 0.52, blue: 0.91)
        case .waitingApproval, .waitingInput: return WatchTheme.accent
        case .responseEnded: return Color(red: 0.25, green: 0.59, blue: 0.43)
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    var uiSymbol: String {
        switch self {
        case .unknown: return "questionmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .waitingApproval: return "hand.raised.fill"
        case .waitingInput: return "text.bubble.fill"
        case .responseEnded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "slash.circle.fill"
        }
    }
}

/// A dot that emits a soft ring while its state is live.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 7
    var pulsing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                if pulsing && !reduceMotion && !WatchPreferences.rendersPreviews {
                    Circle()
                        .fill(color.opacity(0.45))
                        .scaleEffect(expanded ? 2.6 : 1)
                        .opacity(expanded ? 0 : 1)
                        .onAppear {
                            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { expanded = true }
                        }
                }
            }
            .accessibilityHidden(true)
    }
}

func turnDurationText(_ interval: TimeInterval) -> String {
    let seconds = max(1, Int(interval.rounded()))
    if seconds < 60 { return "\(seconds) 秒" }
    if seconds < 3600 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
    return "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分"
}

func watchColorScheme(for appearance: String) -> ColorScheme? {
    switch appearance {
    case "light": return .light
    case "dark": return .dark
    default: return nil
    }
}
