import Foundation
import SwiftData
import Observation

/// One chat's reply (or its "Summarize now") while it runs: what the chat shows live, and what the controller needs to
/// stop, persist and finish it. `ChatController` keeps one per conversation in `runs`; a chat observes only its own, so
/// a delta in one chat never re-renders another.
@MainActor
@Observable
final class ChatRun {
    enum Kind: Equatable {
        case turn
        /// "Summarize now" (an automatic compaction belongs to the turn that triggers it).
        case compaction
    }

    let conversationID: UUID
    let kind: Kind
    /// The answer being written; nil for a compaction.
    let messageID: UUID?
    /// `.queued` until a slot is free (`ChatController.maxConcurrentRuns`).
    var phase: ChatController.Phase = .waiting
    var pendingCalls: [PendingToolCall] = []
    /// Calls that finished in the round still running, so the live feed keeps them before the round's step is saved.
    var roundRecords: [ToolCallRecord] = []
    /// Every call of the running round in request order (finished ones included), for the live tool rows.
    var roundRequested: [PendingToolCall] = []
    /// When the run started working (not when it was queued).
    var turnStart: Date?
    /// Sources of the running turn (conversation-wide ids), updated as tools finish.
    var liveSources: [SourceInfo] = []
    /// Tool rounds finished so far, and whether this is already an early answer (for the "Answer now" pill).
    var completedToolRounds = 0
    var isEarly = false

    var isQueued: Bool { phase == .queued }
    var isCompaction: Bool { kind == .compaction }
    /// Whether the turn can still be cut short for an early answer (the pill still waits for its own timing).
    var canAnswerNow: Bool { kind == .turn && !isEarly && !isQueued }

    @ObservationIgnored var task: Task<Void, Never>?
    /// Starts a queued run once a slot is free.
    @ObservationIgnored var start: (() -> Void)?
    @ObservationIgnored var message: Message?
    @ObservationIgnored var context: ModelContext?
    @ObservationIgnored var endpoint: Endpoint?
    @ObservationIgnored var persister: CheckpointPersister?
    @ObservationIgnored var persistedSourceCount = -1
    @ObservationIgnored var sourceStore: SourceStore?
    @ObservationIgnored var earlyAnswerRequested = false
    /// The chat was deleted while this ran: nothing more is written to it.
    @ObservationIgnored var discarded = false
    /// Holds the shared background lease (`ReplyBackgroundExecution`).
    @ObservationIgnored var holdsLease = false

    init(conversationID: UUID, kind: Kind, messageID: UUID?) {
        self.conversationID = conversationID
        self.kind = kind
        self.messageID = messageID
    }
}

/// The sidebar's marks: a chat whose reply is running, and one whose reply ended while another chat was on screen
/// (unread until it is opened). Pure, so the rules are tested without views.
struct ChatIndicators: Equatable {
    enum Status: Equatable {
        case none
        case running
        case unread
    }

    private(set) var unread: Set<UUID> = []

    /// A run ended. Unread when the chat is not the one on screen. Returns whether it was marked.
    @discardableResult
    mutating func runEnded(_ conversation: UUID, visible: UUID?) -> Bool {
        guard conversation != visible else { return false }
        unread.insert(conversation)
        return true
    }

    /// The chat was opened (or deleted).
    mutating func opened(_ conversation: UUID?) {
        if let conversation { unread.remove(conversation) }
    }

    func status(_ conversation: UUID, running: Bool) -> Status {
        if running { return .running }
        return unread.contains(conversation) ? .unread : .none
    }
}

/// "Reply ready · <chat>": a reply finished in a chat that isn't on screen. The chat shows it for a moment; a tap opens
/// that chat.
struct ReadyNotice: Identifiable, Equatable {
    let id = UUID()
    let conversationID: UUID
    let title: String
}
