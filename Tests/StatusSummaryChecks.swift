import Foundation
import AgentWatchCore

@main
struct StatusSummaryChecks {
    static func main() throws {
        checksCompletionInboxDeduplicatesStructuredIdentity()
        try checksCompletionInboxCapacityAndPersistence()
        checksCompletionInboxReadAndRemove()
        checksStatusBarSummaryCountsOnlyFreshActiveSessions()
        print("PASS: completion inbox and status-bar summary checks")
    }

    private static func checksCompletionInboxDeduplicatesStructuredIdentity() {
        var inbox = CompletionInbox()
        inbox.record(appID: "app", sessionID: "session", turnID: "turn")
        inbox.record(appID: "app", sessionID: "session", turnID: "turn")
        expect(inbox.count == 1, "the same app, session, and turn is recorded once")

        inbox.record(appID: "a", sessionID: "bc", turnID: "d")
        inbox.record(appID: "ab", sessionID: "c", turnID: "d")
        expect(inbox.count == 3, "distinct field boundaries do not collide when concatenated")
    }

    private static func checksCompletionInboxCapacityAndPersistence() throws {
        var inbox = CompletionInbox()
        for index in 0..<105 {
            inbox.record(appID: "app", sessionID: "session-\(index)", turnID: "turn")
        }
        expect(inbox.count == 100, "the inbox retains no more than 100 completion records")

        let restored = try JSONDecoder().decode(CompletionInbox.self, from: JSONEncoder().encode(inbox))
        expect(restored.count == 100, "the inbox persists all retained completion records")
        expect(restored.appIDs == ["app"], "app identifiers survive an encoding round-trip")
    }

    private static func checksCompletionInboxReadAndRemove() {
        var inbox = CompletionInbox()
        inbox.record(appID: "alpha", sessionID: "session-1", turnID: "turn-1")
        inbox.record(appID: "beta", sessionID: "session-2", turnID: "turn-1")
        inbox.record(appID: "alpha", sessionID: "session-3", turnID: "turn-2")

        inbox.remove(appID: "alpha")
        expect(inbox.count == 1 && inbox.appIDs == ["beta"], "removing one app clears only its records")

        inbox.markAllRead()
        expect(inbox.count == 0 && inbox.appIDs.isEmpty, "marking all as read empties the inbox")
    }

    private static func checksStatusBarSummaryCountsOnlyFreshActiveSessions() {
        let now = Date(timeIntervalSince1970: 10_000)
        let sessions = [
            snapshot("pending-approval", state: .waitingApproval, stale: false, at: now),
            snapshot("pending-input", state: .waitingInput, stale: false, at: now),
            snapshot("running", state: .running, stale: false, at: now),
            snapshot("stale-running", state: .running, stale: true, at: now),
            snapshot("unknown", state: .unknown, stale: false, at: now),
            snapshot("ended", state: .responseEnded, stale: false, at: now)
        ]

        expect(
            statusBarText(sessions: sessions, unreadCompletions: 3, paused: false)
                == "待处理2 · 运行1 · 新结束3",
            "pending and running counts exclude stale and unknown sessions"
        )
        expect(
            statusBarText(sessions: [sessions[2]], unreadCompletions: 0, paused: false) == "运行1",
            "zero summary fields are omitted"
        )
        expect(
            statusBarText(sessions: [], unreadCompletions: 2, paused: false) == "新结束2",
            "unread completions remain visible without active sessions"
        )
        expect(
            statusBarText(sessions: [snapshot("failed", state: .failed, stale: false, at: now)], unreadCompletions: 0, paused: false) == "待处理1",
            "a fresh failure requires attention rather than displaying idle"
        )
        expect(
            statusBarText(sessions: [sessions[3], sessions[4]], unreadCompletions: 0, paused: false) == "状态未确认",
            "missing activity evidence is not presented as confirmed idle"
        )
        expect(
            statusBarText(sessions: sessions, unreadCompletions: 3, paused: true) == "已暂停",
            "paused status takes precedence over counts"
        )
    }

    private static func snapshot(
        _ sessionID: String,
        state: SessionState,
        stale: Bool,
        at date: Date
    ) -> SessionSnapshot {
        SessionSnapshot(
            appID: "codex",
            sessionID: sessionID,
            turnID: "turn-1",
            state: state,
            evidence: .explicit,
            updatedAt: date,
            source: "status-summary-check",
            parentSessionID: nil,
            stale: stale
        )
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, "CHECK FAILED: \(message)")
    }
}
