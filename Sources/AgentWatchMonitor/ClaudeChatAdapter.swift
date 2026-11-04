import AppKit
@preconcurrency import ApplicationServices
import CoreFoundation
import CryptoKit
import Foundation
import AgentWatchCore

public enum ClaudeChatWindowScope: String, Sendable {
    case authentication
    case compactCode
    case primaryPane
    case cowork
}

public enum ClaudeChatRouteKind: String, Sendable {
    case code
    case cowork
}

public enum ClaudeChatObservedStatus: String, Sendable, Equatable {
    case responding
    case finished
    case interrupted
    case unknown
}

/// A content-free per-window state candidate. Fingerprints are hashes of the
/// local session route and AX element identifier; raw values are never exposed.
public struct ClaudeChatWindowObservation: Sendable {
    public let windowFingerprint: String?
    /// Transient local route ID for joining an exact visible session to its
    /// metadata record. Callers must not persist or log this value.
    public let routeSessionID: String?
    public let routeKind: ClaudeChatRouteKind?
    public let sessionFingerprint: String?
    public let turnFingerprint: String?
    public let scope: ClaudeChatWindowScope
    public let observedStatus: ClaudeChatObservedStatus
    public let stopButtonVisible: Bool
    public let latestAssistantCopyVisible: Bool
    public let snapshotSequence: UInt64
    public let state: SessionState
    public let finishLabelVisible: Bool

    public init(
        windowFingerprint: String?,
        routeSessionID: String? = nil,
        routeKind: ClaudeChatRouteKind? = nil,
        sessionFingerprint: String? = nil,
        turnFingerprint: String? = nil,
        scope: ClaudeChatWindowScope,
        observedStatus: ClaudeChatObservedStatus = .unknown,
        stopButtonVisible: Bool = false,
        latestAssistantCopyVisible: Bool = false,
        snapshotSequence: UInt64 = 0,
        state: SessionState = .unknown,
        finishLabelVisible: Bool = false
    ) {
        self.windowFingerprint = windowFingerprint
        self.routeSessionID = routeSessionID
        self.routeKind = routeKind
        self.sessionFingerprint = sessionFingerprint
        self.turnFingerprint = turnFingerprint
        self.scope = scope
        self.observedStatus = observedStatus
        self.stopButtonVisible = stopButtonVisible
        self.latestAssistantCopyVisible = latestAssistantCopyVisible
        self.snapshotSequence = snapshotSequence
        self.state = state
        self.finishLabelVisible = finishLabelVisible
    }
}

public struct ClaudeChatAdapterScan: Sendable {
    public let observations: [ClaudeChatWindowObservation]
    public let diagnostics: [String: String]

    public init(observations: [ClaudeChatWindowObservation], diagnostics: [String: String]) {
        self.observations = observations
        self.diagnostics = diagnostics
    }
}

/// Pure, fixed-label checks over the small AX projection accepted by the
/// scanner. Message text and option labels are never part of the projection.
public enum ClaudeChatScopeRules {
    public static let authenticationHeading = "New session"
    public static let openSetupButton = "Open Setup"
    public static let checkAgainButton = "Check again"
    public static let authenticationBanner = "Couldn’t sign in to Gateway"
    public static let authenticationDetail = "The provider rejected your credentials. Re-enter them in Setup."
    public static let primaryPane = "Primary pane"
    public static let sessionChapters = "Session chapters"
    public static let chatMessages = "Chat messages"
    public static let sessionActivityPanel = "Session activity panel"
    public static let coworkStopButton = "Stop response"
    public static let respondingLabel = "Claude is responding"
    public static let finishedLabel = "Claude finished the response"
    public static let interruptedLabel = "Claude’s response was interrupted."
    public static let needsInputLabel = "Needs your input"
    public static let stopButton = "Stop"
    public static let skipButton = "Skip"
    public static let submitButton = "Submit"
    public static let copyButton = "Copy"
    public static let forkButton = "Fork from here"
    public static let pinButton = "Pin as chapter"

    public static func isAuthenticationGroup(
        heading: String?,
        buttonLabels: Set<String>,
        directStatusTexts: [String]
    ) -> Bool {
        guard heading == authenticationHeading,
              buttonLabels.contains(openSetupButton),
              buttonLabels.contains(checkAgainButton),
              directStatusTexts.count == 2 else {
            return false
        }
        return directStatusTexts[0] == authenticationBanner
            && directStatusTexts[1] == authenticationDetail
    }

    public static func isPrimaryPane(
        paneLabel: String?,
        directChildRoles: [String],
        siblingGroupLabels: Set<String>
    ) -> Bool {
        guard paneLabel == primaryPane,
              looksLikePrimaryPane(directChildRoles: directChildRoles, siblingGroupLabels: siblingGroupLabels) else {
            return false
        }
        return siblingGroupLabels.contains(sessionChapters)
            && siblingGroupLabels.contains(chatMessages)
    }

    public static func looksLikePrimaryPane(directChildRoles: [String]) -> Bool {
        looksLikePrimaryPane(directChildRoles: directChildRoles, siblingGroupLabels: [])
    }

    public static func looksLikePrimaryPane(
        directChildRoles: [String],
        siblingGroupLabels: Set<String>
    ) -> Bool {
        guard directChildRoles.count >= 3 else { return false }
        let roles = Array(directChildRoles.prefix(3))
        let legacyStatusShape = roles == ["AXStaticText", "AXGroup", "AXGroup"]
        let groupedStatusShape = roles == ["AXGroup", "AXGroup", "AXGroup"]
            && siblingGroupLabels.contains(sessionChapters)
            && siblingGroupLabels.contains(chatMessages)
        return legacyStatusShape || groupedStatusShape
    }

    public static func isCompactStatusGroup(
        directChildRoles: [String],
        secondChildGroupLabel: String?
    ) -> Bool {
        directChildRoles == ["AXStaticText", "AXGroup"]
            && secondChildGroupLabel == chatMessages
    }

    public static func isCoworkStatusLayout(
        paneLabel: String?,
        directChildRoles: [String],
        activityPanelLabel: String?,
        contentChildRoles: [String],
        contentGroupLabels: Set<String>,
        composerHasInputRole: Bool
    ) -> Bool {
        guard paneLabel == primaryPane,
              directChildRoles == ["AXGroup", "AXGroup", "AXStaticText", "AXGroup"],
              activityPanelLabel == sessionActivityPanel,
              contentGroupLabels.contains(chatMessages),
              contentChildRoles.count == 2 else {
            return false
        }
        let hasDirectComposer = contentChildRoles.contains {
            ["AXTextArea", "AXTextField", "AXTextView"].contains($0)
        }
        let hasComposerGroup = contentChildRoles == ["AXGroup", "AXGroup"] && composerHasInputRole
        return hasDirectComposer || hasComposerGroup
    }

    public static func stopButtonLabel(for routeKind: ClaudeChatRouteKind?) -> String {
        routeKind == .cowork ? coworkStopButton : stopButton
    }

    public static func observedStatus(for exactLabel: String?) -> ClaudeChatObservedStatus {
        switch exactLabel {
        case respondingLabel: .responding
        case finishedLabel: .finished
        case interruptedLabel: .interrupted
        default: .unknown
        }
    }

    /// Question state requires the exact status marker and a structured
    /// control shape. Toggle labels and question text are deliberately absent.
    public static func isStructuredQuestion(
        needsInputTextCount: Int,
        optionToggleCount: Int,
        actionButtonLabels: Set<String>
    ) -> Bool {
        needsInputTextCount == 2
            && optionToggleCount >= 2
            && actionButtonLabels.contains(skipButton)
            && actionButtonLabels.contains(submitButton)
    }

    /// The visible Copy button is retained as structural metadata only. It is
    /// not terminal proof: a stopped partial answer can have the same toolbar.
    public static func hasAssistantActionToolbar(_ labels: Set<String>) -> Bool {
        labels.contains(forkButton) && labels.contains(pinButton)
    }

    public static func sessionFingerprint(forLocalRoute route: String?) -> String? {
        guard let route, route.utf8.count <= 256,
              let components = URLComponents(string: route),
              components.scheme == "app",
              components.host == "localhost",
              components.query == nil,
              components.fragment == nil,
        routeSessionID(forLocalRoute: route) != nil else { return nil }
        let digest = SHA256.hash(data: Data("claude-session-v1:\(components.path.lowercased())".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func routeSessionID(forLocalRoute route: String?) -> String? {
        guard let route, route.utf8.count <= 256,
              let components = URLComponents(string: route),
              components.scheme == "app",
              components.host == "localhost",
              components.query == nil,
              components.fragment == nil else { return nil }
        let allowedPrefixes = ["/epitaxy/local_", "/cowork/local_"]
        guard let prefix = allowedPrefixes.first(where: { components.path.hasPrefix($0) }) else { return nil }
        let localID = String(components.path.dropFirst(prefix.count))
        guard isUUID(localID) else { return nil }
        return "local_\(localID.lowercased())"
    }

    public static func routeKind(forLocalRoute route: String?) -> ClaudeChatRouteKind? {
        guard routeSessionID(forLocalRoute: route) != nil,
              let route, let components = URLComponents(string: route) else { return nil }
        if components.path.hasPrefix("/epitaxy/local_") { return .code }
        if components.path.hasPrefix("/cowork/local_") { return .cowork }
        return nil
    }

    /// Native AX observations never finish a turn. Claude's durable session
    /// record owns terminal completion, because Stop and normal end share the
    /// same visible finished label.
    public static func stateForFinishLabel(
        visible: Bool,
        runningSeenInSameWindow: Bool,
        identityContinuous: Bool,
        matchingFinishedSnapshots: Int = 0
    ) -> SessionState {
        _ = visible
        _ = runningSeenInSameWindow
        _ = identityContinuous
        _ = matchingFinishedSnapshots
        return .unknown
    }

    private static func isUUID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return value.utf8.allSatisfy { byte in
            byte == 45 || (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
        }
    }
}

/// Reduces consecutive snapshots for one stable window/session/turn tuple.
/// Without a matching durable `end_turn` hint, a finished AX label stays
/// unknown, even when its Copy toolbar is present.
public struct ClaudeChatStateReducer: Sendable {
    private struct Key: Hashable, Sendable {
        let windowFingerprint: String
        let sessionFingerprint: String
    }

    private struct Transition: Sendable {
        var lastSnapshot: UInt64
        var turnFingerprint: String?
        var sawResponding = false
        var lastStatus: ClaudeChatObservedStatus?
        var lastState: SessionState = .unknown
    }

    private var transitions: [Key: Transition] = [:]

    public init() {}

    public mutating func reset() {
        transitions.removeAll(keepingCapacity: true)
    }

    public mutating func observe(
        _ observation: ClaudeChatWindowObservation
    ) -> SessionState {
        observe(
            windowFingerprint: observation.windowFingerprint,
            sessionFingerprint: observation.sessionFingerprint,
            turnFingerprint: observation.turnFingerprint,
            status: observation.observedStatus,
            stopButtonVisible: observation.stopButtonVisible,
            structuredQuestion: observation.state == .waitingInput,
            snapshot: observation.snapshotSequence,
            routeKind: observation.routeKind
        )
    }

    public mutating func observe(
        windowFingerprint: String?,
        sessionFingerprint: String?,
        turnFingerprint: String?,
        status: ClaudeChatObservedStatus,
        stopButtonVisible: Bool,
        structuredQuestion: Bool,
        snapshot: UInt64,
        routeKind: ClaudeChatRouteKind? = nil
    ) -> SessionState {
        guard let windowFingerprint, let sessionFingerprint else { return .unknown }
        let key = Key(windowFingerprint: windowFingerprint, sessionFingerprint: sessionFingerprint)
        var transition = transitions[key] ?? Transition(lastSnapshot: snapshot)
        if transition.lastSnapshot == snapshot, transition.lastStatus == status {
            return transition.lastState
        }
        if transition.lastSnapshot != snapshot {
            guard transition.lastSnapshot &+ 1 == snapshot else {
                transition = Transition(lastSnapshot: snapshot)
                transition.turnFingerprint = turnFingerprint
                transitions[key] = transition
                return initialState(
                    status: status,
                    stopButtonVisible: stopButtonVisible,
                    structuredQuestion: structuredQuestion,
                    routeKind: routeKind,
                    turnFingerprint: turnFingerprint,
                    transition: &transition,
                    key: key,
                    snapshot: snapshot
                )
            }
        }
        if transition.turnFingerprint != turnFingerprint {
            let interruptedCoworkRun = routeKind == .cowork
                && status == .interrupted
                && transition.sawResponding
                && transition.lastStatus == .responding
            if interruptedCoworkRun {
                transition.turnFingerprint = turnFingerprint
            } else {
                transition = Transition(lastSnapshot: snapshot)
                transition.turnFingerprint = turnFingerprint
            }
        }

        let state: SessionState
        switch status {
        case .responding:
            guard stopButtonVisible else {
                transition.sawResponding = false
                transition.lastState = .unknown
                transition.lastStatus = status
                transition.lastSnapshot = snapshot
                transitions[key] = transition
                return .unknown
            }
            transition.sawResponding = true
            state = structuredQuestion ? .waitingInput : .running
        case .finished:
            transition.sawResponding = false
            state = .unknown
        case .interrupted:
            let wasContinuousCoworkRun = routeKind == .cowork
                && transition.sawResponding
                && transition.lastStatus == .responding
            transition.sawResponding = false
            state = wasContinuousCoworkRun ? .cancelled : .unknown
        case .unknown:
            transition.sawResponding = false
            state = .unknown
        }
        transition.lastSnapshot = snapshot
        transition.lastStatus = status
        transition.lastState = state
        transitions[key] = transition
        return state
    }

    private mutating func initialState(
        status: ClaudeChatObservedStatus,
        stopButtonVisible: Bool,
        structuredQuestion: Bool,
        routeKind: ClaudeChatRouteKind?,
        turnFingerprint: String?,
        transition: inout Transition,
        key: Key,
        snapshot: UInt64
    ) -> SessionState {
        let state: SessionState
        if status == .responding, stopButtonVisible {
            transition.sawResponding = true
            state = structuredQuestion ? .waitingInput : .running
        } else if status == .interrupted && routeKind == .cowork {
            state = .unknown
        } else {
            state = .unknown
        }
        transition.lastSnapshot = snapshot
        transition.lastStatus = status
        transition.turnFingerprint = turnFingerprint
        transition.lastState = state
        transitions[key] = transition
        return state
    }
}

/// Read-only scope discovery for Claude Desktop's Code pane and Gateway auth
/// surface. It reads no chat messages, prompt values, editor values, or files.
/// The completion label is observed only outside the `Chat messages` group and
/// is not converted into a turn-end event until the transition rules are tested.
public final class ClaudeChatAdapter: @unchecked Sendable {
    private static let bundleIdentifier = "com.anthropic.claudefordesktop"
    private static let maximumWindows = 8
    private static let maximumNodesPerWindow = 1_200
    private static let maximumDepth = 18
    private static let totalScanSeconds: TimeInterval = 0.55
    private static let maximumLabelLength = 160
    private static let maximumIdentityWindowsPerProcess = 32
    private static var urlAttribute: CFString { "AXURL" as CFString }

    private let queue = DispatchQueue(label: "local.agentwatch.claude-chat-ax", qos: .utility)
    private var stateReducer = ClaudeChatStateReducer()
    private var windowIdentities: [pid_t: [TrackedClaudeWindowIdentity]] = [:]
    private var scanSequence: UInt64 = 0

    public init() {}

    public func scan() -> ClaudeChatAdapterScan {
        queue.sync { scanOnQueue() }
    }

    private func scanOnQueue() -> ClaudeChatAdapterScan {
        scanSequence &+= 1
        guard AXIsProcessTrusted() else {
            return ClaudeChatAdapterScan(observations: [], diagnostics: ["claude_code": "accessibility_not_trusted"])
        }
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == Self.bundleIdentifier
        }
        guard !applications.isEmpty else {
            return ClaudeChatAdapterScan(observations: [], diagnostics: ["claude_code": "application_not_running"])
        }

        let deadline = ProcessInfo.processInfo.systemUptime + Self.totalScanSeconds
        var remainingNodes = Self.maximumNodesPerWindow * Self.maximumWindows
        var observations: [ClaudeChatWindowObservation] = []
        var sawStatusScope = false
        var sawPrimaryPane = false
        var sawCompactCode = false
        var sawFinishedLabel = false
        var sawRespondingLabel = false
        var sawInterruptedLabel = false
        var sawAuthentication = false
        var sawUnknownAuthenticationSurface = false
        var scanWasPartial = false
        var identityWasMissing = false
        var visitedWindows = 0

        for application in applications {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  visitedWindows < Self.maximumWindows,
                  remainingNodes > 0 else {
                scanWasPartial = true
                break
            }
            let axApplication = AXUIElementCreateApplication(application.processIdentifier)
            guard Self.configureTimeout(axApplication) else {
                scanWasPartial = true
                continue
            }
            guard let windows = Self.copyChildren(axApplication, attribute: kAXWindowsAttribute as CFString) else {
                scanWasPartial = true
                continue
            }
            if windows.count > Self.maximumIdentityWindowsPerProcess {
                scanWasPartial = true
            }
            windowIdentities[application.processIdentifier] = assignWindowIdentities(
                processID: application.processIdentifier,
                windows: windows
            )
            for window in windows.prefix(Self.maximumIdentityWindowsPerProcess) {
                guard ProcessInfo.processInfo.systemUptime < deadline,
                      visitedWindows < Self.maximumWindows,
                      remainingNodes > 0 else {
                    scanWasPartial = true
                    break
                }
                visitedWindows += 1
                let fingerprint = windowFingerprint(
                    processID: application.processIdentifier,
                    window: window
                )
                let result = inspectWindow(window, deadline: deadline, remainingNodes: &remainingNodes)
                scanWasPartial = scanWasPartial || !result.complete
                if result.authentication == .matched {
                    sawAuthentication = true
                    identityWasMissing = identityWasMissing || fingerprint == nil
                    observations.append(.init(windowFingerprint: fingerprint, scope: .authentication))
                    continue
                }
                if result.authentication == .candidateButUnmatched {
                    sawUnknownAuthenticationSurface = true
                }
                sawStatusScope = sawStatusScope || result.statusScopeFound
                if let status = result.statusEvidence {
                    sawStatusScope = true
                    sawPrimaryPane = sawPrimaryPane || status.scope == .primaryPane
                    sawCompactCode = sawCompactCode || status.scope == .compactCode
                    sawFinishedLabel = sawFinishedLabel || status.status == .finished
                    sawRespondingLabel = sawRespondingLabel || status.status == .responding
                    sawInterruptedLabel = sawInterruptedLabel || status.status == .interrupted
                    identityWasMissing = identityWasMissing || fingerprint == nil
                    let sessionFingerprint = status.sessionFingerprint
                    let state = stateReducer.observe(
                        windowFingerprint: fingerprint,
                        sessionFingerprint: sessionFingerprint,
                        turnFingerprint: status.turnFingerprint,
                        status: status.status,
                        stopButtonVisible: status.stopButtonVisible,
                        structuredQuestion: status.structuredQuestion,
                        snapshot: scanSequence,
                        routeKind: status.routeKind
                    )
                    observations.append(.init(
                        windowFingerprint: fingerprint,
                        routeSessionID: status.routeSessionID,
                        routeKind: status.routeKind,
                        sessionFingerprint: sessionFingerprint,
                        turnFingerprint: status.turnFingerprint,
                        scope: status.scope,
                        observedStatus: status.status,
                        stopButtonVisible: status.stopButtonVisible,
                        latestAssistantCopyVisible: status.latestAssistantCopyVisible,
                        snapshotSequence: scanSequence,
                        state: state,
                        finishLabelVisible: status.status == .finished
                    ))
                    if status.routeSessionID == nil {
                        identityWasMissing = true
                    }
                }
            }
        }

        let liveProcessIDs = Set(applications.map(\.processIdentifier))
        windowIdentities = windowIdentities.filter { liveProcessIDs.contains($0.key) }

        let health: String
        if sawAuthentication && !sawStatusScope {
            health = "auth_required"
        } else if sawAuthentication && sawStatusScope {
            health = "mixed_windows_unknown"
        } else if sawStatusScope && sawInterruptedLabel {
            health = "cowork_interrupted_candidate"
        } else if sawStatusScope && sawFinishedLabel {
            health = "finish_candidate_requires_metadata"
        } else if sawStatusScope && sawRespondingLabel {
            health = "status_candidate_visible"
        } else if identityWasMissing {
            health = "window_identity_unavailable"
        } else if sawStatusScope && sawPrimaryPane {
            health = "primary_pane_status_unknown"
        } else if sawStatusScope && sawCompactCode {
            health = "compact_code_status_unknown"
        } else if sawStatusScope {
            health = "status_scope_ambiguous"
        } else if sawUnknownAuthenticationSurface {
            health = "authentication_surface_unconfirmed"
        } else if scanWasPartial {
            health = "scan_partial"
        } else {
            health = "claude_code_scope_not_found"
        }
        return ClaudeChatAdapterScan(
            observations: observations,
            diagnostics: [
                "claude_code": health,
                "claude_code_status_candidate": sawInterruptedLabel ? "interrupted"
                    : (sawFinishedLabel ? "finished" : (sawRespondingLabel ? "responding" : "unknown")),
                "claude_code_session_route": observations.contains { $0.routeSessionID != nil } ? "present" : "unavailable",
                "claude_code_turn_identity": observations.contains { $0.turnFingerprint != nil } ? "available" : "unavailable",
            ]
        )
    }

    private func inspectWindow(
        _ window: AXUIElement,
        deadline: TimeInterval,
        remainingNodes: inout Int
    ) -> WindowScopeResult {
        let root = TreeWorkItem(
            element: window,
            depth: 0,
            insideWebArea: false,
            routeSessionID: nil,
            routeKind: nil,
            sessionFingerprint: nil
        )
        var stack = [root]
        var complete = true
        var authentication: AuthenticationMatch = .none
        var statusCandidates: [ClaudeChatStatusEvidence] = []

        while let item = stack.popLast() {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  remainingNodes > 0,
                  item.depth <= Self.maximumDepth else {
                complete = false
                break
            }
            remainingNodes -= 1
            guard let role = Self.readRole(item.element) else {
                complete = false
                continue
            }

            var insideWebArea = item.insideWebArea
            var routeSessionID = item.routeSessionID
            var routeKind = item.routeKind
            var sessionFingerprint = item.sessionFingerprint
            if role == "AXWebArea" {
                let admission = Self.webAreaAdmission(item.element)
                if !admission.readable { complete = false }
                guard admission.allowed else { continue }
                insideWebArea = true
                routeSessionID = admission.routeSessionID
                routeKind = admission.routeKind
                sessionFingerprint = admission.sessionFingerprint
            }

            if role == "AXGroup", insideWebArea {
                let groupLabel = Self.readGroupLabel(item.element)
                if [ClaudeChatScopeRules.chatMessages, ClaudeChatScopeRules.sessionChapters, "Preview"].contains(groupLabel ?? "") {
                    continue
                }
                let children = Self.copyChildren(item.element)
                if let children {
                    if children.count <= 32,
                       let auth = inspectAuthenticationGroup(children) {
                        if auth == .matched {
                            authentication = .matched
                            break
                        }
                        if auth == .candidateButUnmatched {
                            authentication = .candidateButUnmatched
                        }
                    }
                    if children.count <= 16,
                       let evidence = inspectCoworkStatusLayout(
                        children,
                        group: item.element,
                        routeSessionID: routeSessionID,
                        routeKind: routeKind,
                        sessionFingerprint: sessionFingerprint
                       ) {
                        statusCandidates.append(evidence)
                        continue
                    }
                    if children.count <= 16,
                       let evidence = inspectPrimaryPaneGroup(
                        children,
                        group: item.element,
                        routeSessionID: routeSessionID,
                        routeKind: routeKind,
                        sessionFingerprint: sessionFingerprint
                       ) {
                        statusCandidates.append(evidence)
                        // The primary pane is the safe boundary. The chat
                        // group is inspected only for fixed control structure.
                        continue
                    }
                    if children.count <= 16,
                       let evidence = inspectCompactStatusGroup(
                        children,
                        routeSessionID: routeSessionID,
                        routeKind: routeKind,
                        sessionFingerprint: sessionFingerprint
                       ) {
                        statusCandidates.append(evidence)
                        continue
                    }
                    let childRoles = Array(children.prefix(3)).compactMap(Self.readRole)
                    let childGroupLabels = Set(children.compactMap(Self.readGroupLabel))
                    if ClaudeChatScopeRules.looksLikePrimaryPane(
                        directChildRoles: childRoles,
                        siblingGroupLabels: childGroupLabels
                    ) {
                        // The role shape resembles the pane but its fixed
                        // sibling labels were not confirmed. Fail closed and
                        // do not enter the candidate's message descendants.
                        complete = false
                        continue
                    }
                    if children.count > 40 {
                        complete = false
                        continue
                    }
                    stack.append(contentsOf: children.reversed().compactMap { child in
                        guard let childRole = Self.readRole(child), Self.isContainerRole(childRole) else { return nil }
                        return TreeWorkItem(
                            element: child,
                            depth: item.depth + 1,
                            insideWebArea: insideWebArea,
                            routeSessionID: routeSessionID,
                            routeKind: routeKind,
                            sessionFingerprint: sessionFingerprint
                        )
                    })
                } else {
                    complete = false
                }
                continue
            }

            guard Self.isContainerRole(role) else { continue }
            guard let children = Self.copyChildren(item.element) else {
                complete = false
                continue
            }
            stack.append(contentsOf: children.reversed().compactMap { child in
                guard let childRole = Self.readRole(child), Self.isContainerRole(childRole) else { return nil }
                return TreeWorkItem(
                    element: child,
                    depth: item.depth + 1,
                    insideWebArea: insideWebArea,
                    routeSessionID: routeSessionID,
                    routeKind: routeKind,
                    sessionFingerprint: sessionFingerprint
                )
            })
        }
        let chosenStatus: ClaudeChatStatusEvidence?
        if statusCandidates.count == 1 {
            chosenStatus = statusCandidates[0]
        } else if statusCandidates.count > 1 {
            chosenStatus = nil
            complete = false
        } else {
            chosenStatus = nil
        }
        return WindowScopeResult(
            authentication: authentication,
            statusEvidence: chosenStatus,
            statusScopeFound: !statusCandidates.isEmpty,
            complete: complete
        )
    }

    private func inspectAuthenticationGroup(
        _ children: [AXUIElement]
    ) -> AuthenticationMatch? {
        let headings = children.filter { Self.readRole($0) == "AXHeading" }
        let staticTexts = children.filter { Self.readRole($0) == "AXStaticText" }
        let buttons = children.filter { Self.readRole($0) == "AXButton" }
        guard !headings.isEmpty, staticTexts.count >= 2, buttons.count >= 2 else { return nil }

        // Button labels are read only on this small auth-panel candidate.
        let hasOpenSetup = buttons.contains { Self.matchesShortLabel($0, attributes: [kAXTitleAttribute as CFString], allowed: [ClaudeChatScopeRules.openSetupButton]) }
        let hasCheckAgain = buttons.contains { Self.matchesShortLabel($0, attributes: [kAXTitleAttribute as CFString], allowed: [ClaudeChatScopeRules.checkAgainButton]) }
        guard hasOpenSetup && hasCheckAgain else { return nil }

        let heading = Self.readShortLabel(headings[0], attributes: [kAXValueAttribute as CFString, kAXTitleAttribute as CFString])
        guard heading == ClaudeChatScopeRules.authenticationHeading else {
            return .candidateButUnmatched
        }
        let directStatusTexts = [
            Self.readShortLabel(staticTexts[0], attributes: [kAXValueAttribute as CFString]),
            Self.readShortLabel(staticTexts[1], attributes: [kAXValueAttribute as CFString]),
        ].compactMap { $0 }
        guard directStatusTexts.count == 2 else { return .candidateButUnmatched }
        return ClaudeChatScopeRules.isAuthenticationGroup(
            heading: heading,
            buttonLabels: [ClaudeChatScopeRules.openSetupButton, ClaudeChatScopeRules.checkAgainButton],
            directStatusTexts: directStatusTexts
        ) ? .matched : .candidateButUnmatched
    }

    private func inspectCoworkStatusLayout(
        _ children: [AXUIElement],
        group: AXUIElement,
        routeSessionID: String?,
        routeKind: ClaudeChatRouteKind?,
        sessionFingerprint: String?
    ) -> ClaudeChatStatusEvidence? {
        guard routeKind == .cowork, routeSessionID != nil, sessionFingerprint != nil,
              children.count == 4 else { return nil }
        let paneRoles = children.compactMap(Self.readRole)
        let contentGroup = children[1]
        guard let contentChildren = Self.copyChildren(contentGroup),
              contentChildren.count == 2 else { return nil }
        let contentRoles = contentChildren.compactMap(Self.readRole)
        let contentLabels = Set(contentChildren.compactMap(Self.readGroupLabel))
        guard let chatIndex = contentChildren.firstIndex(where: {
            Self.readRole($0) == "AXGroup"
                && Self.readGroupLabel($0) == ClaudeChatScopeRules.chatMessages
        }) else { return nil }
        let composerIndex = chatIndex == 0 ? 1 : 0
        let composer = contentChildren[composerIndex]
        let composerRole = Self.readRole(composer)
        let composerRoles: [String]
        if composerRole == "AXGroup",
           let nodes = Self.fixedControlProjection(composer, maximumNodes: 64, maximumDepth: 4) {
            composerRoles = nodes.compactMap(Self.readRole)
        } else {
            composerRoles = composerRole.map { [$0] } ?? []
        }
        let hasComposerInput = composerRoles.contains {
            ["AXTextArea", "AXTextField", "AXTextView"].contains($0)
        }
        guard ClaudeChatScopeRules.isCoworkStatusLayout(
            paneLabel: Self.readGroupLabel(group),
            directChildRoles: paneRoles,
            activityPanelLabel: Self.readGroupLabel(children[3]),
            contentChildRoles: contentRoles,
            contentGroupLabels: contentLabels,
            composerHasInputRole: hasComposerInput
        ),
        let statusLabel = Self.readExactStatusLabel(children[2]) else { return nil }

        let status = ClaudeChatScopeRules.observedStatus(for: statusLabel)
        guard status != .unknown else { return nil }
        let chatEvidence = inspectChatMessagesGroup(contentChildren[chatIndex], routeKind: .cowork)
        let stopButtonVisible = chatEvidence.stopButtonVisible
            || Self.containsButton([contentGroup], label: ClaudeChatScopeRules.coworkStopButton)
        return ClaudeChatStatusEvidence(
            scope: .cowork,
            routeKind: .cowork,
            routeSessionID: routeSessionID,
            sessionFingerprint: sessionFingerprint,
            turnFingerprint: chatEvidence.turnFingerprint,
            status: status,
            stopButtonVisible: stopButtonVisible,
            structuredQuestion: status == .responding && chatEvidence.structuredQuestion,
            latestAssistantCopyVisible: chatEvidence.latestAssistantCopyVisible
        )
    }

    private func inspectPrimaryPaneGroup(
        _ children: [AXUIElement],
        group: AXUIElement,
        routeSessionID: String?,
        routeKind: ClaudeChatRouteKind?,
        sessionFingerprint: String?
    ) -> ClaudeChatStatusEvidence? {
        guard children.count >= 3 else { return nil }
        let roles = Array(children.prefix(3)).compactMap(Self.readRole)
        let groupLabels = children.compactMap(Self.readGroupLabel)
        let siblingLabels = Set(groupLabels)
        let paneLabel = Self.readGroupLabel(group)
        guard ClaudeChatScopeRules.isPrimaryPane(
            paneLabel: paneLabel,
            directChildRoles: roles,
            siblingGroupLabels: siblingLabels
        ) else { return nil }

        let chatIndex = children.firstIndex { Self.readGroupLabel($0) == ClaudeChatScopeRules.chatMessages }
        guard let chatIndex else { return nil }
        let chatEvidence = inspectChatMessagesGroup(children[chatIndex], routeKind: routeKind)

        let statusLabel: String?
        let stopVisible: Bool
        if roles[0] == "AXStaticText" {
            statusLabel = Self.readExactStatusLabel(children[0])
            stopVisible = chatEvidence.stopButtonVisible
        } else {
            let statusProjections = children.compactMap { child -> StatusGroupEvidence? in
                guard Self.readRole(child) == "AXGroup",
                      ![ClaudeChatScopeRules.sessionChapters, ClaudeChatScopeRules.chatMessages]
                        .contains(Self.readGroupLabel(child) ?? "") else { return nil }
                return inspectStatusGroup(child, routeKind: routeKind)
            }
            guard let statusProjection = statusProjections.first(where: { $0.label != nil }) else { return nil }
            statusLabel = statusProjection.label
            stopVisible = statusProjection.stopButtonVisible || chatEvidence.stopButtonVisible
        }
        let status = ClaudeChatScopeRules.observedStatus(for: statusLabel)
        guard status != .unknown,
              !(status == .interrupted && routeKind == .cowork) else { return nil }
        return ClaudeChatStatusEvidence(
            scope: routeKind == .cowork ? .cowork : .primaryPane,
            routeKind: routeKind,
            routeSessionID: routeSessionID,
            sessionFingerprint: sessionFingerprint,
            turnFingerprint: chatEvidence.turnFingerprint,
            status: status,
            stopButtonVisible: stopVisible,
            structuredQuestion: status == .responding && chatEvidence.structuredQuestion,
            latestAssistantCopyVisible: chatEvidence.latestAssistantCopyVisible
        )
    }

    private func inspectCompactStatusGroup(
        _ children: [AXUIElement],
        routeSessionID: String?,
        routeKind: ClaudeChatRouteKind?,
        sessionFingerprint: String?
    ) -> ClaudeChatStatusEvidence? {
        guard children.count == 2,
              ClaudeChatScopeRules.isCompactStatusGroup(
                directChildRoles: children.compactMap(Self.readRole),
                secondChildGroupLabel: Self.readGroupLabel(children[1])
              ) else { return nil }
        let status = ClaudeChatScopeRules.observedStatus(for: Self.readExactStatusLabel(children[0]))
        guard status != .unknown,
              !(status == .interrupted && routeKind == .cowork) else { return nil }
        let chatEvidence = inspectChatMessagesGroup(children[1], routeKind: routeKind)
        return ClaudeChatStatusEvidence(
            scope: routeKind == .cowork ? .cowork : .compactCode,
            routeKind: routeKind,
            routeSessionID: routeSessionID,
            sessionFingerprint: sessionFingerprint,
            turnFingerprint: chatEvidence.turnFingerprint,
            status: status,
            stopButtonVisible: chatEvidence.stopButtonVisible,
            structuredQuestion: status == .responding && chatEvidence.structuredQuestion,
            latestAssistantCopyVisible: chatEvidence.latestAssistantCopyVisible
        )
    }

    private func inspectStatusGroup(
        _ group: AXUIElement,
        routeKind: ClaudeChatRouteKind?
    ) -> StatusGroupEvidence {
        guard let children = Self.copyChildren(group), children.count <= 24 else {
            return StatusGroupEvidence(label: nil, stopButtonVisible: false)
        }
        let label = children.first(where: { Self.readRole($0) == "AXStaticText" })
            .flatMap(Self.readExactStatusLabel)
        return StatusGroupEvidence(
            label: label,
            stopButtonVisible: Self.containsButton(
                [group], label: ClaudeChatScopeRules.stopButtonLabel(for: routeKind)
            )
        )
    }

    private func inspectChatMessagesGroup(
        _ group: AXUIElement,
        routeKind: ClaudeChatRouteKind?
    ) -> ChatMessagesEvidence {
        guard let children = Self.copyChildren(group), children.count <= 500 else {
            return ChatMessagesEvidence()
        }
        let topLevelGroups = Array(children.suffix(32))

        var projections: [QuestionGroupProjection] = []
        let stopButtonLabel = ClaudeChatScopeRules.stopButtonLabel(for: routeKind)
        var stopButtonVisible = Self.containsButton([group], label: stopButtonLabel)
        var latestAssistantCopyVisible = false
        var latestTurnFingerprint: String?

        for messageGroup in topLevelGroups where Self.readRole(messageGroup) == "AXGroup" {
            guard let nodes = Self.fixedControlProjection(messageGroup, maximumNodes: 96, maximumDepth: 4) else { continue }
            var needsInputTextCount = 0
            var optionToggleCount = 0
            var questionActionLabels: Set<String> = []
            var toolbarLabels: Set<String> = []
            for node in nodes {
                switch Self.readRole(node) {
                case "AXStaticText":
                    if Self.matchesShortLabel(
                        node,
                        attributes: [kAXValueAttribute as CFString],
                        allowed: [ClaudeChatScopeRules.needsInputLabel]
                    ) {
                        needsInputTextCount += 1
                    }
                case "AXToggleButton":
                    optionToggleCount += 1
                case "AXButton":
                    for exactLabel in [
                        stopButtonLabel,
                        ClaudeChatScopeRules.skipButton,
                        ClaudeChatScopeRules.submitButton,
                        ClaudeChatScopeRules.copyButton,
                        ClaudeChatScopeRules.forkButton,
                        ClaudeChatScopeRules.pinButton,
                    ] where Self.matchesShortLabel(
                        node,
                        attributes: [kAXTitleAttribute as CFString],
                        allowed: [exactLabel]
                    ) {
                        if [ClaudeChatScopeRules.skipButton, ClaudeChatScopeRules.submitButton].contains(exactLabel) {
                            questionActionLabels.insert(exactLabel)
                        }
                        toolbarLabels.insert(exactLabel)
                    }
                default:
                    break
                }
            }
            stopButtonVisible = stopButtonVisible || toolbarLabels.contains(stopButtonLabel)
            projections.append(QuestionGroupProjection(
                needsInputTextCount: needsInputTextCount,
                optionToggleCount: optionToggleCount,
                actionButtonLabels: questionActionLabels
            ))
            if ClaudeChatScopeRules.hasAssistantActionToolbar(toolbarLabels) {
                latestAssistantCopyVisible = toolbarLabels.contains(ClaudeChatScopeRules.copyButton)
                latestTurnFingerprint = Self.hashedIdentifier(messageGroup)
                    ?? Self.latestActionToolbarIdentifier(in: messageGroup)
            }
        }

        let structuredQuestion = projections.indices.contains { index in
            let question = projections[index]
            guard question.optionToggleCount >= 2,
                  question.actionButtonLabels.contains(ClaudeChatScopeRules.skipButton),
                  question.actionButtonLabels.contains(ClaudeChatScopeRules.submitButton) else { return false }
            if question.needsInputTextCount == 2 { return true }
            let previousHasStatus = index > projections.startIndex
                && projections[index - 1].needsInputTextCount == 2
            let nextIndex = projections.index(after: index)
            let nextHasStatus = nextIndex < projections.endIndex
                && projections[nextIndex].needsInputTextCount == 2
            return previousHasStatus || nextHasStatus
        }

        return ChatMessagesEvidence(
            structuredQuestion: structuredQuestion,
            stopButtonVisible: stopButtonVisible,
            latestAssistantCopyVisible: latestAssistantCopyVisible,
            turnFingerprint: latestTurnFingerprint
        )
    }

    private static func isContainerRole(_ role: String) -> Bool {
        ["AXApplication", "AXWindow", "AXGroup", "AXWebArea", "AXScrollArea", "AXSplitGroup", "AXTabGroup"]
            .contains(role)
    }

    private static func copyChildren(_ element: AXUIElement, attribute: CFString = kAXChildrenAttribute as CFString) -> [AXUIElement]? {
        guard configureTimeout(element) else { return nil }
        var copied: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &copied) == .success,
              let copied,
              CFGetTypeID(copied) == CFArrayGetTypeID() else { return nil }
        let array = unsafeDowncast(copied, to: CFArray.self)
        let count = CFArrayGetCount(array)
        guard count <= 500 else { return nil }
        var result: [AXUIElement] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            let reference = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { continue }
            result.append(Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue())
        }
        return result
    }

    private static func readRole(_ element: AXUIElement) -> String? {
        guard configureTimeout(element) else { return nil }
        return readString(element, attribute: kAXRoleAttribute as CFString, maximumLength: 64)
    }

    private static func readGroupLabel(_ element: AXUIElement) -> String? {
        guard readRole(element) == "AXGroup" else { return nil }
        for attribute in [kAXDescriptionAttribute as CFString, kAXTitleAttribute as CFString] {
            if let value = readString(element, attribute: attribute, maximumLength: 64),
               [ClaudeChatScopeRules.primaryPane, ClaudeChatScopeRules.sessionChapters,
                ClaudeChatScopeRules.chatMessages, ClaudeChatScopeRules.sessionActivityPanel,
                "Preview"].contains(value) {
                return value
            }
        }
        return nil
    }

    private static func readString(_ element: AXUIElement, attribute: CFString, maximumLength: Int) -> String? {
        guard configureTimeout(element) else { return nil }
        var copied: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &copied) == .success,
              let copied,
              CFGetTypeID(copied) == CFStringGetTypeID(),
              let value = copied as? String,
              value.utf8.count <= maximumLength,
              !value.contains(where: \.isNewline) else { return nil }
        return value
    }

    private static func readShortLabel(_ element: AXUIElement, attributes: [CFString]) -> String? {
        for attribute in attributes {
            if let value = readString(element, attribute: attribute, maximumLength: Self.maximumLabelLength) {
                return value
            }
        }
        return nil
    }

    private static func readExactStatusLabel(_ element: AXUIElement) -> String? {
        guard readRole(element) == "AXStaticText",
              let value = readString(element, attribute: kAXValueAttribute as CFString, maximumLength: Self.maximumLabelLength),
              [ClaudeChatScopeRules.respondingLabel, ClaudeChatScopeRules.finishedLabel,
               ClaudeChatScopeRules.interruptedLabel].contains(value) else {
            return nil
        }
        return value
    }

    private static func containsButton(_ groups: [AXUIElement], label: String) -> Bool {
        groups.contains { group in
            guard let nodes = fixedControlProjection(group, maximumNodes: 48, maximumDepth: 3) else { return false }
            return nodes.contains { node in
                readRole(node) == "AXButton"
                    && matchesShortLabel(node, attributes: [kAXTitleAttribute as CFString], allowed: [label])
            }
        }
    }

    /// Returns only shallow container/control nodes. It never reads static
    /// text other than the fixed status marker and never reads toggle labels.
    private static func fixedControlProjection(
        _ root: AXUIElement,
        maximumNodes: Int,
        maximumDepth: Int
    ) -> [AXUIElement]? {
        var pending = [TreeWorkItem(
            element: root,
            depth: 0,
            insideWebArea: true,
            routeSessionID: nil,
            routeKind: nil,
            sessionFingerprint: nil
        )]
        var result: [AXUIElement] = []
        while let item = pending.popLast() {
            guard result.count < maximumNodes, item.depth <= maximumDepth,
                  let role = readRole(item.element) else { return nil }
            result.append(item.element)
            guard ["AXGroup", "AXScrollArea", "AXSplitGroup"].contains(role),
                  let children = copyChildren(item.element), children.count <= 96 else { continue }
            for child in children.reversed() {
                guard let childRole = readRole(child),
                      ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXStaticText", "AXButton",
                       "AXToggleButton", "AXTextArea", "AXTextField", "AXTextView"].contains(childRole) else {
                    continue
                }
                pending.append(TreeWorkItem(
                    element: child,
                    depth: item.depth + 1,
                    insideWebArea: true,
                    routeSessionID: nil,
                    routeKind: nil,
                    sessionFingerprint: nil
                ))
            }
        }
        return result
    }

    private static func hashedIdentifier(_ element: AXUIElement) -> String? {
        guard configureTimeout(element) else { return nil }
        var copied: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &copied) == .success,
              let copied,
              CFGetTypeID(copied) == CFStringGetTypeID(),
              let identifier = copied as? String,
              !identifier.isEmpty,
              identifier.utf8.count <= 256 else { return nil }
        let digest = SHA256.hash(data: Data("claude-turn-v1:\(identifier)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func latestActionToolbarIdentifier(in messageGroup: AXUIElement) -> String? {
        guard let nodes = fixedControlProjection(messageGroup, maximumNodes: 96, maximumDepth: 4) else { return nil }
        for node in nodes.reversed() where readRole(node) == "AXGroup" {
            guard let children = copyChildren(node), children.count <= 24 else { continue }
            var labels: Set<String> = []
            for button in children where readRole(button) == "AXButton" {
                for label in [ClaudeChatScopeRules.forkButton, ClaudeChatScopeRules.pinButton] where
                    matchesShortLabel(button, attributes: [kAXTitleAttribute as CFString], allowed: [label]) {
                    labels.insert(label)
                }
            }
            if ClaudeChatScopeRules.hasAssistantActionToolbar(labels) {
                return hashedIdentifier(node)
            }
        }
        return nil
    }

    private static func matchesShortLabel(
        _ element: AXUIElement,
        attributes: [CFString],
        allowed: Set<String>
    ) -> Bool {
        attributes.contains { attribute in
            guard let value = readString(element, attribute: attribute, maximumLength: Self.maximumLabelLength) else { return false }
            return allowed.contains(value)
        }
    }

    private static func webAreaAdmission(_ element: AXUIElement) -> WebAreaAdmission {
        guard configureTimeout(element) else {
            return WebAreaAdmission(allowed: false, readable: false, routeSessionID: nil, routeKind: nil, sessionFingerprint: nil)
        }
        var copied: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, urlAttribute, &copied)
        guard result == .success, let copied else {
            return WebAreaAdmission(
                allowed: true,
                readable: result == .noValue || result == .attributeUnsupported,
                routeSessionID: nil,
                routeKind: nil,
                sessionFingerprint: nil
            )
        }
        let urlString: String?
        if let string = copied as? String {
            urlString = string
        } else if CFGetTypeID(copied) == CFURLGetTypeID(), let url = copied as? URL {
            urlString = url.absoluteString
        } else {
            return WebAreaAdmission(allowed: false, readable: false, routeSessionID: nil, routeKind: nil, sessionFingerprint: nil)
        }
        guard let urlString, urlString.utf8.count <= 1_024 else {
            return WebAreaAdmission(allowed: false, readable: false, routeSessionID: nil, routeKind: nil, sessionFingerprint: nil)
        }
        let lowered = urlString.lowercased()
        let excluded = lowered.hasPrefix("file://") || lowered.contains(".pdf") || lowered.contains("preview")
        return WebAreaAdmission(
            allowed: !excluded,
            readable: true,
            routeSessionID: ClaudeChatScopeRules.routeSessionID(forLocalRoute: urlString),
            routeKind: ClaudeChatScopeRules.routeKind(forLocalRoute: urlString),
            sessionFingerprint: ClaudeChatScopeRules.sessionFingerprint(forLocalRoute: urlString)
        )
    }

    private func assignWindowIdentities(
        processID: pid_t,
        windows: [AXUIElement]
    ) -> [TrackedClaudeWindowIdentity] {
        let previous = windowIdentities[processID] ?? []
        var used = Set<String>()
        return windows.prefix(Self.maximumIdentityWindowsPerProcess).map { window in
            let match = previous.first {
                !used.contains($0.identifier) && CFEqual($0.element, window)
            }
            let identifier = match?.identifier ?? UUID().uuidString
            used.insert(identifier)
            return TrackedClaudeWindowIdentity(identifier: identifier, element: window)
        }
    }

    private func windowFingerprint(processID: pid_t, window: AXUIElement) -> String? {
        guard let identifier = windowIdentities[processID]?.first(where: {
            CFEqual($0.element, window)
        })?.identifier else { return nil }
        let key = "claude-window-v1:\(processID):\(identifier)"
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func configureTimeout(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.1) == .success
    }
}

private struct TrackedClaudeWindowIdentity {
    let identifier: String
    let element: AXUIElement
}

private struct TreeWorkItem {
    let element: AXUIElement
    let depth: Int
    let insideWebArea: Bool
    let routeSessionID: String?
    let routeKind: ClaudeChatRouteKind?
    let sessionFingerprint: String?
}

private struct WebAreaAdmission {
    let allowed: Bool
    let readable: Bool
    let routeSessionID: String?
    let routeKind: ClaudeChatRouteKind?
    let sessionFingerprint: String?
}

private struct ClaudeChatStatusEvidence {
    let scope: ClaudeChatWindowScope
    let routeKind: ClaudeChatRouteKind?
    let routeSessionID: String?
    let sessionFingerprint: String?
    let turnFingerprint: String?
    let status: ClaudeChatObservedStatus
    let stopButtonVisible: Bool
    let structuredQuestion: Bool
    let latestAssistantCopyVisible: Bool
}

private struct StatusGroupEvidence {
    let label: String?
    let stopButtonVisible: Bool
}

private struct ChatMessagesEvidence {
    var structuredQuestion = false
    var stopButtonVisible = false
    var latestAssistantCopyVisible = false
    var turnFingerprint: String?
}

private struct QuestionGroupProjection {
    let needsInputTextCount: Int
    let optionToggleCount: Int
    let actionButtonLabels: Set<String>
}

private enum AuthenticationMatch {
    case none
    case candidateButUnmatched
    case matched
}

private struct WindowScopeResult {
    let authentication: AuthenticationMatch
    let statusEvidence: ClaudeChatStatusEvidence?
    let statusScopeFound: Bool
    let complete: Bool
}
