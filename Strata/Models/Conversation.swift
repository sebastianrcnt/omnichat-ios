import Foundation
import SwiftData

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    /// The user typed this title: automatic naming never overwrites it.
    var titleIsUserSet: Bool = false
    /// Automatic naming already ran once for this conversation.
    var autoRenameDone: Bool = false
    var connectionID: UUID?
    var modelID: String?
    var effortRaw: String
    /// Usage of the last request in the most recent turn (drives the context ring).
    var lastPromptTokens: Int?
    var lastCompletionTokens: Int?
    var lastCachedTokens: Int?
    var lastReasoningTokens: Int?
    /// JSON-encoded `[SourceInfo]`: web sources numbered across the whole conversation.
    @Attribute(.externalStorage) var sourcesData: Data?
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    init(title: String = "", connectionID: UUID? = nil, modelID: String? = nil, effort: Effort = .default) {
        self.id = UUID()
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
        self.isPinned = false
        self.connectionID = connectionID
        self.modelID = modelID
        self.effortRaw = effort.rawValue
    }

    var effort: Effort {
        get { Effort(rawValue: effortRaw) ?? .default }
        set { effortRaw = newValue.rawValue }
    }

    var sources: [SourceInfo] {
        get {
            guard let data = sourcesData else { return [] }
            return DecodeCache.sources.value(for: id, source: data) { try? JSONDecoder().decode([SourceInfo].self, from: data) } ?? []
        }
        set { sourcesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var sortedMessages: [Message] {
        messages.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }

    var lastUsage: Usage? {
        guard let p = lastPromptTokens, let c = lastCompletionTokens else { return nil }
        return Usage(promptTokens: p, completionTokens: c, cachedTokens: lastCachedTokens, reasoningTokens: lastReasoningTokens)
    }

    /// Texts for the naming request: answer text only (no reasoning or tool results), in order.
    var namingLines: [AutoRename.Line] {
        sortedMessages.filter { !$0.text.isEmpty }.map { AutoRename.Line(role: $0.role, text: $0.text) }
    }

    /// Answers that finished with text, not stopped or failed ones.
    var completedAnswerCount: Int {
        messages.filter { $0.role == .assistant && !$0.text.isEmpty && $0.errorText == nil && !$0.stoppedByUser }.count
    }

    /// Sets a user-typed title; automatic naming leaves it alone from now on.
    func setUserTitle(_ title: String) {
        self.title = title
        titleIsUserSet = true
    }

    var displayTitle: String {
        title.isEmpty ? String(localized: "New chat") : title
    }

    static func autoTitle(from text: String, limit: Int = 40) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    func apply(_ usage: Usage) {
        lastPromptTokens = usage.promptTokens
        lastCompletionTokens = usage.completionTokens
        lastCachedTokens = usage.cachedTokens
        lastReasoningTokens = usage.reasoningTokens
    }

    /// Plain-text transcript for sharing.
    var transcript: String {
        var out = [displayTitle, ""]
        for m in sortedMessages where !m.text.isEmpty {
            out.append((m.role == .user ? String(localized: "You") : String(localized: "Assistant")) + ":")
            out.append(m.text)
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}

/// A small cache of JSON decodes, keyed by object id and validated against the bytes they were decoded from,
/// so a changed value is never served stale.
final class DecodeCache<Value>: @unchecked Sendable {
    private final class Box { let source: Data; let value: Value; init(_ s: Data, _ v: Value) { source = s; value = v } }
    private let cache = NSCache<NSUUID, Box>()
    init(limit: Int = 300) { cache.countLimit = limit }

    func value(for id: UUID, source: Data, _ decode: () -> Value?) -> Value? {
        if let hit = cache.object(forKey: id as NSUUID), hit.source == source { return hit.value }
        guard let v = decode() else { return nil }
        cache.setObject(Box(source, v), forKey: id as NSUUID)
        return v
    }
}

extension DecodeCache where Value == [ToolStep] { static let steps = DecodeCache<[ToolStep]>() }
extension DecodeCache where Value == [ProcessSegment] {
    static let segments = DecodeCache<[ProcessSegment]>()
    static let derived = DecodeCache<[ProcessSegment]>()
}
extension DecodeCache where Value == [SourceInfo] { static let sources = DecodeCache<[SourceInfo]>() }

enum MessageRole: String, Codable, Sendable { case user, assistant }

@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var text: String
    var reasoning: String
    var thinkingSeconds: Double?
    var createdAt: Date
    var sortIndex: Int
    var errorText: String?
    var errorNeedsSettings: Bool = false
    /// Atomic turn checkpoint, including request id, cursor and tool accumulator.
    @Attribute(.externalStorage) var resumeData: Data?
    /// The small, fast-changing half of the checkpoint (cursor and accumulator), written about once a second.
    /// `resumeData` holds the large half and is rewritten only when it changes.
    var resumeDynamicData: Data?
    /// True while an unfinished turn has a checkpoint: lets launch and foreground find it with a predicate.
    var hasResume: Bool = false
    var cancelPending: Bool = false
    var stoppedByUser: Bool
    @Attribute(.externalStorage) var stepsData: Data?
    /// Ordered process segments (thinking, preamble text, tool rounds). Nil on messages saved before they existed.
    @Attribute(.externalStorage) var segmentsData: Data?
    var conversation: Conversation?
    @Relationship(deleteRule: .cascade, inverse: \Attachment.message)
    var attachments: [Attachment] = []

    init(role: MessageRole, text: String = "", sortIndex: Int) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.text = text
        self.reasoning = ""
        self.createdAt = .now
        self.sortIndex = sortIndex
        self.stoppedByUser = false
    }

    var role: MessageRole { MessageRole(rawValue: roleRaw) ?? .assistant }

    /// The persisted checkpoint of an unfinished resumable turn.
    var resumeCheckpoint: TurnCheckpoint? {
        guard let data = resumeData else { return nil }
        return try? TurnCheckpoint.restore(staticData: data, dynamicData: resumeDynamicData)
    }

    func clearResume() {
        resumeData = nil
        resumeDynamicData = nil
        hasResume = false
    }

    /// Decoded once per stored value (the transcript reads this on every redraw).
    var steps: [ToolStep] {
        get {
            guard let data = stepsData else { return [] }
            return DecodeCache.steps.value(for: id, source: data) { try? JSONDecoder().decode([ToolStep].self, from: data) } ?? []
        }
        set { stepsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// Persisted segments, or a derivation from `steps` and `reasoning` for older messages. Segments keep display data
    /// only (tool results are stripped), and the decoded value is cached.
    var segments: [ProcessSegment] {
        get {
            if let data = segmentsData {
                if let saved = DecodeCache.segments.value(for: id, source: data, { try? JSONDecoder().decode([ProcessSegment].self, from: data) }) { return saved }
            }
            // Older messages: derived from steps and reasoning, cached on a small key (those fields no longer change).
            let key = Data("\(stepsData?.count ?? 0):\(reasoning.utf8.count):\(thinkingSeconds ?? -1)".utf8)
            return DecodeCache.derived.value(for: id, source: key) {
                ProcessSegments.derive(steps: self.steps, reasoning: self.reasoning, thinkingSeconds: self.thinkingSeconds)
            } ?? []
        }
        set { segmentsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var sortedAttachments: [Attachment] {
        attachments.sorted { $0.sortIndex < $1.sortIndex }
    }

    var historyMessage: HistoryMessage {
        HistoryMessage(role: role.rawValue, text: text,
                       imageDataURLs: sortedAttachments.map { a in ImageDataURLCache.shared.dataURL(id: a.id) { a.jpegData } },
                       steps: steps)
    }
}

@Model
final class Attachment {
    @Attribute(.unique) var id: UUID
    @Attribute(.externalStorage) var jpegData: Data
    /// Small preview (about 10-30 KB) that transcript bubbles read, so scrolling never faults the full JPEG.
    /// Nil on attachments saved before it existed; `ThumbnailBackfill` fills it lazily.
    var thumbnailData: Data?
    var sortIndex: Int
    var message: Message?

    init(jpegData: Data, sortIndex: Int) {
        self.id = UUID()
        self.jpegData = jpegData
        self.thumbnailData = ImageProcessor.thumbnailData(from: jpegData)
        self.sortIndex = sortIndex
    }
}
