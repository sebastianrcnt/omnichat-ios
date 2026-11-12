import Foundation

/// A version of a conversation's transcript, read from cheap fields only: no message is faulted in and no external
/// blob is read. Every change the chat screen shows from the whole path moves one of them: a message added or
/// removed (`messageCount`), a branch switched or a message attached (`leafID`), an old chat linked (`treeLinked`), a
/// summary made (`compactionCount`), and a turn sent or finished, which is when the engine writes the path's
/// segments, sources and early-answer cut (`updatedAt`). Text that streams into a message between those moments is
/// read by that message's own row, never through this.
struct TranscriptVersion: Hashable, Sendable {
    let conversationID: UUID
    let messageCount: Int
    let compactionCount: Int
    let updatedAt: Date
    let leafID: UUID?
    let treeLinked: Bool

    init(_ conversation: Conversation) {
        conversationID = conversation.id
        messageCount = conversation.storedMessages?.count ?? 0
        compactionCount = conversation.storedCompactions?.count ?? 0
        updatedAt = conversation.updatedAt
        leafID = conversation.leafID
        treeLinked = conversation.treeLinked
    }
}

/// The path the chat screen shows, worked out once per `TranscriptVersion` instead of on every redraw.
struct ChatTranscript {
    let version: TranscriptVersion
    /// Root to leaf, hidden messages included (`Conversation.activePath`).
    let activePath: [Message]
    /// The rows: the path without what is never drawn (`Message.isHiddenInTranscript`).
    let items: [Message]
    /// The rows' ids, read once here: diffing the rows then reads no message.
    let rows: [Row]
    let tree: MessageTreeIndex
    /// Summaries anchored to each shown message (`Conversation.compactions(anchoredIn:)`).
    let compactions: [UUID: [CompactionRecord]]

    struct Row: Identifiable {
        let id: UUID
        let message: Message
    }

    init(_ conversation: Conversation) {
        version = TranscriptVersion(conversation)
        activePath = conversation.activePath
        items = activePath.filter { !$0.isHiddenInTranscript }
        rows = items.map { Row(id: $0.id, message: $0) }
        tree = conversation.treeIndex
        compactions = conversation.compactions(anchoredIn: items)
    }
}

/// One chat screen's cache of its transcript and its sources. A long chat costs the same per redraw as a short one:
/// a hit compares a `TranscriptVersion` and touches nothing else.
@MainActor
final class ChatTranscriptCache {
    private var cached: ChatTranscript?
    private var sources: (version: TranscriptVersion, list: [SourceInfo])?
    /// How many times the transcript and the sources were worked out (tests).
    private(set) var transcriptBuilds = 0
    private(set) var sourceBuilds = 0

    func transcript(for conversation: Conversation) -> ChatTranscript {
        let version = TranscriptVersion(conversation)
        if let cached, cached.version == version { return cached }
        let fresh = ChatTranscript(conversation)
        transcriptBuilds += 1
        cached = fresh
        return fresh
    }

    /// `Conversation.allSources`, which reads every message's segments: only once per version.
    func allSources(for conversation: Conversation) -> [SourceInfo] {
        let version = TranscriptVersion(conversation)
        if let sources, sources.version == version { return sources.list }
        let list = conversation.allSources
        sourceBuilds += 1
        sources = (version, list)
        return list
    }
}
