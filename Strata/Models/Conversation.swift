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
    /// The local day (yyyy-MM-dd) the conversation was created. The model is told this date and it never changes, so the
    /// system message, and with it the cached prefix, stays byte-identical across turns and midnights.
    var createdDay: String = ""
    /// The message whose path from the root is shown and sent (nil before the first message).
    var leafID: UUID?
    /// False for conversations saved before branching: `ensureTree()` links them in creation order, once.
    var treeLinked: Bool = false
    var connectionID: UUID?
    var modelID: String?
    var effortRaw: String
    /// Usage of the last request in the most recent turn (drives the context ring).
    var lastPromptTokens: Int?
    var lastCompletionTokens: Int?
    var lastCachedTokens: Int?
    var lastReasoningTokens: Int?
    /// The answer whose request that usage belongs to, so a branch that did not produce it does not trust it.
    var lastUsageMessageID: UUID?
    /// JSON-encoded `[SourceInfo]`: web sources numbered across the whole conversation.
    @Attribute(.externalStorage) var sourcesData: Data?
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []
    @Relationship(deleteRule: .cascade, inverse: \CompactionRecord.conversation)
    var compactions: [CompactionRecord] = []

    init(title: String = "", connectionID: UUID? = nil, modelID: String? = nil, effort: Effort = .default) {
        self.id = UUID()
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
        self.createdDay = ConversationDate.day(for: .now)
        self.treeLinked = true
        self.isPinned = false
        self.connectionID = connectionID
        self.modelID = modelID
        self.effortRaw = effort.rawValue
    }

    /// The frozen day for this conversation's system message. Conversations from before the field existed take the
    /// day of their creation, once.
    var systemDay: String {
        if createdDay.isEmpty { createdDay = ConversationDate.day(for: createdAt) }
        return createdDay
    }

    /// The user's preferences as they were at this conversation's first request: editing them later starts with
    /// the next chat, so a conversation's system message (and cached prefix) never changes under it.
    var preferencesSnapshot: String?

    func frozenPreferences(current: String) -> String {
        if let preferencesSnapshot { return preferencesSnapshot }
        preferencesSnapshot = current
        return current
    }

    /// The skill list (`SkillIndex`) as it was at this conversation's first request with the browser tools on: a skill
    /// saved later is listed from the next chat on, so the system message never changes under this one.
    var skillIndexSnapshot: String?

    func frozenSkillIndex(current: String) -> String {
        if let skillIndexSnapshot { return skillIndexSnapshot }
        skillIndexSnapshot = current
        return current
    }

    /// The site plugins' prompt section as it was at this conversation's first request with web tools on: switching a
    /// plugin in Settings applies from the next chat on, so the system message never changes under this one.
    var pluginSectionSnapshot: String?

    func frozenPluginSection(current: String) -> String {
        if let pluginSectionSnapshot { return pluginSectionSnapshot }
        pluginSectionSnapshot = current
        return current
    }

    /// The chat's tool switches (`ToolGroup` raw values): nil while it follows the defaults in Settings, that is until
    /// the user flips one in the composer's "+" menu or the chat first sends.
    var toolSwitchesRaw: String?
    /// The tool groups offered at the first request, with their definitions and system prompt sections (`ToolGroup`).
    /// Nil before it. Chats from before the field existed freeze what Settings offers at their next request, which is
    /// what they were sending all along.
    var offeredToolsRaw: String?
    /// The switches as the model last heard of them: at the first request, or in a note on a user message.
    var announcedToolsRaw: String?

    /// The groups among the switches. Setting them keeps the package switches (`packageSwitches`).
    var toolSwitches: Set<ToolGroup>? {
        get { toolSwitchesRaw.map(ToolGroup.decode) }
        set { toolSwitchesRaw = newValue.map { ToolSwitch.encode(groups: $0, packages: packageSwitches) } }
    }

    /// The packages switched on in the chat (`pkg:<id>` entries of the same field): nil while it follows the defaults.
    var packageSwitches: Set<String>? { toolSwitchesRaw.flatMap(ToolSwitch.packages) }

    /// Sets both kinds of switches at once (a chat taking its defaults, or a flip in the "+" menu). Nil packages: the
    /// defaults, taken at the first send.
    func setSwitches(groups: Set<ToolGroup>, packages: Set<String>?) {
        toolSwitchesRaw = ToolSwitch.encode(groups: groups, packages: packages)
    }

    /// The packages the model last heard of as on (`pkg:` entries of `announcedToolsRaw`).
    var announcedPackages: Set<String>? { announcedToolsRaw.flatMap(ToolSwitch.packages) }

    var offeredTools: Set<ToolGroup>? {
        get { offeredToolsRaw.map(ToolGroup.decode) }
        set { offeredToolsRaw = newValue.map(ToolGroup.encode) }
    }

    var announcedTools: Set<ToolGroup>? {
        get { announcedToolsRaw.map(ToolGroup.decode) }
        set { announcedToolsRaw = newValue.map { ToolSwitch.encode(groups: $0, packages: announcedPackages ?? []) } }
    }

    func setAnnounced(groups: Set<ToolGroup>, packages: Set<String>) {
        announcedToolsRaw = ToolSwitch.encode(groups: groups, packages: packages)
    }

    /// The packages the chat offers, with the bytes of their tools and prompt sections (`PackageSnapshot`), frozen at
    /// the first request that had one on. Nil: no packages, as in every chat from before packages existed.
    @Attribute(.externalStorage) var packageSnapshotData: Data?

    var packageSnapshot: PackageSnapshot? {
        get { PackageSnapshot.decode(packageSnapshotData) }
        set { packageSnapshotData = newValue.flatMap { $0.entries.isEmpty ? nil : $0.encoded } }
    }

    /// The offered groups, frozen to `current` at the first call, like `frozenPreferences`.
    func frozenTools(current: Set<ToolGroup>) -> Set<ToolGroup> {
        if let offeredTools { return offeredTools }
        offeredTools = current
        announcedTools = current
        return current
    }

    /// The offered packages, frozen with the groups: before the chat's first request `current` makes the snapshot (only
    /// when it has packages: a chat without any stores nothing); after it, the stored snapshot holds, whatever is
    /// installed now. A chat from before the tool switches existed (it froze its preferences but not its groups) gets
    /// none, so its prefix stays as it was.
    func frozenPackages(current: () -> PackageSnapshot) -> PackageSnapshot? {
        guard offeredTools == nil else { return packageSnapshot }
        let snapshot = preferencesSnapshot == nil ? current() : PackageSnapshot(entries: [])
        packageSnapshot = snapshot
        setAnnounced(groups: announcedTools ?? [], packages: snapshot.ids)
        return packageSnapshot
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
        activePath.filter { !$0.text.isEmpty && !$0.hiddenInstruction }.map { AutoRename.Line(role: $0.role, text: $0.text) }
    }

    /// Answers that finished with text, not stopped or failed ones.
    var completedAnswerCount: Int {
        activePath.filter { $0.role == .assistant && !$0.text.isEmpty && $0.errorText == nil && !$0.stoppedByUser }.count
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
        for m in activePath where !m.text.isEmpty && !m.hiddenInstruction {
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

/// The date line appended to the system message.
enum ConversationDate {
    /// yyyy-MM-dd in the given calendar's time zone (the user's, by default).
    static func day(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// "Current date: 2026-10-11 (Sunday)." The weekday comes from the day itself, in English, so it is deterministic.
    static func line(day: String) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return "Current date: \(day)."
        }
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return "Current date: \(day) (\(names[utc.component(.weekday, from: date) - 1]))."
    }

    /// The conversation's system message: the user's prompt (if any), the enabled plugins (if any) and the frozen date line.
    static func systemPrompt(base: String, day: String, plugins: String = "") -> String {
        let parts = [base.trimmingCharacters(in: .whitespacesAndNewlines), plugins, line(day: day)]
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
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
    /// The small, fast-changing half of the checkpoint (cursor and accumulator), written about once a second.
    /// `resumeData` holds the large half and is rewritten only when it changes.
    var resumeDynamicData: Data?
    /// True while an unfinished turn has a checkpoint: lets launch and foreground find it with a predicate.
    var hasResume: Bool = false
    var cancelPending: Bool = false
    /// The message this one follows (nil for a first message). A user message edited later gets a sibling here.
    var parentID: UUID?
    /// Which child was showing last, so returning to this message lands where the reader left.
    var lastActiveChildID: UUID?
    var stoppedByUser: Bool
    /// The answer translated on this device (Markdown, same structure as `text`). The API history never sees it.
    var translatedText: String?
    /// The language `translatedText` is in (an identifier such as "en-US").
    var translationTarget: String?
    /// Whether the translation is the version on screen.
    var showingTranslation: Bool = false
    /// The instruction sent by "Answer now" (or "Save as skill"). It is on the path (so later requests carry it) but never
    /// shown.
    var hiddenInstruction: Bool = false
    /// A hidden instruction sent by "Save as skill" (`SkillOffer`), not "Answer now": the reply after it may use tools.
    var skillRequest: Bool = false
    /// The run that "Answer now" cut short; it keeps the results gathered so far.
    var cutForEarlyAnswer: Bool = false
    /// The answer written after "Answer now".
    var answeredEarly: Bool = false
    /// Appended to this user message's text in requests only, never shown: the chat's tool switches that changed
    /// before it was sent ("[Web search: off]", `ToolGroup.note`). Kept, so later requests repeat the message
    /// byte for byte and the cached prefix holds.
    var apiNote: String?
    @Attribute(.externalStorage) var stepsData: Data?
    /// Ordered process segments (thinking, preamble text, tool rounds). Nil on messages saved before they existed.
    @Attribute(.externalStorage) var segmentsData: Data?
    /// What the person did in the answer's interactive views, by block (`openUIStates`). Nil until they act.
    var openUIStateData: Data?
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

    /// Not drawn in the transcript: the early-answer instruction, and a run cut short before it produced anything.
    var isHiddenInTranscript: Bool {
        hiddenInstruction || (cutForEarlyAnswer && text.isEmpty && stepsData == nil && reasoning.isEmpty)
    }

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
        HistoryMessage(role: role.rawValue, text: apiNote.map { text.isEmpty ? $0 : text + "\n\n" + $0 } ?? text,
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

    /// For code already off the main thread, or with a thumbnail in hand. A nil thumbnail is made later by `ThumbnailBackfill`.
    init(jpegData: Data, sortIndex: Int, thumbnailData: Data?) {
        self.id = UUID()
        self.jpegData = jpegData
        self.thumbnailData = thumbnailData
        self.sortIndex = sortIndex
    }

    init(jpegData: Data, sortIndex: Int) {
        self.id = UUID()
        self.jpegData = jpegData
        self.thumbnailData = ImageProcessor.thumbnailData(from: jpegData)
        self.sortIndex = sortIndex
    }
}
