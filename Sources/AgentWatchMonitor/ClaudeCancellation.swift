import CryptoKit
import Darwin
import Foundation
import AgentWatchCore

struct ClaudeActiveAuditTurn {
    let sessionID: String
    let turnID: String
    let observedAt: Date
}

/// Joins an explicit Cowork interruption label to an already observed audit
/// turn. It cannot create a session or finish a reply from a window label.
final class ClaudeCancellationBridge {
    private struct Witness {
        let startedAt: Date
        var turn: ClaudeActiveAuditTurn?
    }
    private var witnesses: [String: Witness] = [:]
    private var sequence = 0
    private let resolve: (String) -> ClaudeActiveAuditTurn?

    init(resolve: @escaping (String) -> ClaudeActiveAuditTurn? = ClaudeAuditIdentity.resolve) {
        self.resolve = resolve
    }

    func apply(_ scan: ClaudeChatAdapterScan, now: Date = Date()) -> [MonitorEvent] {
        var seen = Set<String>()
        var events: [MonitorEvent] = []
        for observation in scan.observations {
            guard observation.routeKind == .cowork,
                  let route = observation.routeSessionID,
                  let window = observation.windowFingerprint,
                  let session = observation.sessionFingerprint else { continue }
            let key = window + ":" + session
            seen.insert(key)
            if observation.state == .running || observation.state == .waitingInput {
                var witness = witnesses[key] ?? Witness(startedAt: now)
                // The audit must have advanced while this native run was
                // visible. An older active cursor cannot identify a new turn.
                if let turn = resolve(route), turn.observedAt >= witness.startedAt,
                   turn.observedAt <= now.addingTimeInterval(30) {
                    witness.turn = turn
                }
                witnesses[key] = witness
            } else if observation.state == .cancelled,
                      let witness = witnesses[key], let prior = witness.turn,
                      let current = resolve(route),
                      current.sessionID == prior.sessionID, current.turnID == prior.turnID,
                      current.observedAt >= witness.startedAt,
                      current.observedAt <= now.addingTimeInterval(30) {
                sequence += 1
                events.append(MonitorEvent(id: UUID().uuidString, appID: "claude",
                    sessionID: current.sessionID, turnID: current.turnID,
                    state: .cancelled, evidence: .inferred, observedAt: now,
                    sequence: sequence, source: "ax:claude:cowork_interrupted", identityScope: .session))
                witnesses.removeValue(forKey: key)
            } else {
                witnesses.removeValue(forKey: key)
            }
        }
        witnesses = witnesses.filter { seen.contains($0.key) }
        return events
    }
}

private enum ClaudeAuditIdentity {
    private struct StateFile: Decodable { let sessions: [String: Cursor] }
    private struct Cursor: Decodable {
        let turnID: String?
        let state: SessionState?
        let lastObservedAt: String?
    }

    static func resolve(_ route: String) -> ClaudeActiveAuditTurn? {
        guard route.hasPrefix("local_"), UUID(uuidString: String(route.dropFirst(6))) != nil else { return nil }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        var candidates: [String] = []
        var remaining = 256
        for (index, profile) in ["Claude", "Claude-3p"].enumerated() {
            let profileDirectory = support.appendingPathComponent(profile, isDirectory: true)
            let root = profileDirectory.appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
            guard plainDirectory(profileDirectory), plainDirectory(root) else { continue }
            for account in childDirectories(root, remaining: &remaining) {
                guard account.lastPathComponent != "skills-plugin" else { continue }
                for organization in childDirectories(account, remaining: &remaining) {
                    let file = organization.appendingPathComponent(route + ".json")
                    guard plainFile(file, maximum: 1_048_576) else { continue }
                    let prefix = index == 0 ? "" : "gateway/"
                    let scope = prefix + account.lastPathComponent + "/" + organization.lastPathComponent + "/" + route
                    let input = "claude-desktop-local-session-v1\0" + scope
                    candidates.append(SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined())
                }
            }
        }
        guard remaining > 0, candidates.count == 1, let session = candidates.first else { return nil }
        let directory = support.appendingPathComponent("Agent Watch/metadata", isDirectory: true)
        guard plainDirectory(directory), plainDirectory(directory.deletingLastPathComponent()),
              let data = readSnapshot(directory.appendingPathComponent("claude_desktop_state.json")),
              let file = try? JSONDecoder().decode(StateFile.self, from: data),
              let cursor = file.sessions[session], let state = cursor.state,
              [.running, .waitingInput, .waitingApproval].contains(state),
              let turn = cursor.turnID, !turn.isEmpty, turn.utf8.count <= 128,
              !turn.contains(where: \.isNewline),
              let timestamp = cursor.lastObservedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: timestamp) else { return nil }
        return ClaudeActiveAuditTurn(sessionID: session, turnID: turn, observedAt: date)
    }

    private static func plainDirectory(_ url: URL) -> Bool {
        guard let value = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return value.isDirectory == true && value.isSymbolicLink != true
    }

    private static func plainFile(_ url: URL, maximum: Int) -> Bool {
        guard let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
        return value.isRegularFile == true && value.isSymbolicLink != true && (value.fileSize ?? Int.max) <= maximum
    }

    private static func childDirectories(_ url: URL, remaining: inout Int) -> [URL] {
        guard let iterator = FileManager.default.enumerator(at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { return [] }
        var directories: [URL] = []
        while remaining > 0, let child = iterator.nextObject() as? URL {
            remaining -= 1
            if plainDirectory(child) { directories.append(child) }
        }
        return directories
    }

    private static func readSnapshot(_ url: URL) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= 1_048_576,
              let data = try? handle.read(upToCount: Int(before.st_size) + 1),
              data.count == before.st_size else { return nil }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_ino == before.st_ino,
              after.st_dev == before.st_dev, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { return nil }
        return data
    }
}
