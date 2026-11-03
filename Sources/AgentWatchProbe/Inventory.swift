import AppKit
import ApplicationServices
import Foundation

struct InstalledApplication: Codable, Sendable {
    let path: String
    let bundleID: String?
    let version: String?
}

struct CandidateMetadata: Codable, Sendable {
    let path: String
    let purpose: String
    let status: String
    let isDirectory: Bool?
    let modifiedAt: String?
}

struct RunningInstance: Codable, Sendable {
    let bundleID: String?
    let appPath: String?
    let pid: Int32
    let hidden: Bool
    let frontmost: Bool
    let accessibility: AccessibilityProbeResult
}

struct ApplicationObservation: Encodable, Sendable {
    let id: String
    let name: String
    let installations: [InstalledApplication]
    let instances: [RunningInstance]
    let sourceCandidates: [CandidateMetadata]
    let nextVerification: String

    // This inventory contains no session lifecycle evidence.
    var taskStatus: String { "unknown" }

    enum CodingKeys: String, CodingKey {
        case id, name, installations, instances, sourceCandidates, nextVerification, taskStatus
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(installations, forKey: .installations)
        try values.encode(instances, forKey: .instances)
        try values.encode(sourceCandidates, forKey: .sourceCandidates)
        try values.encode(nextVerification, forKey: .nextVerification)
        try values.encode(taskStatus, forKey: .taskStatus)
    }
}

enum ProbeDate {
    static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

struct InventoryProbe: Sendable {
    let home: URL
    let accessibility: Bool

    func collect(_ targets: [TargetApplication]) -> [ApplicationObservation] {
        let roundDeadline = ProcessInfo.processInfo.systemUptime + 6
        let running = NSWorkspace.shared.runningApplications
        return targets.map { target in
            let installs = installedApplications(target)
            // Deduplicate by PID, never by a window title or a conversation label.
            var seenPIDs = Set<Int32>()
            let instances = running.filter { app in
                let knownID = app.bundleIdentifier.map(target.knownBundleIDs.contains) ?? false
                let knownPath = app.bundleURL.map { url in
                    installs.contains { $0.path == PrivatePath.display(url, home: home) }
                } ?? false
                return !app.isTerminated && (knownID || knownPath) && seenPIDs.insert(app.processIdentifier).inserted
            }.map { app in
                RunningInstance(bundleID: app.bundleIdentifier,
                                appPath: app.bundleURL.map { PrivatePath.display($0, home: home) },
                                pid: app.processIdentifier, hidden: app.isHidden, frontmost: app.isActive,
                                accessibility: accessibilityResult(pid: app.processIdentifier, deadline: roundDeadline))
            }
            return ApplicationObservation(id: target.id, name: target.name, installations: installs,
                                          instances: instances, sourceCandidates: target.candidates.map(metadata),
                                          nextVerification: target.nextVerification)
        }
    }

    private func accessibilityResult(pid: Int32, deadline: TimeInterval) -> AccessibilityProbeResult {
        guard !accessibility || ProcessInfo.processInfo.systemUptime < deadline else {
            return AccessibilityProbeResult(status: "round_budget_exhausted", trusted: AXIsProcessTrusted(),
                windowsObserved: nil, elementsVisited: 0, roleCounts: [:], truncated: true,
                elapsedMilliseconds: 0, errors: ["round_budget_exhausted"])
        }
        // Each started probe has its own 1.8s soft budget; no new probe starts after 6s.
        return inspectAccessibility(pid: pid, enabled: accessibility)
    }

    private func installedApplications(_ target: TargetApplication) -> [InstalledApplication] {
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var seen = Set<String>()
        return roots.flatMap { root in target.bundleNames.map { root.appendingPathComponent($0) } }.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted, let bundle = Bundle(url: url) else { return nil }
            return InstalledApplication(path: PrivatePath.display(url, home: home), bundleID: bundle.bundleIdentifier,
                                        version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        }
    }

    private func metadata(_ candidate: SourceCandidate) -> CandidateMetadata {
        let url = PrivatePath.expand(candidate.path, home: home)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            // Report existence, type and modification time only; no enumeration or file reads.
            return CandidateMetadata(path: candidate.path, purpose: candidate.purpose, status: "present",
                                     isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory,
                                     modifiedAt: (attributes[.modificationDate] as? Date).map(ProbeDate.text))
        } catch let error as NSError {
            let missing = (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
                || (error.domain == NSPOSIXErrorDomain && error.code == ENOENT)
            return CandidateMetadata(path: candidate.path, purpose: candidate.purpose,
                                     status: missing ? "absent" : "unavailable",
                                     isDirectory: nil, modifiedAt: nil)
        }
    }
}
