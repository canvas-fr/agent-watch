import Foundation

@MainActor
enum WatchPreferences {
    static let store: UserDefaults = {
        guard CommandLine.arguments.contains("--render-previews") else { return .standard }
        // A fresh suite with a volatile value keeps preview output independent
        // of the installed app's appearance without changing its preferences.
        let defaults = UserDefaults(suiteName: "local.agentwatch.preview." + UUID().uuidString)!
        defaults.setVolatileDomain(["appearance": "system"], forName: UserDefaults.argumentDomain)
        return defaults
    }()
}
