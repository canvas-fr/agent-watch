import Foundation
import AgentWatchCore

// GeminiEvents only consumes these two WindowScan fields. This minimal
// fixture keeps the reducer check independent of a live AppKit window scan.
struct WindowScan: Sendable {
    let events: [MonitorEvent]
    let diagnostics: [String: String]
}

@main
private struct GeminiRuleFixtures {
    static let completeControls = [
        "thumb-up-unselected", "thumb-down-unselected", "copy-button", "regen"
    ]

    static func main() {
        messageAreaRequiresTheNativeMessagePath()
        sidebarChildTruncationDoesNotInvalidateTheSnapshot()
        incompleteLatestCellNeverFallsBackToOlderFeedback()
        roleOnlyDiagnosticsStayOnTheAllowlist()
        windowCoverageDistinguishesGapsFromClosure()
        normalCompletionNeedsTwoStableReads()
        normalCompletionInNewSlotNeedsTwoStableReads()
        cancelledLatestRowCannotReuseOlderFeedback()
        scrolledHistoryCannotComplete()
        remountedOldSlotCannotComplete()
        sameNameSelectionChangeBreaksContinuity()
        incompleteTreeResetsTheRun()
        windowListGapRequiresAFreshStop()
        unboundStopShowsRunningButCannotEnd()
        eventCursorSurvivesTransientWindowListGap()
        print("Gemini lifecycle fixtures passed")
    }

    private static func messageAreaRequiresTheNativeMessagePath() {
        let messageAncestors = [
            "AXWindow", "AXSplitGroup", "AXGroup", "AXScrollArea", "AXGroup", "AXRow"
        ]
        precondition(GeminiAXStructureRules.isMessageListGroup(
            role: "AXGroup",
            ancestorRoles: ["AXWindow", "AXSplitGroup", "AXGroup", "AXScrollArea"]
        ))
        precondition(GeminiAXStructureRules.isMessageCell(role: "AXCell", ancestorRoles: messageAncestors))
        let messagePaths = [[], [0], [0, 1], [0, 1, 0], [0, 1, 0, 0], [0, 1, 0, 0, 0]]
        precondition(GeminiAXStructureRules.isMessageListGroup(
            role: "AXGroup",
            ancestorRoles: ["AXWindow", "AXSplitGroup", "AXGroup", "AXScrollArea"],
            ancestorChildIndexes: Array(messagePaths.prefix(4))
        ), "the right split pane message area is accepted")
        let leftMessagePaths = [[], [0], [0, 0], [0, 0, 0], [0, 0, 0, 0]]
        precondition(!GeminiAXStructureRules.isMessageListGroup(
            role: "AXGroup",
            ancestorRoles: ["AXWindow", "AXSplitGroup", "AXGroup", "AXScrollArea"],
            ancestorChildIndexes: leftMessagePaths
        ), "the left split pane is never selected as the message area")
        precondition(!GeminiAXStructureRules.isMessageCell(
            role: "AXRow", ancestorRoles: messageAncestors
        ))
        precondition(!GeminiAXStructureRules.isMessageCell(
            role: "AXCell", ancestorRoles: ["AXWindow", "AXScrollArea", "AXRow"]
        ))

        for sidebarRole in ["AXOutline", "AXList", "AXTable"] {
            let sidebarAncestors = ["AXWindow", sidebarRole] + messageAncestors.dropFirst()
            precondition(!GeminiAXStructureRules.isMessageListGroup(
                role: "AXGroup", ancestorRoles: ["AXWindow", sidebarRole, "AXScrollArea"]
            ))
            precondition(!GeminiAXStructureRules.isMessageCell(
                role: "AXCell", ancestorRoles: sidebarAncestors
            ))
        }
    }

    private static func sidebarChildTruncationDoesNotInvalidateTheSnapshot() {
        precondition(!GeminiAXStructureRules.childLimitInvalidatesSnapshot(
            role: "AXOutline", ancestorRoles: ["AXWindow"], truncated: true
        ))
        precondition(!GeminiAXStructureRules.childLimitInvalidatesSnapshot(
            role: "AXGroup", ancestorRoles: ["AXWindow", "AXList"], truncated: true
        ))
        precondition(GeminiAXStructureRules.childLimitInvalidatesSnapshot(
            role: "AXGroup", ancestorRoles: ["AXWindow", "AXScrollArea"], truncated: true
        ))
        precondition(!GeminiAXStructureRules.childLimitInvalidatesSnapshot(
            role: "AXGroup", ancestorRoles: ["AXWindow", "AXScrollArea"], truncated: false
        ))
    }

    private static func incompleteLatestCellNeverFallsBackToOlderFeedback() {
        precondition(GeminiAXStructureRules.shouldStopOlderRowSearch(
            rowHadCell: true, rowHadUnverifiedContainer: false, assistantBodyFound: false
        ))
        precondition(GeminiAXStructureRules.shouldStopOlderRowSearch(
            rowHadCell: false, rowHadUnverifiedContainer: true, assistantBodyFound: false
        ))
        precondition(GeminiAXStructureRules.shouldStopOlderRowSearch(
            rowHadCell: false, rowHadUnverifiedContainer: false, assistantBodyFound: true
        ))
        precondition(!GeminiAXStructureRules.shouldStopOlderRowSearch(
            rowHadCell: false, rowHadUnverifiedContainer: false, assistantBodyFound: false
        ))

        precondition(GeminiAssistantSlotRules.isBodyRole("AXHeading"))
        precondition(GeminiAssistantSlotRules.isBodyRole("AXTextArea"))
        precondition(GeminiAssistantSlotRules.isAssistantBodySlot(
            hasGroup: true, hasBodyStaticText: false, hasOtherBodyRole: true
        ))
        precondition(!GeminiAssistantSlotRules.isAssistantBodySlot(
            hasGroup: false, hasBodyStaticText: false, hasOtherBodyRole: true
        ), "a text-area role alone is not a response-body candidate")
        let headingSlot = GeminiAssistantSlotRules.latestAssistantSlot(in: [
            GeminiAssistantSlotDescriptor(slotID: "latest-heading", hasGroup: true,
                                          hasBodyStaticText: false, hasOtherBodyRole: true,
                                          controls: [])
        ])
        precondition(headingSlot?.slotID == "latest-heading")

        var state = GeminiLifecycleRuleState()
        expect(.running, GeminiLifecycleRules.decide(frame(slot: "active-slot", stop: true), state: &state))
        let latestHeadingOnly = frame(slot: "latest-heading-cell", controls: [], order: 3)
        expect(.unknown, GeminiLifecycleRules.decide(latestHeadingOnly, state: &state))
        expect(.unknown, GeminiLifecycleRules.decide(latestHeadingOnly, state: &state))
    }

    private static func roleOnlyDiagnosticsStayOnTheAllowlist() {
        let path = GeminiAXStructureRules.diagnosticRolePath([
            "AXWindow", "AXScrollArea", "AXList", "AXRow", "AXCell", "PrivateRoleName"
        ])
        precondition(path == "AXWindow>AXScrollArea>AXList>AXRow>AXCell>AXOther")
        precondition(!path.contains("PrivateRoleName"))

        let splitRoles = ["AXWindow", "AXSplitGroup", "AXGroup"]
        let leftPath = [[], [0], [0, 0]]
        let rightPath = [[], [0], [0, 1]]
        precondition(GeminiAXStructureRules.isVerifiedSidebarContainer(
            role: "AXOutline", ancestorRoles: splitRoles, ancestorChildIndexes: leftPath
        ))
        precondition(!GeminiAXStructureRules.isVerifiedSidebarContainer(
            role: "AXTable", ancestorRoles: splitRoles, ancestorChildIndexes: rightPath
        ))
        precondition(!GeminiAXStructureRules.isVerifiedSidebarContainer(
            role: "AXList", ancestorRoles: splitRoles, ancestorChildIndexes: leftPath,
            insideValidatedMessageCell: true
        ), "a list nested in a validated response cell is content, never a sidebar")
        let longPath = GeminiAXStructureRules.diagnosticRolePath(Array(repeating: "AXGroup", count: 20))
        precondition(longPath.split(separator: ">").count == 10)
    }

    private static func windowCoverageDistinguishesGapsFromClosure() {
        precondition(GeminiWindowGapRules.shouldPreserveUnseenWindow(
            processID: 9, activeProcessIDs: [9], enumeratedProcessIDs: []
        ), "an active process with a failed or unattempted AXWindows query is a gap")
        precondition(!GeminiWindowGapRules.shouldPreserveUnseenWindow(
            processID: 9, activeProcessIDs: [9], enumeratedProcessIDs: [9]
        ), "a successful empty AXWindows list proves that old windows are gone")
        precondition(!GeminiWindowGapRules.shouldPreserveUnseenWindow(
            processID: 9, activeProcessIDs: [], enumeratedProcessIDs: []
        ), "an exited process must be pruned")
        precondition(GeminiWindowGapRules.isWindowScanGap(reason: "window_not_scanned_budget"))
        precondition(GeminiWindowGapRules.isWindowScanGap(reason: "window_limit_not_scanned"))
        precondition(!GeminiWindowGapRules.isWindowScanGap(reason: "ax_tree_incomplete"))
    }

    private static func normalCompletionNeedsTwoStableReads() {
        var state = GeminiLifecycleRuleState()
        let running = frame(slot: "assistant-slot-2", stop: true)
        expect(.running, GeminiLifecycleRules.decide(running, state: &state))

        let firstEnd = frame(slot: "assistant-slot-2", controls: completeControls)
        expect(.unknown, GeminiLifecycleRules.decide(firstEnd, state: &state))
        expect(.responseEndedInferred, GeminiLifecycleRules.decide(firstEnd, state: &state))
    }

    private static func normalCompletionInNewSlotNeedsTwoStableReads() {
        var state = GeminiLifecycleRuleState()
        expect(.running, GeminiLifecycleRules.decide(
            frame(slot: "assistant-slot-old", controls: completeControls, stop: true, order: 4),
            state: &state
        ))
        let newResponse = frame(slot: "assistant-slot-new", controls: completeControls, order: 6)
        expect(.unknown, GeminiLifecycleRules.decide(newResponse, state: &state))
        expect(.responseEndedInferred, GeminiLifecycleRules.decide(newResponse, state: &state))
    }

    private static func cancelledLatestRowCannotReuseOlderFeedback() {
        var state = GeminiLifecycleRuleState()
        let oldCompletedSlot = frame(slot: "assistant-slot-1", controls: completeControls)
        expect(.unknown, GeminiLifecycleRules.decide(oldCompletedSlot, state: &state))
        expect(.running, GeminiLifecycleRules.decide(
            frame(slot: "assistant-slot-cancelled", stop: true), state: &state
        ))

        // Select by assistant-body structure, never by which old rows have buttons.
        let latestSlot = GeminiAssistantSlotRules.latestAssistantSlot(in: [
            GeminiAssistantSlotDescriptor(slotID: "assistant-slot-1", hasGroup: true,
                                          hasBodyStaticText: true, controls: completeControls),
            GeminiAssistantSlotDescriptor(slotID: "assistant-slot-cancelled", hasGroup: true,
                                          hasBodyStaticText: true, controls: []),
            GeminiAssistantSlotDescriptor(slotID: "disclaimer", hasGroup: true,
                                          hasBodyStaticText: false, controls: [])
        ])
        precondition(latestSlot?.slotID == "assistant-slot-cancelled")
        let cancelledLatest = frame(slot: latestSlot!.slotID, controls: latestSlot!.controls)
        expect(.unknown, GeminiLifecycleRules.decide(cancelledLatest, state: &state))
        expect(.unknown, GeminiLifecycleRules.decide(cancelledLatest, state: &state))
    }

    private static func scrolledHistoryCannotComplete() {
        var state = GeminiLifecycleRuleState()
        expect(.running, GeminiLifecycleRules.decide(
            frame(slot: "assistant-slot-2", stop: true), state: &state
        ))
        let oldVisibleRow = frame(slot: "assistant-slot-1", controls: completeControls, atBottom: false)
        expect(.unknown, GeminiLifecycleRules.decide(oldVisibleRow, state: &state))
        expect(.unknown, GeminiLifecycleRules.decide(oldVisibleRow, state: &state))
    }

    private static func remountedOldSlotCannotComplete() {
        var state = GeminiLifecycleRuleState()
        expect(.running, GeminiLifecycleRules.decide(
            frame(slot: "assistant-slot-4", controls: completeControls, stop: true, order: 4),
            state: &state
        ))
        let remountedOldSlot = frame(slot: "remounted-assistant-slot-4",
                                     controls: completeControls, order: 4)
        expect(.unknown, GeminiLifecycleRules.decide(remountedOldSlot, state: &state))
        expect(.unknown, GeminiLifecycleRules.decide(remountedOldSlot, state: &state))
    }

    private static func sameNameSelectionChangeBreaksContinuity() {
        let epochMustAdvance = GeminiContinuityRules.shouldAdvanceEpoch(
            hasSeenFrame: true,
            wasContinuityKnown: true,
            isContinuityKnown: true,
            previousSessionFingerprint: nil,
            currentSessionFingerprint: nil,
            hasConversationRoute: false,
            selectedSidebarRowEqual: false // AXUIElement CFEqual changed; title is never read.
        )
        precondition(epochMustAdvance, "a changed selected-row AX element must end continuity")

        var state = GeminiLifecycleRuleState()
        expect(.running, GeminiLifecycleRules.decide(
            frame(slot: "assistant-slot-2", stop: true), state: &state
        ))

        // The AX collector increments this epoch after that same-name row switch.
        let switchedChat = frame(slot: "assistant-slot-1", controls: completeControls,
                                 epoch: 1)
        expect(.unknown, GeminiLifecycleRules.decide(switchedChat, state: &state))
        expect(.unknown, GeminiLifecycleRules.decide(switchedChat, state: &state))
    }

    private static func incompleteTreeResetsTheRun() {
        var state = GeminiLifecycleRuleState()
        expect(.running, GeminiLifecycleRules.decide(
            frame(slot: "assistant-slot-2", stop: true), state: &state
        ))
        let clipped = GeminiLifecycleRuleFrame(
            windowIdentity: "window-a", continuityEpoch: 0, scope: .conversation,
            treeComplete: false, stopVisible: false, latestAssistantSlotID: "assistant-slot-2",
            latestAssistantSlotOrder: 2,
            latestAssistantControls: completeControls, latestAssistantAtBottom: true
        )
        expect(.unknown, GeminiLifecycleRules.decide(clipped, state: &state))
        expect(.unknown, GeminiLifecycleRules.decide(
            frame(slot: "assistant-slot-2", controls: completeControls), state: &state
        ))
    }

    private static func windowListGapRequiresAFreshStop() {
        var state = GeminiLifecycleRuleState()
        expect(.running, GeminiLifecycleRules.decide(
            frame(slot: "before-gap", stop: true), state: &state
        ))

        GeminiLifecycleRules.resetAfterWindowListGap(state: &state)
        let endedDuringUnknownGap = frame(slot: "after-gap", controls: completeControls)
        expect(.unknown, GeminiLifecycleRules.decide(endedDuringUnknownGap, state: &state))
        expect(.unknown, GeminiLifecycleRules.decide(endedDuringUnknownGap, state: &state))

        expect(.running, GeminiLifecycleRules.decide(
            frame(slot: "fresh-run", stop: true), state: &state
        ))
        let freshCompletion = frame(slot: "fresh-run", controls: completeControls)
        expect(.unknown, GeminiLifecycleRules.decide(freshCompletion, state: &state))
        expect(.responseEndedInferred, GeminiLifecycleRules.decide(freshCompletion, state: &state))
    }

    private static func unboundStopShowsRunningButCannotEnd() {
        var state = GeminiLifecycleRuleState()
        let running = GeminiLifecycleRuleFrame(
            windowIdentity: "window-unbound", continuityEpoch: 0, scope: .unbound,
            treeComplete: false, stopVisible: true, latestAssistantSlotID: nil,
            latestAssistantSlotOrder: nil, latestAssistantControls: [], latestAssistantAtBottom: false
        )
        expect(.running, GeminiLifecycleRules.decide(running, state: &state))

        let stopGone = GeminiLifecycleRuleFrame(
            windowIdentity: "window-unbound", continuityEpoch: 0, scope: .unbound,
            treeComplete: false, stopVisible: false, latestAssistantSlotID: "unverified-slot",
            latestAssistantSlotOrder: 99, latestAssistantControls: completeControls,
            latestAssistantAtBottom: true
        )
        expect(.unknown, GeminiLifecycleRules.decide(stopGone, state: &state))
        expect(.unknown, GeminiLifecycleRules.decide(stopGone, state: &state))
    }

    private static func eventCursorSurvivesTransientWindowListGap() {
        let reducer = GeminiEventReducer()
        let window = "stable-window"
        let started = reducer.apply(scan(observations: [
            observation(window: window, state: .running, reason: "stop_button_visible")
        ]))
        guard let initial = started.events.first else {
            preconditionFailure("expected an initial running event")
        }

        let gap = reducer.apply(scan(observations: [], preservedWindows: [window],
                                     health: "window_list_unavailable"))
        precondition(gap.events.isEmpty, "a transient AXWindows failure must not sweep the cursor")

        let gapHeartbeat = reducer.apply(scan(observations: [
            observation(window: window, state: .unknown, reason: "window_list_unavailable")
        ], preservedWindows: [window], health: "window_list_unavailable"))
        guard let unknownHeartbeat = gapHeartbeat.events.first else {
            preconditionFailure("a transient window-list failure should emit an unknown heartbeat")
        }
        precondition(unknownHeartbeat.sessionID == initial.sessionID)
        precondition(unknownHeartbeat.turnID == initial.turnID)
        precondition(unknownHeartbeat.state == .unknown)

        let recovered = reducer.apply(scan(observations: [
            observation(window: window, state: .unknown, reason: "window_list_unavailable")
        ]))
        guard let resumed = recovered.events.first else {
            preconditionFailure("expected a same-window recovery heartbeat")
        }
        precondition(resumed.sessionID == initial.sessionID)
        precondition(resumed.turnID == initial.turnID)
        precondition(resumed.state == .unknown)

        let closed = reducer.apply(scan(observations: [], preservedWindows: []))
        guard let closedEvent = closed.events.first else {
            preconditionFailure("a successfully enumerated empty window list must close the cursor")
        }
        precondition(closedEvent.sessionID == initial.sessionID)
        precondition(closedEvent.source == "ax:gemini:window_unobservable")
    }

    private static func scan(observations: [GeminiObservation],
                             preservedWindows: Set<String> = [],
                             health: String = "snapshot_complete") -> GeminiObservationScan {
        GeminiObservationScan(observations: observations, snapshotDiagnostics: [],
                              health: health,
                              preservedWindowIdentities: preservedWindows)
    }

    private static func observation(window: String, state: GeminiObservedState,
                                    reason: String) -> GeminiObservation {
        let diagnostic = GeminiSnapshotDiagnostic(
            processID: 9, windowIndex: 0, complete: state != .unknown, reason: reason,
            failingRole: nil, failingAttribute: nil, axErrorCode: nil, elementsVisited: 0,
            roleCounts: [:], candidateCellAncestorRolePaths: [:],
            candidateCellChildRoleCounts: [:], unverifiedContainerRolePaths: [:],
            knownControlPresence: ["stop": state == .running], selectedSidebarRows: 1,
            sidebarScopeFound: true, messageAreaFound: false, messageAtBottom: false,
            scrollBarValue: nil, tailWindowed: false, elapsedMilliseconds: 0
        )
        return GeminiObservation(
            appID: "gemini", build: "fixture", processID: 9, windowIndex: 0,
            windowIdentity: window, continuityEpoch: 0, sessionFingerprint: nil,
            scope: .windowContinuity, state: state, reason: reason,
            taskToolbarCompleted: false, responseControls: [], isHeartbeat: true,
            snapshotDiagnostic: diagnostic, observedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private static func frame(
        slot: String,
        controls: [String] = [],
        stop: Bool = false,
        atBottom: Bool = true,
        order: Int = 2,
        epoch: UInt64 = 0,
        scope: GeminiObservationScope = .conversation,
        treeComplete: Bool = true
    ) -> GeminiLifecycleRuleFrame {
        GeminiLifecycleRuleFrame(
            windowIdentity: "window-a", continuityEpoch: epoch, scope: scope,
            treeComplete: treeComplete, stopVisible: stop, latestAssistantSlotID: slot,
            latestAssistantSlotOrder: order,
            latestAssistantControls: controls, latestAssistantAtBottom: atBottom
        )
    }

    private static func expect(_ expected: GeminiObservedState, _ actual: GeminiLifecycleRuleDecision,
                               file: StaticString = #file, line: UInt = #line) {
        precondition(expected == actual.state,
                     "expected \(expected.rawValue), got \(actual.state.rawValue) (\(actual.reason))",
                     file: file, line: line)
    }
}
