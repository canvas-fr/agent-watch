import Foundation

public enum SessionState: String, Codable, Sendable, Hashable {
    case unknown
    case running
    case waitingApproval
    case waitingInput
    case responseEnded
    case failed
    case cancelled
}

public enum EvidenceKind: String, Codable, Sendable {
    case explicit
    case inferred
}

public struct MonitorEvent: Codable, Sendable {
    public let id: String
    public let appID: String
    public let sessionID: String
    public let turnID: String
    public let state: SessionState
    public let evidence: EvidenceKind
    public let observedAt: Date
    public let sequence: Int?
    public let parentSessionID: String?
    public let source: String

    public init(
        id: String,
        appID: String,
        sessionID: String,
        turnID: String,
        state: SessionState,
        evidence: EvidenceKind,
        observedAt: Date,
        sequence: Int? = nil,
        parentSessionID: String? = nil,
        source: String
    ) {
        self.id = id
        self.appID = appID
        self.sessionID = sessionID
        self.turnID = turnID
        self.state = state
        self.evidence = evidence
        self.observedAt = observedAt
        self.sequence = sequence
        self.parentSessionID = parentSessionID
        self.source = source
    }
}

public struct SessionSnapshot: Codable, Identifiable, Sendable {
    public let id: String
    public let appID: String
    public let sessionID: String
    public let turnID: String
    public let state: SessionState
    public let evidence: EvidenceKind
    public let updatedAt: Date
    public let source: String
    public let parentSessionID: String?
    public let stale: Bool

    public init(
        appID: String,
        sessionID: String,
        turnID: String,
        state: SessionState,
        evidence: EvidenceKind,
        updatedAt: Date,
        source: String,
        parentSessionID: String?,
        stale: Bool
    ) {
        self.id = Self.makeID(appID: appID, sessionID: sessionID)
        self.appID = appID
        self.sessionID = sessionID
        self.turnID = turnID
        self.state = state
        self.evidence = evidence
        self.updatedAt = updatedAt
        self.source = source
        self.parentSessionID = parentSessionID
        self.stale = stale
    }

    private static func makeID(appID: String, sessionID: String) -> String {
        "\(appID.utf8.count):\(appID)\(sessionID)"
    }
}

public struct MonitorNotice: Sendable {
    public let appID: String
    public let sessionID: String
    public let state: SessionState
    public let evidence: EvidenceKind

    public init(appID: String, sessionID: String, state: SessionState, evidence: EvidenceKind) {
        self.appID = appID
        self.sessionID = sessionID
        self.state = state
        self.evidence = evidence
    }
}

private struct SessionKey: Codable, Hashable, Sendable {
    let appID: String
    let sessionID: String
}

private func sequenceDomain(for source: String) -> String {
    if source == "codex_app_server" || source.hasPrefix("codex_app_server:") {
        return "codex_app_server"
    }
    for domain in ["codex", "dsh", "ax"] where source == domain || source.hasPrefix(domain + ":") {
        return domain
    }
    return String(source.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(source))
}

private struct SessionRecord: Codable, Sendable {
    var snapshot: SessionSnapshot
    var lastObservedState: SessionState
    var terminalState: SessionState?
    var eventIDs: [String] = []
    var eventIDSet: Set<String> = []
    var closedTurnIDs: [String] = []
    var closedTurnIDSet: Set<String> = []
    var notifiedTerminalStates: Set<SessionState> = []
    var lastSequencesByDomain: [String: Int] = [:]
    var lastTouched: UInt64

    private enum CodingKeys: String, CodingKey {
        case snapshot, lastObservedState, terminalState, eventIDs, eventIDSet
        case closedTurnIDs, closedTurnIDSet, notifiedTerminalStates
        case lastSequencesByDomain, lastSequence, lastTouched
    }

    init(snapshot: SessionSnapshot, lastObservedState: SessionState, terminalState: SessionState?, lastTouched: UInt64) {
        self.snapshot = snapshot
        self.lastObservedState = lastObservedState
        self.terminalState = terminalState
        self.lastTouched = lastTouched
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try values.decode(SessionSnapshot.self, forKey: .snapshot)
        lastObservedState = try values.decode(SessionState.self, forKey: .lastObservedState)
        terminalState = try values.decodeIfPresent(SessionState.self, forKey: .terminalState)
        eventIDs = try values.decode([String].self, forKey: .eventIDs)
        eventIDSet = try values.decode(Set<String>.self, forKey: .eventIDSet)
        closedTurnIDs = try values.decode([String].self, forKey: .closedTurnIDs)
        closedTurnIDSet = try values.decode(Set<String>.self, forKey: .closedTurnIDSet)
        notifiedTerminalStates = try values.decode(Set<SessionState>.self, forKey: .notifiedTerminalStates)
        lastSequencesByDomain = try values.decodeIfPresent([String: Int].self, forKey: .lastSequencesByDomain) ?? [:]
        if lastSequencesByDomain.isEmpty,
           let legacySequence = try values.decodeIfPresent(Int.self, forKey: .lastSequence) {
            lastSequencesByDomain[sequenceDomain(for: snapshot.source)] = legacySequence
        }
        lastTouched = try values.decode(UInt64.self, forKey: .lastTouched)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(snapshot, forKey: .snapshot)
        try values.encode(lastObservedState, forKey: .lastObservedState)
        try values.encodeIfPresent(terminalState, forKey: .terminalState)
        try values.encode(eventIDs, forKey: .eventIDs)
        try values.encode(eventIDSet, forKey: .eventIDSet)
        try values.encode(closedTurnIDs, forKey: .closedTurnIDs)
        try values.encode(closedTurnIDSet, forKey: .closedTurnIDSet)
        try values.encode(notifiedTerminalStates, forKey: .notifiedTerminalStates)
        try values.encode(lastSequencesByDomain, forKey: .lastSequencesByDomain)
        try values.encode(lastTouched, forKey: .lastTouched)
    }

    mutating func rememberEvent(_ id: String) {
        guard eventIDSet.insert(id).inserted else { return }
        eventIDs.append(id)
        if eventIDs.count > SessionStore.maximumRememberedEvents {
            let removedID = eventIDs.removeFirst()
            eventIDSet.remove(removedID)
        }
    }

    mutating func closeTurn(_ id: String) {
        guard closedTurnIDSet.insert(id).inserted else { return }
        closedTurnIDs.append(id)
        if closedTurnIDs.count > SessionStore.maximumRememberedTurns {
            let removedID = closedTurnIDs.removeFirst()
            closedTurnIDSet.remove(removedID)
        }
    }
}

public struct SessionStore: Codable, Sendable {
    fileprivate static let maximumRememberedEvents = 128
    fileprivate static let maximumRememberedTurns = 128
    private static let maximumSessions = 500
    private static let allowedFutureSkew: TimeInterval = 30
    private static let notifiableStates: Set<SessionState> = [
        .waitingApproval, .waitingInput, .responseEnded, .failed
    ]
    private static let rollbackStates: Set<SessionState> = [
        .running, .waitingApproval, .waitingInput
    ]
    private static let terminalStates: Set<SessionState> = [
        .responseEnded, .failed, .cancelled
    ]
    private static let deduplicatedNoticeStates: Set<SessionState> = [
        .responseEnded, .failed
    ]

    private var records: [SessionKey: SessionRecord] = [:]
    private var touchCounter: UInt64 = 0

    public init() {}

    public mutating func remove(appID: String) {
        records = records.filter { $0.key.appID != appID }
    }

    public mutating func removeInferred() {
        records = records.filter { $0.value.snapshot.evidence != .inferred }
    }

    /// Reclassifies persisted terminal states produced by legacy Stop hooks.
    /// Those hooks recorded stop intent, not a completed turn. Event IDs and
    /// closed-turn history remain intact so replay cannot restore the false end.
    public mutating func invalidatePrematureStopCompletions() -> [(appID: String, sessionID: String, turnID: String)] {
        let stopSources: Set<String> = [
            "codex:Stop",
            "codex:SubagentStop",
            "claude_code:Stop",
            "claude_code:SubagentStop",
        ]
        let orderedKeys = records.keys.sorted {
            if $0.appID != $1.appID { return $0.appID < $1.appID }
            return $0.sessionID < $1.sessionID
        }
        var invalidated: [(appID: String, sessionID: String, turnID: String)] = []

        for key in orderedKeys {
            guard var record = records[key],
                  record.snapshot.state == .responseEnded,
                  stopSources.contains(record.snapshot.source) else {
                continue
            }

            let previous = record.snapshot
            invalidated.append((appID: previous.appID, sessionID: previous.sessionID, turnID: previous.turnID))
            record.lastObservedState = .unknown
            record.terminalState = nil
            record.notifiedTerminalStates.remove(.responseEnded)
            record.snapshot = SessionSnapshot(
                appID: previous.appID,
                sessionID: previous.sessionID,
                turnID: previous.turnID,
                state: .unknown,
                evidence: previous.evidence,
                updatedAt: previous.updatedAt,
                source: previous.source + ":awaiting_confirmation",
                parentSessionID: previous.parentSessionID,
                stale: previous.stale
            )
            record.lastTouched = nextTouch()
            records[key] = record
        }

        return invalidated
    }

    public var sessions: [SessionSnapshot] {
        records.values.map(\.snapshot).sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.id < $1.id
        }
    }

    @discardableResult
    public mutating func apply(_ event: MonitorEvent, now: Date = Date()) -> MonitorNotice? {
        let futureSkew = event.observedAt.timeIntervalSince(now)
        guard futureSkew.isFinite, futureSkew <= Self.allowedFutureSkew else { return nil }

        let key = SessionKey(appID: event.appID, sessionID: event.sessionID)
        if var record = records[key] {
            guard !record.eventIDSet.contains(event.id) else { return nil }

            let startsNewTurn = record.snapshot.turnID != event.turnID
            if startsNewTurn {
                guard !record.closedTurnIDSet.contains(event.turnID),
                      event.observedAt >= record.snapshot.updatedAt else { return nil }
                record.closeTurn(record.snapshot.turnID)
                record.lastObservedState = .unknown
                record.terminalState = nil
                record.notifiedTerminalStates.removeAll(keepingCapacity: true)
                record.lastSequencesByDomain.removeAll(keepingCapacity: true)
            } else {
                guard event.observedAt >= record.snapshot.updatedAt else { return nil }
                let domain = sequenceDomain(for: event.source)
                if let sequence = event.sequence,
                   let previousSequence = record.lastSequencesByDomain[domain],
                   sequence <= previousSequence {
                    return nil
                }
                if let terminal = record.terminalState {
                    if Self.rollbackStates.contains(event.state) || event.state == .unknown { return nil }
                    if terminal == .cancelled && event.state != .cancelled { return nil }
                    if terminal == .failed && event.state == .responseEnded { return nil }
                }
            }

            let previousState = record.lastObservedState
            let didTransition = previousState != event.state
            let terminalNoticeWasSent = Self.deduplicatedNoticeStates.contains(event.state)
                && record.notifiedTerminalStates.contains(event.state)
            let shouldNotify = didTransition
                && Self.notifiableStates.contains(event.state)
                && !(event.state == .responseEnded && startsNewTurn)
                && !terminalNoticeWasSent

            if shouldNotify, Self.deduplicatedNoticeStates.contains(event.state) {
                record.notifiedTerminalStates.insert(event.state)
            }
            record.rememberEvent(event.id)
            if let sequence = event.sequence {
                record.lastSequencesByDomain[sequenceDomain(for: event.source)] = sequence
            }
            record.lastObservedState = event.state
            if Self.terminalStates.contains(event.state) {
                record.terminalState = event.state
            }
            record.snapshot = Self.snapshot(for: event, stale: false,
                                            previousParentID: record.snapshot.parentSessionID)
            record.lastTouched = nextTouch()
            records[key] = record

            if shouldNotify {
                return MonitorNotice(
                    appID: event.appID,
                    sessionID: event.sessionID,
                    state: event.state,
                    evidence: event.evidence
                )
            }
            return nil
        }

        if records.count >= Self.maximumSessions {
            evictLeastRecentlyTouchedSession()
        }

        var record = SessionRecord(
            snapshot: Self.snapshot(for: event, stale: false),
            lastObservedState: event.state,
            terminalState: Self.terminalStates.contains(event.state) ? event.state : nil,
            lastTouched: nextTouch()
        )
        record.rememberEvent(event.id)
        if let sequence = event.sequence {
            record.lastSequencesByDomain[sequenceDomain(for: event.source)] = sequence
        }
        let shouldNotify = Self.notifiableStates.contains(event.state) && event.state != .responseEnded
        if shouldNotify {
            if Self.deduplicatedNoticeStates.contains(event.state) {
                record.notifiedTerminalStates.insert(event.state)
            }
        }
        records[key] = record

        guard shouldNotify else { return nil }
        return MonitorNotice(
            appID: event.appID,
            sessionID: event.sessionID,
            state: event.state,
            evidence: event.evidence
        )
    }

    public mutating func expire(now: Date, maxAge: TimeInterval = 120) {
        let ageLimit = maxAge.isFinite ? max(0, maxAge) : 120
        for key in Array(records.keys) {
            guard var record = records[key] else { continue }
            let age = now.timeIntervalSince(record.snapshot.updatedAt)
            if age.isFinite, age > ageLimit,
               !record.snapshot.stale || (record.snapshot.state == .unknown && record.terminalState != nil) {
                let previous = record.snapshot
                record.snapshot = SessionSnapshot(
                    appID: previous.appID,
                    sessionID: previous.sessionID,
                    turnID: previous.turnID,
                    state: record.terminalState ?? .unknown,
                    evidence: previous.evidence,
                    updatedAt: previous.updatedAt,
                    source: previous.source,
                    parentSessionID: previous.parentSessionID,
                    stale: true
                )
                records[key] = record
            }
        }
    }

    private static func snapshot(for event: MonitorEvent, stale: Bool, previousParentID: String? = nil) -> SessionSnapshot {
        SessionSnapshot(
            appID: event.appID,
            sessionID: event.sessionID,
            turnID: event.turnID,
            state: event.state,
            evidence: event.evidence,
            updatedAt: event.observedAt,
            source: event.source,
            parentSessionID: event.parentSessionID ?? previousParentID,
            stale: stale
        )
    }

    private mutating func nextTouch() -> UInt64 {
        touchCounter &+= 1
        return touchCounter
    }

    private mutating func evictLeastRecentlyTouchedSession() {
        guard let oldest = records.min(by: { lhs, rhs in
            if lhs.value.lastTouched != rhs.value.lastTouched {
                return lhs.value.lastTouched < rhs.value.lastTouched
            }
            if lhs.key.appID != rhs.key.appID {
                return lhs.key.appID < rhs.key.appID
            }
            return lhs.key.sessionID < rhs.key.sessionID
        })?.key else { return }
        records.removeValue(forKey: oldest)
    }
}
