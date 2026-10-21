import Foundation
import SwiftUI
import SwiftData
import Observation

/// A tool call that has been requested and is still running (or just finished).
struct PendingToolCall: Identifiable, Equatable {
    var id: String
    var name: String
    var primaryArgument: String
    /// `web_fetch` offset; above zero it is a continuation of an earlier read.
    var offset: Int = 0
    /// The plugin a `run_plugin` call runs.
    var plugin: String?
}

/// Drives generation for the app: persists messages, runs the turns, publishes live state for the UI.
///
/// Several chats can reply at once. Each running reply is a `ChatRun` in `runs`, keyed by its conversation; up to
/// `maxConcurrentRuns` work at a time and later ones wait their turn (`Phase.queued`), oldest first. Switching chats
/// never stops a run; deleting a chat discards its run first (`discardRun`).
@MainActor
@Observable
final class ChatController {
    enum Phase: Equatable {
        case idle
        /// Sent, but other chats hold every slot: it starts when one of them ends.
        case queued
        case waiting
        case thinking
        case tool(name: String, argument: String)
        case writing
        /// The model is writing handoff notes to summarize the conversation.
        case compacting
    }

    /// How many chats generate at the same time; the next one waits.
    static let maxConcurrentRuns = 3
    /// `maxConcurrentRuns`; tests lower it.
    @ObservationIgnored var maxConcurrentRuns = ChatController.maxConcurrentRuns

    /// The running (or queued) reply of each chat that has one. Observed for the sidebar; a chat observes its own run.
    private(set) var runs: [UUID: ChatRun] = [:]
    /// Queued runs, oldest first.
    @ObservationIgnored private var queue: [UUID] = []

    /// Some chat is replying (or summarizing).
    var isStreaming: Bool { !runs.isEmpty }
    var runningConversationIDs: Set<UUID> { Set(runs.keys) }

    func run(for conversation: Conversation?) -> ChatRun? {
        conversation.flatMap { runs[$0.id] }
    }

    func run(for conversationID: UUID?) -> ChatRun? {
        conversationID.flatMap { runs[$0] }
    }

    func isStreaming(_ conversation: Conversation) -> Bool { runs[conversation.id] != nil }
    func isRunning(_ conversationID: UUID) -> Bool { runs[conversationID] != nil }
    /// "Summarize now" is running in the chat.
    func isCompacting(_ conversation: Conversation?) -> Bool { run(for: conversation)?.isCompaction == true }

    /// The chat on screen (set by the root), so a reply that ends in another one is marked unread and announced.
    var visibleConversationID: UUID? {
        didSet {
            indicators.opened(visibleConversationID)
            if readyNotice?.conversationID == visibleConversationID { readyNotice = nil }
        }
    }
    /// Unread marks for the sidebar.
    private(set) var indicators = ChatIndicators()
    /// The last reply that finished in a chat that wasn't on screen ("Reply ready · <chat>").
    private(set) var readyNotice: ReadyNotice?

    func status(of conversationID: UUID) -> ChatIndicators.Status {
        indicators.status(conversationID, running: runs[conversationID] != nil)
    }

    func dismissReadyNotice(_ id: UUID) {
        if readyNotice?.id == id { readyNotice = nil }
    }

    /// Each chat's answer showing "Save as skill" (`SkillOffer`): set when a turn of hard-won web work finishes in this
    /// session, cleared by the chat's next turn, by tapping it or by closing it. Never persisted, so older answers
    /// don't offer it.
    private(set) var skillOffers: [UUID: UUID] = [:]

    func skillOfferMessageID(for conversation: Conversation?) -> UUID? {
        conversation.flatMap { skillOffers[$0.id] }
    }

    /// Why each chat's last "Summarize now" failed, for the chat to show once.
    private(set) var compactionErrors: [UUID: String] = [:]

    func compactionError(for conversation: Conversation?) -> String? {
        conversation.flatMap { compactionErrors[$0.id] }
    }

    func clearCompactionError(for conversation: Conversation?) {
        if let id = conversation?.id { compactionErrors[id] = nil }
    }

    /// For the diagnostics panel.
    var backgroundStateDescription: String { background.stateDescription }
    /// Runs holding the background lease (tests).
    var backgroundHolderCount: Int { background.holderCount }
    /// The running chats' ids, for the diagnostics panel.
    var activeTurnsDescription: String? {
        runs.isEmpty ? nil : runs.keys.map(\.uuidString).sorted().joined(separator: ",")
    }

    /// On-device translation of finished answers.
    let translation = TranslationService()

    private let connections: ConnectionStore
    private let settings: AppSettings
    private let streamer: any ChatStreaming
    private let tools: any ToolExecuting
    /// Not observed: `renderState(for:)` inserts here while a view body runs.
    @ObservationIgnored private var renderStates: [UUID: MessageRenderState] = [:]
    /// Bytes handed to the store by each checkpoint write (large half only when it changed). Instrumentation for tests.
    @ObservationIgnored var onCheckpointWrite: ((Int) -> Void)?
    /// Recent request bodies for the diagnostics panel.
    @ObservationIgnored var requestRing: RequestRing = .shared
    /// The skills listed in a new chat's system prompt.
    @ObservationIgnored var skills: SkillStore = .shared
    @ObservationIgnored private var cancelTasks: [UUID: Task<Void, Never>] = [:]
    private let background = ReplyBackgroundExecution()

    init(connections: ConnectionStore, settings: AppSettings,
         streamer: any ChatStreaming = ChatClient(), tools: any ToolExecuting = ToolRouter()) {
        self.connections = connections
        self.settings = settings
        self.streamer = streamer
        self.tools = tools
        ReplyBackgroundExecution.prepareNotifications()
        #if DEBUG
        DebugHooks.configure(translation)
        #endif
    }

    /// Wait until no chat is replying, queued runs included (tests).
    func waitUntilIdle() async {
        // A run can hand over to another (an early answer follows the run it cut short), and a queued run starts when
        // one ends: wait until there are none.
        while !runs.isEmpty {
            let tasks = runs.values.compactMap(\.task)
            guard !tasks.isEmpty else { return } // only queued runs with nothing ahead of them: can't happen
            for task in tasks { await task.value }
        }
    }

    /// Wait until this chat's run (and an early answer it hands over to) has ended (tests).
    func waitUntilIdle(_ conversation: Conversation) async {
        let id = conversation.id
        while let run = runs[id] {
            if let task = run.task { await task.value } else { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }

    /// Streaming-aware render models for a message, cached so finalized blocks keep their identity.
    func renderState(for message: Message) -> MessageRenderState {
        if let existing = renderStates[message.id] { return existing }
        let state = MessageRenderState(text: message.text, reasoning: message.reasoning, smoothing: settings.smoothStreaming)
        renderStates[message.id] = state
        return state
    }

    /// Show everything the chat's run received so far (user scrolled away or stopped).
    func revealAllNow(_ conversation: Conversation) {
        if let run = runs[conversation.id] { revealAll(run) }
    }

    private func revealAll(_ run: ChatRun) {
        if let id = run.messageID { renderStates[id]?.revealAll() }
    }

    /// Keeps the render states of `keep` and of every running answer.
    func forgetRenderStates(except keep: Set<UUID>) {
        let live = Set(runs.values.compactMap(\.messageID))
        renderStates = renderStates.filter { keep.contains($0.key) || live.contains($0.key) }
    }

    /// A ChatGPT or OpenCode connection needs a sign-in (or, for OpenCode, a key); an OpenAI-compatible one may be
    /// keyless (local servers), so its server says when a key is missing.
    static func needsKey(_ endpoint: Endpoint, connections: ConnectionStore) -> Bool {
        if endpoint.kind == .chatGPT { return !connections.isChatGPTSignedIn(endpoint.connectionID) }
        if endpoint.kind == .openCode { return !connections.isOpenCodeSignedIn(endpoint.connectionID) }
        return false
    }

    /// What the chat says when `needsKey`.
    static func credentialError(_ endpoint: Endpoint) -> APIError {
        switch endpoint.kind {
        case .chatGPT: .chatGPTSignInRequired(connection: endpoint.connectionName)
        case .openCode: .openCodeSignInRequired(connection: endpoint.connectionName)
        case .openAICompatible: .missingAPIKey(connection: endpoint.connectionName)
        }
    }

    // MARK: Entry points

    /// Sends a user message. With `editing`, the new message is a sibling of that one (same parent): the old branch stays
    /// and the leaf moves to the new message.
    func send(text: String, images: [Data], thumbnails: [Data?] = [], conversation: Conversation, context: ModelContext, editing: Message? = nil) {
        guard !isStreaming(conversation) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        ReplyBackgroundExecution.requestPermissionIfNeeded()
        conversation.ensureTree()
        let parent = editing.map { conversation.message(id: $0.parentID) } ?? conversation.leafMessage
        let user = Message(role: .user, text: trimmed, sortIndex: nextIndex(conversation))
        context.insert(user)
        conversation.attach(user, parent: parent)
        for (i, data) in images.enumerated() {
            // The thumbnail was made when the photo was added; without one, the bubble's backfill makes it (never here, on main).
            let a = Attachment(jpegData: data, sortIndex: i, thumbnailData: thumbnails.indices.contains(i) ? thumbnails[i] : nil)
            a.message = user
            context.insert(a)
        }
        if conversation.title.isEmpty {
            let basis = trimmed.isEmpty ? String(localized: "Image") : trimmed
            conversation.title = Conversation.autoTitle(from: basis)
        }
        conversation.updatedAt = .now
        generate(conversation: conversation, context: context)
    }

    func regenerate(conversation: Conversation, context: ModelContext) {
        guard !isStreaming(conversation) else { return }
        conversation.ensureTree()
        guard let leaf = conversation.leafMessage else { return }
        guard leaf.role == .assistant else {
            generate(conversation: conversation, context: context, under: leaf)
            return
        }
        let parent = conversation.message(id: leaf.parentID)
        if leaf.text.isEmpty && leaf.steps.isEmpty && leaf.reasoning.isEmpty {
            // A failed or stopped attempt with nothing in it is replaced rather than kept as a branch.
            context.delete(leaf)
            try? context.save()
        }
        generate(conversation: conversation, context: context, under: parent)
    }

    /// Conversations whose title request is running. Transient: a relaunch mid-request just leaves the placeholder.
    private(set) var titlingConversationIDs: Set<UUID> = []
    /// Set when "Regenerate title" got no title (no key, an error, an empty reply); the chat shows an alert.
    var titleFailedConversationID: UUID?

    func isTitling(_ conversationID: UUID?) -> Bool {
        conversationID.map { titlingConversationIDs.contains($0) } ?? false
    }

    /// Names the conversation with a standalone side request, in the background. Failure keeps the old title, quietly.
    /// `force` ("Regenerate title") overwrites even a user-set title and marks the new title as not user-set; it runs
    /// whether or not automatic titles are on in Settings.
    func autoRename(conversation: Conversation, context: ModelContext, force: Bool) {
        guard !titlingConversationIDs.contains(conversation.id) else { return }
        guard let endpoint = connections.endpoint(connectionID: conversation.connectionID, modelID: conversation.modelID,
                                                  sessionID: conversation.id.uuidString),
              !Self.needsKey(endpoint, connections: connections),
              let prompt = AutoRename.prompt(lines: conversation.namingLines,
                                             replacing: force ? conversation.displayTitle : nil) else {
            if force { titleFailedConversationID = conversation.id }
            return
        }
        // The title is asked as a follow-up to the chat's own request: the cached prefix is reused, and the model sees
        // everything, not just the first exchange.
        let path = conversation.activePath
        var followUp: ChatRequest?
        if path.last?.role == .assistant {
            var base = ChatRequest(model: endpoint.model.id,
                                   messages: apiHistory(path: path, conversation: conversation, endpoint: endpoint))
            if endpoint.model.supportsEffort { base.reasoningEffort = conversation.effort.apiValue }
            if endpoint.model.supportsTools { base.tools = requestTools(endpoint, conversation: conversation) }
            followUp = AutoRename.followUp(base, replacing: force ? conversation.displayTitle : nil)
        }
        let streamer = streamer
        let ring = requestRing
        let conversationID = conversation.id
        let titleAtStart = conversation.title
        conversation.autoRenameDone = true
        titlingConversationIDs.insert(conversationID)
        Task { @MainActor [weak self] in
            defer { self?.titlingConversationIDs.remove(conversationID) }
            let name = await AutoRename.generate(prompt: prompt, endpoint: endpoint, streamer: streamer, followUp: followUp) { event in
                switch event {
                case .sent(let id, let url, let body): ring.record(conversationID: conversationID, url: url, body: body, id: id)
                case .finished(let id, let reason, let usage): ring.complete(id, finishReason: reason, usage: usage)
                }
            }
            guard let name else {
                // "Regenerate title" says it failed; a failed automatic title is tried again after a later answer.
                if force { self?.titleFailedConversationID = conversationID }
                if !force, conversation.modelContext != nil, !conversation.isDeleted { conversation.autoRenameDone = false }
                return
            }
            guard conversation.modelContext != nil, !conversation.isDeleted else { return }
            // Renamed by hand while the request ran: the user's title wins.
            if conversation.title != titleAtStart || (!force && conversation.titleIsUserSet) { return }
            conversation.title = name
            if force { conversation.titleIsUserSet = false }
            try? context.save()
        }
    }

    /// Stops the chat's reply (or its "Summarize now"). A queued reply is dropped before it starts, marked Stopped.
    func stop(_ conversation: Conversation) {
        stop(conversationID: conversation.id)
    }

    func stop(conversationID: UUID) {
        guard let run = runs[conversationID] else { return }
        if run.isQueued {
            unqueue(run)
            if let message = run.message, let context = run.context, let conversation = message.conversation {
                message.stoppedByUser = true
                finish(run, message: message, conversation: conversation, context: context, error: nil)
            } else {
                endRun(run)
            }
            return
        }
        revealAll(run)
        run.persister?.flush() // the cancel request needs the newest request id and cursor
        if let message = run.message, let context = run.context, let endpoint = run.endpoint {
            message.stoppedByUser = true
            message.cancelPending = message.resumeData != nil
            try? context.save()
            if message.cancelPending { cancelOnServer(message, endpoint: endpoint, context: context) }
        }
        run.task?.cancel()
    }

    /// Stops every chat's reply.
    func stop() {
        for id in Array(runs.keys) { stop(conversationID: id) }
    }

    /// The chat is being deleted: its reply stops (the server is told, as for Stop) and nothing more is written to it.
    func discardRun(for conversationID: UUID) {
        indicators.opened(conversationID)
        if readyNotice?.conversationID == conversationID { readyNotice = nil }
        skillOffers[conversationID] = nil
        compactionErrors[conversationID] = nil
        guard let run = runs[conversationID] else { return }
        if !run.isQueued, let message = run.message, let context = run.context, let endpoint = run.endpoint {
            run.persister?.flush()
            message.cancelPending = message.resumeData != nil
            if message.cancelPending { cancelOnServer(message, endpoint: endpoint, context: context) }
        }
        run.discarded = true
        run.task?.cancel()
        unqueue(run)
        KeptPages.shared.turnEnded(conversation: conversationID)
        BrowserSessions.shared.turnEnded(conversation: conversationID)
        if run.holdsLease {
            run.holdsLease = false
            background.end(conversationID, success: false)
        }
        run.message = nil
        run.context = nil
        endRun(run)
    }

    /// "Answer now": stops the running request the way Stop does (the gateway is told to cancel it too), keeps the
    /// tool results gathered so far and the reasoning written, drops the call that was still open, and then sends one
    /// continuation that asks for the answer without tools.
    func answerNow(_ conversation: Conversation) {
        guard let run = runs[conversation.id], run.canAnswerNow, run.message != nil else { return }
        run.earlyAnswerRequested = true
        stop(conversationID: conversation.id)
    }

    /// "Save as skill": a hidden instruction after the answer that offered it, and a turn that writes the skill.
    func saveAsSkill(conversation: Conversation, context: ModelContext) {
        guard !isStreaming(conversation), toolSwitches(conversation).contains(.browser), let leaf = conversation.leafMessage,
              leaf.id == skillOffers[conversation.id] else { return }
        skillOffers[conversation.id] = nil
        let instruction = Message(role: .user, text: SkillOffer.instruction, sortIndex: nextIndex(conversation))
        instruction.hiddenInstruction = true
        instruction.skillRequest = true
        context.insert(instruction)
        conversation.attach(instruction, parent: leaf)
        conversation.updatedAt = .now
        try? context.save()
        generate(conversation: conversation, context: context, under: instruction)
    }

    func dismissSkillOffer(_ conversation: Conversation) {
        skillOffers[conversation.id] = nil
    }

    /// The hidden instruction goes on the path after the cut-short run; the answer follows it.
    private func continueEarly(after cut: Message, conversation: Conversation, context: ModelContext) {
        let instruction = Message(role: .user, text: AnswerNow.instruction, sortIndex: nextIndex(conversation))
        instruction.hiddenInstruction = true
        context.insert(instruction)
        conversation.attach(instruction, parent: cut)
        try? context.save()
        generate(conversation: conversation, context: context, under: instruction)
    }

    static let cancelRetryWindow: TimeInterval = 600
    /// How long after its message a cancel whose request the server doesn't know yet is kept for a later foreground.
    /// Past it, the server has no stream left for the turn.
    static let cancelLookupLifetime: TimeInterval = 3600

    private func cancelOnServer(_ message: Message, endpoint: Endpoint, context: ModelContext) {
        guard cancelTasks[message.id] == nil else { return }
        guard let checkpoint = message.resumeCheckpoint,
              checkpoint.requestID != nil || (checkpoint.idempotencyKey != nil && checkpoint.submissionStarted),
              let client = streamer as? any ResumableChatStreaming else {
            message.cancelPending = false
            message.clearResume()
            try? context.save()
            return
        }
        let messageID = message.id
        let createdAt = message.createdAt
        cancelTasks[messageID] = Task { @MainActor [weak self] in
            // The chat may be deleted while this retries (deleting a chat stops its reply): the server is still told,
            // but nothing is written to a deleted message.
            func alive() -> Bool { message.modelContext != nil && !message.isDeleted }
            let lookupDeadline = Date().addingTimeInterval(30)
            // Bounded: after this long the flag stays set and the next foreground retries (restorePending).
            let giveUp = Date().addingTimeInterval(Self.cancelRetryWindow)
            while !Task.isCancelled, Date() < giveUp {
                do {
                    var id = checkpoint.requestID
                    if id == nil, let key = checkpoint.idempotencyKey {
                        id = try await client.requestID(forIdempotencyKey: key, endpoint: endpoint)
                    }
                    if let id {
                        try await client.cancel(requestID: id, endpoint: endpoint)
                    } else if Date() < lookupDeadline {
                        // The original POST may still be in gateway authentication/routing.
                        try await RecoverySignals.shared.wait(seconds: 0.5)
                        continue
                    } else if Date().timeIntervalSince(createdAt) < Self.cancelLookupLifetime {
                        // Still no request for the key: it may yet arrive (a slow upload). Nothing was cancelled, so
                        // the flag stays and the next foreground looks again (restorePending).
                        break
                    }
                    // A cancel went out, or the turn is too old for the server to still run it.
                    guard alive() else { break }
                    message.cancelPending = false
                    message.clearResume()
                    try? context.save()
                    break
                } catch {
                    try? await RecoverySignals.shared.wait(seconds: 5)
                }
            }
            self?.cancelTasks[messageID] = nil
        }
    }

    /// Called at launch and foreground. Live runs reconnect themselves; every other unfinished reply is picked up, each
    /// in its own chat (later ones queue like any send).
    func restorePending(context: ModelContext) {
        let messages = Self.pendingMessages(context: context)
        for message in messages where message.cancelPending {
            if let conversation = message.conversation,
               let endpoint = connections.endpoint(connectionID: conversation.connectionID, modelID: conversation.modelID,
                                                   sessionID: conversation.id.uuidString) {
                cancelOnServer(message, endpoint: endpoint, context: context)
            }
        }
        var claimed = Set(runs.keys)
        for message in messages.sorted(by: { $0.createdAt < $1.createdAt })
        where message.resumeData != nil && !message.stoppedByUser && !message.cancelPending {
            guard let conversation = message.conversation, !claimed.contains(conversation.id),
                  let checkpoint = message.resumeCheckpoint else { continue }
            claimed.insert(conversation.id)
            generate(conversation: conversation, context: context, restoring: message, checkpoint: checkpoint)
        }
    }

    /// Unfinished turns only, found by a predicate (not by loading every message on each foreground).
    /// Turns saved before the `hasResume` flag existed are flagged once.
    static func pendingMessages(context: ModelContext, defaults: UserDefaults = .standard) -> [Message] {
        let key = "strata.resumeFlagMigrated.v1"
        if !defaults.bool(forKey: key) {
            for message in (try? context.fetch(FetchDescriptor<Message>())) ?? [] where message.resumeData != nil && !message.hasResume {
                message.hasResume = true
            }
            try? context.save()
            defaults.set(true, forKey: key)
        }
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.cancelPending || $0.hasResume })
        descriptor.fetchLimit = 20
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: Slots

    private var workingCount: Int { runs.values.filter { !$0.isQueued }.count }

    /// Starts the run now, or queues it while every slot is taken.
    private func admit(_ run: ChatRun) {
        if workingCount - 1 < maxConcurrentRuns { // the run itself is counted until it is queued
            run.start?()
        } else {
            run.phase = .queued
            queue.append(run.conversationID)
        }
    }

    /// A slot came free: the oldest queued run starts.
    private func admitNext() {
        while workingCount < maxConcurrentRuns, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let run = runs[id], run.isQueued else { continue }
            run.phase = .waiting
            run.start?()
        }
    }

    private func unqueue(_ run: ChatRun) {
        queue.removeAll { $0 == run.conversationID }
    }

    /// Takes the run out of `runs` and gives back what it held. `handover`: an early answer takes its slot next.
    private func endRun(_ run: ChatRun, handover: Bool = false) {
        run.persister?.close()
        run.persister = nil
        run.start = nil
        if runs[run.conversationID] === run { runs[run.conversationID] = nil }
        if !handover { admitNext() }
    }

    // MARK: Generation

    private func nextIndex(_ conversation: Conversation) -> Int {
        (conversation.messages.map(\.sortIndex).max() ?? -1) + 1
    }

    /// - Parameter parent: the message the answer follows (default: the current leaf). Regenerating passes the user message
    ///   the old answer followed, so the new answer becomes its sibling.
    private func generate(conversation: Conversation, context: ModelContext, restoring: Message? = nil,
                          checkpoint: TurnCheckpoint? = nil, under parent: Message? = nil) {
        conversation.ensureTree()
        let assistant = restoring ?? Message(role: .assistant, sortIndex: nextIndex(conversation))
        if restoring == nil {
            // After the hidden instruction: an early answer (also when it is regenerated).
            let above = parent ?? conversation.leafMessage
            assistant.answeredEarly = above?.hiddenInstruction == true && above?.skillRequest != true
            context.insert(assistant)
            conversation.attach(assistant, parent: parent ?? conversation.leafMessage)
        } else {
            assistant.conversation = conversation
            assistant.errorText = nil // a reconnect after an outage clears the outage's message
            assistant.errorNeedsSettings = false
        }
        try? context.save()

        let render = MessageRenderState(smoothing: settings.smoothStreaming)
        renderStates[assistant.id] = render
        let run = ChatRun(conversationID: conversation.id, kind: .turn, messageID: assistant.id)
        run.isEarly = assistant.answeredEarly
        run.liveSources = conversation.sources
        run.message = assistant
        run.context = context
        skillOffers[conversation.id] = nil
        indicators.opened(conversation.id)
        runs[conversation.id] = run

        guard let endpoint = connections.endpoint(connectionID: conversation.connectionID, modelID: conversation.modelID,
                                                  sessionID: conversation.id.uuidString) else {
            finish(run, message: assistant, conversation: conversation, context: context, error: APIError.missingModel)
            return
        }
        if Self.needsKey(endpoint, connections: connections) {
            finish(run, message: assistant, conversation: conversation, context: context,
                   error: Self.credentialError(endpoint))
            return
        }
        run.endpoint = endpoint
        run.start = { [weak self, weak run] in
            guard let self, let run else { return }
            self.startTurn(run, assistant: assistant, conversation: conversation, context: context, endpoint: endpoint,
                           render: render, restoring: restoring != nil, checkpoint: checkpoint)
        }
        admit(run)
    }

    /// The turn's work, once it has a slot: the request is built from the history as it is now.
    private func startTurn(_ run: ChatRun, assistant: Message, conversation: Conversation, context: ModelContext,
                           endpoint: Endpoint, render: MessageRenderState, restoring: Bool, checkpoint: TurnCheckpoint?) {
        run.start = nil
        run.phase = .waiting
        run.turnStart = .now
        run.completedToolRounds = 0
        run.earlyAnswerRequested = false
        run.pendingCalls = []

        let path = conversation.path(to: assistant.parentID).filter { $0.id != assistant.id }
        run.persistedSourceCount = -1
        run.persister = endpoint.supportsResumable ? CheckpointPersister { [weak self, weak run] snapshot in
            guard let self, let run, !run.discarded else { return }
            self.persist(snapshot, run: run, message: assistant, conversation: conversation, context: context)
        } : nil
        background.begin(run.conversationID)
        run.holdsLease = true
        var runner = TurnRunner(streamer: streamer, tools: tools)
        runner.toolsDisabled = assistant.answeredEarly
        runner.continueOnEmptyAnswer = settings.continueOnEmptyAnswer
        let ring = requestRing
        let conversationID = conversation.id
        runner.requestLog = { event in
            switch event {
            case .sent(let id, let url, let body): ring.record(conversationID: conversationID, url: url, body: body, id: id)
            case .finished(let id, let reason, let usage): ring.complete(id, finishReason: reason, usage: usage)
            }
        }
        DiagnosticCounters.shared.beginTurn(conversation: conversation.id)
        let effort = conversation.effort
        if !restoring, endpoint.model.supportsTools { applyToolSwitches(conversation, path: path) }
        let messages = apiHistory(path: path, conversation: conversation, endpoint: endpoint)
        runner.offered = endpoint.model.supportsTools ? offeredTools(conversation, freeze: true) : []
        runner.switches = ChatToolSwitches(conversation)
        runner.compaction = compactionSettings(conversation: conversation, endpoint: endpoint, messages: messages, path: path)
        let sourceStore = SourceStore(items: conversation.sources)
        run.sourceStore = sourceStore

        run.task = Task { @MainActor [weak self] in
            guard let self else { return }
            let tracker = TurnTracker(message: assistant, conversation: conversation, render: render, checkpoint: checkpoint)
            do {
                let outcome = try await ToolContext.$conversationID.withValue(conversationID) {
                    try await ToolContext.$readsImages.withValue(endpoint.model.supportsImages) {
                        try await runner.run(endpoint: endpoint, messages: messages, effort: effort, sources: sourceStore, checkpoint: checkpoint) { event in
                            try self.handle(event, run: run, tracker: tracker, context: context)
                        }
                    }
                }
                guard !run.discarded else { return }
                tracker.finishThinking()
                conversation.sources = sourceStore.items
                tracker.complete(finalText: outcome.finalContent)
                assistant.steps = tracker.completedSteps
                if let usage = outcome.lastUsage { conversation.apply(usage) }
                ReplyBackgroundExecution.notifyCompletion(title: Self.notificationTitle(conversation, assistant: assistant),
                                                          body: Self.notificationBody(assistant.text),
                                                          conversationID: conversation.id)
                self.finish(run, message: assistant, conversation: conversation, context: context, error: nil, tracker: tracker)
            } catch where error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                guard !run.discarded else { return }
                // Stop in any state (first byte, thinking, writing, tool): keep what is there, mark it Stopped.
                let early = run.earlyAnswerRequested
                if early { tracker.keepFinishedCallsOfOpenRound() }
                tracker.finishThinking()
                tracker.complete(finalText: nil)
                conversation.sources = sourceStore.items
                assistant.stoppedByUser = true
                assistant.cutForEarlyAnswer = early
                assistant.steps = tracker.completedSteps
                self.finish(run, message: assistant, conversation: conversation, context: context, error: nil, tracker: tracker,
                            handover: early)
                if early { self.continueEarly(after: assistant, conversation: conversation, context: context) }
            } catch {
                guard !run.discarded else { return }
                tracker.finishThinking()
                conversation.sources = sourceStore.items
                tracker.complete(finalText: nil)
                assistant.steps = tracker.completedSteps
                self.finish(run, message: assistant, conversation: conversation, context: context, error: error, tracker: tracker)
            }
        }
    }

    private func handle(_ event: TurnEvent, run: ChatRun, tracker: TurnTracker, context: ModelContext) throws {
        // A deleted chat's run writes nothing more, even a tool result that lands before the cancellation does.
        if run.discarded { throw CancellationError() }
        background.advance()
        switch event {
        case .checkpoint(let checkpoint):
            run.persister?.update(checkpoint)
        case .roundStarted(let n):
            run.completedToolRounds = n
            tracker.beginRound(n)
            run.pendingCalls = []
            run.roundRecords = []
            run.roundRequested = []
            run.phase = .waiting
        case .reasoning(let r):
            tracker.addReasoning(r)
            if run.phase != .thinking { run.phase = .thinking }
        case .content(let c):
            tracker.addContent(c)
            if run.phase != .writing { run.phase = .writing }
        case .toolsRequested(let calls):
            tracker.finishThinking()
            tracker.beginTools(calls)
            run.pendingCalls = calls.map { PendingToolCall(id: $0.id, name: $0.name, primaryArgument: ToolCallRecord(id: $0.id, name: $0.name, arguments: $0.arguments, result: "", isError: false).primaryArgument, offset: ToolCallRecord.fetchOffset(in: $0.arguments),
                                                        plugin: $0.name == ToolNames.runPlugin ? PluginCall.name(in: $0.arguments) : nil) }
            run.roundRequested = run.pendingCalls
            if let first = run.pendingCalls.first { run.phase = .tool(name: first.name, argument: first.primaryArgument) }
        case .toolFinished(let record):
            tracker.completeTool(record)
            if let store = run.sourceStore { run.liveSources = store.items }
            run.roundRecords.append(record)
            run.pendingCalls.removeAll { $0.id == record.id }
            if let next = run.pendingCalls.first { run.phase = .tool(name: next.name, argument: next.primaryArgument) }
        case .usage(let u):
            tracker.conversation.apply(u)
            tracker.conversation.lastUsageMessageID = tracker.message.id
        case .compactionStarted:
            tracker.finishThinking()
            run.phase = .compacting
        case .compacted(let outcome, let steps, let preTurn):
            storeCompaction(outcome, conversation: tracker.conversation, anchor: preTurn
                            ? tracker.conversation.message(id: tracker.message.parentID)?.parentID : tracker.message.id,
                            anchorSteps: preTurn ? -1 : steps, automatic: true, context: context)
            tracker.conversation.lastUsageMessageID = tracker.message.id
            run.phase = .waiting
        }
    }

    // MARK: Tool switches

    /// The chat's tool switches: its own, or the defaults in Settings until it has any.
    func toolSwitches(_ conversation: Conversation?) -> Set<ToolGroup> {
        conversation?.toolSwitches ?? settings.defaultToolGroups
    }

    /// The composer's "+" menu: applies from the next message. A call to a group turned off is refused at once.
    func setTool(_ group: ToolGroup, on: Bool, conversation: Conversation) {
        var switches = toolSwitches(conversation)
        if on { switches.insert(group) } else { switches.remove(group) }
        conversation.toolSwitches = switches
    }

    /// The tool groups the chat's requests offer: frozen at its first request (`freeze`), its switches before that.
    private func offeredTools(_ conversation: Conversation, freeze: Bool) -> Set<ToolGroup> {
        if let offered = conversation.offeredTools { return offered }
        let current = toolSwitches(conversation)
        guard freeze else { return current }
        if conversation.toolSwitches == nil { conversation.toolSwitches = current }
        return conversation.frozenTools(current: current)
    }

    /// Before a turn's first request. Switches flipped since the model last heard of them are told in a note at the end
    /// of the turn's user message (`Message.apiNote`: in requests only, kept so later requests repeat it). The tool
    /// list and the system message stay as they were, so the cached prefix holds.
    private func applyToolSwitches(_ conversation: Conversation, path: [Message]) {
        let current = toolSwitches(conversation)
        if conversation.toolSwitches == nil { conversation.toolSwitches = current }
        guard let offered = conversation.offeredTools else { return } // the first request freezes them as they are
        let announced = conversation.announcedTools ?? offered
        let changed = Set(ToolGroup.allCases.filter { offered.contains($0) && current.contains($0) != announced.contains($0) })
        if !changed.isEmpty, let user = path.last, user.role == .user {
            // Sent again (Regenerate): the groups it named before keep their place, with their state now.
            user.apiNote = ToolGroup.note(changed.union(ToolGroup.groups(inNote: user.apiNote)), enabled: current)
        }
        // A group turned on that the chat wasn't offered at its start joins the offered set: its tools and its system
        // prompt section are added, which changes the request's prefix, so the provider's prompt cache is lost once.
        // (Off at the start costs nothing: not offered, nothing cached yet.)
        conversation.offeredTools = offered.union(current)
        conversation.announcedTools = current
    }

    // MARK: Compaction

    /// The messages to send for `path`: the conversation's latest compaction on it, then what follows its anchor.
    /// `freeze` is false for display-only estimates, which must not pin the chat's preferences or tools before it sends.
    private func apiHistory(path: [Message], conversation: Conversation, endpoint: Endpoint, freeze: Bool = true) -> [APIMessage] {
        let tools = endpoint.model.supportsTools
        let offered = tools ? offeredTools(conversation, freeze: freeze) : []
        let plugins = offered.contains(.web) ? PluginRegistry.bundled.promptSection(enabled: AppSettings.currentEnabledPlugins) : ""
        // A chat keeps the skill list it first had with the browser on, like its preferences.
        let skillIndex = !offered.contains(.browser) ? ""
            : freeze ? conversation.frozenSkillIndex(current: skills.index) : conversation.skillIndexSnapshot ?? skills.index
        let base = [AppPrompt.text(tools: tools, python: offered.contains(.python), browser: offered.contains(.browser),
                                   skills: offered.contains(.browser), video: offered.contains(.video), ssh: offered.contains(.ssh),
                                   views: offered.contains(.views)),
                    skillIndex,
                    AppPrompt.preferences(freeze ? conversation.frozenPreferences(current: settings.userPreferences)
                                                  : conversation.preferencesSnapshot ?? settings.userPreferences)]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        let system = ConversationDate.systemPrompt(base: base, day: conversation.systemDay, plugins: plugins)
        if let compacted = conversation.compactedHistory(path: path) {
            return MessageAssembler.apiMessages(from: compacted.rest, systemPrompt: system, replacing: compacted.replacement,
                                                readsImages: endpoint.model.supportsImages)
        }
        let history = path.filter { $0.role == .user || !$0.text.isEmpty || !$0.steps.isEmpty }.map(\.historyMessage)
        return MessageAssembler.apiMessages(from: history, systemPrompt: system, readsImages: endpoint.model.supportsImages)
    }

    /// The tools the chat's requests send (see `ToolDefinition.available`).
    private func requestTools(_ endpoint: Endpoint, conversation: Conversation) -> [ToolDefinition] {
        ToolDefinition.available(groups: offeredTools(conversation, freeze: false), images: endpoint.model.supportsImages)
    }

    /// The window, the room for an answer and the context size before this turn's own message.
    private func contextWindow(for endpoint: Endpoint) -> Int {
        var window = endpoint.model.effectiveContextLength(default: settings.defaultContextLength)
        #if DEBUG
        if let n = Int(DebugHooks.value("StrataContextWindow") ?? ""), n > 0 { window = n }
        #endif
        return window
    }

    private func compactionSettings(conversation: Conversation, endpoint: Endpoint, messages: [APIMessage], path: [Message]) -> CompactionSettings {
        let window = contextWindow(for: endpoint)
        // The last reported usage belongs to the request that ended just before this turn's user message, when it was
        // made on this branch; otherwise everything is an estimate.
        let history = messages.last?.role == "user" ? Array(messages.dropLast()) : messages
        var meter = ContextMeter.estimate(history)
        if let usage = conversation.lastUsage, let id = conversation.lastUsageMessageID,
           path.dropLast().last?.id == id {
            meter = ContextMeter(usage: usage)
        }
        return CompactionSettings(window: window, maxOutput: endpoint.model.maxOutputTokens, meter: meter)
    }

    /// Saves a compaction, replacing one made at the same point (a turn restored after the notes were written), and
    /// moves the context ring to the size after it.
    func storeCompaction(_ outcome: CompactionOutcome, conversation: Conversation, anchor: UUID?, anchorSteps: Int,
                         automatic: Bool, context: ModelContext) {
        conversation.apply(Usage(promptTokens: outcome.tokensAfter, completionTokens: 0))
        guard let anchor else { return }
        for old in conversation.compactions where old.anchorMessageID == anchor && old.anchorSteps == anchorSteps {
            context.delete(old)
        }
        guard let record = try? CompactionRecord(anchorMessageID: anchor, anchorSteps: anchorSteps, notes: outcome.notes,
                                                 replacement: outcome.replacement, tokensBefore: outcome.tokensBefore,
                                                 tokensAfter: outcome.tokensAfter, isAutomatic: automatic) else { return }
        context.insert(record)
        record.conversation = conversation
        try? context.save()
    }

    /// "Summarize now": compacts the conversation as it stands, without a turn. It takes a slot like a reply.
    func compactNow(conversation: Conversation, context: ModelContext) {
        guard !isStreaming(conversation) else { return }
        conversation.ensureTree()
        let path = conversation.activePath
        guard let leaf = path.last,
              let endpoint = connections.endpoint(connectionID: conversation.connectionID, modelID: conversation.modelID,
                                                  sessionID: conversation.id.uuidString),
              !Self.needsKey(endpoint, connections: connections) else { return }
        let conversationID = conversation.id
        let run = ChatRun(conversationID: conversationID, kind: .compaction, messageID: nil)
        compactionErrors[conversationID] = nil
        runs[conversationID] = run
        run.start = { [weak self, weak run] in
            guard let self, let run else { return }
            self.startCompaction(run, conversation: conversation, leaf: leaf, path: path, endpoint: endpoint, context: context)
        }
        admit(run)
    }

    private func startCompaction(_ run: ChatRun, conversation: Conversation, leaf: Message, path: [Message], endpoint: Endpoint,
                                 context: ModelContext) {
        run.start = nil
        run.phase = .compacting
        run.turnStart = .now
        let messages = apiHistory(path: path, conversation: conversation, endpoint: endpoint)
        let window = contextWindow(for: endpoint)
        var request = ChatRequest(model: endpoint.model.id, messages: messages)
        if endpoint.model.supportsEffort { request.reasoningEffort = conversation.effort.apiValue }
        if endpoint.model.supportsTools { request.tools = requestTools(endpoint, conversation: conversation) }
        let streamer = streamer
        let ring = requestRing
        let conversationID = conversation.id
        let url = endpoint.requestURL.absoluteString
        let meter = ContextMeter.estimate(messages)
        let usable = conversation.lastUsage.flatMap { conversation.lastUsageMessageID == leaf.id ? $0 : nil }
        run.task = Task { @MainActor [weak self] in
            defer { self?.endRun(run) }
            do {
                let outcome = try await Compactor(streamer: streamer).compact(
                    endpoint: endpoint, base: request, meter: usable.map { ContextMeter(usage: $0) } ?? meter, window: window) { sent in
                    if let body = try? sent.encoded() { ring.record(conversationID: conversationID, url: url, body: body, id: UUID()) }
                }
                guard !run.discarded else { return }
                self?.storeCompaction(outcome, conversation: conversation, anchor: leaf.id, anchorSteps: -1, automatic: false, context: context)
                conversation.lastUsageMessageID = leaf.id
                try? context.save()
            } catch is CancellationError {
                // Stopped: nothing changed.
            } catch {
                guard !run.discarded else { return }
                self?.compactionErrors[conversationID] = error.localizedDescription
            }
        }
    }

    /// The Context sheet's split of `total` tokens by category, estimated from what the next request would send (the
    /// same history and tools as a turn). Display only: nothing is sent or stored. Nil when the chat has no endpoint.
    func contextSplit(conversation: Conversation, total: Int) -> [Int]? {
        guard let endpoint = connections.endpoint(connectionID: conversation.connectionID, modelID: conversation.modelID,
                                                  sessionID: conversation.id.uuidString)
        else { return nil }
        let messages = apiHistory(path: conversation.activePath, conversation: conversation, endpoint: endpoint, freeze: false)
        return ContextEstimator.split(messages: messages, tools: endpoint.model.supportsTools ? requestTools(endpoint, conversation: conversation) : nil,
                                      total: total)
    }

    /// One throttled checkpoint write: the large half only when it changed, the small half always, together.
    private func persist(_ snapshot: CheckpointPersister.Snapshot, run: ChatRun, message: Message, conversation: Conversation, context: ModelContext) {
        if let data = snapshot.staticData { message.resumeData = data }
        if !message.hasResume { message.hasResume = true }
        message.resumeDynamicData = snapshot.dynamicData
        onCheckpointWrite?((snapshot.staticData?.count ?? 0) + snapshot.dynamicData.count)
        DiagnosticCounters.shared.recordCheckpointWrite(conversation: conversation.id, staticBytes: snapshot.staticData?.count,
                                                        dynamicBytes: snapshot.dynamicData.count)
        // Text and reasoning live in the dynamic half (the accumulator); they are copied into their columns when the
        // turn ends. Sources are written only when new ones arrived, so the sidebar's query is not invalidated.
        if let items = run.sourceStore?.items, items.count != run.persistedSourceCount {
            run.persistedSourceCount = items.count
            conversation.sources = items
        }
        try? context.save()
        #if DEBUG
        DebugHooks.recordResumeSmoke(message, checkpoint: snapshot.checkpoint)
        #endif
    }

    /// The chat's title, or (before it has one) the question that was asked.
    static func notificationTitle(_ conversation: Conversation, assistant: Message) -> String {
        if !conversation.title.isEmpty { return conversation.title }
        let question = conversation.activePath.last { $0.role == .user && !$0.isHiddenInTranscript }?.text ?? ""
        return Conversation.autoTitle(from: question)
    }

    /// The start of the answer as plain text, about three lines on a lock screen.
    nonisolated static func notificationBody(_ answer: String, limit: Int = 180) -> String {
        // Block markers (headings, bullets, quotes, fences) first, then the inline Markdown of what is left.
        let lines = answer.split(whereSeparator: \.isNewline).map { line in
            line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^(#{1,6}\s+|[-*+]\s+|>\s*|\d+[.)]\s+|```.*$)"#, with: "", options: .regularExpression)
        }.filter { !$0.isEmpty }
        let flat = MarkdownPlain.text(from: lines.joined(separator: " "))
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// - Parameter handover: an early answer follows at once and takes this run's slot.
    private func finish(_ run: ChatRun, message: Message, conversation: Conversation, context: ModelContext,
                        error: Error?, tracker: TurnTracker? = nil, handover: Bool = false) {
        run.persister?.close()
        run.persister = nil
        // Pages kept for the user after a failed tool go a few minutes from now; Stop browsing applied to this reply.
        KeptPages.shared.turnEnded(conversation: conversation.id)
        BrowserSessions.shared.turnEnded(conversation: conversation.id)
        if let error {
            message.errorText = error.localizedDescription
            message.errorNeedsSettings = (error as? APIError)?.needsSettings ?? false
        }
        // An outage keeps the checkpoint: the reply is still on the server, and the next foreground reconnects.
        if !message.cancelPending && !(error is StreamOutage) { message.clearResume() }
        // A turn the person stopped ended as they asked: only an error reads "failed" in the system's task list, and a
        // stopped one says so rather than "ready".
        let stopped = message.stoppedByUser && !message.answeredEarly
        // VoiceOver hears that the reply ended, instead of having to go and look.
        if !stopped {
            let spoken = error.map { (($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription) } ?? String(localized: "Answer ready")
            AccessibilityNotification.Announcement(spoken).post()
        }
        skillOffers[conversation.id] = SkillOffer.isOffered(
            steps: message.steps,
            browserAvailable: toolSwitches(conversation).contains(.browser) && run.endpoint?.model.supportsTools == true,
            finishedWithAnswer: error == nil && !message.stoppedByUser && !message.text.isEmpty) ? message.id : nil
        if run.holdsLease {
            run.holdsLease = false
            background.end(run.conversationID, success: error == nil,
                           title: error != nil ? nil : stopped ? String(localized: "Reply stopped") : String(localized: "Reply ready"),
                           subtitle: Self.notificationTitle(conversation, assistant: message))
        }
        run.message = nil
        run.context = nil
        conversation.updatedAt = .now
        try? context.save()
        #if DEBUG
        DebugHooks.recordResumeSmoke(message)
        #endif
        run.phase = .idle
        run.pendingCalls = []
        run.roundRecords = []
        run.roundRequested = []
        var autoNaming = true
        #if DEBUG
        autoNaming = DebugHooks.value("StrataNoAutoRename") == nil // keeps request-count smoke tests exact
        #endif
        if error == nil, !message.stoppedByUser, autoNaming,
           AutoRename.shouldRunAutomatically(enabled: settings.generateTitles,
                                             titleIsUserSet: conversation.titleIsUserSet, alreadyAutoNamed: conversation.autoRenameDone,
                                             completedAnswers: conversation.completedAnswerCount) {
            autoRename(conversation: conversation, context: context, force: false)
        }
        // A reply that ended in a chat that isn't on screen: an unread mark, and "Reply ready" when there is one. A run
        // the person stopped (or cut short for an early answer) is not news.
        if !message.stoppedByUser, indicators.runEnded(conversation.id, visible: visibleConversationID), error == nil {
            readyNotice = ReadyNotice(conversationID: conversation.id, title: Self.notificationTitle(conversation, assistant: message))
        }
        run.sourceStore = nil
        endRun(run, handover: handover)
    }
}

#if DEBUG
extension ChatController {
    /// Screenshots of the sidebar marks and the "Reply ready" banner (`-StrataMultiChatDemo 1`): runs that do nothing
    /// (one of them queued), a chat with a reply not seen yet, and the notice for it. Nothing is sent.
    func debugMultiChatDemo(running: [UUID], queued: UUID?, unread: UUID, title: String) {
        for id in running where runs[id] == nil {
            let run = ChatRun(conversationID: id, kind: .turn, messageID: nil)
            run.phase = .writing
            runs[id] = run
        }
        if let queued, runs[queued] == nil {
            let run = ChatRun(conversationID: queued, kind: .turn, messageID: nil)
            run.phase = .queued
            runs[queued] = run
        }
        indicators.runEnded(unread, visible: visibleConversationID)
        readyNotice = ReadyNotice(conversationID: unread, title: title)
    }
}
#endif

/// Feeds streamed deltas into the render models and measures thinking time.
/// Resumable turns checkpoint persisted fields at each applied SSE boundary.
@MainActor
final class TurnTracker {
    let message: Message
    let conversation: Conversation
    let render: MessageRenderState
    private var thinkingStart: ContinuousClock.Instant?
    private var thinkingTotal: Double = 0
    private var roundContent = ""
    private var roundHasReasoning = false
    private var reasoningAll = ""
    private var requested: [ToolCall] = []
    private var stepParagraphs = 0
    private var finishedRecords: [ToolCallRecord] = []
    private(set) var completedSteps: [ToolStep] = []
    // Ordered process segments, appended as the stream produces them.
    private var segments: [ProcessSegment] = []
    private var roundReasoning = ""
    private var roundSeconds: Double = 0
    private var thinkingEmitted = false

    init(message: Message, conversation: Conversation, render: MessageRenderState, checkpoint: TurnCheckpoint? = nil) {
        self.message = message
        self.conversation = conversation
        self.render = render
        completedSteps = checkpoint?.steps ?? []
        reasoningAll = checkpoint?.priorReasoning ?? ""
        if !reasoningAll.isEmpty { render.reasoning.append(reasoningAll) }
        thinkingTotal = message.thinkingSeconds ?? 0
        if let checkpoint { segments = ProcessSegments.derive(steps: checkpoint.steps, reasoning: checkpoint.priorReasoning) }
    }

    func beginRound(_ n: Int) {
        finishThinking()
        roundContent = ""
        roundHasReasoning = false
        roundReasoning = ""
        roundSeconds = 0
        thinkingEmitted = false
        if n > 0 { render.markdown.reset() } // intermediate text lives in the tool step
    }

    func addReasoning(_ r: String) {
        if thinkingStart == nil { thinkingStart = .now }
        roundHasReasoning = true
        reasoningAll += r
        roundReasoning += r
        render.reasoning.append(r)
    }

    func addContent(_ c: String) {
        finishThinking()
        emitThinking() // the thinking row sits above the answer from its first character
        roundContent += c
        render.markdown.append(c)
    }

    func finishThinking() {
        guard let start = thinkingStart else { return }
        let elapsed = (ContinuousClock.now - start).seconds
        thinkingTotal += elapsed
        roundSeconds += elapsed
        thinkingStart = nil
        message.thinkingSeconds = thinkingTotal
    }

    func beginTools(_ calls: [ToolCall]) {
        requested = calls
        finishedRecords = []
        finishThinking() // the round's thinking time, for its line
        emitThinking()
        let preamble = roundContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preamble.isEmpty { append(.init(index: 0, kind: .text, text: preamble)) }
        // The round's text now lives in its segment, shown as a note above this round's calls; clearing the model
        // keeps it from showing twice.
        render.markdown.reset()
        // Force a paragraph boundary so the timeline can place this step after the reasoning so far.
        render.reasoning.beginSection()
        if !reasoningAll.isEmpty && !reasoningAll.hasSuffix("\n\n") { reasoningAll += "\n\n" }
        stepParagraphs = render.reasoning.finalized.count
    }

    func completeTool(_ record: ToolCallRecord) {
        finishedRecords.append(record)
        if finishedRecords.count == requested.count {
            completedSteps.append(ToolStep(assistantContent: roundContent, calls: finishedRecords, reasoningParagraphs: stepParagraphs))
            message.steps = completedSteps
            append(.init(index: 0, kind: .toolRound, calls: finishedRecords.map(\.displayOnly)))
        }
    }

    /// For an early answer: a round cut short keeps the calls that did finish, each with its result, and drops the rest
    /// (a call without a result cannot be sent back). A round with nothing finished is dropped whole.
    func keepFinishedCallsOfOpenRound() {
        guard !requested.isEmpty, !finishedRecords.isEmpty, finishedRecords.count < requested.count else { return }
        completedSteps.append(ToolStep(assistantContent: roundContent, calls: finishedRecords, reasoningParagraphs: stepParagraphs))
        message.steps = completedSteps
        append(.init(index: 0, kind: .toolRound, calls: finishedRecords.map(\.displayOnly)))
        requested = []
        finishedRecords = []
    }

    private func append(_ segment: ProcessSegment) {
        var s = segment
        s.index = segments.count
        segments.append(s)
        message.segments = segments
    }

    /// The round's reasoning becomes one thinking segment, once.
    private func emitThinking() {
        guard !thinkingEmitted else { return }
        thinkingEmitted = true
        let text = roundReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        append(.init(index: 0, kind: .thinking, text: text, seconds: roundSeconds > 0 ? roundSeconds : nil))
    }

    /// Persist the final text and reasoning and reconcile the render models.
    func complete(finalText: String?) {
        let text = finalText ?? render.markdown.text
        message.text = text
        message.reasoning = reasoningAll
        emitThinking()
        render.markdown.finish(finalText: text)
        render.reasoning.revealAll()
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
