import Foundation
import SwiftData
import Observation

/// A tool call that has been requested and is still running (or just finished).
struct PendingToolCall: Identifiable, Equatable {
    var id: String
    var name: String
    var primaryArgument: String
    /// `web_fetch` offset; above zero it is a continuation of an earlier read.
    var offset: Int = 0
}

/// Drives generation for the app: persists messages, runs the turn, publishes live state for the UI.
@MainActor
@Observable
final class ChatController {
    enum Phase: Equatable {
        case idle
        case waiting
        case thinking
        case tool(name: String, argument: String)
        case writing
    }

    private(set) var activeConversationID: UUID?
    private(set) var activeMessageID: UUID?
    private(set) var phase: Phase = .idle
    private(set) var pendingCalls: [PendingToolCall] = []
    private(set) var turnStart: Date?
    /// Sources of the running turn (conversation-wide ids), updated as tools finish.
    private(set) var liveSources: [SourceInfo] = []
    var isStreaming: Bool { activeMessageID != nil }

    private let connections: ConnectionStore
    private let settings: AppSettings
    private let streamer: any ChatStreaming
    private let tools: any ToolExecuting
    private var task: Task<Void, Never>?
    private var renderStates: [UUID: MessageRenderState] = [:]
    private var sourceStore: SourceStore?
    private var activeMessage: Message?
    private var activeContext: ModelContext?
    private var activeEndpoint: Endpoint?
    private var cancelTasks: [UUID: Task<Void, Never>] = [:]
    private let background = ReplyBackgroundExecution()

    init(connections: ConnectionStore, settings: AppSettings,
         streamer: any ChatStreaming = ChatClient(), tools: any ToolExecuting = ToolRouter()) {
        self.connections = connections
        self.settings = settings
        self.streamer = streamer
        self.tools = tools
        ReplyBackgroundExecution.prepareNotifications()
    }

    /// Wait for the running turn to end (tests).
    func waitUntilIdle() async { await task?.value }

    /// Streaming-aware render models for a message, cached so finalized blocks keep their identity.
    func renderState(for message: Message) -> MessageRenderState {
        if let existing = renderStates[message.id] { return existing }
        let state = MessageRenderState(text: message.text, reasoning: message.reasoning, smoothing: settings.smoothStreaming)
        renderStates[message.id] = state
        return state
    }

    /// Show everything received so far (user scrolled away or stopped).
    func revealAllNow() {
        if let id = activeMessageID { renderStates[id]?.revealAll() }
    }

    func forgetRenderStates(except keep: Set<UUID>) {
        renderStates = renderStates.filter { keep.contains($0.key) || $0.key == activeMessageID }
    }

    /// The Strata gateway always needs a key; other connections may be keyless (local servers).
    static func needsKey(_ endpoint: Endpoint, connections: ConnectionStore) -> Bool {
        (endpoint.apiKey ?? "").isEmpty && connections.connection(endpoint.connectionID)?.isStrata == true
    }

    func isStreaming(_ conversation: Conversation) -> Bool {
        isStreaming && activeConversationID == conversation.id
    }

    // MARK: Entry points

    func send(text: String, images: [Data], conversation: Conversation, context: ModelContext) {
        guard !isStreaming else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        let user = Message(role: .user, text: trimmed, sortIndex: nextIndex(conversation))
        user.conversation = conversation
        context.insert(user)
        for (i, data) in images.enumerated() {
            let a = Attachment(jpegData: data, sortIndex: i)
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
        guard !isStreaming else { return }
        let messages = conversation.sortedMessages
        if let last = messages.last, last.role == .assistant {
            context.delete(last)
            try? context.save()
        }
        generate(conversation: conversation, context: context)
    }

    func stop() {
        revealAllNow()
        if let message = activeMessage, let context = activeContext, let endpoint = activeEndpoint {
            message.stoppedByUser = true
            message.cancelPending = message.resumeData != nil
            try? context.save()
            if message.cancelPending { cancelOnServer(message, endpoint: endpoint, context: context) }
        }
        task?.cancel()
    }

    private func cancelOnServer(_ message: Message, endpoint: Endpoint, context: ModelContext) {
        guard cancelTasks[message.id] == nil else { return }
        guard let data = message.resumeData,
              let checkpoint = try? JSONDecoder().decode(TurnCheckpoint.self, from: data),
              checkpoint.requestID != nil || (checkpoint.idempotencyKey != nil && checkpoint.submissionStarted),
              let client = streamer as? any ResumableChatStreaming else {
            message.cancelPending = false
            message.resumeData = nil
            try? context.save()
            return
        }
        cancelTasks[message.id] = Task { @MainActor [weak self] in
            let lookupDeadline = Date().addingTimeInterval(30)
            while !Task.isCancelled {
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
                    }
                    message.cancelPending = false
                    message.resumeData = nil
                    try? context.save()
                    break
                } catch {
                    try? await RecoverySignals.shared.wait(seconds: 5)
                }
            }
            self?.cancelTasks[message.id] = nil
        }
    }

    /// Called at launch and foreground. Existing live tasks reconnect themselves.
    func restorePending(context: ModelContext) {
        guard let messages = try? context.fetch(FetchDescriptor<Message>()) else { return }
        for message in messages where message.cancelPending {
            if let conversation = message.conversation,
               let endpoint = connections.endpoint(connectionID: conversation.connectionID, modelID: conversation.modelID) {
                cancelOnServer(message, endpoint: endpoint, context: context)
            }
        }
        guard !isStreaming else { return }
        if let message = messages.sorted(by: { $0.createdAt < $1.createdAt }).first(where: {
            $0.resumeData != nil && !$0.stoppedByUser && !$0.cancelPending
        }), let conversation = message.conversation,
           let data = message.resumeData,
           let checkpoint = try? JSONDecoder().decode(TurnCheckpoint.self, from: data) {
            generate(conversation: conversation, context: context, restoring: message, checkpoint: checkpoint)
        }
    }

    // MARK: Generation

    private func nextIndex(_ conversation: Conversation) -> Int {
        (conversation.messages.map(\.sortIndex).max() ?? -1) + 1
    }

    private func generate(conversation: Conversation, context: ModelContext, restoring: Message? = nil, checkpoint: TurnCheckpoint? = nil) {
        let assistant = restoring ?? Message(role: .assistant, sortIndex: nextIndex(conversation))
        assistant.conversation = conversation
        if restoring == nil { context.insert(assistant) }
        try? context.save()

        let render = MessageRenderState(smoothing: settings.smoothStreaming)
        renderStates[assistant.id] = render
        activeConversationID = conversation.id
        activeMessageID = assistant.id
        phase = .waiting
        pendingCalls = []
        turnStart = .now
        liveSources = conversation.sources

        let history = conversation.sortedMessages
            .filter { $0.id != assistant.id }
            .filter { $0.role == .user || !$0.text.isEmpty || !$0.steps.isEmpty }
            .map(\.historyMessage)
        guard let endpoint = connections.endpoint(connectionID: conversation.connectionID, modelID: conversation.modelID) else {
            finish(assistant, conversation: conversation, context: context, error: APIError.missingModel)
            return
        }
        if Self.needsKey(endpoint, connections: connections) {
            finish(assistant, conversation: conversation, context: context, error: APIError.missingAPIKey(connection: endpoint.connectionName))
            return
        }
        activeMessage = assistant
        activeContext = context
        activeEndpoint = endpoint
        background.begin()
        let runner = TurnRunner(streamer: streamer, tools: tools)
        let effort = conversation.effort
        let messages = MessageAssembler.apiMessages(from: history, systemPrompt: endpoint.systemPrompt)
        let sourceStore = SourceStore(items: conversation.sources)

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let tracker = TurnTracker(message: assistant, conversation: conversation, render: render, checkpoint: checkpoint)
            self.sourceStore = sourceStore
            do {
                let outcome = try await runner.run(endpoint: endpoint, messages: messages, effort: effort, sources: sourceStore, checkpoint: checkpoint) { event in
                    try self.handle(event, tracker: tracker, context: context)
                }
                tracker.finishThinking()
                conversation.sources = sourceStore.items
                tracker.complete(finalText: outcome.finalContent)
                assistant.steps = tracker.completedSteps
                if let usage = outcome.lastUsage { conversation.apply(usage) }
                ReplyBackgroundExecution.notifyCompletion()
                self.finish(assistant, conversation: conversation, context: context, error: nil, tracker: tracker)
            } catch where error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                // Stop in any state (first byte, thinking, writing, tool): keep what is there, mark it Stopped.
                tracker.finishThinking()
                tracker.complete(finalText: nil)
                conversation.sources = sourceStore.items
                assistant.stoppedByUser = true
                assistant.steps = tracker.completedSteps
                self.finish(assistant, conversation: conversation, context: context, error: nil, tracker: tracker)
            } catch {
                tracker.finishThinking()
                conversation.sources = sourceStore.items
                tracker.complete(finalText: nil)
                assistant.steps = tracker.completedSteps
                self.finish(assistant, conversation: conversation, context: context, error: error, tracker: tracker)
            }
        }
    }

    private func handle(_ event: TurnEvent, tracker: TurnTracker, context: ModelContext) throws {
        background.advance()
        switch event {
        case .checkpoint(let checkpoint):
            if activeEndpoint?.supportsResumable == true {
                tracker.message.resumeData = try? JSONEncoder().encode(checkpoint)
                tracker.message.text = checkpoint.accumulator.content
                tracker.message.reasoning = checkpoint.priorReasoning + checkpoint.accumulator.reasoning
                tracker.conversation.sources = sourceStore?.items ?? tracker.conversation.sources
                try context.save()
                #if DEBUG
                DebugHooks.recordResumeSmoke(tracker.message, checkpoint: checkpoint)
                #endif
            }
        case .roundStarted(let n):
            tracker.beginRound(n)
            pendingCalls = []
            phase = n == 0 ? .waiting : .waiting
        case .reasoning(let r):
            tracker.addReasoning(r)
            phase = .thinking
        case .content(let c):
            tracker.addContent(c)
            phase = .writing
        case .toolsRequested(let calls):
            tracker.finishThinking()
            tracker.beginTools(calls)
            pendingCalls = calls.map { PendingToolCall(id: $0.id, name: $0.name, primaryArgument: ToolCallRecord(id: $0.id, name: $0.name, arguments: $0.arguments, result: "", isError: false).primaryArgument, offset: ToolCallRecord.fetchOffset(in: $0.arguments)) }
            if let first = pendingCalls.first { phase = .tool(name: first.name, argument: first.primaryArgument) }
        case .toolFinished(let record):
            tracker.completeTool(record)
            if let store = sourceStore { liveSources = store.items }
            pendingCalls.removeAll { $0.id == record.id }
            if let next = pendingCalls.first { phase = .tool(name: next.name, argument: next.primaryArgument) }
        case .usage(let u):
            tracker.conversation.apply(u)
        }
    }

    private func finish(_ message: Message, conversation: Conversation, context: ModelContext,
                        error: Error?, tracker: TurnTracker? = nil) {
        if let error {
            message.errorText = error.localizedDescription
            message.errorNeedsSettings = (error as? APIError)?.needsSettings ?? false
        }
        if !message.cancelPending { message.resumeData = nil }
        background.end(success: error == nil && !message.stoppedByUser)
        activeMessage = nil
        activeContext = nil
        activeEndpoint = nil
        conversation.updatedAt = .now
        try? context.save()
        #if DEBUG
        DebugHooks.recordResumeSmoke(message)
        #endif
        phase = .idle
        pendingCalls = []
        activeMessageID = nil
        activeConversationID = nil
        turnStart = nil
        sourceStore = nil
        task = nil
    }
}

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
        emitThinking()
        let preamble = roundContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preamble.isEmpty { append(.init(index: 0, kind: .text, text: preamble)) }
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
            append(.init(index: 0, kind: .toolRound, calls: finishedRecords))
        }
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
