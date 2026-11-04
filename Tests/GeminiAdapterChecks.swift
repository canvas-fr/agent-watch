import Foundation

@main
private struct GeminiRuleFixtures {
    static let completeControls = [
        "thumb-up-unselected", "thumb-down-unselected", "copy-button", "regen"
    ]

    static func main() {
        messageAreaRequiresTheNativeMessagePath()
        sidebarChildTruncationDoesNotInvalidateTheSnapshot()
        normalCompletionNeedsTwoStableReads()
        normalCompletionInNewSlotNeedsTwoStableReads()
        cancelledLatestRowCannotReuseOlderFeedback()
        scrolledHistoryCannotComplete()
        remountedOldSlotCannotComplete()
        sameNameSelectionChangeBreaksContinuity()
        incompleteTreeResetsTheRun()
        unboundStopShowsRunningButCannotEnd()
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
