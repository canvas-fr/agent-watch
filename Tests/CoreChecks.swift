import Foundation
import AgentWatchCore

@main
struct CoreChecks {
    static func main() throws {
        try checksColdResponseEndIsSilent()
        try checksTransitionsAndPerTurnDeduplication()
        try checksNewAndOldTurns()
        try checksOrderingAndFutureRejection()
        try checksSourceDomainOrderingAndPersistence()
        try checksLegacyStopCompletionMigration()
        try checksTerminalRollbackAndDeduplication()
        try checksPersistenceRoundTrip()
        try checksExpiryAndChildren()
        try checksParentMetadataAcrossSources()
        try checksDurableInferredSessionsSurviveRestart()
        try checksWindowHeartbeatsDoNotChangeDurableSnapshot()
        try checksLegacyDevinEndIsReclassified()
        try checksSnapshotCacheDetectsReplacement()
        try checksTerminalEncodingIsStable()
        try checksCapacity()
        print("PASS: Agent Watch core state, ordering, notice, expiry, and capacity checks")
    }

    private static func checksSnapshotCacheDetectsReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-watch-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("engine.json")
        var cache = SnapshotFileCache()
        let expected = Data("expected-state".utf8)
        let first = try cache.write(expected, to: file)
        let initial = try FileManager.default.attributesOfItem(atPath: file.path)
        let repeated = try cache.write(expected, to: file)
        try expect(first && !repeated, "unchanged persisted bytes must not be rewritten")
        try Data("outdated-state".utf8).write(to: file, options: .atomic)
        if let originalDate = initial[.modificationDate] {
            try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        }
        let repaired = try cache.write(expected, to: file)
        let actual = try Data(contentsOf: file)
        try expect(repaired && actual == expected, "an old writer's atomic replacement must invalidate the cache")
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: file.path)
        var rejectedLink = false
        do { try cache.write(Data("wrong-state".utf8), to: link) } catch { rejectedLink = true }
        try expect(rejectedLink, "a symlink is not an owned snapshot file")
        let unchanged = try Data(contentsOf: file)
        try expect(unchanged == expected, "a rejected cache target cannot modify another file")
    }

    private static func checksTerminalEncodingIsStable() throws {
        let start = Date(timeIntervalSince1970: 96_000)
        var store = SessionStore()
        for (offset, state) in [SessionState.running, .responseEnded, .failed].enumerated() {
            let time = start.addingTimeInterval(Double(offset))
            _ = store.apply(MonitorEvent(id: "terminal-\(offset)", appID: "codex", sessionID: "stable-session",
                turnID: "stable-turn", state: state, evidence: .explicit, observedAt: time,
                source: "fixture"), now: time)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(store.persistentCopy())
        let restored = try JSONDecoder().decode(SessionStore.self, from: before)
        let after = try encoder.encode(restored.persistentCopy())
        try expect(before == after, "nonempty terminal notice sets have stable persisted order")
        let object = try JSONSerialization.jsonObject(with: before) as? [String: Any]
        let pairs = object?["records"] as? [Any]
        let record = pairs?.dropFirst().first as? [String: Any]
        try expect(record?["eventIDSet"] != nil && record?["closedTurnIDSet"] != nil,
                   "older decoders still receive their required replay-set fields")
    }

    private static func checksDurableInferredSessionsSurviveRestart() throws {
        let start = Date(timeIntervalSince1970: 80_000)
        var store = SessionStore()
        let running = MonitorEvent(id: "durable-running", appID: "claude_code",
            sessionID: "cli-session", turnID: "real-turn", state: .running,
            evidence: .inferred, observedAt: start, source: "claude_code_records:latestUserFrameAt")
        _ = store.apply(running, now: start)
        _ = store.apply(MonitorEvent(id: "window-running", appID: "gemini",
            sessionID: "ephemeral-window", turnID: "observed-turn", state: .running,
            evidence: .inferred, observedAt: start, source: "ax:gemini:stop_button_visible"), now: start)
        let encoder = JSONEncoder()
        var restored = try JSONDecoder().decode(SessionStore.self, from: encoder.encode(store.persistentCopy()))
        restored.removeWindowObservations()
        try expect(restored.sessions.count == 1 && restored.sessions.first?.sessionID == "cli-session",
                   "confidence must not erase a durable inferred session on restart")
        let notice = restored.apply(MonitorEvent(id: "durable-ended", appID: "claude_code",
            sessionID: "cli-session", turnID: "real-turn", state: .responseEnded,
            evidence: .explicit, observedAt: start.addingTimeInterval(1),
            source: "claude_code_records:completedTurns"), now: start.addingTimeInterval(1))
        try expect(notice?.state == .responseEnded, "a resumed tracked turn must still notify its actual end")
        _ = restored.apply(MonitorEvent(id: "linked-cancel", appID: "claude", sessionID: "audit-session",
            turnID: "audit-turn", state: .cancelled, evidence: .inferred,
            observedAt: start, source: "ax:claude:cowork_interrupted", identityScope: .session), now: start)
        restored.removeWindowObservations()
        try expect(restored.sessions.contains { $0.sessionID == "audit-session" },
                   "a linked native event may carry durable session identity")

        // Old files contain no identityScope and include the old dictionary
        // pair encoding. Confidence alone must not decide their identity.
        func legacy(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                object.removeValue(forKey: "identityScope")
                return object.mapValues(legacy)
            }
            if let array = value as? [Any] { return array.map(legacy) }
            return value
        }
        let oldObject = legacy(try JSONSerialization.jsonObject(with: encoder.encode(store)))
        var old = try JSONDecoder().decode(SessionStore.self, from: JSONSerialization.data(withJSONObject: oldObject))
        old.removeWindowObservations()
        try expect(old.sessions.count == 1 && old.sessions.first?.sessionID == "cli-session",
                   "legacy canonical metadata survives while legacy AX windows are discarded")
        _ = old.apply(MonitorEvent(id: "typed-window", appID: "gemini", sessionID: "custom-window",
            turnID: "window-turn", state: .running, evidence: .explicit, observedAt: start,
            source: "custom_window_adapter", identityScope: .window), now: start)
        _ = old.apply(MonitorEvent(id: "typed-heartbeat", appID: "gemini", sessionID: "custom-window",
            turnID: "window-turn", state: .running, evidence: .inferred, observedAt: start.addingTimeInterval(1),
            source: "another_observer"), now: start.addingTimeInterval(1))
        try expect(old.sessions.first(where: { $0.sessionID == "custom-window" })?.isWindowObservation == true,
                   "an observer without identity metadata cannot erase a previously declared window scope")
        _ = old.apply(MonitorEvent(id: "other-source", appID: "claude", sessionID: "other-session",
            turnID: "other-turn", state: .running, evidence: .inferred, observedAt: start,
            source: "axolotl_adapter"), now: start)
        try expect(old.persistentCopy().sessions.contains { $0.sessionID == "other-session" },
                   "an unrelated adapter name beginning with ax is not a window namespace")
    }

    private static func checksWindowHeartbeatsDoNotChangeDurableSnapshot() throws {
        let start = Date(timeIntervalSince1970: 90_000)
        var store = SessionStore()
        _ = store.apply(MonitorEvent(id: "saved-prompt", appID: "claude", sessionID: "saved-session",
            turnID: "saved-turn", state: .waitingInput, evidence: .inferred, observedAt: start,
            source: "claude_desktop_cowork:audit_v1"), now: start)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let baseline = try encoder.encode(store.persistentCopy())
        for index in 0..<150 {
            let timestamp = start.addingTimeInterval(Double(index))
            _ = store.apply(MonitorEvent(id: "heartbeat-\(index)", appID: "gemini",
                sessionID: "window", turnID: "window-turn", state: .unknown, evidence: .inferred,
                observedAt: timestamp, source: "ax:gemini:no_verified_lifecycle_evidence",
                identityScope: .window), now: timestamp)
        }
        let afterHeartbeats = try encoder.encode(store.persistentCopy())
        try expect(afterHeartbeats == baseline,
                   "window-only heartbeat traffic must not rewrite identical durable engine state")
        var restored = try JSONDecoder().decode(SessionStore.self, from: baseline)
        let duplicate = MonitorEvent(id: "saved-prompt", appID: "claude", sessionID: "saved-session",
            turnID: "saved-turn", state: .waitingInput, evidence: .inferred, observedAt: start,
            source: "claude_desktop_cowork:audit_v1")
        try expect(restored.apply(duplicate, now: start) == nil, "persisted replay guards remain effective")
    }

    private static func checksLegacyDevinEndIsReclassified() throws {
        var store = SessionStore()
        let time = Date(timeIntervalSince1970: 95_000)
        _ = store.apply(MonitorEvent(id: "legacy-devin-post", appID: "devin", sessionID: "legacy-session",
            turnID: "legacy-turn", state: .responseEnded, evidence: .explicit, observedAt: time,
            source: "devin:post_cascade_response"), now: time)
        let changed = store.invalidateUnconfirmedCompletions()
        try expect(changed.count == 1 && changed.first?.appID == "devin",
                   "a legacy Devin post is an unconfirmed end, not a durable result")
        try expect(store.sessions.first?.state == .unknown,
                   "persisted early post callbacks cannot continue showing completion")
        try expect(store.invalidateUnconfirmedCompletions().isEmpty, "the migration is idempotent")
    }

    private static func checksColdResponseEndIsSilent() throws {
        var store = SessionStore()
        let now = Date(timeIntervalSince1970: 1_000)
        let notice = store.apply(event("cold-end", state: .responseEnded, at: now), now: now)
        try expect(notice == nil, "cold responseEnded must not notify")
        try expect(store.sessions.first?.state == .responseEnded, "cold responseEnded is retained")
    }

    private static func checksTransitionsAndPerTurnDeduplication() throws {
        var store = SessionStore()
        let start = Date(timeIntervalSince1970: 2_000)
        try expect(store.apply(event("start", state: .running, at: start), now: start) == nil,
                    "running does not notify")
        let approval = event("approval", state: .waitingApproval, at: start.addingTimeInterval(1), sequence: 2)
        try expect(store.apply(approval, now: start.addingTimeInterval(1))?.state == .waitingApproval,
                    "transition into approval notifies")
        try expect(store.apply(approval, now: start.addingTimeInterval(1)) == nil,
                    "replaying the same event is ignored")
        try expect(store.apply(event("approval-duplicate", state: .waitingApproval,
                                     at: start.addingTimeInterval(2), sequence: 3),
                               now: start.addingTimeInterval(2)) == nil,
                    "continuous approval refresh does not notify again")
        try expect(store.apply(event("running-again", state: .running, at: start.addingTimeInterval(3), sequence: 4),
                               now: start.addingTimeInterval(3)) == nil,
                    "running transition does not notify")
        try expect(store.apply(event("approval-again", state: .waitingApproval,
                                     at: start.addingTimeInterval(4), sequence: 5),
                               now: start.addingTimeInterval(4))?.state == .waitingApproval,
                    "a new transition back into approval notifies again")
        try expect(store.apply(event("input", state: .waitingInput, at: start.addingTimeInterval(5), sequence: 6),
                               now: start.addingTimeInterval(5))?.state == .waitingInput,
                    "a distinct transition into input notifies")
        try expect(store.apply(event("running-before-input-refresh", state: .running,
                                     at: start.addingTimeInterval(6), sequence: 7),
                               now: start.addingTimeInterval(6)) == nil,
                    "running does not notify")
        try expect(store.apply(event("input-again", state: .waitingInput,
                                     at: start.addingTimeInterval(7), sequence: 8),
                               now: start.addingTimeInterval(7))?.state == .waitingInput,
                    "re-entering input after running notifies again")
    }

    private static func checksNewAndOldTurns() throws {
        var store = SessionStore()
        let start = Date(timeIntervalSince1970: 3_000)
        _ = store.apply(event("turn-one-running", turnID: "turn-1", state: .running, at: start), now: start)
        let newTurnTime = start.addingTimeInterval(1)
        try expect(store.apply(event("turn-two-approval", turnID: "turn-2", state: .waitingApproval,
                                     at: newTurnTime), now: newTurnTime)?.state == .waitingApproval,
                    "new turn resets per-turn notice deduplication")
        try expect(store.apply(event("late-turn-one", turnID: "turn-1", state: .running,
                                     at: start.addingTimeInterval(2)), now: start.addingTimeInterval(2)) == nil,
                    "a closed turn cannot become current again")
        try expect(store.sessions.first?.turnID == "turn-2", "late old turn cannot replace current turn")
    }

    private static func checksOrderingAndFutureRejection() throws {
        var store = SessionStore()
        let start = Date(timeIntervalSince1970: 4_000)
        _ = store.apply(event("seq-2", state: .running, at: start.addingTimeInterval(2), sequence: 2),
                        now: start.addingTimeInterval(2))
        try expect(store.apply(event("seq-1", state: .waitingInput, at: start.addingTimeInterval(1), sequence: 1),
                               now: start.addingTimeInterval(2)) == nil,
                    "older timestamp and sequence are ignored")
        try expect(store.sessions.first?.state == .running, "out-of-order event cannot roll back state")
        let tooFarAhead = start.addingTimeInterval(100)
        try expect(store.apply(event("future", state: .failed, at: tooFarAhead), now: start) == nil,
                    "events over 30 seconds in the future are rejected")
        try expect(store.sessions.first?.state == .running, "rejected future event does not mutate state")
    }

    private static func checksSourceDomainOrderingAndPersistence() throws {
        var store = SessionStore()
        let start = Date(timeIntervalSince1970: 4_300)
        _ = store.apply(event("hook-running", appID: "codex", state: .running, at: start,
                              sequence: 50, source: "codex:UserPromptSubmit"), now: start)

        let appServerApprovalTime = start.addingTimeInterval(1)
        try expect(store.apply(event("app-server-approval", appID: "codex", state: .waitingApproval,
                                     at: appServerApprovalTime, sequence: 3,
                                     source: "codex_app_server:approval"),
                               now: appServerApprovalTime)?.state == .waitingApproval,
                    "Codex App Server sequence is independent of Codex hook sequence")

        let encoded = try JSONEncoder().encode(store)
        var restored = try JSONDecoder().decode(SessionStore.self, from: encoded)

        let appServerOlderSequenceTime = start.addingTimeInterval(2)
        try expect(restored.apply(event("app-server-old-sequence", appID: "codex", state: .running,
                                        at: appServerOlderSequenceTime, sequence: 2,
                                        source: "codex_app_server:status"),
                                  now: appServerOlderSequenceTime) == nil,
                    "round-trip preserves the Codex App Server sequence watermark")
        let hookOlderSequenceTime = start.addingTimeInterval(3)
        try expect(restored.apply(event("hook-old-sequence", appID: "codex", state: .running,
                                        at: hookOlderSequenceTime, sequence: 49,
                                        source: "codex:PreToolUse"),
                                  now: hookOlderSequenceTime) == nil,
                    "Codex hook prefixes share one sequence domain after round-trip")
        try expect(restored.sessions.first?.state == .waitingApproval,
                    "older same-domain sequence cannot roll back the state")

        let newerHookTime = start.addingTimeInterval(4)
        try expect(restored.apply(event("hook-new-sequence", appID: "codex", state: .running,
                                        at: newerHookTime, sequence: 51,
                                        source: "codex:PreToolUse"),
                                  now: newerHookTime) == nil,
                    "newer hook event is accepted without an alert")
        let dshTime = start.addingTimeInterval(5)
        try expect(restored.apply(event("dsh-input", appID: "codex", state: .waitingInput,
                                        at: dshTime, sequence: 1, source: "dsh:step/start"),
                                  now: dshTime)?.state == .waitingInput,
                    "DSH sequence is independent of both Codex domains")

        let oldAxTime = start.addingTimeInterval(4.5)
        try expect(restored.apply(event("old-ax", appID: "codex", state: .running,
                                        at: oldAxTime, sequence: 999, source: "ax:tree"),
                                  now: dshTime) == nil,
                    "different source with an older observation time is rejected")
        let failedTime = start.addingTimeInterval(6)
        try expect(restored.apply(event("ax-failed", appID: "codex", state: .failed,
                                        at: failedTime, sequence: 1, source: "ax:tree"),
                                  now: failedTime)?.state == .failed,
                    "AX has its own sequence domain and may report a newer terminal event")

        let terminalRoundTrip = try JSONEncoder().encode(restored)
        var terminalRestored = try JSONDecoder().decode(SessionStore.self, from: terminalRoundTrip)
        let rollbackTime = start.addingTimeInterval(7)
        try expect(terminalRestored.apply(event("server-rollback", appID: "codex", state: .running,
                                                at: rollbackTime, sequence: 4,
                                                source: "codex_app_server:status"),
                                          now: rollbackTime) == nil,
                    "round-trip preserves terminal protection across source domains")
        let nextTurnTime = start.addingTimeInterval(8)
        try expect(terminalRestored.apply(event("next-turn", appID: "codex", turnID: "turn-2",
                                                state: .running, at: nextTurnTime, sequence: 1,
                                                source: "codex:UserPromptSubmit"),
                                          now: nextTurnTime) == nil,
                    "new turn resets per-domain sequence watermarks")
        try expect(terminalRestored.sessions.first?.state == .running,
                    "new turn can proceed after the terminal turn")
    }

    private static func checksTerminalRollbackAndDeduplication() throws {
        var store = SessionStore()
        let start = Date(timeIntervalSince1970: 4_500)
        _ = store.apply(event("terminal-start", state: .running, at: start, sequence: 1), now: start)
        let responseTime = start.addingTimeInterval(1)
        try expect(store.apply(event("response-end", state: .responseEnded, at: responseTime, sequence: 2),
                               now: responseTime)?.state == .responseEnded,
                    "responseEnded transition notifies")
        try expect(store.apply(event("response-end-refresh", state: .responseEnded,
                                     at: start.addingTimeInterval(2), sequence: 3),
                               now: start.addingTimeInterval(2)) == nil,
                    "responseEnded refresh does not notify again")

        store.expire(now: start.addingTimeInterval(124))
        try expect(store.sessions.first?.state == .responseEnded && store.sessions.first?.stale == true,
                    "expiry preserves a known terminal fact as historical evidence")
        try expect(store.apply(event("late-running", state: .running, at: start.addingTimeInterval(125), sequence: 4),
                               now: start.addingTimeInterval(125)) == nil,
                    "stale terminal session rejects same-turn running rollback")
        try expect(store.apply(event("late-waiting", state: .waitingApproval,
                                     at: start.addingTimeInterval(126), sequence: 5),
                               now: start.addingTimeInterval(126)) == nil,
                    "stale terminal session rejects same-turn waiting rollback")
        try expect(store.sessions.first?.state == .responseEnded && store.sessions.first?.stale == true,
                    "rejected rollback does not revive the stale snapshot")

        let nextTurnTime = start.addingTimeInterval(127)
        try expect(store.apply(event("new-turn", turnID: "turn-2", state: .waitingApproval,
                                     at: nextTurnTime), now: nextTurnTime)?.state == .waitingApproval,
                    "a new turn can continue after a terminal state")
        let runningTime = start.addingTimeInterval(128)
        _ = store.apply(event("new-turn-running", turnID: "turn-2", state: .running,
                              at: runningTime, sequence: 1), now: runningTime)
        let secondEndTime = start.addingTimeInterval(129)
        try expect(store.apply(event("second-end", turnID: "turn-2", state: .responseEnded,
                                     at: secondEndTime, sequence: 2), now: secondEndTime)?.state == .responseEnded,
                    "responseEnded can notify once in the new turn")
        let failedTime = start.addingTimeInterval(130)
        try expect(store.apply(event("new-failure", turnID: "turn-2", state: .failed,
                                     at: failedTime, sequence: 3), now: failedTime)?.state == .failed,
                    "failed can notify once when it is a distinct terminal transition")
        let repeatedEndTime = start.addingTimeInterval(131)
        try expect(store.apply(event("repeated-end", turnID: "turn-2", state: .responseEnded,
                                     at: repeatedEndTime, sequence: 4), now: repeatedEndTime) == nil,
                    "responseEnded is not notified twice in one turn")
        try expect(store.sessions.first?.state == .failed,
                    "a generic Stop cannot erase a specific failure")

        var cancelledStore = SessionStore()
        _ = cancelledStore.apply(event("cancel-start", state: .running, at: start), now: start)
        let cancelledTime = start.addingTimeInterval(1)
        try expect(cancelledStore.apply(event("cancel", state: .cancelled, at: cancelledTime),
                                        now: cancelledTime) == nil,
                    "cancelled is terminal but does not notify")
        try expect(cancelledStore.apply(event("after-cancel", state: .running,
                                              at: start.addingTimeInterval(2)),
                                        now: start.addingTimeInterval(2)) == nil,
                    "cancelled rejects same-turn running rollback")
        _ = cancelledStore.apply(event("cleanup-stop", state: .responseEnded,
                                       at: start.addingTimeInterval(2.5)), now: start.addingTimeInterval(2.5))
        try expect(cancelledStore.sessions.first?.state == .cancelled,
                    "a generic Stop cannot erase an explicit cancellation")
        try expect(cancelledStore.apply(event("after-cancel-new-turn", turnID: "turn-2", state: .running,
                                              at: start.addingTimeInterval(3)),
                                        now: start.addingTimeInterval(3)) == nil,
                    "cancelled session resumes only in a new turn")
        try expect(cancelledStore.sessions.first?.state == .running,
                    "new turn clears the cancelled terminal marker")
    }

    private static func checksLegacyStopCompletionMigration() throws {
        var store = SessionStore()
        let start = Date(timeIntervalSince1970: 4_400)
        let legacyStops: [(appID: String, sessionID: String, source: String)] = [
            ("codex", "codex-stop", "codex:Stop"),
            ("codex", "codex-subagent-stop", "codex:SubagentStop"),
            ("claude_code", "claude-stop", "claude_code:Stop"),
            ("claude_code", "claude-subagent-stop", "claude_code:SubagentStop"),
        ]

        for (index, item) in legacyStops.enumerated() {
            let turnID = "turn-\(item.sessionID)"
            let runningTime = start.addingTimeInterval(Double(index * 3))
            _ = store.apply(event("\(item.sessionID)-start", appID: item.appID,
                                  sessionID: item.sessionID, turnID: turnID,
                                  parentSessionID: item.sessionID == "codex-stop" ? "parent-session" : nil,
                                  state: .running, at: runningTime, sequence: 1,
                                  source: item.appID == "codex" ? "codex:UserPromptSubmit" : "claude_code:UserPromptSubmit"),
                                now: runningTime)
            let stopTime = runningTime.addingTimeInterval(1)
            _ = store.apply(event("\(item.sessionID)-stop", appID: item.appID,
                                  sessionID: item.sessionID, turnID: turnID,
                                  state: .responseEnded, at: stopTime, sequence: 2,
                                  source: item.source), now: stopTime)
        }

        let journalTime = start.addingTimeInterval(20)
        _ = store.apply(event("journal-start", appID: "codex", sessionID: "journal-session",
                              turnID: "journal-turn", state: .running, at: journalTime,
                              source: "codex_app_server:turn_started"), now: journalTime)
        let journalEndTime = journalTime.addingTimeInterval(1)
        _ = store.apply(event("journal-end", appID: "codex", sessionID: "journal-session",
                              turnID: "journal-turn", state: .responseEnded, at: journalEndTime,
                              source: "codex_rollout:task_complete"), now: journalEndTime)
        let alreadyNormalizedTime = journalTime.addingTimeInterval(2)
        _ = store.apply(event("normalized-stop", appID: "codex", sessionID: "normalized-session",
                              turnID: "normalized-turn", state: .unknown, at: alreadyNormalizedTime,
                              source: "codex:Stop:awaiting_confirmation"), now: alreadyNormalizedTime)

        var completions = CompletionInbox()
        for item in legacyStops {
            completions.record(appID: item.appID, sessionID: item.sessionID,
                               turnID: "turn-\(item.sessionID)")
        }
        completions.record(appID: "codex", sessionID: "journal-session", turnID: "journal-turn")
        completions.record(appID: "codex", sessionID: "codex-stop", turnID: "another-turn")

        var restored = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(store))
        let invalidated = restored.invalidatePrematureStopCompletions()
        try expect(invalidated.count == legacyStops.count,
                   "only the four exact legacy Stop sources are invalidated")
        for item in legacyStops {
            let turnID = "turn-\(item.sessionID)"
            guard let snapshot = restored.sessions.first(where: { $0.sessionID == item.sessionID }) else {
                throw NSError(domain: "CoreChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "CHECK FAILED: migrated Stop snapshot is missing"])
            }
            try expect(snapshot.state == .unknown && snapshot.source == item.source + ":awaiting_confirmation",
                       "legacy Stop terminal state becomes unknown pending durable confirmation")
            if item.sessionID == "codex-stop" {
                try expect(snapshot.parentSessionID == "parent-session",
                           "migration preserves learned parent metadata")
            }
            try expect(invalidated.contains(where: {
                $0.appID == item.appID && $0.sessionID == item.sessionID && $0.turnID == turnID
            }), "migration returns the exact app, session, and turn receipt key")
        }
        for receipt in invalidated {
            completions.remove(appID: receipt.appID, sessionID: receipt.sessionID, turnID: receipt.turnID)
        }
        try expect(completions.count == 2,
                   "migration removes only matching legacy receipts, preserving journal and other-turn receipts")

        try expect(restored.sessions.first(where: { $0.sessionID == "journal-session" })?.state == .responseEnded,
                   "a durable journal completion is preserved")
        try expect(restored.sessions.first(where: { $0.sessionID == "normalized-session" })?.state == .unknown,
                   "an already-normalized Stop intent remains unknown")
        try expect(restored.invalidatePrematureStopCompletions().isEmpty,
                   "repeating the migration does not change already-normalized records")

        let duplicateStopTime = start.addingTimeInterval(3)
        try expect(restored.apply(event("codex-stop-stop", appID: "codex", sessionID: "codex-stop",
                                        turnID: "turn-codex-stop", state: .responseEnded,
                                        at: duplicateStopTime, sequence: 2, source: "codex:Stop"),
                                  now: duplicateStopTime) == nil,
                   "migration preserves event-ID deduplication for the original Stop record")
        let continuedTime = start.addingTimeInterval(4)
        _ = restored.apply(event("codex-stop-continued", appID: "codex", sessionID: "codex-stop",
                                 turnID: "turn-codex-stop", state: .running, at: continuedTime,
                                 sequence: 3, source: "codex:PreToolUse"), now: continuedTime)
        try expect(restored.sessions.first(where: { $0.sessionID == "codex-stop" })?.state == .running,
                   "a blocked Stop can continue within the same turn after migration")
        let trueEndTime = start.addingTimeInterval(5)
        try expect(restored.apply(event("codex-stop-durable-end", appID: "codex", sessionID: "codex-stop",
                                        turnID: "turn-codex-stop", state: .responseEnded, at: trueEndTime,
                                        source: "codex_rollout:task_complete"), now: trueEndTime)?.state == .responseEnded,
                   "durable same-turn completion can close the migrated session")
    }

    private static func checksPersistenceRoundTrip() throws {
        var store = SessionStore()
        let start = Date(timeIntervalSince1970: 4_800)
        _ = store.apply(event("persist-start", state: .running, at: start, sequence: 1), now: start)
        let firstApprovalTime = start.addingTimeInterval(1)
        try expect(store.apply(event("persist-approval-1", state: .waitingApproval,
                                     at: firstApprovalTime, sequence: 2),
                               now: firstApprovalTime)?.state == .waitingApproval,
                    "first authorization wait notifies before persistence")
        let runningTime = start.addingTimeInterval(2)
        _ = store.apply(event("persist-running-again", state: .running,
                              at: runningTime, sequence: 3), now: runningTime)
        let secondApproval = event("persist-approval-2", state: .waitingApproval,
                                   at: start.addingTimeInterval(3), sequence: 4)
        try expect(store.apply(secondApproval, now: start.addingTimeInterval(3))?.state == .waitingApproval,
                    "re-entered authorization wait notifies before persistence")

        let nextTurnTime = start.addingTimeInterval(4)
        _ = store.apply(event("persist-turn-2", turnID: "turn-2", state: .running,
                              at: nextTurnTime, sequence: 1), now: nextTurnTime)
        let responseTime = start.addingTimeInterval(5)
        try expect(store.apply(event("persist-response-end", turnID: "turn-2", state: .responseEnded,
                                     at: responseTime, sequence: 2), now: responseTime)?.state == .responseEnded,
                    "responseEnded notifies before persistence")
        let failedTime = start.addingTimeInterval(6)
        let failedEvent = event("persist-failed", turnID: "turn-2", state: .failed,
                                at: failedTime, sequence: 3)
        try expect(store.apply(failedEvent, now: failedTime)?.state == .failed,
                    "failed notifies before persistence")

        let encoded = try JSONEncoder().encode(store)
        var restored = try JSONDecoder().decode(SessionStore.self, from: encoded)

        try expect(restored.apply(failedEvent, now: start.addingTimeInterval(7)) == nil,
                    "restored event-ID deduplication prevents replaying an already-seen current-turn event")
        try expect(restored.apply(secondApproval, now: start.addingTimeInterval(7)) == nil,
                    "restored event deduplication prevents replaying an already-seen event")
        let repeatedResponseTime = start.addingTimeInterval(7)
        try expect(restored.apply(event("persist-response-end-again", turnID: "turn-2",
                                        state: .responseEnded, at: repeatedResponseTime, sequence: 4),
                                  now: repeatedResponseTime) == nil,
                    "restored per-turn terminal notice history suppresses a repeated responseEnded notice")
        let runningRollbackTime = start.addingTimeInterval(8)
        try expect(restored.apply(event("persist-running-rollback", turnID: "turn-2", state: .running,
                                        at: runningRollbackTime, sequence: 5),
                                  now: runningRollbackTime) == nil,
                    "restored terminal marker rejects same-turn running rollback")
        let oldTurnTime = start.addingTimeInterval(9)
        try expect(restored.apply(event("persist-old-turn", turnID: "turn-1", state: .running,
                                        at: oldTurnTime, sequence: 6),
                                  now: oldTurnTime) == nil,
                    "restored closed-turn set rejects an old turn")
        try expect(restored.sessions.first?.turnID == "turn-2",
                    "round-trip preserves the current turn")
    }

    private static func checksExpiryAndChildren() throws {
        var store = SessionStore()
        let start = Date(timeIntervalSince1970: 5_000)
        _ = store.apply(event("parent", sessionID: "parent", state: .running, at: start), now: start)
        let childTime = start.addingTimeInterval(1)
        let childNotice = store.apply(event("child", sessionID: "child", parentSessionID: "parent",
                                            state: .waitingInput, at: childTime), now: childTime)
        try expect(childNotice?.sessionID == "child", "child notice identifies the child session")
        try expect(store.sessions.count == 2, "parent and child are separate sessions")
        try expect(store.sessions.first { $0.sessionID == "parent" }?.state == .running,
                    "child event does not update its parent")

        store.expire(now: childTime.addingTimeInterval(121))
        try expect(store.sessions.allSatisfy { $0.state == .unknown && $0.stale },
                    "expired sessions become stale unknown snapshots")
        try expect(store.apply(event("fresh-child", sessionID: "child", turnID: "turn-1",
                                     parentSessionID: "parent", state: .waitingInput,
                                     at: childTime.addingTimeInterval(122)),
                               now: childTime.addingTimeInterval(122)) == nil,
                    "expiry itself and a repeated same state do not duplicate a notice")
    }

    private static func checksCapacity() throws {
        var store = SessionStore()
        let start = Date(timeIntervalSince1970: 6_000)
        for index in 0..<501 {
            let instant = start.addingTimeInterval(TimeInterval(index))
            _ = store.apply(event("capacity-\(index)", sessionID: "session-\(index)",
                                  state: .running, at: instant), now: instant)
        }
        try expect(store.sessions.count == 500, "store keeps no more than 500 sessions")
        try expect(!store.sessions.contains { $0.sessionID == "session-0" }, "least recently touched session is evicted")
    }

    private static func checksParentMetadataAcrossSources() throws {
        var store = SessionStore()
        let start = Date(timeIntervalSince1970: 5_500)
        _ = store.apply(event("parent-start", sessionID: "parent", state: .running, at: start), now: start)
        _ = store.apply(event("child-hook", sessionID: "child", parentSessionID: "parent",
                              state: .running, at: start, source: "codex:PreToolUse"), now: start)
        let end = start.addingTimeInterval(1)
        _ = store.apply(event("child-journal", sessionID: "child", state: .responseEnded,
                              at: end, source: "codex_rollout:task_complete"), now: end)
        try expect(store.sessions.first { $0.sessionID == "child" }?.parentSessionID == "parent",
                   "a journal without parent metadata preserves the relationship already learned from hooks")
        try expect(store.sessions.first { $0.sessionID == "parent" }?.state == .running,
                   "confirmed child completion cannot complete the parent")
    }

    private static func event(
        _ id: String,
        appID: String = "sample-app",
        sessionID: String = "session-1",
        turnID: String = "turn-1",
        parentSessionID: String? = nil,
        state: SessionState,
        at date: Date,
        sequence: Int? = nil,
        source: String = "core-check"
    ) -> MonitorEvent {
        MonitorEvent(
            id: id,
            appID: appID,
            sessionID: sessionID,
            turnID: turnID,
            state: state,
            evidence: .explicit,
            observedAt: date,
            sequence: sequence,
            parentSessionID: parentSessionID,
            source: source
        )
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "CoreChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "CHECK FAILED: \(message)"])
        }
    }
}
