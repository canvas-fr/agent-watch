import Foundation
import AgentWatchCore

@main
struct InboxChecks {
    static func main() async throws {
        try await badFilesDoNotStarveLaterEvents()
        try await validEventBatchIsBounded()
        try stopIntentDoesNotLockTheTurn()
        try coworkCancellationRequiresTheObservedAuditTurn()
        print("PASS: inbox scan bounds, cursor fairness, and acknowledgement boundary")
    }

    private static func coworkCancellationRequiresTheObservedAuditTurn() throws {
        let start = Date(timeIntervalSince1970: 10_000)
        var current = ClaudeActiveAuditTurn(sessionID: "canonical-session", turnID: "old-turn", observedAt: start.addingTimeInterval(-1))
        let bridge = ClaudeCancellationBridge(resolve: { _ in current })
        func scan(_ state: SessionState, kind: ClaudeChatRouteKind = .cowork) -> ClaudeChatAdapterScan {
            ClaudeChatAdapterScan(observations: [ClaudeChatWindowObservation(
                windowFingerprint: "window", routeSessionID: "local_00000000-0000-4000-8000-000000000001",
                routeKind: kind, sessionFingerprint: "route-hash", scope: .cowork,
                state: state)], diagnostics: [:])
        }
        try expect(bridge.apply(scan(.cancelled), now: start).isEmpty, "cold interruption has no active audit identity")
        _ = bridge.apply(scan(.running), now: start)
        try expect(bridge.apply(scan(.cancelled), now: start.addingTimeInterval(1)).isEmpty,
                   "an old audit cursor cannot identify a newly observed native run")
        _ = bridge.apply(scan(.running), now: start.addingTimeInterval(2))
        current = ClaudeActiveAuditTurn(sessionID: "canonical-session", turnID: "actual-turn", observedAt: start.addingTimeInterval(3))
        _ = bridge.apply(scan(.running), now: start.addingTimeInterval(3))
        let cancelled = bridge.apply(scan(.cancelled), now: start.addingTimeInterval(4))
        try expect(cancelled.count == 1 && cancelled.first?.turnID == "actual-turn"
                   && cancelled.first?.state == .cancelled, "a continuous Cowork interruption closes only its observed audit turn")
        try expect(bridge.apply(scan(.cancelled), now: start.addingTimeInterval(5)).isEmpty,
                   "one native interruption emits only once")
        _ = bridge.apply(scan(.running), now: start.addingTimeInterval(6))
        current = ClaudeActiveAuditTurn(sessionID: "canonical-session", turnID: "another-turn", observedAt: start.addingTimeInterval(7))
        try expect(bridge.apply(scan(.cancelled), now: start.addingTimeInterval(7)).isEmpty,
                   "a changed audit turn cannot inherit an earlier window witness")
        _ = bridge.apply(scan(.running, kind: .code), now: start.addingTimeInterval(8))
        try expect(bridge.apply(scan(.cancelled, kind: .code), now: start.addingTimeInterval(9)).isEmpty,
                   "Cowork interruption rules never classify Claude Code cancellation")
    }

    private static func stopIntentDoesNotLockTheTurn() throws {
        var store = SessionStore()
        let now = Date()
        let make = { (identifier: String, state: SessionState, source: String, seconds: Double) in
            MonitorEvent(id: identifier, appID: "codex", sessionID: "thread", turnID: "turn",
                         state: state, evidence: .explicit, observedAt: now.addingTimeInterval(seconds),
                         source: source)
        }
        _ = store.apply(make("start", .running, "codex:PreToolUse", 0), now: now)
        let stop = normalizeLifecycleEvidence(make("intent", .responseEnded, "codex:Stop", 1))
        try expect(stop.state == .unknown, "Stop is not durable completion")
        try expect(store.apply(stop, now: now.addingTimeInterval(1)) == nil, "stop intent does not notify completion")
        _ = store.apply(make("continue", .running, "codex:PreToolUse", 2), now: now.addingTimeInterval(2))
        try expect(store.sessions.first?.state == .running, "a blocked Stop can continue in the same turn")
        let end = normalizeLifecycleEvidence(make("complete", .responseEnded, "codex_rollout:task_complete", 3))
        try expect(store.apply(end, now: now.addingTimeInterval(3))?.state == .responseEnded,
                   "durable TurnComplete closes and notifies the actual turn")
        let claudeStop = MonitorEvent(id: "claude-stop-intent", appID: "claude_code",
            sessionID: "claude-session", turnID: "claude-turn", state: .responseEnded,
            evidence: .explicit, observedAt: now, source: "claude_code:Stop")
        let inferredClaudeEnd = normalizeLifecycleEvidence(claudeStop)
        try expect(inferredClaudeEnd.state == .responseEnded && inferredClaudeEnd.evidence == .inferred
                   && inferredClaudeEnd.source == claudeCodeInferredStopSource,
                   "Claude Stop is only an inferred end because a later hook can block it")
        let claudeSubagentStop = MonitorEvent(id: "claude-subagent-stop", appID: "claude_code",
            sessionID: "claude-session", turnID: "claude-turn", state: .responseEnded,
            evidence: .explicit, observedAt: now, source: "claude_code:SubagentStop")
        try expect(normalizeLifecycleEvidence(claudeSubagentStop).state == .unknown,
                   "a subagent Stop does not end the parent turn")
        let legacyPost = MonitorEvent(id: "devin-early-post", appID: "devin", sessionID: "devin-session",
            turnID: "devin-turn", state: .responseEnded, evidence: .explicit, observedAt: now,
            source: "devin:post_cascade_response")
        try expect(normalizeLifecycleEvidence(legacyPost).state == .unknown,
                   "an old installed Devin bridge cannot reintroduce early completion")
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
