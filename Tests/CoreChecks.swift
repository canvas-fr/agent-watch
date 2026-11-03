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
        try checksTerminalRollbackAndDeduplication()
        try checksPersistenceRoundTrip()
        try checksExpiryAndChildren()
        try checksCapacity()
        print("PASS: Agent Watch core state, ordering, notice, expiry, and capacity checks")
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
