/// Pure checks for the screened-label state rules; this file never talks to AX or an app.
@main
struct WindowRuleChecks {
    static func main() {
        let targets = (0..<8).map { index in
            WindowTarget(appID: "app\(index)", bundleIDs: ["bundle.\(index)"])
        }
        var rotator = WindowTargetRotator()
        var visitedApps: Set<String> = []
        for _ in 0..<8 {
            visitedApps.formUnion(rotator.rotate(targets).prefix(6).map(\.appID))
        }
        expect(visitedApps == Set(targets.map(\.appID)), "rotating start eventually covers all eight apps")
        expect(rotator.rotate([]).isEmpty, "empty target list is safe")

        var turnCursor = WindowTurnCursor(initialTurnID: "window-idle")
        let runningTurnID = turnCursor.eventTurnID(candidateTurnActive: true, candidateTurnBecameInactive: false)
        let firstUnverifiedTurnID = turnCursor.eventTurnID(candidateTurnActive: true, candidateTurnBecameInactive: false)
        let completionCandidateTurnID = turnCursor.eventTurnID(candidateTurnActive: false, candidateTurnBecameInactive: true)
        let nextIdleTurnID = turnCursor.eventTurnID(candidateTurnActive: false, candidateTurnBecameInactive: false)
        let nextRunningTurnID = turnCursor.eventTurnID(candidateTurnActive: true, candidateTurnBecameInactive: false)
        expect(runningTurnID == firstUnverifiedTurnID && runningTurnID == completionCandidateTurnID, "unverified completion keeps the previous running turn ID")
        expect(nextIdleTurnID == completionCandidateTurnID, "unknown does not invent a new task identity")
        expect(nextRunningTurnID != completionCandidateTurnID, "a later running edge starts a fresh window-level turn")

        let coldComposer = input(composerSend: true)
        expect(WindowStateRules.decide(coldComposer).state == .unknown, "cold start stays unknown")

        let running = input(
            controls: [.stopGeneration],
            composerSpecificStop: true
        )
        let runningDecision = WindowStateRules.decide(running)
        expect(runningDecision.state == .running && runningDecision.wasRunning, "composer stop can replace send")

        expect(WindowStateRules.isComposerSpecificStop([.stopGeneration, .textFieldInput]), "specific stop shares an input group")
        expect(!WindowStateRules.isComposerGenericStop([.genericStop, .textFieldInput]), "generic stop alone is not a composer signal")
        expect(WindowStateRules.isComposerGenericStop([.genericStop, .textAreaInput]), "generic stop needs a local text area")
        let unrelatedStop = WindowStateRules.decide(input(
            controls: [.genericStop],
            composerSend: true
        ))
        expect(unrelatedStop.state == .unknown, "generic stop elsewhere cannot imply running")
        let localGenericStop = WindowStateRules.decide(input(
            controls: [.genericStop],
            composerGenericStop: true
        ))
        expect(localGenericStop.state == .running, "locally grouped generic stop is only a candidate")

        let firstMissing = WindowStateRules.decide(input(
            controls: [],
            composerSend: true,
            wasRunning: true
        ))
        expect(firstMissing.state == .unknown && firstMissing.completionUnverified && firstMissing.completeMisses == 1, "first completion candidate stays unknown")
        expect(firstMissing.source == "ax_window_level_completion_unverified_v1", "first candidate carries the fixed unverified source")

        let secondMissing = WindowStateRules.decide(input(
            controls: [],
            composerSend: true,
            wasRunning: true,
            completeMisses: 1
        ))
        expect(secondMissing.state == .unknown && secondMissing.completionUnverified && !secondMissing.wasRunning, "second complete candidate remains nonterminal unknown")
        expect(secondMissing.state.eventState == .unknown, "completion candidates never map to responseEnded")
        expect(secondMissing.source == "ax_window_level_completion_unverified_v1", "completion candidate has a fixed unverified source")

        let incomplete = WindowStateRules.decide(input(
            controls: [],
            composerSend: true,
            wasRunning: true,
            completeMisses: 1,
            collectionComplete: false
        ))
        expect(incomplete.state == .unknown && incomplete.completeMisses == 0, "incomplete collection resets the completion streak")
        expect(!WindowStateRules.shouldEmit(.unknown, collectionComplete: false), "incomplete scan retains the last visible state")
        expect(WindowStateRules.shouldEmit(.running, collectionComplete: false), "strong positive signal may still be reported")
        expect(!WindowStateRules.shouldEmit(.unknown, collectionComplete: false), "incomplete scan cannot emit a completion candidate")
        expect(WindowStateRules.shouldEmit(.unknown, collectionComplete: true), "complete candidate emits only its unknown evidence")

        let approval = WindowStateRules.decide(input(
            dialogControls: [.allow, .deny],
            hasDialog: true
        ))
        expect(approval.state == .waitingApproval, "dialog with allow and deny pair")

        let choiceDialog = WindowStateRules.decide(input(
            controls: [.stopGeneration],
            dialogControls: [.send],
            hasDialog: true,
            composerSend: true,
            wasRunning: true,
            completeMisses: 1
        ))
        expect(choiceDialog.state == .unknown && choiceDialog.completeMisses == 0, "unrecognized dialog does not guess")

        let pairOutsideDialog = WindowStateRules.decide(input(dialogControls: [.approve, .reject]))
        expect(pairOutsideDialog.state == .unknown, "approval words outside a dialog are not enough")

        print("PASS: window candidate rules")
    }

    private static func input(
        controls: Set<WindowControlSignal> = [],
        dialogControls: Set<WindowControlSignal> = [],
        hasDialog: Bool = false,
        composerSend: Bool = false,
        composerSpecificStop: Bool = false,
        composerGenericStop: Bool = false,
        wasRunning: Bool = false,
        completeMisses: Int = 0,
        collectionComplete: Bool = true
    ) -> WindowRuleInput {
        WindowRuleInput(
            controls: controls,
            dialogControls: dialogControls,
            hasDialog: hasDialog,
            composerSend: composerSend,
            composerSpecificStop: composerSpecificStop,
            composerGenericStop: composerGenericStop,
            wasRunning: wasRunning,
            completeMisses: completeMisses,
            collectionComplete: collectionComplete
        )
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, "CHECK FAILED: \(message)")
    }
}
