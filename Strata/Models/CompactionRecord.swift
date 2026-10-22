import Foundation
import SwiftData

/// One compaction of a conversation: the handoff notes and the history that replaced everything up to the anchor.
/// Anchored to a message on the path, so a branch that does not pass through it never sees it (see `MessageTree.swift`).
@Model
final class CompactionRecord {
    // Synced through CloudKit: see the rules at the top of `Conversation.swift`.
    var id: UUID = UUID()
    /// The message the summary covers up to. Messages after it are sent as they are.
    var anchorMessageID: UUID = UUID()
    /// For a compaction in the middle of a turn, the anchor is the answer being written and this is how many of its tool
    /// steps the summary covers; the steps after that (and its text) follow the replacement. Negative: the whole message.
    var anchorSteps: Int = -1
    var notes: String = ""
    /// JSON `[APIMessage]` (no system message): recent user messages, the notes, and any kept tool group.
    @Attribute(.externalStorage) var replacementData: Data = Data()
    var tokensBefore: Int = 0
    var tokensAfter: Int = 0
    var createdAt: Date = Date.now
    /// False for "Summarize now".
    var isAutomatic: Bool = true
    var conversation: Conversation?

    init(anchorMessageID: UUID, anchorSteps: Int = -1, notes: String, replacement: [APIMessage], tokensBefore: Int,
         tokensAfter: Int, isAutomatic: Bool, createdAt: Date = .now) throws {
        self.id = UUID()
        self.anchorMessageID = anchorMessageID
        self.anchorSteps = anchorSteps
        self.notes = notes
        self.replacementData = try ChatRequest.encoder.encode(HealthRedaction.isActive ? HealthRedaction.redacted(replacement) : replacement)
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.isAutomatic = isAutomatic
        self.createdAt = createdAt
    }

    /// The messages that stand in for everything before the anchor. If they can't be decoded (a format change), the
    /// notes alone stand in, rather than nothing: an empty replacement would silently drop all earlier context.
    var replacement: [APIMessage] {
        DecodeCache.replacements.value(for: id, source: replacementData) { try? JSONDecoder().decode([APIMessage].self, from: replacementData) }
            ?? [.user(Compaction.summaryPrefix + notes)]
    }

    /// Covers the whole anchor message.
    var coversWholeMessage: Bool { anchorSteps < 0 }
}

extension DecodeCache where Value == [APIMessage] { static let replacements = DecodeCache<[APIMessage]>(limit: 20) }

/// The history to send for a path, given the conversation's compactions.
struct CompactedHistory: Equatable {
    /// The replacement messages (no system message), to follow the system message.
    var replacement: [APIMessage]
    /// The path from the anchor on, as history messages: the tail of a half-covered anchor message first.
    var rest: [HistoryMessage]
    var record: UUID
}

extension Conversation {
    /// Compactions of this conversation, oldest first.
    var sortedCompactions: [CompactionRecord] { compactions.sorted { $0.createdAt < $1.createdAt } }

    /// The compaction that applies to `path` (its latest anchor on the path), and the position of its anchor.
    func appliedCompaction(on path: [Message]) -> (record: CompactionRecord, index: Int)? {
        guard !compactions.isEmpty else { return nil }
        var positions: [UUID: Int] = [:]
        for (i, m) in path.enumerated() { positions[m.id] = i }
        var best: (record: CompactionRecord, index: Int)?
        for r in compactions {
            guard let i = positions[r.anchorMessageID] else { continue }
            if let b = best, (b.index, b.record.anchorSteps < 0 ? Int.max : b.record.anchorSteps, b.record.createdAt)
                >= (i, r.anchorSteps < 0 ? Int.max : r.anchorSteps, r.createdAt) { continue }
            best = (r, i)
        }
        return best
    }

    /// Compaction records anchored to each message of the path, in the order they were made (for the dividers).
    func compactions(anchoredIn path: [Message]) -> [UUID: [CompactionRecord]] {
        guard !compactions.isEmpty else { return [:] }
        let ids = Set(path.map(\.id))
        var out: [UUID: [CompactionRecord]] = [:]
        for r in sortedCompactions where ids.contains(r.anchorMessageID) { out[r.anchorMessageID, default: []].append(r) }
        return out
    }

    /// `path` as it is sent to the model: the latest compaction on it, then everything after its anchor. Nil when no
    /// compaction applies (the caller sends the whole path). Messages with nothing to send are left out.
    func compactedHistory(path: [Message]) -> CompactedHistory? {
        guard let (record, index) = appliedCompaction(on: path) else { return nil }
        var rest: [HistoryMessage] = []
        let anchor = path[index]
        if !record.coversWholeMessage {
            let remaining = Array(anchor.steps.dropFirst(record.anchorSteps))
            if !remaining.isEmpty || !anchor.text.isEmpty {
                var h = anchor.historyMessage
                h.steps = remaining
                rest.append(h)
            }
        }
        for m in path[(index + 1)...] where m.role == .user || !m.text.isEmpty || !m.steps.isEmpty {
            rest.append(m.historyMessage)
        }
        return CompactedHistory(replacement: record.replacement, rest: rest, record: record.id)
    }
}
