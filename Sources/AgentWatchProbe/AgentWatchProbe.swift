import AppKit
import Foundation

@main
struct AgentWatchProbe {
    @MainActor
    static func main() {
        do {
            let options = try ProbeOptions.parse(Array(CommandLine.arguments.dropFirst()))
            if options.help { print(ProbeOptions.usage); return }
            let targets = AppCatalog.applications.filter { options.appID == nil || $0.id == options.appID }
            let observations = InventoryProbe(home: FileManager.default.homeDirectoryForCurrentUser,
                                              accessibility: options.accessibility).collect(targets)
            let report = ProbeReport(collectedAt: ProbeDate.text(Date()),
                                     operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                                     accessibilityRequested: options.accessibility, applications: observations)
            let data: Data
            if options.format == "json" {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                data = try encoder.encode(report) + Data([0x0a])
            } else {
                data = Data(report.markdown().utf8)
            }
            if let output = options.output {
                let url = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath)
                // Do not clobber a report, link, or any pre-existing user file.
                try data.write(to: url, options: .withoutOverwriting)
            } else {
                FileHandle.standardOutput.write(data)
            }
        } catch {
            FileHandle.standardError.write(Data("Agent Watch: \(error)\n".utf8))
            exit(1)
        }
    }
}
