import Foundation
import SwiftData

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
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
        get { sourcesData.flatMap { try? JSONDecoder().decode([SourceInfo].self, from: $0) } ?? [] }
        set { sourcesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var sortedMessages: [Message] {
        messages.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
    }

    var lastUsage: Usage? {
        guard let p = lastPromptTokens, let c = lastCompletionTokens else { return nil }
        return Usage(promptTokens: p, completionTokens: c, cachedTokens: lastCachedTokens, reasoningTokens: lastReasoningTokens)
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
    var cancelPending: Bool = false
    var stoppedByUser: Bool
    @Attribute(.externalStorage) var stepsData: Data?
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

    var steps: [ToolStep] {
        get { stepsData.flatMap { try? JSONDecoder().decode([ToolStep].self, from: $0) } ?? [] }
        set { stepsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var sortedAttachments: [Attachment] {
        attachments.sorted { $0.sortIndex < $1.sortIndex }
    }

    var historyMessage: HistoryMessage {
        HistoryMessage(role: role.rawValue, text: text, images: sortedAttachments.map(\.jpegData), steps: steps)
    }
}

@Model
final class Attachment {
    @Attribute(.unique) var id: UUID
    @Attribute(.externalStorage) var jpegData: Data
    var sortIndex: Int
    var message: Message?

    init(jpegData: Data, sortIndex: Int) {
        self.id = UUID()
        self.jpegData = jpegData
        self.sortIndex = sortIndex
    }
}
