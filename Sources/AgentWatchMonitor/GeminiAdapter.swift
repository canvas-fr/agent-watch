import AppKit
import ApplicationServices
import CryptoKit
import Foundation

// Read-only, version-pinned observer for the installed Gemini macOS app.
// It never reads AXTitle, message text, clipboard data, or screenshots. The
// only AXValue read is the numeric AXScrollBar position for bottom visibility.
// It never performs an AX action or activates the target application.

public enum GeminiObservationScope: String, Sendable {
    case conversation
    case windowContinuity = "window_continuity"
    case unbound
}

public enum GeminiObservedState: String, Sendable {
    case unknown
    case running
    case responseEndedInferred = "response_ended_inferred"
    case responseEndedInferredWindow = "response_ended_inferred_window"
}

/// Safe AX debug summary. It contains only fixed role/attribute names, counts,
/// error codes and numeric scroll position; never titles, body text or AX IDs.
public struct GeminiSnapshotDiagnostic: Codable, Sendable {
    public let processID: Int32?
    public let windowIndex: Int?
    public let complete: Bool
    public let reason: String
    public let failingRole: String?
    public let failingAttribute: String?
    public let axErrorCode: Int32?
    public let elementsVisited: Int
    public let roleCounts: [String: Int]
    public let selectedSidebarRows: Int
    public let sidebarScopeFound: Bool
    public let messageAreaFound: Bool
    public let messageAtBottom: Bool
    public let scrollBarValue: Double?
    public let tailWindowed: Bool
    public let elapsedMilliseconds: Int
}

public struct GeminiObservation: Sendable {
    public let appID: String
    public let build: String
    public let processID: Int32?
    public let windowIndex: Int?
    /// Random, process-local identity tracked by CFEqual across window reordering.
    public let windowIdentity: String?
    /// Increments when window/session continuity is lost or the selected row changes.
    public let continuityEpoch: UInt64
    /// SHA-256 of an allowlisted conversation route ID. The raw ID is never returned.
    public let sessionFingerprint: String?
    /// Window-scoped observations are explicitly ephemeral and have no session ID.
    public let scope: GeminiObservationScope
    public let state: GeminiObservedState
    public let reason: String
    public let taskToolbarCompleted: Bool
    /// Contains only allowlisted accessibility identifiers, never descriptions.
    public let responseControls: [String]
    /// Every scan returns a snapshot so downstream freshness can be refreshed.
    public let isHeartbeat: Bool
    public let snapshotDiagnostic: GeminiSnapshotDiagnostic
    public let observedAt: Date
}

public struct GeminiObservationScan: Sendable {
    public let observations: [GeminiObservation]
    public let snapshotDiagnostics: [GeminiSnapshotDiagnostic]
    public let health: String
}

public struct GeminiLifecycleRuleFrame: Sendable {
    public let windowIdentity: String
    public let continuityEpoch: UInt64
    public let scope: GeminiObservationScope
    public let treeComplete: Bool
    public let stopVisible: Bool
    public let latestAssistantSlotID: String?
    public let latestAssistantSlotOrder: Int?
    public let latestAssistantControls: [String]
    public let latestAssistantAtBottom: Bool

    public init(windowIdentity: String, continuityEpoch: UInt64, scope: GeminiObservationScope,
                treeComplete: Bool, stopVisible: Bool, latestAssistantSlotID: String?,
                latestAssistantSlotOrder: Int?,
                latestAssistantControls: [String], latestAssistantAtBottom: Bool) {
        self.windowIdentity = windowIdentity
        self.continuityEpoch = continuityEpoch
        self.scope = scope
        self.treeComplete = treeComplete
        self.stopVisible = stopVisible
        self.latestAssistantSlotID = latestAssistantSlotID
        self.latestAssistantSlotOrder = latestAssistantSlotOrder
        self.latestAssistantControls = latestAssistantControls
        self.latestAssistantAtBottom = latestAssistantAtBottom
    }
}

public struct GeminiLifecycleRuleState: Sendable {
    fileprivate var windowIdentity: String?
    fileprivate var continuityEpoch: UInt64?
    fileprivate var runningSeen = false
    fileprivate var awaitingEndEvidence = false
    fileprivate var baselineSlotID: String?
    fileprivate var baselineSlotOrder: Int?
    fileprivate var baselineControls: Set<String> = []
    fileprivate var candidateSignature: String?
    fileprivate var candidateReads = 0
    fileprivate var lastState: GeminiObservedState = .unknown

    public init() {}
}

public struct GeminiLifecycleRuleDecision: Sendable {
    public let state: GeminiObservedState
    public let reason: String
}

public struct GeminiAssistantSlotDescriptor: Sendable {
    public let slotID: String
    public let hasGroup: Bool
    public let hasBodyStaticText: Bool
    public let controls: [String]

    public init(slotID: String, hasGroup: Bool, hasBodyStaticText: Bool, controls: [String]) {
        self.slotID = slotID
        self.hasGroup = hasGroup
        self.hasBodyStaticText = hasBodyStaticText
        self.controls = controls
    }
}

public enum GeminiAssistantSlotRules {
    public static func isAssistantBodySlot(hasGroup: Bool, hasBodyStaticText: Bool) -> Bool {
        hasGroup && hasBodyStaticText
    }

    /// Input order is oldest to newest. Controls do not affect slot selection.
    public static func latestAssistantSlot(
        in orderedSlots: [GeminiAssistantSlotDescriptor]
    ) -> GeminiAssistantSlotDescriptor? {
        orderedSlots.last(where: { isAssistantBodySlot(hasGroup: $0.hasGroup,
                                                       hasBodyStaticText: $0.hasBodyStaticText) })
    }
}

public enum GeminiAXStructureRules {
    private static let sidebarRoles: Set<String> = ["AXList", "AXOutline", "AXTable"]

    public static func isSidebarRole(_ role: String) -> Bool {
        sidebarRoles.contains(role)
    }

    public static func isSidebarBranch(role: String, ancestorRoles: [String]) -> Bool {
        isSidebarRole(role) || ancestorRoles.contains(where: isSidebarRole)
    }

    public static func isMessageListGroup(role: String, ancestorRoles: [String]) -> Bool {
        role == "AXGroup"
            && ancestorRoles.last == "AXScrollArea"
            && !ancestorRoles.contains(where: isSidebarRole)
    }

    public static func isMessageCell(role: String, ancestorRoles: [String]) -> Bool {
        role == "AXCell"
            && Array(ancestorRoles.suffix(3)) == ["AXScrollArea", "AXGroup", "AXRow"]
            && !ancestorRoles.contains(where: isSidebarRole)
    }

    public static func childLimitInvalidatesSnapshot(
        role: String,
        ancestorRoles: [String],
        truncated: Bool
    ) -> Bool {
        truncated && !isSidebarBranch(role: role, ancestorRoles: ancestorRoles)
    }
}

/// Pure identity comparison; display titles never participate in continuity.
public enum GeminiContinuityRules {
    public static func shouldAdvanceEpoch(
        hasSeenFrame: Bool,
        wasContinuityKnown: Bool,
        isContinuityKnown: Bool,
        previousSessionFingerprint: String?,
        currentSessionFingerprint: String?,
        hasConversationRoute: Bool,
        selectedSidebarRowEqual: Bool
    ) -> Bool {
        guard hasSeenFrame else { return false }
        if wasContinuityKnown != isContinuityKnown { return true }
        if previousSessionFingerprint != currentSessionFingerprint { return true }
        return !hasConversationRoute && !selectedSidebarRowEqual
    }
}

/// Pure transition rule. It consumes only a validated latest assistant slot,
/// never message text, titles, or a global scan of old response controls.
public enum GeminiLifecycleRules {
    private static let feedbackIDs: Set<String> = ["thumb-up-unselected", "thumb-down-unselected"]
    private static let supportingIDs: Set<String> = ["copy-button", "regen", "regen_button"]

    public static func decide(
        _ frame: GeminiLifecycleRuleFrame,
        state: inout GeminiLifecycleRuleState
    ) -> GeminiLifecycleRuleDecision {
        if state.windowIdentity != frame.windowIdentity || state.continuityEpoch != frame.continuityEpoch {
            state = GeminiLifecycleRuleState()
            state.windowIdentity = frame.windowIdentity
            state.continuityEpoch = frame.continuityEpoch
        }

        if frame.stopVisible && frame.scope == .unbound {
            state.resetTurn()
            state.runningSeen = true
            state.lastState = .running
            return .init(state: .running, reason: "stop_button_visible_window_only")
        }

        if frame.stopVisible && !frame.treeComplete {
            state.resetTurn()
            state.runningSeen = true
            state.lastState = .running
            return .init(state: .running, reason: "stop_button_visible_partial_tree")
        }

        guard frame.treeComplete else {
            state.resetTurn()
            state.lastState = .unknown
            return .init(state: .unknown, reason: "ax_tree_incomplete")
        }
        guard frame.scope != .unbound else {
            state.resetTurn()
            state.lastState = .unknown
            return .init(state: .unknown, reason: "no_route_or_selected_sidebar_identity")
        }

        if frame.stopVisible {
            // A stop control that returns after it disappeared marks a new run.
            if state.runningSeen && state.awaitingEndEvidence { state.resetTurn() }
            if !state.runningSeen {
                state.baselineSlotID = frame.latestAssistantSlotID
                state.baselineSlotOrder = frame.latestAssistantSlotOrder
                state.baselineControls = Set(frame.latestAssistantControls)
            }
            state.runningSeen = true
            state.awaitingEndEvidence = false
            state.candidateSignature = nil
            state.candidateReads = 0
            state.lastState = .running
            return .init(state: .running, reason: "stop_button_visible")
        }

        guard state.runningSeen else {
            if state.lastState == .responseEndedInferred || state.lastState == .responseEndedInferredWindow {
                return .init(state: state.lastState, reason: "same_window_continuity_after_inferred_end")
            }
            state.lastState = .unknown
            return .init(state: .unknown, reason: "no_verified_lifecycle_evidence")
        }
        state.awaitingEndEvidence = true

        let controls = Set(frame.latestAssistantControls)
        guard frame.latestAssistantAtBottom,
              let slotID = frame.latestAssistantSlotID,
              feedbackIDs.isSubset(of: controls),
              !supportingIDs.isDisjoint(with: controls),
              let baselineSlotID = state.baselineSlotID,
              let baselineSlotOrder = state.baselineSlotOrder,
              let currentSlotOrder = frame.latestAssistantSlotOrder else {
            state.candidateSignature = nil
            state.candidateReads = 0
            state.lastState = .unknown
            return .init(state: .unknown, reason: frame.latestAssistantAtBottom
                ? "stop_absent_without_new_latest_response_controls" : "latest_response_not_at_scroll_bottom")
        }

        let isNewSlot = slotID != baselineSlotID && currentSlotOrder > baselineSlotOrder
        let controlsAppearedInSameSlot = currentSlotOrder == baselineSlotOrder
            && !feedbackIDs.isSubset(of: state.baselineControls)
        guard isNewSlot || controlsAppearedInSameSlot else {
            state.lastState = .unknown
            return .init(state: .unknown, reason: "feedback_controls_preexisted_on_baseline_slot")
        }

        let signature = slotID + "|" + controls.sorted().joined(separator: ",")
        if state.candidateSignature == signature {
            state.candidateReads += 1
        } else {
            state.candidateSignature = signature
            state.candidateReads = 1
        }
        guard state.candidateReads >= 2 else {
            state.lastState = .unknown
            return .init(state: .unknown, reason: "awaiting_second_feedback_snapshot")
        }

        state.runningSeen = false
        state.awaitingEndEvidence = false
        state.candidateSignature = nil
        state.candidateReads = 0
        state.lastState = frame.scope == .conversation ? .responseEndedInferred : .responseEndedInferredWindow
        return .init(state: state.lastState, reason: "new_latest_feedback_controls_stable_for_two_reads")
    }
}

private extension GeminiLifecycleRuleState {
    mutating func resetTurn() {
        runningSeen = false
        awaitingEndEvidence = false
        baselineSlotID = nil
        baselineSlotOrder = nil
        baselineControls.removeAll()
        candidateSignature = nil
        candidateReads = 0
    }
}

/// Version-bound Gemini macOS adapter. Call `scan()` from the monitor loop.
/// Its AX reader and lifecycle tracker are serialized and retain no data on disk.
public final class GeminiAdapter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.agentwatch.gemini-adapter.ax", qos: .utility)
    private let snapshotter = GeminiAXSnapshotter()
    private let tracker = GeminiStatusTracker()

    public init() {}

    public func scan() -> GeminiObservationScan {
        queue.sync {
            let snapshot = snapshotter.frames()
            let statusEvents = tracker.update(snapshot.frames, globalReason: snapshot.globalReason)
            let observations = statusEvents.map { event in
                GeminiObservation(
                    appID: event.app,
                    build: event.build,
                    processID: event.pid,
                    windowIndex: event.window,
                    windowIdentity: event.windowIdentity,
                    continuityEpoch: event.continuityEpoch,
                    sessionFingerprint: event.session,
                    scope: GeminiObservationScope(rawValue: event.scope) ?? .unbound,
                    state: GeminiObservedState(rawValue: event.status) ?? .unknown,
                    reason: event.reason,
                    taskToolbarCompleted: event.taskToolbarCompleted,
                    responseControls: event.responseControls,
                    isHeartbeat: event.isHeartbeat,
                    snapshotDiagnostic: event.snapshotDiagnostic,
                    observedAt: event.observedAt
                )
            }
            let health = snapshot.globalReason
                ?? (snapshot.frames.allSatisfy(\.complete)
                    ? (snapshot.frames.contains(where: \.tailWindowed)
                        ? "snapshot_complete_latest_tail_windowed" : "snapshot_complete")
                    : "snapshot_partial")
            return GeminiObservationScan(observations: observations,
                                         snapshotDiagnostics: observations.map(\.snapshotDiagnostic),
                                         health: health)
        }
    }
}

private enum GeminiTarget {
    static let appPath = "/Applications/Gemini.app"
    static let bundleID = "com.google.GeminiMacOS"
    static let supportedBuild = "1.138.0.1315"

    static let safeButtonIdentifiers: Set<String> = [
        "stop_button",
        "mic_button",
        "more_button",
        "collapse_button",
        "thumb-up-unselected",
        "thumb-down-unselected",
        "copy-button",
        "regen",
        "regen_button"
    ]

    static let feedbackIdentifiers: Set<String> = [
        "thumb-up-unselected",
        "thumb-down-unselected"
    ]

    static let supportingResponseIdentifiers: Set<String> = [
        "copy-button",
        "regen",
        "regen_button"
    ]

    static let containerRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXToolbar", "AXGroup", "AXRow", "AXCell",
        "AXSplitGroup", "AXScrollArea", "AXList", "AXOutline",
        "AXTable", "AXTabGroup", "AXLayoutArea", "AXScrollBar", "AXUnknown"
    ]
}

private struct ProbeEvent {
    let app: String
    let build: String
    let pid: Int32?
    let window: Int?
    let windowIdentity: String?
    let continuityEpoch: UInt64
    let session: String?
    let scope: String
    let status: String
    let reason: String
    let taskToolbarCompleted: Bool
    let responseControls: [String]
    let isHeartbeat: Bool
    let snapshotDiagnostic: GeminiSnapshotDiagnostic
    let observedAt: Date
}

private struct ResponseRow {
    let key: String
    let order: Int
    let controls: Set<String>
    let element: AXUIElement
    let scrollArea: ContainerPath
    let scrollAtBottom: Bool

    static func == (left: ResponseRow, right: ResponseRow) -> Bool {
        left.key == right.key && left.order == right.order && left.controls == right.controls
            && left.scrollArea == right.scrollArea && left.scrollAtBottom == right.scrollAtBottom
    }
}

private struct GeminiFrame {
    let pid: Int32
    let windowIndex: Int
    let sessionFingerprint: String?
    let windowElement: AXUIElement
    let selectedSidebarRow: AXUIElement?
    let stopVisible: Bool
    let latestResponseRow: ResponseRow?
    let taskToolbarCompleted: Bool
    let complete: Bool
    let reason: String
    let tailWindowed: Bool
    let snapshotDiagnostic: GeminiSnapshotDiagnostic
}

private struct ContainerPath: Hashable {
    let role: String
    let childIndexes: [Int]

    var stableText: String {
        "\(role):" + childIndexes.map(String.init).joined(separator: ".")
    }
}

private struct ButtonOccurrence {
    let identifier: String?
    let element: AXUIElement
    let ancestors: [ContainerPath]
}

private struct ToolbarOccurrence {
    let depth: Int
    let path: ContainerPath
}

private struct ChildSlice {
    let elements: [AXUIElement]
    let startIndex: Int
    let totalCount: Int
    let skippedPrefix: Bool
    let truncated: Bool
}

private final class CellAccumulator {
    let element: AXUIElement
    let childIndexes: [Int]
    let scrollArea: ContainerPath
    var hasGroup = false
    var hasBodyStaticText = false
    var controls: Set<String> = []

    init(element: AXUIElement, childIndexes: [Int], scrollArea: ContainerPath) {
        self.element = element
        self.childIndexes = childIndexes
        self.scrollArea = scrollArea
    }
}

private struct AXReadFailure {
    let reason: String
    let role: String?
    let attribute: String?
    let errorCode: Int32?
}

private struct GeminiTreeDiagnostic {
    let reason: String
    let failingRole: String?
    let failingAttribute: String?
    let axErrorCode: Int32?
    let roleCounts: [String: Int]
    let selectedSidebarRows: Int
    let sidebarScopeFound: Bool
    let messageAreaFound: Bool
    let messageAtBottom: Bool
    let scrollBarValue: Double?
    let elementsVisited: Int
    let elapsedMilliseconds: Int
}

private struct AXElementArrayRead {
    let elements: [AXUIElement]
    let failure: String?
}

private func accessibilityElements(_ array: CFArray, expectedCount: Int? = nil) -> AXElementArrayRead {
    let count = CFArrayGetCount(array)
    if let expectedCount, count != expectedCount {
        return AXElementArrayRead(elements: [], failure: "array_count_mismatch")
    }
    var elements: [AXUIElement] = []
    elements.reserveCapacity(count)
    for index in 0..<count {
        guard let pointer = CFArrayGetValueAtIndex(array, index) else {
            return AXElementArrayRead(elements: [], failure: "array_element_missing")
        }
        let reference = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        guard CFGetTypeID(reference) == AXUIElementGetTypeID() else {
            return AXElementArrayRead(elements: [], failure: "array_element_wrong_type")
        }
        let element = Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
        elements.append(element)
    }
    return AXElementArrayRead(elements: elements, failure: nil)
}

private struct WindowTreeResult {
    var stopVisible = false
    var taskToolbarCompleted = false
    var assistantRows: [([Int], ResponseRow)] = []
    var scrollBarValues: [ContainerPath: Double] = [:]
    var messageAreaScrollArea: ContainerPath?
    var sidebarScopeFound = false
    var latestTailWindowed = false
    var complete = true
    var elementsVisited = 0
    var buttons: [ButtonOccurrence] = []
    var toolbars: [ToolbarOccurrence] = []
    var selectedSidebarRows: [AXUIElement] = []
    var diagnostic: GeminiTreeDiagnostic?
}

private final class WindowTreeReader {
    private let maxElements = 180
    private let maxDepth = 12
    private let maxChildren = 60
    private let messageTimeout: Float = 0.15
    private var deadline = 0.0
    private var collectSidebarIdentity = true
    private var startedAt = 0.0
    private var roleCounts: [String: Int] = [:]
    private var firstFailure: AXReadFailure?
    private var lastAXErrorCode: Int32?

    private let knownRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXDialog", "AXSheet", "AXGroup", "AXSplitGroup",
        "AXToolbar", "AXScrollArea", "AXScrollBar", "AXList", "AXOutline", "AXTable",
        "AXWebArea", "AXRow", "AXCell", "AXButton", "AXStaticText", "AXTextField", "AXTextArea",
        "AXHeading", "AXLink", "AXImage", "AXUnknown"
    ]

    func read(_ window: AXUIElement, deadline: TimeInterval,
              collectSidebarIdentity: Bool) -> WindowTreeResult {
        self.deadline = deadline
        self.collectSidebarIdentity = collectSidebarIdentity
        self.startedAt = systemUptime
        roleCounts.removeAll(keepingCapacity: true)
        firstFailure = nil
        lastAXErrorCode = nil
        var result = WindowTreeResult()
        guard configureTimeout(for: window, role: "AXWindow", attribute: nil) else {
            result.complete = false
            recordFailure("timeout_setup_failed", role: "AXWindow", attribute: nil,
                          errorCode: lastAXErrorCode)
            result.diagnostic = diagnostic(for: result)
            return result
        }
        walk(window, depth: 0, childIndexes: [], ancestors: [], cell: nil, result: &result)
        finish(result: &result)
        result.diagnostic = diagnostic(for: result)
        return result
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        childIndexes: [Int],
        ancestors: [ContainerPath],
        cell: CellAccumulator?,
        result: inout WindowTreeResult
    ) {
        guard result.elementsVisited < maxElements, depth <= maxDepth else {
            result.complete = false
            recordFailure(depth > maxDepth ? "depth_limit" : "element_limit",
                          role: nil, attribute: nil, errorCode: nil)
            return
        }
        guard configureTimeout(for: element, role: nil, attribute: nil) else {
            result.complete = false
            recordFailure("timeout_setup_failed", role: nil, attribute: nil, errorCode: lastAXErrorCode)
            return
        }
        result.elementsVisited += 1

        guard let role = stringAttribute(element, "AXRole", required: true) else {
            result.complete = false
            recordFailure("required_role_unavailable", role: nil, attribute: "AXRole",
                          errorCode: lastAXErrorCode)
            return
        }
        let safeRole = knownRoles.contains(role) ? role : "AXOther"
        roleCounts[safeRole, default: 0] += 1
        if depth == 0, role != "AXWindow" {
            result.complete = false
            recordFailure("unexpected_window_role", role: role, attribute: "AXRole", errorCode: nil)
            return
        }

        if role == "AXCell" {
            let ancestorRoles = ancestors.map(\.role)
            guard GeminiAXStructureRules.isMessageCell(role: role, ancestorRoles: ancestorRoles),
                  let scrollIndex = ancestors.lastIndex(where: { $0.role == "AXScrollArea" }) else { return }
            let scrollArea = ancestors[scrollIndex]
            let accumulator = CellAccumulator(element: element,
                                              childIndexes: childIndexes,
                                              scrollArea: scrollArea)
            walkChildren(of: element, role: role, depth: depth, childIndexes: childIndexes,
                         ancestors: ancestors, cell: accumulator, result: &result)
            if GeminiAssistantSlotRules.isAssistantBodySlot(
                hasGroup: accumulator.hasGroup,
                hasBodyStaticText: accumulator.hasBodyStaticText
            ) {
                result.messageAreaScrollArea = scrollArea
                result.assistantRows.append((childIndexes, ResponseRow(
                    key: ContainerPath(role: "AXCell", childIndexes: childIndexes).stableText,
                    order: childIndexes.dropLast().last ?? 0,
                    controls: accumulator.controls,
                    element: accumulator.element,
                    scrollArea: accumulator.scrollArea,
                    scrollAtBottom: false
                )))
            }
            return
        }
        if role == "AXScrollBar" {
            if let scrollArea = ancestors.last(where: { $0.role == "AXScrollArea" }),
               let value = numericValueAttribute(element, "AXValue") {
                result.scrollBarValues[scrollArea] = value
            }
            return
        }
        if GeminiAXStructureRules.isSidebarRole(role) {
            result.sidebarScopeFound = true
            collectSelectedSidebarRows(in: element, result: &result)
            return
        }
        if role == "AXButton" {
            inspectButton(element, ancestors: ancestors, cell: cell, result: &result)
            return
        }
        if role == "AXStaticText" {
            cell?.hasBodyStaticText = true
            return
        }
        // Gemini's main app is native SwiftUI. Embedded WebAreas are previews;
        // their controls must never be interpreted as the native composer.
        guard GeminiTarget.containerRoles.contains(role) else { return }

        let currentPath = ContainerPath(role: role, childIndexes: childIndexes)
        if role == "AXToolbar" {
            result.toolbars.append(ToolbarOccurrence(depth: depth, path: currentPath))
        }
        if role == "AXGroup" { cell?.hasGroup = true }

        let ancestorRoles = ancestors.map(\.role)
        let isMessageList = GeminiAXStructureRules.isMessageListGroup(
            role: role, ancestorRoles: ancestorRoles
        )
        guard let childrenResult = childElements(element, role: role, tailIfLarge: isMessageList) else {
            // Leaf or unsupported containers do not contain evidence. Marking the
            // snapshot incomplete prevents a partial AX read from ending a task.
            result.complete = false
            return
        }
        if GeminiAXStructureRules.childLimitInvalidatesSnapshot(
            role: role, ancestorRoles: ancestorRoles, truncated: childrenResult.truncated
        ) {
            result.complete = false
            recordFailure("child_limit_exceeded", role: role, attribute: "AXChildren", errorCode: nil)
        }
        if childrenResult.skippedPrefix { result.latestTailWindowed = true }

        if isMessageList {
            // This is the verified message-list role path. Read its newest rows
            // first and stop on the latest body-bearing assistant cell. Older
            // message cells cannot change which row is latest.
            let priorRowCount = result.assistantRows.count
            for offset in childrenResult.elements.indices.reversed() {
                let childIndex = childrenResult.startIndex + offset
                walk(childrenResult.elements[offset], depth: depth + 1,
                     childIndexes: childIndexes + [childIndex],
                     ancestors: ancestors + [currentPath], cell: cell, result: &result)
                if result.assistantRows.count > priorRowCount { break }
            }
            return
        }

        walkChildren(of: element, role: role, depth: depth, childIndexes: childIndexes,
                     ancestors: ancestors, cell: cell, result: &result,
                     knownChildren: childrenResult)
    }

    private func walkChildren(
        of element: AXUIElement,
        role: String,
        depth: Int,
        childIndexes: [Int],
        ancestors: [ContainerPath],
        cell: CellAccumulator?,
        result: inout WindowTreeResult,
        knownChildren: ChildSlice? = nil
    ) {
        let children: [AXUIElement]
        if let knownChildren {
            children = knownChildren.elements
        } else {
            guard let childrenResult = childElements(element, role: role) else {
                result.complete = false
                return
            }
            children = childrenResult.elements
            if GeminiAXStructureRules.childLimitInvalidatesSnapshot(
                role: role, ancestorRoles: ancestors.map(\.role), truncated: childrenResult.truncated
            ) {
                result.complete = false
                recordFailure("child_limit_exceeded", role: role, attribute: "AXChildren", errorCode: nil)
            }
            if childrenResult.skippedPrefix { result.latestTailWindowed = true }
        }
        let nextAncestors = ancestors + [ContainerPath(role: role,
                                                        childIndexes: childIndexes)]
        for (offset, child) in children.prefix(maxChildren).enumerated() {
            let index = (knownChildren?.startIndex ?? 0) + offset
            walk(child, depth: depth + 1, childIndexes: childIndexes + [index],
                 ancestors: nextAncestors, cell: cell, result: &result)
        }
    }

    private func inspectButton(
        _ element: AXUIElement,
        ancestors: [ContainerPath],
        cell: CellAccumulator?,
        result: inout WindowTreeResult
    ) {
        let identifier = stringAttribute(element, "AXIdentifier")
        result.buttons.append(ButtonOccurrence(identifier: identifier, element: element, ancestors: ancestors))
        if let identifier, GeminiTarget.safeButtonIdentifiers.contains(identifier) {
            cell?.controls.insert(identifier)
        }
        if identifier == "stop_button" { result.stopVisible = true }
    }

    private func isSelected(_ element: AXUIElement) -> Bool {
        var copied: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXSelected" as CFString, &copied)
        guard result == .success, let copied,
              CFGetTypeID(copied) == CFBooleanGetTypeID() else { return false }
        let value = unsafeDowncast(copied, to: CFBoolean.self)
        return CFBooleanGetValue(value)
    }

    private enum SelectedChildrenResult {
        case rows([AXUIElement])
        case unavailable
    }

    private func selectedChildren(_ element: AXUIElement) -> SelectedChildrenResult {
        guard quietlyConfigureTimeout(for: element) else { return .unavailable }
        var copied: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXSelectedChildren" as CFString, &copied)
        if result == .attributeUnsupported || result == .noValue { return .unavailable }
        guard result == .success, let copied,
              CFGetTypeID(copied) == CFArrayGetTypeID() else {
            return .unavailable
        }
        let arrayResult = accessibilityElements(unsafeDowncast(copied, to: CFArray.self))
        guard arrayResult.failure == nil else { return .unavailable }
        return .rows(arrayResult.elements)
    }

    private func collectSelectedSidebarRows(in element: AXUIElement,
                                            result: inout WindowTreeResult) {
        guard collectSidebarIdentity, result.selectedSidebarRows.count < 2 else { return }
        if case .rows(let rows) = selectedChildren(element) {
            for row in rows {
                guard quietlyConfigureTimeout(for: row),
                      stringAttribute(row, "AXRole") == "AXRow" else { continue }
                result.selectedSidebarRows.append(row)
                if result.selectedSidebarRows.count == 2 { return }
            }
            if !rows.isEmpty { return }
        }

        guard let rows = sidebarChildRows(in: element) else { return }
        for row in rows {
            guard quietlyConfigureTimeout(for: row),
                  stringAttribute(row, "AXRole") == "AXRow",
                  isSelected(row) else { continue }
            result.selectedSidebarRows.append(row)
            if result.selectedSidebarRows.count == 2 { return }
        }
    }

    private func sidebarChildRows(in element: AXUIElement) -> [AXUIElement]? {
        guard quietlyConfigureTimeout(for: element) else { return nil }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, "AXChildren" as CFString, &count) == .success,
              count > 0 else { return nil }
        let limit = min(count, CFIndex(maxChildren))
        var copied: CFArray?
        guard quietlyConfigureTimeout(for: element),
              AXUIElementCopyAttributeValues(element, "AXChildren" as CFString, 0, limit, &copied) == .success,
              let copied else { return nil }
        let result = accessibilityElements(copied, expectedCount: Int(limit))
        return result.failure == nil ? result.elements : nil
    }

    private func quietlyConfigureTimeout(for element: AXUIElement) -> Bool {
        let remaining = deadline - systemUptime
        guard remaining > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, min(messageTimeout, Float(remaining))) == .success
    }

    private func finish(result: inout WindowTreeResult) {
        // Only inspect a no-ID button within a toolbar when both known toolbar
        // controls are present. Compare the description in memory to one fixed
        // observed label; never emit that text.
        for toolbar in result.toolbars where toolbar.depth <= 5 {
            let toolbarButtons = result.buttons.filter { button in
                button.ancestors.contains(toolbar.path)
                    && button.ancestors.last.map { $0.childIndexes.count - toolbar.path.childIndexes.count <= 3 } == true
            }
            let knownIDs = Set(toolbarButtons.compactMap(\.identifier)
                .filter(GeminiTarget.safeButtonIdentifiers.contains))
            guard knownIDs.contains("more_button"), knownIDs.contains("collapse_button") else { continue }
            for button in toolbarButtons where button.identifier == nil {
                guard systemUptime < deadline else {
                    result.complete = false
                    recordFailure("scan_deadline_before_toolbar_label", role: "AXToolbar",
                                  attribute: "AXDescription", errorCode: nil)
                    return
                }
                if stringAttribute(button.element, "AXDescription") == "已完成" {
                    result.taskToolbarCompleted = true
                }
            }
        }

        let scrollAreas = Set(result.assistantRows.map { $0.1.scrollArea })
        guard scrollAreas.count <= 1 else {
            result.complete = false
            result.assistantRows.removeAll()
            recordFailure("multiple_message_scroll_areas", role: "AXScrollArea",
                          attribute: "AXChildren", errorCode: nil)
            return
        }
        if result.messageAreaScrollArea == nil, let slotArea = scrollAreas.first {
            result.messageAreaScrollArea = slotArea
        }
        guard let messageScrollArea = result.messageAreaScrollArea else { return }
        let scrollValue = result.scrollBarValues[messageScrollArea]
        let scrollAtBottom = (scrollValue ?? 0) >= 0.99
        result.assistantRows = result.assistantRows.map { order, row in
            (order, ResponseRow(key: row.key, order: row.order, controls: row.controls, element: row.element,
                                scrollArea: row.scrollArea,
                                scrollAtBottom: row.scrollArea == messageScrollArea && scrollAtBottom))
        }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String,
                                 required: Bool = false) -> String? {
        guard systemUptime < deadline else {
            if required { recordFailure("deadline_before_attribute", role: nil, attribute: name, errorCode: nil) }
            return nil
        }
        var copied: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &copied)
        guard result == .success, let copied,
              CFGetTypeID(copied) == CFStringGetTypeID() else {
            lastAXErrorCode = result == .success ? nil : Int32(result.rawValue)
            if required {
                recordFailure("required_attribute_unavailable", role: nil, attribute: name,
                              errorCode: lastAXErrorCode)
            }
            return nil
        }
        lastAXErrorCode = nil
        return copied as? String
    }

    private func numericValueAttribute(_ element: AXUIElement, _ name: String) -> Double? {
        guard systemUptime < deadline else {
            recordFailure("deadline_before_numeric_attribute", role: "AXScrollBar", attribute: name, errorCode: nil)
            return nil
        }
        var copied: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &copied)
        guard result == .success, let copied,
              CFGetTypeID(copied) == CFNumberGetTypeID() else {
            lastAXErrorCode = result == .success ? nil : Int32(result.rawValue)
            recordFailure("scroll_value_unavailable", role: "AXScrollBar", attribute: name,
                          errorCode: lastAXErrorCode)
            return nil
        }
        let number = unsafeDowncast(copied, to: CFNumber.self)
        var value = 0.0
        guard CFNumberGetValue(number, .doubleType, &value) else {
            recordFailure("scroll_value_not_numeric", role: "AXScrollBar", attribute: name, errorCode: nil)
            return nil
        }
        lastAXErrorCode = nil
        return value
    }

    private func childElements(_ element: AXUIElement, role: String,
                               tailIfLarge: Bool = false) -> ChildSlice? {
        guard configureTimeout(for: element, role: role, attribute: "AXChildren") else { return nil }
        var count: CFIndex = 0
        let countResult = AXUIElementGetAttributeValueCount(element, "AXChildren" as CFString, &count)
        guard countResult == .success, count >= 0 else {
            lastAXErrorCode = Int32(countResult.rawValue)
            recordFailure("children_count_failed", role: role, attribute: "AXChildren",
                          errorCode: lastAXErrorCode)
            return nil
        }
        guard count > 0 else { return ChildSlice(elements: [], startIndex: 0, totalCount: 0,
                                                  skippedPrefix: false, truncated: false) }

        var copied: CFArray?
        guard configureTimeout(for: element, role: role, attribute: "AXChildren") else { return nil }
        let limit = min(count, CFIndex(maxChildren))
        let startIndex = tailIfLarge && count > limit ? count - limit : 0
        let copyResult = AXUIElementCopyAttributeValues(
            element, "AXChildren" as CFString, startIndex, limit, &copied
        )
        guard copyResult == .success, let copied else {
            lastAXErrorCode = Int32(copyResult.rawValue)
            recordFailure("children_copy_failed", role: role, attribute: "AXChildren",
                          errorCode: lastAXErrorCode)
            return nil
        }
        let arrayResult = accessibilityElements(copied, expectedCount: Int(limit))
        guard arrayResult.failure == nil else {
            recordFailure(arrayResult.failure ?? "children_array_invalid", role: role,
                          attribute: "AXChildren", errorCode: nil)
            return nil
        }
        return ChildSlice(elements: arrayResult.elements, startIndex: Int(startIndex), totalCount: Int(count),
                          skippedPrefix: startIndex > 0,
                          truncated: count > limit && !tailIfLarge)
    }

    private func configureTimeout(for element: AXUIElement, role: String?, attribute: String?) -> Bool {
        let remaining = deadline - systemUptime
        guard remaining > 0 else {
            recordFailure("scan_deadline_exhausted", role: role, attribute: attribute, errorCode: nil)
            return false
        }
        let result = AXUIElementSetMessagingTimeout(element, min(messageTimeout, Float(remaining)))
        guard result == .success else {
            lastAXErrorCode = Int32(result.rawValue)
            recordFailure("timeout_setup_failed", role: role, attribute: attribute,
                          errorCode: lastAXErrorCode)
            return false
        }
        lastAXErrorCode = nil
        return true
    }

    private func recordFailure(_ reason: String, role: String?, attribute: String?, errorCode: Int32?) {
        guard firstFailure == nil else { return }
        let safeRole: String?
        if let role { safeRole = knownRoles.contains(role) ? role : "AXOther" }
        else { safeRole = nil }
        firstFailure = AXReadFailure(reason: reason, role: safeRole, attribute: safeAttribute(attribute),
                                     errorCode: errorCode)
    }

    private func safeAttribute(_ attribute: String?) -> String? {
        guard let attribute else { return nil }
        let allowed: Set<String> = ["AXRole", "AXChildren", "AXSelectedChildren", "AXSelected",
                                    "AXIdentifier", "AXDescription", "AXValue", "AXDocument", "AXURL"]
        return allowed.contains(attribute) ? attribute : "AXOtherAttribute"
    }

    private func diagnostic(for result: WindowTreeResult) -> GeminiTreeDiagnostic {
        let messageScrollValue = result.messageAreaScrollArea.flatMap { result.scrollBarValues[$0] }
        return GeminiTreeDiagnostic(
            reason: firstFailure?.reason ?? (result.complete ? "complete" : "partial"),
            failingRole: firstFailure?.role,
            failingAttribute: firstFailure?.attribute,
            axErrorCode: firstFailure?.errorCode,
            roleCounts: roleCounts,
            selectedSidebarRows: result.selectedSidebarRows.count,
            sidebarScopeFound: result.sidebarScopeFound,
            messageAreaFound: result.messageAreaScrollArea != nil,
            messageAtBottom: (messageScrollValue ?? 0) >= 0.99,
            scrollBarValue: messageScrollValue,
            elementsVisited: result.elementsVisited,
            elapsedMilliseconds: max(0, Int((systemUptime - startedAt) * 1_000))
        )
    }

    private var systemUptime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

private final class GeminiAXSnapshotter {
    private let maxWindowsPerScan = 4
    private let scanBudgetSeconds: TimeInterval = 3.0

    func frames() -> (frames: [GeminiFrame], globalReason: String?) {
        let scanDeadline = ProcessInfo.processInfo.systemUptime + scanBudgetSeconds
        guard AXIsProcessTrusted() else { return ([], "accessibility_not_trusted") }
        let appURL = URL(fileURLWithPath: GeminiTarget.appPath, isDirectory: true)
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == GeminiTarget.bundleID else {
            return ([], "installed_app_mismatch")
        }
        let installedBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard installedBuild == GeminiTarget.supportedBuild else {
            return ([], "unsupported_build")
        }

        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == GeminiTarget.bundleID && !$0.isTerminated
        }
        guard !applications.isEmpty else { return ([], "app_not_running") }

        var output: [GeminiFrame] = []
        let reader = WindowTreeReader()
        for application in applications {
            guard ProcessInfo.processInfo.systemUptime < scanDeadline else {
                return (output, "scan_deadline_exhausted")
            }
            guard application.bundleURL?.standardizedFileURL.path == GeminiTarget.appPath else {
                return ([], "running_app_path_mismatch")
            }
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            _ = AXUIElementSetMessagingTimeout(appElement, 0.15)
            let windows = copyElementArray(appElement, attribute: "AXWindows")
            guard let windows else { return ([], "window_list_unavailable") }

            let indexedWindows = prioritizeFocusedWindow(windows, appElement: appElement)
            let windowsToScan = Array(indexedWindows.prefix(maxWindowsPerScan))
            var remainingWindowSlots = windowsToScan.count
            for (windowIndex, window) in windowsToScan {
                let now = ProcessInfo.processInfo.systemUptime
                guard now < scanDeadline else {
                    output.append(skippedWindowFrame(pid: application.processIdentifier,
                                                     windowIndex: windowIndex, window: window,
                                                     reason: "window_not_scanned_budget"))
                    continue
                }
                let fairShare = (scanDeadline - now) / Double(max(1, remainingWindowSlots))
                let windowDeadline = min(scanDeadline, now + fairShare)
                remainingWindowSlots -= 1
                _ = AXUIElementSetMessagingTimeout(window, 0.15)
                let sessionID = conversationID(from: window)
                let tree = reader.read(window, deadline: windowDeadline,
                                       collectSidebarIdentity: sessionID == nil)
                let latestRow = tree.assistantRows.last?.1
                let selectedSidebarRow = tree.selectedSidebarRows.count == 1
                    ? tree.selectedSidebarRows[0] : nil
                let treeDiagnostic = tree.diagnostic
                let diagnosticReason: String
                if !tree.complete {
                    diagnosticReason = treeDiagnostic?.reason ?? "tree_partial_without_detail"
                } else if sessionID == nil && tree.selectedSidebarRows.count != 1 {
                    diagnosticReason = "selected_sidebar_identity_missing_or_ambiguous"
                } else {
                    diagnosticReason = treeDiagnostic?.reason ?? "complete"
                }
                let diagnostic = GeminiSnapshotDiagnostic(
                    processID: application.processIdentifier, windowIndex: windowIndex,
                    complete: tree.complete, reason: diagnosticReason,
                    failingRole: treeDiagnostic?.failingRole,
                    failingAttribute: treeDiagnostic?.failingAttribute,
                    axErrorCode: treeDiagnostic?.axErrorCode,
                    elementsVisited: tree.elementsVisited,
                    roleCounts: treeDiagnostic?.roleCounts ?? [:],
                    selectedSidebarRows: tree.selectedSidebarRows.count,
                    sidebarScopeFound: treeDiagnostic?.sidebarScopeFound ?? false,
                    messageAreaFound: treeDiagnostic?.messageAreaFound ?? false,
                    messageAtBottom: treeDiagnostic?.messageAtBottom ?? false,
                    scrollBarValue: treeDiagnostic?.scrollBarValue,
                    tailWindowed: tree.latestTailWindowed,
                    elapsedMilliseconds: treeDiagnostic?.elapsedMilliseconds ?? 0
                )
                output.append(GeminiFrame(pid: application.processIdentifier,
                                          windowIndex: windowIndex,
                                          sessionFingerprint: sessionID.map(fingerprint),
                                          windowElement: window,
                                          selectedSidebarRow: selectedSidebarRow,
                                          stopVisible: tree.stopVisible,
                                          latestResponseRow: latestRow,
                                          taskToolbarCompleted: tree.taskToolbarCompleted,
                                          complete: tree.complete,
                                          reason: tree.complete ? "observed" : "ax_tree_incomplete",
                                          tailWindowed: tree.latestTailWindowed,
                                          snapshotDiagnostic: diagnostic))
            }
            for (windowIndex, window) in indexedWindows.dropFirst(windowsToScan.count) {
                output.append(skippedWindowFrame(pid: application.processIdentifier,
                                                 windowIndex: windowIndex, window: window,
                                                 reason: "window_limit_not_scanned"))
            }
        }
        return (output, nil)
    }

    private func prioritizeFocusedWindow(
        _ windows: [AXUIElement], appElement: AXUIElement
    ) -> [(Int, AXUIElement)] {
        let indexed = Array(windows.enumerated())
        guard let focused = copySingleElement(appElement, attribute: "AXFocusedWindow"),
              let focusedPosition = indexed.firstIndex(where: { CFEqual($0.element, focused) }) else {
            return indexed
        }
        return [indexed[focusedPosition]] + indexed.enumerated().compactMap { position, item in
            position == focusedPosition ? nil : item
        }
    }

    private func copySingleElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var copied: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &copied)
        guard result == .success, let copied,
              CFGetTypeID(copied) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(copied, to: AXUIElement.self)
    }

    private func skippedWindowFrame(pid: Int32, windowIndex: Int, window: AXUIElement,
                                    reason: String) -> GeminiFrame {
        let diagnostic = GeminiSnapshotDiagnostic(
            processID: pid, windowIndex: windowIndex, complete: false, reason: reason,
            failingRole: nil, failingAttribute: nil, axErrorCode: nil, elementsVisited: 0,
            roleCounts: [:], selectedSidebarRows: 0, sidebarScopeFound: false,
            messageAreaFound: false, messageAtBottom: false, scrollBarValue: nil,
            tailWindowed: false, elapsedMilliseconds: 0
        )
        return GeminiFrame(pid: pid, windowIndex: windowIndex, sessionFingerprint: nil,
                           windowElement: window, selectedSidebarRow: nil, stopVisible: false,
                           latestResponseRow: nil, taskToolbarCompleted: false, complete: false,
                           reason: reason, tailWindowed: false, snapshotDiagnostic: diagnostic)
    }

    private func conversationID(from window: AXUIElement) -> String? {
        // Only the top-level window's AXDocument / AXURL is parsed. The raw
        // value is never returned, logged, or included in an error message.
        for attribute in ["AXDocument", "AXURL"] {
            guard let rawURL = stringLikeAttribute(window, attribute),
                  let id = supportedConversationID(rawURL) else { continue }
            return id
        }
        return nil
    }

    private func supportedConversationID(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              components.user == nil, components.password == nil else { return nil }

        let path = components.path.split(separator: "/").map(String.init)
        let identifier: String?
        if components.scheme?.lowercased() == "googlegemini",
           components.host?.lowercased() == "conversation",
           path.count == 1 {
            identifier = path[0]
        } else if components.scheme?.lowercased() == "https",
                  components.host?.lowercased() == "gemini.google.com",
                  path.count == 2, path[0] == "app" {
            identifier = path[1]
        } else {
            identifier = nil
        }

        guard let identifier,
              identifier.range(of: "^[A-Za-z0-9_-]{8,128}$", options: .regularExpression) != nil else {
            return nil
        }
        return identifier
    }

    private func stringLikeAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var copied: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &copied)
        guard result == .success, let copied else { return nil }
        if CFGetTypeID(copied) == CFStringGetTypeID() { return copied as? String }
        if CFGetTypeID(copied) == CFURLGetTypeID() {
            let url = unsafeDowncast(copied, to: CFURL.self)
            return CFURLGetString(url) as String?
        }
        return nil
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var copied: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &copied)
        guard result == .success, let copied,
              CFGetTypeID(copied) == CFStringGetTypeID() else { return nil }
        return copied as? String
    }

    private func copyElementArray(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var copied: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &copied)
        guard result == .success, let copied,
              CFGetTypeID(copied) == CFArrayGetTypeID() else { return nil }
        let arrayResult = accessibilityElements(unsafeDowncast(copied, to: CFArray.self))
        guard arrayResult.failure == nil else { return nil }
        return arrayResult.elements
    }
}

private func fingerprint(_ identifier: String) -> String {
    let digest = SHA256.hash(data: Data(identifier.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

private struct WindowTracker {
    var windowIdentity: String?
    var continuityEpoch: UInt64 = 0
    var hasSeenFrame = false
    var continuityKnown = false
    var sessionFingerprint: String?
    var selectedSidebarRow: AXUIElement?
    var ruleState = GeminiLifecycleRuleState()
}

private struct TrackedWindowIdentity {
    let id: String
    let element: AXUIElement
}

private final class GeminiStatusTracker {
    private var trackers: [String: WindowTracker] = [:]
    private var windowIdentities: [Int32: [TrackedWindowIdentity]] = [:]

    func update(_ frames: [GeminiFrame], globalReason: String?) -> [ProbeEvent] {
        let now = Date()
        var events: [ProbeEvent] = []

        if let globalReason {
            trackers.removeAll()
            windowIdentities.removeAll()
            let diagnostic = GeminiSnapshotDiagnostic(
                processID: nil, windowIndex: nil, complete: false, reason: globalReason,
                failingRole: nil, failingAttribute: nil, axErrorCode: nil, elementsVisited: 0,
                roleCounts: [:], selectedSidebarRows: 0, sidebarScopeFound: false,
                messageAreaFound: false, messageAtBottom: false, scrollBarValue: nil,
                tailWindowed: false, elapsedMilliseconds: 0
            )
            return [event(pid: nil, window: nil, windowIdentity: nil, continuityEpoch: 0,
                          session: nil, scope: "unbound", status: "unknown",
                          reason: globalReason, taskToolbarCompleted: false, row: nil,
                          snapshotDiagnostic: diagnostic, now: now)]
        }

        let identifiedFrames = assignWindowIdentities(frames)
        let seenKeys = Set(identifiedFrames.map { "\($0.frame.pid):\($0.identity)" })
        for (frame, identity) in identifiedFrames {
            let key = "\(frame.pid):\(identity)"
            var tracker = trackers[key] ?? WindowTracker(windowIdentity: identity)
            let scope = observationScope(for: frame)
            let continuityKnown = frame.complete && scope != "unbound"
            let selectedSidebarRowEqual = sameElement(tracker.selectedSidebarRow, frame.selectedSidebarRow)
            if GeminiContinuityRules.shouldAdvanceEpoch(
                hasSeenFrame: tracker.hasSeenFrame,
                wasContinuityKnown: tracker.continuityKnown,
                isContinuityKnown: continuityKnown,
                previousSessionFingerprint: tracker.sessionFingerprint,
                currentSessionFingerprint: frame.sessionFingerprint,
                hasConversationRoute: frame.sessionFingerprint != nil,
                selectedSidebarRowEqual: selectedSidebarRowEqual
            ) {
                tracker.continuityEpoch += 1
                tracker.ruleState = GeminiLifecycleRuleState()
            }
            tracker.hasSeenFrame = true
            tracker.continuityKnown = continuityKnown
            tracker.sessionFingerprint = frame.sessionFingerprint
            tracker.selectedSidebarRow = frame.selectedSidebarRow
            tracker.windowIdentity = identity

            let latestRow = frame.latestResponseRow
            let ruleFrame = GeminiLifecycleRuleFrame(
                windowIdentity: identity,
                continuityEpoch: tracker.continuityEpoch,
                scope: GeminiObservationScope(rawValue: scope) ?? .unbound,
                treeComplete: frame.complete,
                stopVisible: frame.stopVisible,
                latestAssistantSlotID: latestRow?.key,
                latestAssistantSlotOrder: latestRow?.order,
                latestAssistantControls: latestRow.map { Array($0.controls) } ?? [],
                latestAssistantAtBottom: latestRow?.scrollAtBottom ?? false
            )
            let decision = GeminiLifecycleRules.decide(ruleFrame, state: &tracker.ruleState)
            trackers[key] = tracker
            events.append(event(pid: frame.pid, window: frame.windowIndex,
                                windowIdentity: identity, continuityEpoch: tracker.continuityEpoch,
                                session: frame.sessionFingerprint, scope: scope,
                                status: decision.state.rawValue,
                                reason: decision.reason,
                                taskToolbarCompleted: frame.taskToolbarCompleted,
                                row: frame.latestResponseRow,
                                snapshotDiagnostic: frame.snapshotDiagnostic,
                                now: now))
        }

        for key in trackers.keys where !seenKeys.contains(key) {
            trackers.removeValue(forKey: key)
        }
        return events
    }

    private func assignWindowIdentities(_ frames: [GeminiFrame]) -> [(frame: GeminiFrame, identity: String)] {
        var nextByProcess: [Int32: [TrackedWindowIdentity]] = [:]
        var usedByProcess: [Int32: Set<String>] = [:]
        var identified: [(GeminiFrame, String)] = []

        for frame in frames {
            let pid = frame.pid
            let prior = windowIdentities[pid] ?? []
            let used = usedByProcess[pid, default: []]
            let match = prior.first { !used.contains($0.id) && CFEqual($0.element, frame.windowElement) }
            let identity = match?.id ?? UUID().uuidString
            usedByProcess[pid, default: []].insert(identity)
            nextByProcess[pid, default: []].append(
                TrackedWindowIdentity(id: identity, element: frame.windowElement)
            )
            identified.append((frame, identity))
        }

        windowIdentities = nextByProcess
        return identified
    }

    private func observationScope(for frame: GeminiFrame) -> String {
        if frame.sessionFingerprint != nil { return "conversation" }
        if frame.selectedSidebarRow != nil { return "window_continuity" }
        return "unbound"
    }

    private func sameElement(_ left: AXUIElement?, _ right: AXUIElement?) -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        return CFEqual(left, right)
    }

    private func event(
        pid: Int32?, window: Int?, windowIdentity: String?, continuityEpoch: UInt64,
        session: String?, scope: String, status: String, reason: String,
        taskToolbarCompleted: Bool, row: ResponseRow?,
        snapshotDiagnostic: GeminiSnapshotDiagnostic, now: Date
    ) -> ProbeEvent {
        return ProbeEvent(app: "gemini", build: GeminiTarget.supportedBuild, pid: pid,
                          window: window, windowIdentity: windowIdentity,
                          continuityEpoch: continuityEpoch, session: session,
                          scope: scope, status: status, reason: reason,
                          taskToolbarCompleted: taskToolbarCompleted,
                          responseControls: row.map { $0.controls.sorted() } ?? [],
                          isHeartbeat: true,
                          snapshotDiagnostic: snapshotDiagnostic,
                          observedAt: now)
    }
}

