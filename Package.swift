// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentWatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agent-watch-probe", targets: ["AgentWatchProbe"]),
        .executable(name: "AgentWatch", targets: ["AgentWatchMonitor"]),
        .library(name: "AgentWatchCore", targets: ["AgentWatchCore"])
    ],
    targets: [
        .executableTarget(name: "AgentWatchProbe"),
        .target(name: "AgentWatchCore"),
        .executableTarget(name: "AgentWatchMonitor", dependencies: ["AgentWatchCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["AgentWatchCore"], path: "Tests", exclude: ["ProbeChecks.swift", "WindowRuleChecks.swift", "StatusSummaryChecks.swift", "check_hooks.py", "check_cli.py", "check_inbox.swift", "check_devin.py", "check_devin_local.py", "check_antigravity.py", "check_codex_rollouts.py", "check_claude_desktop.py", "check_claude_code_records.py", "ChromiumAccessibilityChecks.swift", "GeminiAdapterChecks.swift", "WindowIdentityChecks.swift", "ClaudeChatAdapterChecks.swift", "fixtures"], sources: ["CoreChecks.swift"])
    ]
)
