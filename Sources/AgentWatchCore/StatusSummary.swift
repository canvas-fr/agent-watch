import Foundation

/// Keeps a bounded, de-duplicated list of unread turn completions.
public struct CompletionInbox: Codable, Sendable {
    private static let maximumEntries = 100

    private struct Entry: Codable, Hashable, Sendable {
        let appID: String
        let sessionID: String
        let turnID: String
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    private var entries: [Entry] = []

    public init() {}

    /// Adds a completion unless this exact app, session, and turn is already unread.
    public mutating func record(appID: String, sessionID: String, turnID: String) {
        let entry = Entry(appID: appID, sessionID: sessionID, turnID: turnID)
        guard !entries.contains(entry) else { return }

        entries.append(entry)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
    }

    /// Marks every completion as read.
    public mutating func markAllRead() {
        entries.removeAll(keepingCapacity: true)
    }

    /// Removes unread completions belonging to one app.
    public mutating func remove(appID: String) {
        entries.removeAll { $0.appID == appID }
    }

    /// Number of unread completion records.
    public var count: Int {
        entries.count
    }

    /// App identifiers represented in the inbox, in first-seen order.
    public var appIDs: [String] {
        var seen: Set<String> = []
        return entries.compactMap { entry in
            seen.insert(entry.appID).inserted ? entry.appID : nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEntries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []

        var uniqueEntries: [Entry] = []
        var seen: Set<Entry> = []
        for entry in decodedEntries where seen.insert(entry).inserted {
            uniqueEntries.append(entry)
        }
        entries = Array(uniqueEntries.suffix(Self.maximumEntries))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }
}

/// Formats the compact status-bar summary from currently fresh session snapshots.
public func statusBarText(
    sessions: [SessionSnapshot],
    unreadCompletions: Int,
    paused: Bool
) -> String {
    if paused {
        return "已暂停"
    }

    let freshSessions = sessions.filter { !$0.stale }
    let pendingCount = freshSessions.reduce(into: 0) { count, session in
        if session.state == .waitingApproval || session.state == .waitingInput || session.state == .failed {
            count += 1
        }
    }
    let runningCount = freshSessions.filter { $0.state == .running }.count
    let completionCount = max(0, unreadCompletions)

    var parts: [String] = []
    if pendingCount > 0 {
        parts.append("待处理\(pendingCount)")
    }
    if runningCount > 0 {
        parts.append("运行\(runningCount)")
    }
    if completionCount > 0 {
        parts.append("新结束\(completionCount)")
    }

    if parts.isEmpty {
        return sessions.contains { $0.state == .unknown || ($0.stale && [.running, .waitingApproval, .waitingInput].contains($0.state)) }
            ? "状态未确认" : "待命"
    }
    return parts.joined(separator: " · ")
}
