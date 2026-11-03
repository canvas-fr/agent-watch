import Foundation
import AgentWatchCore

struct CollectionBatch: Sendable {
    let events: [MonitorEvent]
    let diagnostics: [String: String]
    let consumedFiles: [URL]
    let scannedEntryCount: Int
}

actor WindowCollector {
    private let adapter = WindowAdapter()
    func collect() -> WindowScan { adapter.scan(targets: liveApps.map(\.target)) }
}

actor MonitorCollector {
    private let windows = WindowAdapter()
    let directory: URL
    private var eventEnumerator: FileManager.DirectoryEnumerator?

    private static let maximumEntriesPerScan = 2_000
    private static let maximumValidEventsPerScan = 200
    private static let maximumEventFileBytes = 16_384

    init(directory: URL) { self.directory = directory }

    func collect(windowsEnabled: Bool) -> CollectionBatch {
        let scan = windowsEnabled ? windows.scan(targets: liveApps.map(\.target))
            : WindowScan(events: [], diagnostics: Dictionary(uniqueKeysWithValues: liveApps.map { ($0.id, "window_observation_disabled") }))
        var events = scan.events
        var diagnostics = scan.diagnostics
        var consumed: [URL] = []
        var scannedEntryCount = 0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { input in
            let value = try input.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: input.codingPath, debugDescription: "invalid timestamp"))
        }
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
        ]
        do {
            guard FileManager.default.fileExists(atPath: directory.path) else {
                eventEnumerator = nil
                return CollectionBatch(
                    events: events.sorted { $0.observedAt < $1.observedAt },
                    diagnostics: diagnostics,
                    consumedFiles: consumed,
                    scannedEntryCount: scannedEntryCount
                )
            }
            guard let directoryProperties = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  directoryProperties.isDirectory == true,
                  directoryProperties.isSymbolicLink != true else {
                eventEnumerator = nil
                diagnostics["events"] = "event_directory_unavailable"
                return CollectionBatch(
                    events: events.sorted { $0.observedAt < $1.observedAt },
                    diagnostics: diagnostics,
                    consumedFiles: consumed,
                    scannedEntryCount: scannedEntryCount
                )
            }
            if eventEnumerator == nil {
                eventEnumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: keys,
                    options: [.skipsSubdirectoryDescendants]
                )
            }
            guard let enumerator = eventEnumerator else {
                diagnostics["events"] = "event_directory_unavailable"
                return CollectionBatch(
                    events: events.sorted { $0.observedAt < $1.observedAt },
                    diagnostics: diagnostics,
                    consumedFiles: consumed,
                    scannedEntryCount: scannedEntryCount
                )
            }

            while scannedEntryCount < Self.maximumEntriesPerScan,
                  consumed.count < Self.maximumValidEventsPerScan {
                guard let file = enumerator.nextObject() as? URL else {
                    // Start a fresh pass on the next poll. Keeping the enumerator
                    // between polls makes large directories progress fairly.
                    eventEnumerator = nil
                    break
                }
                scannedEntryCount += 1

                guard file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                      file.pathExtension == "json" else { continue }

                guard let properties = try? file.resourceValues(forKeys: Set(keys)),
                      properties.isRegularFile == true,
                      properties.isDirectory != true,
                      properties.isSymbolicLink != true,
                      (properties.fileSize ?? Int.max) <= Self.maximumEventFileBytes else {
                    diagnostics["events"] = "invalid_event_file"
                    continue
                }
                guard let data = try? Data(contentsOf: file),
                      let event = try? decoder.decode(MonitorEvent.self, from: data),
                      valid(event) else {
                    diagnostics["events"] = "invalid_event_file"
                    continue
                }

                // Offline observations still carry useful terminal facts. The
                // state engine and notification freshness checks handle age;
                // do not silently discard valid buffered events after an hour.
                events.append(event)
                consumed.append(file)
            }
        }
        return CollectionBatch(
            events: events.sorted { $0.observedAt < $1.observedAt },
            diagnostics: diagnostics,
            consumedFiles: consumed,
            scannedEntryCount: scannedEntryCount
        )
    }

    func acknowledge(_ files: [URL]) {
        for file in files where file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func valid(_ event: MonitorEvent) -> Bool {
        let allowed = Set(liveApps.map(\.id) + ["claude_code", "demo"])
        let identifiers = [event.id, event.sessionID, event.turnID, event.source]
            + (event.parentSessionID.map { [$0] } ?? [])
        return allowed.contains(event.appID) && identifiers.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains(where: \.isNewline)
        }
    }
}
