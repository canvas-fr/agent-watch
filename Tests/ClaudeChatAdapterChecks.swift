import Foundation
import AgentWatchCore

@main
struct ClaudeChatAdapterChecks {
    private struct AXFixture: Decodable {
        let layout: String
        let route: String
        let statusLabel: String
        let stopButtonVisible: Bool
        let needsInputTextCount: Int
        let optionToggleCount: Int
        let questionActionLabels: Set<String>
        let latestAssistantCopyVisible: Bool
    }

    static func main() {
        let authLabels: Set<String> = [
            ClaudeChatScopeRules.openSetupButton,
            ClaudeChatScopeRules.checkAgainButton,
        ]
        expect(
            ClaudeChatScopeRules.isAuthenticationGroup(
                heading: "New session",
                buttonLabels: authLabels,
                directStatusTexts: [
                    "Couldn’t sign in to Gateway",
                    "The provider rejected your credentials. Re-enter them in Setup.",
                ]
            ),
            "only the explicit auth panel maps to auth_required"
        )
        expect(
            !ClaudeChatScopeRules.isAuthenticationGroup(
                heading: "New session",
                buttonLabels: ["Open Setup"],
                directStatusTexts: [
                    "Couldn’t sign in to Gateway",
                    "The provider rejected your credentials. Re-enter them in Setup.",
                ]
            ),
            "auth banner alone is insufficient without the button pair"
        )

        let responding = fixture("compact_code_responding.json")
        let question = fixture("primary_pane_question.json")
        let finished = fixture("finished_candidate.json")
        expect(responding.layout == "compactCode", "compact Code fixture is loaded")
        expect(question.layout == "primaryPane", "full Primary pane fixture is loaded")
        expect(
            ClaudeChatScopeRules.isCompactStatusGroup(
                directChildRoles: ["AXStaticText", "AXGroup"],
                secondChildGroupLabel: "Chat messages"
            ),
            "compact session status is scoped by its direct Chat messages group"
        )
        expect(
            !ClaudeChatScopeRules.isCompactStatusGroup(
                directChildRoles: ["AXStaticText", "AXGroup"],
                secondChildGroupLabel: "Preview"
            ),
            "a preview group cannot stand in for Chat messages"
        )
        expect(
            ClaudeChatScopeRules.isCoworkStatusLayout(
                paneLabel: "Primary pane",
                directChildRoles: ["AXGroup", "AXGroup", "AXStaticText", "AXGroup"],
                activityPanelLabel: "Session activity panel",
                contentChildRoles: ["AXGroup", "AXGroup"],
                contentGroupLabels: ["Chat messages"],
                composerHasInputRole: true
            ),
            "Cowork interruption requires the fixed status row, activity panel, Chat messages, and composer"
        )
        expect(
            !ClaudeChatScopeRules.isCoworkStatusLayout(
                paneLabel: "Primary pane",
                directChildRoles: ["AXStaticText", "AXGroup", "AXGroup"],
                activityPanelLabel: nil,
                contentChildRoles: ["AXGroup", "AXGroup"],
                contentGroupLabels: ["Chat messages"],
                composerHasInputRole: true
            ),
            "the Code pane shape cannot authorize Cowork cancellation"
        )
        expect(
            !ClaudeChatScopeRules.isCoworkStatusLayout(
                paneLabel: "Primary pane",
                directChildRoles: ["AXGroup", "AXGroup", "AXStaticText", "AXGroup"],
                activityPanelLabel: "Session chapters",
                contentChildRoles: ["AXGroup", "AXGroup"],
                contentGroupLabels: ["Chat messages"],
                composerHasInputRole: true
            ),
            "an unrelated panel label cannot authorize Cowork cancellation"
        )
        expect(ClaudeChatScopeRules.stopButtonLabel(for: .cowork) == "Stop response",
               "Cowork uses the exact Stop response control")
        expect(ClaudeChatScopeRules.stopButtonLabel(for: .code) == "Stop",
               "Code retains its existing Stop control")
        expect(
            ClaudeChatScopeRules.isPrimaryPane(
                paneLabel: "Primary pane",
                directChildRoles: ["AXGroup", "AXGroup", "AXGroup"],
                siblingGroupLabels: ["Status", "Session chapters", "Chat messages"]
            ),
            "grouped status, Session chapters, and Chat messages form the full pane"
        )
        expect(
            !ClaudeChatScopeRules.isPrimaryPane(
                paneLabel: "Primary pane",
                directChildRoles: ["AXStaticText", "AXGroup", "AXGroup"],
                siblingGroupLabels: ["Preview", "Chat messages"]
            ),
            "an unrelated preview cannot stand in for Session chapters"
        )

        expect(
            ClaudeChatScopeRules.observedStatus(for: responding.statusLabel) == .responding,
            "the exact responding label is accepted"
        )
        expect(
            ClaudeChatScopeRules.observedStatus(for: finished.statusLabel) == .finished,
            "the exact finished label is a candidate"
        )
        expect(
            ClaudeChatScopeRules.observedStatus(for: "Claude is waiting") == .unknown,
            "unverified status wording remains unknown"
        )
        expect(
            ClaudeChatScopeRules.observedStatus(for: "Claude’s response was interrupted.") == .interrupted,
            "the exact Cowork interruption status is recognized"
        )
        expect(
            ClaudeChatScopeRules.observedStatus(for: "Claude's response was interrupted.") == .unknown,
            "a different apostrophe is not accepted"
        )
        expect(
            ClaudeChatScopeRules.isStructuredQuestion(
                needsInputTextCount: question.needsInputTextCount,
                optionToggleCount: question.optionToggleCount,
                actionButtonLabels: question.questionActionLabels
            ),
            "AskUserQuestion needs its fixed status and structured controls"
        )
        expect(
            !ClaudeChatScopeRules.isStructuredQuestion(
                needsInputTextCount: question.needsInputTextCount,
                optionToggleCount: 0,
                actionButtonLabels: []
            ),
            "Needs your input text alone is not enough"
        )
        expect(
            ClaudeChatScopeRules.hasAssistantActionToolbar(["Fork from here", "Pin as chapter", "Copy"]),
            "the fixed assistant action toolbar is recognized structurally"
        )
        expect(finished.latestAssistantCopyVisible, "the canceled partial-text fixture retains Copy")

        let codeRouteID = ClaudeChatScopeRules.routeSessionID(forLocalRoute: responding.route)
        let sessionFingerprint = ClaudeChatScopeRules.sessionFingerprint(forLocalRoute: responding.route)
        expect(codeRouteID == "local_01234567-89ab-cdef-0123-456789abcdef", "Code route ID is extracted transiently")
        expect(sessionFingerprint?.count == 64, "the stored session identity is a SHA-256 fingerprint")
        expect(sessionFingerprint?.contains("01234567") == false, "the hash does not expose the local route ID")
        let coworkRoute = "app://localhost/cowork/local_01234567-89ab-cdef-0123-456789abcdef"
        expect(ClaudeChatScopeRules.routeKind(forLocalRoute: coworkRoute) == .cowork, "Cowork route is classified separately")
        expect(ClaudeChatScopeRules.routeSessionID(forLocalRoute: coworkRoute) == codeRouteID, "Cowork uses the same transient local-session key shape")
        expect(
            ClaudeChatScopeRules.sessionFingerprint(forLocalRoute: "app://localhost/epitaxy/local_01234567-89ab-cdef-0123-456789abcdef?prompt=private") == nil,
            "routes with query data are not admitted"
        )
        expect(
            ClaudeChatScopeRules.sessionFingerprint(forLocalRoute: "https://example.com/epitaxy/local_01234567-89ab-cdef-0123-456789abcdef") == nil,
            "only the local app route is admitted"
        )

        var reducer = ClaudeChatStateReducer()
        expect(
            reducer.observe(
                windowFingerprint: "window-a",
                sessionFingerprint: sessionFingerprint,
                turnFingerprint: "turn-hash-a",
                status: .responding,
                stopButtonVisible: responding.stopButtonVisible,
                structuredQuestion: false,
                snapshot: 1
            ) == .running,
            "responding plus Stop maps to running"
        )
        expect(
            reducer.observe(
                windowFingerprint: "window-a",
                sessionFingerprint: sessionFingerprint,
                turnFingerprint: "turn-hash-a",
                status: .finished,
                stopButtonVisible: finished.stopButtonVisible,
                structuredQuestion: false,
                snapshot: 2
            ) == .unknown,
            "a finished label with Copy stays a candidate for the durable reader"
        )
        expect(
            reducer.observe(
                windowFingerprint: "window-a",
                sessionFingerprint: sessionFingerprint,
                turnFingerprint: "turn-hash-a",
                status: .finished,
                stopButtonVisible: finished.stopButtonVisible,
                structuredQuestion: false,
                snapshot: 3
            ) == .unknown,
            "two finished AX snapshots remain unknown in the native adapter"
        )
        expect(
            ClaudeChatScopeRules.stateForFinishLabel(
                visible: true,
                runningSeenInSameWindow: true,
                identityContinuous: true,
                matchingFinishedSnapshots: 2
            ) == .unknown,
            "the AX adapter never emits responseEnded"
        )

        var coldFinishedReducer = ClaudeChatStateReducer()
        expect(
            coldFinishedReducer.observe(
                windowFingerprint: "window-a",
                sessionFingerprint: sessionFingerprint,
                turnFingerprint: "turn-hash-a",
                status: .finished,
                stopButtonVisible: false,
                structuredQuestion: false,
                snapshot: 1
            ) == .unknown,
            "a cold finished snapshot cannot create a completion"
        )

        var cancelReducer = ClaudeChatStateReducer()
        _ = cancelReducer.observe(
            windowFingerprint: "window-a",
            sessionFingerprint: sessionFingerprint,
            turnFingerprint: "turn-hash-a",
            status: .responding,
            stopButtonVisible: true,
            structuredQuestion: false,
            snapshot: 10
        )
        expect(
            cancelReducer.observe(
                windowFingerprint: "window-a",
                sessionFingerprint: sessionFingerprint,
                turnFingerprint: "turn-hash-a",
                status: .finished,
                stopButtonVisible: false,
                structuredQuestion: false,
                snapshot: 11
            ) == .unknown,
            "the same finished status after cancellation remains unknown"
        )
        expect(
            cancelReducer.observe(
                windowFingerprint: "window-a",
                sessionFingerprint: sessionFingerprint,
                turnFingerprint: "turn-hash-a",
                status: .finished,
                stopButtonVisible: false,
                structuredQuestion: false,
                snapshot: 12
            ) == .unknown,
            "a canceled turn cannot later become complete without a new responding transition"
        )

        let coworkInterruptedRoute = "app://localhost/cowork/local_01234567-89ab-cdef-0123-456789abcdef"
        let coworkFingerprint = ClaudeChatScopeRules.sessionFingerprint(forLocalRoute: coworkInterruptedRoute)
        var coworkReducer = ClaudeChatStateReducer()
        let coworkResponding = ClaudeChatWindowObservation(
            windowFingerprint: "cowork-window",
            routeSessionID: codeRouteID,
            routeKind: .cowork,
            sessionFingerprint: coworkFingerprint,
            turnFingerprint: "cowork-turn",
            scope: .cowork,
            observedStatus: .responding,
            stopButtonVisible: true,
            snapshotSequence: 20
        )
        let coworkInterrupted = ClaudeChatWindowObservation(
            windowFingerprint: "cowork-window",
            routeSessionID: codeRouteID,
            routeKind: .cowork,
            sessionFingerprint: coworkFingerprint,
            turnFingerprint: "cowork-turn",
            scope: .cowork,
            observedStatus: .interrupted,
            stopButtonVisible: false,
            snapshotSequence: 21
        )
        expect(coworkReducer.observe(coworkResponding) == .running,
               "Cowork responding with Stop response records the active run")
        expect(coworkReducer.observe(coworkInterrupted) == .cancelled,
               "same-window same-route Cowork interruption maps to cancelled")

        var coldCoworkReducer = ClaudeChatStateReducer()
        expect(
            coldCoworkReducer.observe(
                windowFingerprint: "cowork-window",
                sessionFingerprint: coworkFingerprint,
                turnFingerprint: "cowork-turn",
                status: .interrupted,
                stopButtonVisible: false,
                structuredQuestion: false,
                snapshot: 30,
                routeKind: .cowork
            ) == .unknown,
            "a cold Cowork interruption label cannot create cancellation"
        )

        var codeInterruptedReducer = ClaudeChatStateReducer()
        _ = codeInterruptedReducer.observe(
            windowFingerprint: "code-window",
            sessionFingerprint: sessionFingerprint,
            turnFingerprint: "code-turn",
            status: .responding,
            stopButtonVisible: true,
            structuredQuestion: false,
            snapshot: 40,
            routeKind: .code
        )
        expect(
            codeInterruptedReducer.observe(
                windowFingerprint: "code-window",
                sessionFingerprint: sessionFingerprint,
                turnFingerprint: "code-turn",
                status: .interrupted,
                stopButtonVisible: false,
                structuredQuestion: false,
                snapshot: 41,
                routeKind: .code
            ) == .unknown,
            "the interrupted wording on Code remains unknown"
        )

        var codeFinishedReducer = ClaudeChatStateReducer()
        _ = codeFinishedReducer.observe(
            windowFingerprint: "code-window",
            sessionFingerprint: sessionFingerprint,
            turnFingerprint: "code-turn",
            status: .responding,
            stopButtonVisible: true,
            structuredQuestion: false,
            snapshot: 50,
            routeKind: .code
        )
        expect(
            codeFinishedReducer.observe(
                windowFingerprint: "code-window",
                sessionFingerprint: sessionFingerprint,
                turnFingerprint: "code-turn",
                status: .finished,
                stopButtonVisible: false,
                structuredQuestion: false,
                snapshot: 51,
                routeKind: .code
            ) == .unknown,
            "the exact Code finished label after Stop remains unknown"
        )

        var coworkToolbarChangeReducer = ClaudeChatStateReducer()
        _ = coworkToolbarChangeReducer.observe(
            windowFingerprint: "cowork-window",
            sessionFingerprint: coworkFingerprint,
            turnFingerprint: "cowork-turn-a",
            status: .responding,
            stopButtonVisible: true,
            structuredQuestion: false,
            snapshot: 60,
            routeKind: .cowork
        )
        expect(
            coworkToolbarChangeReducer.observe(
                windowFingerprint: "cowork-window",
                sessionFingerprint: coworkFingerprint,
                turnFingerprint: "cowork-turn-b",
                status: .interrupted,
                stopButtonVisible: false,
                structuredQuestion: false,
                snapshot: 61,
                routeKind: .cowork
            ) == .cancelled,
            "the exact Cowork interrupted label may follow a toolbar remount in the same route/window"
        )

        var changedWindowCoworkReducer = ClaudeChatStateReducer()
        _ = changedWindowCoworkReducer.observe(
            windowFingerprint: "cowork-window-a",
            sessionFingerprint: coworkFingerprint,
            turnFingerprint: "cowork-turn",
            status: .responding,
            stopButtonVisible: true,
            structuredQuestion: false,
            snapshot: 70,
            routeKind: .cowork
        )
        expect(
            changedWindowCoworkReducer.observe(
                windowFingerprint: "cowork-window-b",
                sessionFingerprint: coworkFingerprint,
                turnFingerprint: "cowork-turn",
                status: .interrupted,
                stopButtonVisible: false,
                structuredQuestion: false,
                snapshot: 71,
                routeKind: .cowork
            ) == .unknown,
            "another Cowork window cannot cancel the witnessed window's run"
        )

        var gapCoworkReducer = ClaudeChatStateReducer()
        _ = gapCoworkReducer.observe(
            windowFingerprint: "cowork-window",
            sessionFingerprint: coworkFingerprint,
            turnFingerprint: "cowork-turn",
            status: .responding,
            stopButtonVisible: true,
            structuredQuestion: false,
            snapshot: 80,
            routeKind: .cowork
        )
        expect(
            gapCoworkReducer.observe(
                windowFingerprint: "cowork-window",
                sessionFingerprint: coworkFingerprint,
                turnFingerprint: "cowork-turn",
                status: .interrupted,
                stopButtonVisible: false,
                structuredQuestion: false,
                snapshot: 82,
                routeKind: .cowork
            ) == .unknown,
            "a missed snapshot breaks the Cowork responding continuity witness"
        )

        var questionReducer = ClaudeChatStateReducer()
        expect(
            questionReducer.observe(
                windowFingerprint: "window-question",
                sessionFingerprint: sessionFingerprint,
                turnFingerprint: "turn-question",
                status: .responding,
                stopButtonVisible: question.stopButtonVisible,
                structuredQuestion: ClaudeChatScopeRules.isStructuredQuestion(
                    needsInputTextCount: question.needsInputTextCount,
                    optionToggleCount: question.optionToggleCount,
                    actionButtonLabels: question.questionActionLabels
                ),
                snapshot: 1
            ) == .waitingInput,
            "the validated AskUserQuestion control pattern maps to waitingInput"
        )
        expect(
            questionReducer.observe(
                windowFingerprint: "window-question",
                sessionFingerprint: sessionFingerprint,
                turnFingerprint: "turn-question",
                status: .responding,
                stopButtonVisible: true,
                structuredQuestion: false,
                snapshot: 2
            ) == .running,
            "the responding label and Stop alone do not mean waitingInput"
        )

        var discontinuousReducer = ClaudeChatStateReducer()
        _ = discontinuousReducer.observe(
            windowFingerprint: "window-a",
            sessionFingerprint: sessionFingerprint,
            turnFingerprint: "turn-hash-a",
            status: .responding,
            stopButtonVisible: true,
            structuredQuestion: false,
            snapshot: 1
        )
        expect(
            discontinuousReducer.observe(
                windowFingerprint: "window-b",
                sessionFingerprint: sessionFingerprint,
                turnFingerprint: "turn-hash-a",
                status: .finished,
                stopButtonVisible: false,
                structuredQuestion: false,
                snapshot: 2
            ) == .unknown,
            "a different window cannot finish the prior window's turn"
        )
        expect(
            discontinuousReducer.observe(
                windowFingerprint: "window-a",
                sessionFingerprint: "another-session",
                turnFingerprint: "turn-hash-a",
                status: .finished,
                stopButtonVisible: false,
                structuredQuestion: false,
                snapshot: 2
            ) == .unknown,
            "a different route session cannot reuse the previous transition"
        )

        print("PASS: Claude Code scope and Cowork interruption continuity rules")
    }

    private static func fixture(_ name: String) -> AXFixture {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/claude_code_ax/\(name)")
        do {
            return try JSONDecoder().decode(AXFixture.self, from: Data(contentsOf: fileURL))
        } catch {
            preconditionFailure("CHECK FAILED: cannot decode fixture \(name): \(error)")
        }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, "CHECK FAILED: \(message)")
    }
}
