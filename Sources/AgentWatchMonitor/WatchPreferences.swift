import Foundation

@MainActor
enum WatchPreferences {
    /// Offscreen preview rendering captures a single frame, so views skip entrance animations.
    static let rendersPreviews = CommandLine.arguments.contains("--render-previews")

    static let store: UserDefaults = {
        guard rendersPreviews else { return .standard }
        // A fresh suite with a volatile value keeps preview output independent
        // of the installed app's appearance without changing its preferences.
        let defaults = UserDefaults(suiteName: "local.agentwatch.preview." + UUID().uuidString)!
        defaults.setVolatileDomain(["appearance": "system"], forName: UserDefaults.argumentDomain)
        return defaults
    }()
}
