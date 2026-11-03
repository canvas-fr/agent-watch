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
        .executableTarget(name: "CoreChecks", dependencies: ["AgentWatchCore"], path: "Tests", exclude: ["ProbeChecks.swift", "WindowRuleChecks.swift", "StatusSummaryChecks.swift", "check_hooks.py", "check_cli.py", "check_inbox.swift", "check_devin.py", "check_antigravity.py"], sources: ["CoreChecks.swift"])
    ]
)
