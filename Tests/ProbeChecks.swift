import Foundation

/// Uses only the toolchain and system frameworks, including on Command Line Tools installs.
@main
struct ProbeChecks {
    static func main() throws {
        let home = URL(fileURLWithPath: "/Users/test-person")
        try expect(PrivatePath.display(home.appendingPathComponent("Applications/Gemini.app"), home: home) == "~/Applications/Gemini.app", "home redaction")
        try expect(PrivatePath.display(URL(fileURLWithPath: "/Users/test-person-other/private/Gemini.app"), home: home) == "<outside-standard-applications>/Gemini.app", "directory-boundary redaction")
        try expect(PrivatePath.display(URL(fileURLWithPath: "/Applications/Claude.app"), home: home) == "/Applications/Claude.app", "standard app path")
        try expect(AppCatalog.applications.count == 8 && Set(AppCatalog.applications.map(\.id)).count == 8, "eight distinct targets")
        try expect(AppCatalog.applications.first { $0.id == "gemini" }!.bundleNames.contains("Gemini.app"), "desktop Gemini target")
        for arguments in [["--app", "typo"], ["--format", "html"], ["--output", "--accessibility"], ["--request-permission"]] {
            var rejected = false
            do { _ = try ProbeOptions.parse(arguments) } catch { rejected = true }
            try expect(rejected, "reject invalid or unsupported options: \(arguments)")
        }
        let options = try ProbeOptions.parse([])
        try expect(!options.accessibility && options.appID == nil, "no implicit Accessibility request")
        let ax = AccessibilityProbeResult(status: "disabled", trusted: false, windowsObserved: nil, elementsVisited: 0,
                                          roleCounts: [:], truncated: false, elapsedMilliseconds: 0, errors: [])
        let record = ApplicationObservation(id: "gemini", name: "Gemini 桌面版", installations: [],
            instances: [RunningInstance(bundleID: "example", appPath: nil, pid: 42, hidden: false, frontmost: true,
                                       accessibility: ax)], sourceCandidates: [], nextVerification: "待验证")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        try expect(encoded["taskStatus"] as? String == "unknown", "a live app is not a running task")
        try expect((encoded["instances"] as? [[String: Any]])?.count == 1, "keep app evidence separate")
        print("PASS: privacy, catalog, option validation, and task-evidence checks")
    }

    private static func expect(_ condition: Bool, _ label: String) throws {
        if !condition { throw ProbeError.usage("CHECK FAILED: \(label)") }
    }
}
