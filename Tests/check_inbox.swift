import Foundation
import AgentWatchCore

@main
struct InboxChecks {
    static func main() async throws {
        try await badFilesDoNotStarveLaterEvents()
        try await validEventBatchIsBounded()
        print("PASS: inbox scan bounds, cursor fairness, and acknowledgement boundary")
    }

    private static func badFilesDoNotStarveLaterEvents() async throws {
        let directory = try makeTemporaryEventDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        for index in 0..<2_201 {
            let name = String(format: "%04d-invalid.json", index)
            try Data("not-json".utf8).write(to: directory.appendingPathComponent(name))
        }
        let validURL = directory.appendingPathComponent("zz-valid.json")
        try encodedEvent(id: "valid-after-invalid-prefix", sessionID: "fixture-session")
            .write(to: validURL)

        let collector = MonitorCollector(directory: directory)
        var foundBatch: CollectionBatch?
        for _ in 0..<4 {
            let batch = await collector.collect(windowsEnabled: false)
            try expect(batch.scannedEntryCount <= 2_000, "one poll scans no more than 2,000 directory entries")
            try expect(batch.consumedFiles.count <= 200, "one poll accepts no more than 200 event files")
            try expect(batch.consumedFiles.allSatisfy { $0.standardizedFileURL == validURL.standardizedFileURL },
                       "invalid files never enter the acknowledgement list")
            if batch.events.contains(where: { $0.sessionID == "fixture-session" }) {
                foundBatch = batch
                break
            }
        }

        guard let foundBatch else {
            throw InboxCheckFailure(message: "a valid event after more than one scan batch was never reached")
        }
        try expect(foundBatch.consumedFiles.contains { $0.standardizedFileURL == validURL.standardizedFileURL }, "the valid event is acknowledged after validation")
        await collector.acknowledge(foundBatch.consumedFiles)
        try expect(!FileManager.default.fileExists(atPath: validURL.path), "acknowledged valid event is removed")
        try expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("0000-invalid.json").path),
                   "invalid file content remains untouched")
    }

    private static func validEventBatchIsBounded() async throws {
        let directory = try makeTemporaryEventDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        for index in 0..<205 {
            let event = try encodedEvent(id: "valid-\(index)", sessionID: "session-\(index)")
            try event.write(to: directory.appendingPathComponent(String(format: "%04d.json", index)))
        }

        let collector = MonitorCollector(directory: directory)
        let firstBatch = await collector.collect(windowsEnabled: false)
        try expect(firstBatch.scannedEntryCount <= 2_000, "large directory scan stays bounded")
        try expect(firstBatch.consumedFiles.count == 200, "first poll stops after 200 valid event files")

        let secondBatch = await collector.collect(windowsEnabled: false)
        try expect(secondBatch.scannedEntryCount <= 2_000, "cursor continuation stays bounded")
        try expect(secondBatch.consumedFiles.count == 5, "next poll resumes at the remaining valid events")
    }

    private static func makeTemporaryEventDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentWatchInbox-\(UUID().uuidString)")
        let events = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        return events
    }

    private static func encodedEvent(id: String, sessionID: String) throws -> Data {
        let event = MonitorEvent(
            id: id,
            appID: "codex",
            sessionID: sessionID,
            turnID: "turn-1",
            state: .waitingApproval,
            evidence: .explicit,
            observedAt: Date(),
            source: "inbox_fixture"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(event)
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw InboxCheckFailure(message: message) }
    }
}

private struct InboxCheckFailure: Error {
    let message: String
}
