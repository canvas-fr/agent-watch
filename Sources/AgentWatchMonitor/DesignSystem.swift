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
}

struct AppBadge: View {
    let appID: String
    var size: CGFloat = 32

    init(appID: String, size: CGFloat = 32) {
        self.appID = appID
        self.size = size
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
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint.opacity(0.13))
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
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
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .contentTransition(.numericText())
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
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
        case .running: return Color(red: 0.25, green: 0.59, blue: 0.43)
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

func watchColorScheme(for appearance: String) -> ColorScheme? {
    switch appearance {
    case "light": return .light
    case "dark": return .dark
    default: return nil
    }
}
