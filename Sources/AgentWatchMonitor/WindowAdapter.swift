import AgentWatchCore
import AppKit
import ApplicationServices
import CoreFoundation
import Foundation

public struct WindowTarget: Sendable {
    public let appID: String
    public let bundleIDs: [String]

    public init(appID: String, bundleIDs: [String]) {
        self.appID = appID
        self.bundleIDs = bundleIDs
    }
}

public struct WindowScan: Sendable {
    public let events: [MonitorEvent]
    public let diagnostics: [String: String]

    public init(events: [MonitorEvent], diagnostics: [String: String]) {
        self.events = events
        self.diagnostics = diagnostics
    }
}

struct WindowTargetRotator {
    private var nextStart = 0

    mutating func rotate(_ targets: [WindowTarget]) -> [WindowTarget] {
        guard !targets.isEmpty else { return [] }
        let startIndex = nextStart % targets.count
        nextStart = (startIndex + 1) % targets.count
        return Array(targets[startIndex...]) + Array(targets[..<startIndex])
    }
}

/// Reads a bounded AX tree on a private serial queue. It never performs AX actions.
public final class WindowAdapter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.agentwatch.window-adapter.ax", qos: .utility)
    private var windowStates: [WindowKey: WindowState] = [:]
    private var targetRotator = WindowTargetRotator()

    public init() {}

    public func scan(targets: [WindowTarget]) -> WindowScan {
        queue.sync { scanSerial(targets: targets) }
    }

    private func scanSerial(targets: [WindowTarget]) -> WindowScan {
        let start = ProcessInfo.processInfo.systemUptime
        let totalDeadline = start + WindowLimits.totalSeconds
        let orderedTargets = targetRotator.rotate(targets)
        let runningApplications = NSWorkspace.shared.runningApplications
        let liveProcessIDs = Set(runningApplications.map(\.processIdentifier))
        removeExitedProcesses(liveProcessIDs)

        guard AXIsProcessTrusted() else {
            var trustDiagnostics: [String: String] = [:]
            for target in orderedTargets {
                breakMissingRunStreak(appID: target.appID)
                trustDiagnostics[target.appID] = "accessibility_not_trusted_window_level"
            }
            return WindowScan(
                events: [],
                diagnostics: trustDiagnostics
            )
        }

        var events: [MonitorEvent] = []
        var diagnostics: [String: String] = [:]

        for target in orderedTargets {
            guard ProcessInfo.processInfo.systemUptime < totalDeadline else {
                breakMissingRunStreak(appID: target.appID)
                diagnostics[target.appID] = "total_time_budget_exhausted"
                continue
            }
            guard !target.bundleIDs.isEmpty else {
                breakMissingRunStreak(appID: target.appID)
                diagnostics[target.appID] = "no_bundle_ids"
                continue
            }

            let matchingApplications = runningApplications.filter {
                guard let bundleID = $0.bundleIdentifier else { return false }
                return target.bundleIDs.contains(bundleID)
            }
            guard !matchingApplications.isEmpty else {
                breakMissingRunStreak(appID: target.appID)
                diagnostics[target.appID] = "application_not_running"
                continue
            }

            let appDeadline = min(
                totalDeadline,
                ProcessInfo.processInfo.systemUptime + WindowLimits.perApplicationSeconds
            )
            var observations: [WindowObservation] = []
            var appComplete = true
            var remainingNodes = WindowLimits.maximumNodes

            for runningApplication in matchingApplications {
                guard ProcessInfo.processInfo.systemUptime < appDeadline else {
                    appComplete = false
                    break
                }
                let result = inspectProcess(
                    pid: runningApplication.processIdentifier,
                    appID: target.appID,
                    deadline: appDeadline,
                    remainingNodes: &remainingNodes
                )
                observations.append(contentsOf: result.windows)
                appComplete = appComplete && result.complete
            }

            let seenKeys = Set(observations.map(\.key))
            for observation in observations {
                let collectionComplete = appComplete && observation.treeComplete
                let input = WindowRuleInput(
                    controls: observation.controls,
                    dialogControls: observation.dialogControls,
                    hasDialog: observation.hasDialog,
                    composerSend: observation.composerSend,
                    composerSpecificStop: observation.composerSpecificStop,
                    composerGenericStop: observation.composerGenericStop,
                    wasRunning: windowStates[observation.key]?.wasRunning ?? false,
                    completeMisses: windowStates[observation.key]?.completeMisses ?? 0,
                    collectionComplete: collectionComplete
                )
                let decision = WindowStateRules.decide(input)
                guard WindowStateRules.shouldEmit(
                    decision.state,
                    collectionComplete: collectionComplete
                ) else {
                    var retained = windowStates[observation.key] ?? WindowState(
                        sessionID: UUID().uuidString,
                        turnID: UUID().uuidString
                    )
                    retained.completeMisses = 0
                    retained.missingWindowScans = 0
                    windowStates[observation.key] = retained
                    continue
                }
                var state = windowStates[observation.key] ?? WindowState(
                    sessionID: UUID().uuidString,
                    turnID: UUID().uuidString
                )
                let eventTurnID = state.turnCursor.eventTurnID(
                    candidateTurnActive: decision.wasRunning,
                    candidateTurnBecameInactive: decision.completionUnverified && !decision.wasRunning
                )
                state.wasRunning = decision.wasRunning
                state.completeMisses = decision.completeMisses
                state.missingWindowScans = 0
                state.sequence += 1
                events.append(makeEvent(
                    appID: target.appID,
                    state: decision.state.eventState,
                    sessionID: state.sessionID,
                    turnID: eventTurnID,
                    sequence: state.sequence,
                    source: decision.source
                ))
                windowStates[observation.key] = state
            }

            if appComplete {
                ageMissingWindows(
                    appID: target.appID,
                    processIDs: Set(matchingApplications.map(\.processIdentifier)),
                    seenKeys: seenKeys
                )
                diagnostics[target.appID] = "scan_complete_window_level_hidden_sessions_not_guaranteed"
            } else if ProcessInfo.processInfo.systemUptime >= totalDeadline
                        || ProcessInfo.processInfo.systemUptime >= appDeadline {
                breakMissingRunStreak(appID: target.appID)
                diagnostics[target.appID] = "scan_partial_timeout_window_level"
            } else {
                breakMissingRunStreak(appID: target.appID)
                diagnostics[target.appID] = "scan_partial_ax_or_tree_limit_window_level"
            }
        }

        return WindowScan(events: events, diagnostics: diagnostics)
    }

    private func inspectProcess(
        pid: Int32,
        appID: String,
        deadline: TimeInterval,
        remainingNodes: inout Int
    ) -> ProcessObservation {
        let application = AXUIElementCreateApplication(pid)
        guard configureTimeout(for: application), systemUptime < deadline else {
            return ProcessObservation(windows: [], complete: false)
        }

        var windowCount: CFIndex = 0
        let countResult = AXUIElementGetAttributeValueCount(
            application,
            kAXWindowsAttribute as CFString,
            &windowCount
        )
        guard countResult == .success, windowCount >= 0 else {
            return ProcessObservation(windows: [], complete: false)
        }
        guard windowCount > 0 else {
            return ProcessObservation(windows: [], complete: true)
        }
        let inspectedWindowCount = min(windowCount, WindowLimits.maximumWindowsPerProcess)
        var complete = inspectedWindowCount == windowCount

        var copiedWindows: CFArray?
        let windowsResult = AXUIElementCopyAttributeValues(
            application,
            kAXWindowsAttribute as CFString,
            0,
            inspectedWindowCount,
            &copiedWindows
        )
        guard windowsResult == .success, let copiedWindows else {
            return ProcessObservation(windows: [], complete: false)
        }

        let arrayCount = CFArrayGetCount(copiedWindows)
        guard arrayCount == inspectedWindowCount else {
            return ProcessObservation(windows: [], complete: false)
        }

        var observations: [WindowObservation] = []
        for index in 0..<arrayCount {
            guard systemUptime < deadline,
                  let pointer = CFArrayGetValueAtIndex(copiedWindows, index) else {
                complete = false
                break
            }
            let reference = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(reference) == AXUIElementGetTypeID() else {
                complete = false
                continue
            }
            let window = Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
            let (possibleKey, identityComplete) = resolveWindowKey(
                appID: appID,
                pid: pid,
                window: window,
                singleWindow: windowCount == 1
            )
            guard let key = possibleKey else { complete = false; continue }
            let tree = inspectWindow(window, deadline: deadline, remainingNodes: &remainingNodes)
            complete = complete && identityComplete && tree.complete
            observations.append(WindowObservation(
                key: key,
                controls: tree.controls,
                dialogControls: tree.dialogControls,
                hasDialog: tree.hasDialog,
                composerSend: tree.composerSend,
                composerSpecificStop: tree.composerSpecificStop,
                composerGenericStop: tree.composerGenericStop,
                treeComplete: tree.complete
            ))
        }
        return ProcessObservation(windows: observations, complete: complete)
    }

    private func inspectWindow(
        _ window: AXUIElement,
        deadline: TimeInterval,
        remainingNodes: inout Int
    ) -> TreeObservation {
        var collector = TreeCollector()
        let complete = visit(
            window,
            depth: 0,
            dialogID: nil,
            nearestGroup: nil,
            collector: &collector,
            deadline: deadline,
            remainingNodes: &remainingNodes
        )
        let composerSend = collector.groupSignals.values.contains { group in
            WindowStateRules.isComposerSend(group)
        }
        let composerSpecificStop = collector.groupSignals.values.contains { group in
            WindowStateRules.isComposerSpecificStop(group)
        }
        let composerGenericStop = collector.groupSignals.values.contains { group in
            WindowStateRules.isComposerGenericStop(group)
        }
        return TreeObservation(
            controls: collector.controls,
            dialogControls: collector.dialogGroupSignals.values.first(where: WindowStateRules.containsApprovalPair) ?? [],
            hasDialog: collector.hasDialog,
            composerSend: composerSend,
            composerSpecificStop: composerSpecificStop,
            composerGenericStop: composerGenericStop,
            complete: complete && !collector.clipped
        )
    }

    @discardableResult
    private func visit(
        _ element: AXUIElement,
        depth: Int,
        dialogID inheritedDialogID: Int?,
        nearestGroup inheritedGroup: Int?,
        collector: inout TreeCollector,
        deadline: TimeInterval,
        remainingNodes: inout Int
    ) -> Bool {
        guard systemUptime < deadline,
              remainingNodes > 0,
              configureTimeout(for: element) else {
            collector.clipped = true
            return false
        }
        collector.nodesVisited += 1
        remainingNodes -= 1
        let nodeID = collector.nodesVisited

        guard let role = readRole(from: element, collector: &collector) else {
            return false
        }
        let opensDialog = role == "AXSheet" || role == "AXDialog"
        let dialogID = opensDialog ? nodeID : inheritedDialogID
        if opensDialog { collector.hasDialog = true }
        let groupID = role == "AXGroup" ? nodeID : inheritedGroup

        if isActionRole(role) {
            let signals = readControlSignals(from: element, role: role, collector: &collector)
            collector.controls.formUnion(signals)
            if let dialogID, !signals.isEmpty {
                collector.dialogGroupSignals[dialogID, default: []].formUnion(signals)
            }
            if let groupID, !signals.isEmpty {
                collector.groupSignals[groupID, default: []].formUnion(signals)
            }
        }
        if let inputSignal = inputSignal(for: role), let groupID {
            collector.groupSignals[groupID, default: []].insert(inputSignal)
        }

        var childCount: CFIndex = 0
        let countResult = AXUIElementGetAttributeValueCount(
            element,
            kAXChildrenAttribute as CFString,
            &childCount
        )
        if isMissingAttribute(countResult) { return true }
        guard countResult == .success, childCount >= 0 else { return false }
        guard childCount > 0 else { return true }
        guard depth < WindowLimits.maximumDepth,
              remainingNodes > 0 else {
            collector.clipped = true
            return false
        }

        let inspectedChildCount = min(childCount, CFIndex(remainingNodes))
        if inspectedChildCount < childCount { collector.clipped = true }
        var copiedChildren: CFArray?
        let childrenResult = AXUIElementCopyAttributeValues(
            element,
            kAXChildrenAttribute as CFString,
            0,
            inspectedChildCount,
            &copiedChildren
        )
        guard childrenResult == .success, let copiedChildren else { return false }
        let actualCount = CFArrayGetCount(copiedChildren)
        guard actualCount == inspectedChildCount else { return false }

        var subtreeComplete = inspectedChildCount == childCount
        for index in 0..<actualCount {
            guard systemUptime < deadline,
                  remainingNodes > 0,
                  let pointer = CFArrayGetValueAtIndex(copiedChildren, index) else {
                collector.clipped = true
                return false
            }
            let reference = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(reference) == AXUIElementGetTypeID() else {
                subtreeComplete = false
                continue
            }
            let child = Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
            subtreeComplete = visit(
                child,
                depth: depth + 1,
                dialogID: dialogID,
                nearestGroup: groupID,
                collector: &collector,
                deadline: deadline,
                remainingNodes: &remainingNodes
            ) && subtreeComplete
        }
        return subtreeComplete
    }

    private func readRole(from element: AXUIElement, collector: inout TreeCollector) -> String? {
        var copiedRole: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &copiedRole)
        guard result == .success, let copiedRole,
              CFGetTypeID(copiedRole) == CFStringGetTypeID(),
              let role = copiedRole as? String else {
            if !isMissingAttribute(result) { collector.clipped = true }
            return nil
        }
        return role
    }

    private func readControlSignals(
        from element: AXUIElement,
        role: String,
        collector: inout TreeCollector
    ) -> Set<WindowControlSignal> {
        var signals: Set<WindowControlSignal> = []
        for attribute in [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString
        ] {
            var copiedLabel: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute, &copiedLabel)
            guard result == .success, let copiedLabel else {
                if !isMissingAttribute(result) { collector.clipped = true }
                continue
            }
            guard CFGetTypeID(copiedLabel) == CFStringGetTypeID(),
                  let label = copiedLabel as? String,
                  label.utf8.count <= WindowLimits.maximumLabelBytes else {
                continue
            }
            if let signal = WindowControlWhitelist.signal(for: label, role: role) {
                signals.insert(signal)
            }
            // The raw label is intentionally discarded here and is never logged or returned.
        }
        return signals
    }

    private func resolveWindowKey(
        appID: String,
        pid: Int32,
        window: AXUIElement,
        singleWindow: Bool
    ) -> (WindowKey?, Bool) {
        let (windowNumber, numberReadComplete) = readWindowNumber(from: window)
        if let windowNumber {
            return (WindowKey(appID: appID, pid: pid, identity: "number:\(windowNumber)"), numberReadComplete)
        }
        // Some providers recreate AX references every scan. Do not turn those
        // transient references into a stream of imaginary sessions.
        if singleWindow {
            return (WindowKey(appID: appID, pid: pid, identity: "single-window"), numberReadComplete)
        }
        // Multiple windows without a stable OS ID cannot safely be distinguished.
        return (nil, false)
    }

    private func readWindowNumber(from window: AXUIElement) -> (Int?, Bool) {
        var copiedNumber: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &copiedNumber)
        guard result == .success, let copiedNumber else {
            return (nil, isMissingAttribute(result))
        }
        guard CFGetTypeID(copiedNumber) == CFNumberGetTypeID(),
              let number = copiedNumber as? NSNumber else {
            return (nil, false)
        }
        return (number.intValue, true)
    }

    private func ageMissingWindows(
        appID: String,
        processIDs: Set<Int32>,
        seenKeys: Set<WindowKey>
    ) {
        for key in Array(windowStates.keys) where key.appID == appID
            && processIDs.contains(key.pid) && !seenKeys.contains(key) {
            guard var state = windowStates[key] else { continue }
            state.missingWindowScans += 1
            state.completeMisses = 0
            if state.missingWindowScans >= WindowLimits.windowExpiryScans {
                windowStates.removeValue(forKey: key)
            } else {
                windowStates[key] = state
            }
        }
    }

    private func removeExitedProcesses(_ liveProcessIDs: Set<Int32>) {
        windowStates = windowStates.filter { liveProcessIDs.contains($0.key.pid) }
    }

    private func breakMissingRunStreak(appID: String) {
        for key in Array(windowStates.keys) where key.appID == appID {
            windowStates[key]?.completeMisses = 0
        }
    }

    private func makeEvent(
        appID: String,
        state: SessionState,
        sessionID: String,
        turnID: String,
        sequence: Int,
        source: String
    ) -> MonitorEvent {
        MonitorEvent(
            id: UUID().uuidString,
            appID: appID,
            sessionID: sessionID,
            turnID: turnID,
            state: state,
            evidence: .inferred,
            observedAt: Date(),
            sequence: sequence,
            parentSessionID: nil,
            source: source
        )
    }

    private func isActionRole(_ role: String) -> Bool {
        ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSwitch"]
            .contains(role)
    }

    private func inputSignal(for role: String) -> WindowControlSignal? {
        switch role {
        case "AXTextArea": return .textAreaInput
        case "AXTextField": return .textFieldInput
        default: return nil
        }
    }

    private func configureTimeout(for element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, WindowLimits.messageTimeout) == .success
    }

    private func isMissingAttribute(_ error: AXError) -> Bool {
        error == .attributeUnsupported || error == .noValue
    }

    private var systemUptime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

private enum WindowLimits {
    static let messageTimeout: Float = 0.1
    static let perApplicationSeconds: TimeInterval = 1.0
    static let totalSeconds: TimeInterval = 6.0
    static let maximumNodes = 500
    static let maximumDepth = 24
    static let maximumWindowsPerProcess = 32
    static let maximumLabelBytes = 48
    static let windowExpiryScans = 2
}

private struct WindowKey: Hashable {
    let appID: String
    let pid: Int32
    let identity: String
}

private struct WindowState {
    let sessionID: String
    var turnCursor: WindowTurnCursor
    var wasRunning = false
    var completeMisses = 0
    var missingWindowScans = 0
    var sequence = 0

    init(sessionID: String, turnID: String) {
        self.sessionID = sessionID
        self.turnCursor = WindowTurnCursor(initialTurnID: turnID)
    }
}

struct WindowTurnCursor {
    private(set) var currentTurnID: String
    private var isCandidateTurnActive = false

    init(initialTurnID: String) {
        currentTurnID = initialTurnID
    }

    mutating func eventTurnID(
        candidateTurnActive: Bool,
        candidateTurnBecameInactive: Bool
    ) -> String {
        if candidateTurnActive && !isCandidateTurnActive {
            currentTurnID = UUID().uuidString
            isCandidateTurnActive = true
        }
        let eventTurnID = currentTurnID
        if candidateTurnBecameInactive {
            isCandidateTurnActive = false
        }
        return eventTurnID
    }
}

private struct ProcessObservation {
    let windows: [WindowObservation]
    let complete: Bool
}

private struct WindowObservation {
    let key: WindowKey
    let controls: Set<WindowControlSignal>
    let dialogControls: Set<WindowControlSignal>
    let hasDialog: Bool
    let composerSend: Bool
    let composerSpecificStop: Bool
    let composerGenericStop: Bool
    let treeComplete: Bool
}

private struct TreeObservation {
    let controls: Set<WindowControlSignal>
    let dialogControls: Set<WindowControlSignal>
    let hasDialog: Bool
    let composerSend: Bool
    let composerSpecificStop: Bool
    let composerGenericStop: Bool
    let complete: Bool
}

private struct TreeCollector {
    var nodesVisited = 0
    var clipped = false
    var hasDialog = false
    var controls: Set<WindowControlSignal> = []
    var dialogGroupSignals: [Int: Set<WindowControlSignal>] = [:]
    var groupSignals: [Int: Set<WindowControlSignal>] = [:]
}

/// Labels have already passed the role, length, and exact allowlist checks.
enum WindowControlSignal: Hashable, Sendable {
    case stopGeneration
    case cancelGeneration
    case genericStop
    case allow
    case deny
    case approve
    case reject
    case send
    case textFieldInput
    case textAreaInput
}

enum WindowRuleState: Equatable, Sendable {
    case unknown
    case running
    case waitingApproval

    var eventState: SessionState {
        switch self {
        case .unknown: return .unknown
        case .running: return .running
        case .waitingApproval: return .waitingApproval
        }
    }

    var source: String {
        switch self {
        case .unknown: return "ax_window_level_observation_unknown_v1"
        case .running: return "ax_window_level_candidate_running_v1"
        case .waitingApproval: return "ax_window_level_candidate_approval_v1"
        }
    }
}

struct WindowRuleInput: Sendable {
    let controls: Set<WindowControlSignal>
    let dialogControls: Set<WindowControlSignal>
    let hasDialog: Bool
    let composerSend: Bool
    let composerSpecificStop: Bool
    let composerGenericStop: Bool
    let wasRunning: Bool
    let completeMisses: Int
    let collectionComplete: Bool
}

struct WindowRuleDecision: Equatable, Sendable {
    let state: WindowRuleState
    let wasRunning: Bool
    let completeMisses: Int
    var completionUnverified = false

    var source: String {
        completionUnverified ? "ax_window_level_completion_unverified_v1" : state.source
    }
}

enum WindowStateRules {
    static func isComposerSend(_ signals: Set<WindowControlSignal>) -> Bool {
        signals.contains(.send) && hasTextInput(signals)
    }

    static func isComposerSpecificStop(_ signals: Set<WindowControlSignal>) -> Bool {
        (signals.contains(.stopGeneration) || signals.contains(.cancelGeneration))
            && hasTextInput(signals)
    }

    static func isComposerGenericStop(_ signals: Set<WindowControlSignal>) -> Bool {
        signals.contains(.genericStop) && signals.contains(.textAreaInput)
    }

    private static func hasTextInput(_ signals: Set<WindowControlSignal>) -> Bool {
        signals.contains(.textAreaInput) || signals.contains(.textFieldInput)
    }

    static func shouldEmit(_ state: WindowRuleState, collectionComplete: Bool) -> Bool {
        switch state {
        case .running, .waitingApproval:
            return true
        case .unknown:
            return collectionComplete
        }
    }

    static func containsApprovalPair(_ controls: Set<WindowControlSignal>) -> Bool {
        (controls.contains(.allow) && controls.contains(.deny))
            || (controls.contains(.approve) && controls.contains(.reject))
    }

    static func decide(_ input: WindowRuleInput) -> WindowRuleDecision {
        let hasSpecificStop = input.controls.contains(.stopGeneration)
            || input.controls.contains(.cancelGeneration)
        let hasRunningEvidence = (hasSpecificStop && input.composerSpecificStop)
            || (input.controls.contains(.genericStop) && input.composerGenericStop)
        let hasApprovalPair = input.hasDialog && containsApprovalPair(input.dialogControls)

        if hasRunningEvidence && hasApprovalPair {
            return WindowRuleDecision(
                state: .unknown,
                wasRunning: true,
                completeMisses: 0
            )
        }
        if hasApprovalPair {
            return WindowRuleDecision(
                state: .waitingApproval,
                wasRunning: true,
                completeMisses: 0
            )
        }
        if input.hasDialog {
            return WindowRuleDecision(
                state: .unknown,
                wasRunning: input.wasRunning,
                completeMisses: 0
            )
        }
        if hasRunningEvidence {
            return WindowRuleDecision(state: .running, wasRunning: true, completeMisses: 0)
        }

        guard input.collectionComplete else {
            return WindowRuleDecision(
                state: .unknown,
                wasRunning: input.wasRunning,
                completeMisses: 0
            )
        }
        guard input.wasRunning, input.composerSend else {
            return WindowRuleDecision(state: .unknown, wasRunning: input.wasRunning, completeMisses: 0)
        }

        let nextMisses = input.completeMisses + 1
        if nextMisses >= 2 {
            return WindowRuleDecision(
                state: .unknown,
                wasRunning: false,
                completeMisses: 0,
                completionUnverified: true
            )
        }
        return WindowRuleDecision(
            state: .unknown,
            wasRunning: true,
            completeMisses: nextMisses,
            completionUnverified: true
        )
    }
}

private enum WindowControlWhitelist {
    private static let signals: [String: WindowControlSignal] = [
        "stop": .genericStop,
        "停止": .genericStop,
        "stop generation": .stopGeneration,
        "stop generating": .stopGeneration,
        "stop response": .stopGeneration,
        "停止生成": .stopGeneration,
        "停止回答": .stopGeneration,
        "cancel generation": .cancelGeneration,
        "cancel response": .cancelGeneration,
        "取消生成": .cancelGeneration,
        "send": .send,
        "send message": .send,
        "send prompt": .send,
        "发送": .send,
        "发送消息": .send,
        "发送提示": .send,
        "allow": .allow,
        "允许": .allow,
        "deny": .deny,
        "拒绝": .deny,
        "approve": .approve,
        "批准": .approve,
        "驳回": .reject,
        "reject": .reject
    ]

    static func signal(for label: String, role: String) -> WindowControlSignal? {
        guard role == "AXButton" else { return nil }
        return signals[label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }
}
