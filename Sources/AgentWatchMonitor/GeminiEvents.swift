import Foundation
import AgentWatchCore

actor GeminiCollector {
    private let adapter = GeminiAdapter()
    private let reducer = GeminiEventReducer()

    func collect() -> WindowScan { reducer.apply(adapter.scan()) }
}

/// Window observations never masquerade as a durable chat identity. Losing a
/// continuity guard invalidates the old observation before opening a new one.
final class GeminiEventReducer {
    private struct Cursor {
        let sessionID: String
        var turnID = UUID().uuidString
        var state = SessionState.unknown
        var ended = false
        var sequence = 0
    }
    private var windows: [String: Cursor] = [:]

    func apply(_ scan: GeminiObservationScan) -> WindowScan {
        var events: [MonitorEvent] = []
        var seen = Set<String>()
        for observation in scan.observations {
            guard let window = observation.windowIdentity else { continue }
            seen.insert(window)
            let identity = "window:\(window):\(observation.continuityEpoch)"
            if var prior = windows[window], prior.sessionID != identity {
                events.append(event(.unknown, cursor: &prior, at: observation.observedAt,
                                    reason: "continuity_lost"))
                windows.removeValue(forKey: window)
            }
            var cursor = windows[window] ?? Cursor(sessionID: identity)
            let state: SessionState
            switch observation.state {
            case .running: state = .running
            case .responseEndedInferred, .responseEndedInferredWindow: state = .responseEnded
            case .unknown: state = .unknown
            }
            if state == .running && cursor.ended {
                cursor.turnID = UUID().uuidString
                cursor.ended = false
            }
            events.append(event(state, cursor: &cursor, at: observation.observedAt,
                                reason: observation.reason))
            windows[window] = cursor
        }
        // A failed AXWindows read does not prove that a physical window closed.
        // The adapter emits an unknown heartbeat when it has a cached identity;
        // this set also protects cursors that could not produce that heartbeat.
        // Run evidence is cleared at the adapter, so recovery must observe Stop
        // again before it can infer a response end.
        for key in Array(windows.keys)
        where !seen.contains(key) && !scan.preservedWindowIdentities.contains(key) {
            if var prior = windows.removeValue(forKey: key) {
                events.append(event(.unknown, cursor: &prior, at: Date(), reason: "window_unobservable"))
            }
        }
        var diagnostics = ["gemini": scan.health]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(scan.snapshotDiagnostics),
           let summary = String(data: data, encoding: .utf8) {
            diagnostics["gemini_snapshot_diagnostics"] = summary
        }
        return WindowScan(events: events, diagnostics: diagnostics)
    }

    private func event(_ state: SessionState, cursor: inout Cursor, at date: Date, reason: String) -> MonitorEvent {
        cursor.sequence += 1
        cursor.state = state
        if state == .responseEnded { cursor.ended = true }
        return MonitorEvent(id: UUID().uuidString, appID: "gemini", sessionID: cursor.sessionID,
                            turnID: cursor.turnID, state: state, evidence: .inferred,
                            observedAt: date, sequence: cursor.sequence,
                            source: "ax:gemini:" + reason)
    }
}
