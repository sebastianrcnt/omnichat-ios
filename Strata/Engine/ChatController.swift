import Foundation
import SwiftData
import Observation

/// A tool call that has been requested and is still running (or just finished).
struct PendingToolCall: Identifiable, Equatable {
    var id: String
    var name: String
    var primaryArgument: String
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
    var isStreaming: Bool { activeMessageID != nil }

    private let connections: ConnectionStore
    private let settings: AppSettings
    private let streamer: any ChatStreaming
    private let tools: any ToolExecuting
    private var task: Task<Void, Never>?
    private var renderStates: [UUID: MessageRenderState] = [:]

    init(connections: ConnectionStore, settings: AppSettings,
         streamer: any ChatStreaming = ChatClient(), tools: any ToolExecuting = ToolRouter()) {
        self.connections = connections
        self.settings = settings
        self.streamer = streamer
        self.tools = tools
    }

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
        task?.cancel()
    }

    // MARK: Generation

    private func nextIndex(_ conversation: Conversation) -> Int {
        (conversation.messages.map(\.sortIndex).max() ?? -1) + 1
    }

    private func generate(conversation: Conversation, context: ModelContext) {
        let assistant = Message(role: .assistant, sortIndex: nextIndex(conversation))
        assistant.conversation = conversation
        context.insert(assistant)
        try? context.save()

        let render = MessageRenderState(smoothing: settings.smoothStreaming)
        renderStates[assistant.id] = render
        activeConversationID = conversation.id
        activeMessageID = assistant.id
        phase = .waiting
        pendingCalls = []

        let history = conversation.sortedMessages
            .filter { $0.id != assistant.id }
            .filter { $0.role == .user || !$0.text.isEmpty || !$0.steps.isEmpty }
            .map(\.historyMessage)
        guard let endpoint = connections.endpoint(connectionID: conversation.connectionID, modelID: conversation.modelID) else {
            finish(assistant, conversation: conversation, context: context, error: APIError.missingModel)
            return
        }
        let runner = TurnRunner(streamer: streamer, tools: tools)
        let effort = conversation.effort
        let messages = MessageAssembler.apiMessages(from: history, systemPrompt: endpoint.systemPrompt)
        let sourceStore = SourceStore(items: conversation.sources)

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let tracker = TurnTracker(message: assistant, conversation: conversation, render: render)
            do {
                let outcome = try await runner.run(endpoint: endpoint, messages: messages, effort: effort, sources: sourceStore) { event in
                    self.handle(event, tracker: tracker)
                }
                tracker.finishThinking()
                conversation.sources = sourceStore.items
                tracker.complete(finalText: outcome.finalContent)
                assistant.steps = outcome.steps
                if let usage = outcome.lastUsage { conversation.apply(usage) }
                self.finish(assistant, conversation: conversation, context: context, error: nil, tracker: tracker)
            } catch is CancellationError {
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

    private func handle(_ event: TurnEvent, tracker: TurnTracker) {
        switch event {
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
            pendingCalls = calls.map { PendingToolCall(id: $0.id, name: $0.name, primaryArgument: ToolCallRecord(id: $0.id, name: $0.name, arguments: $0.arguments, result: "", isError: false).primaryArgument) }
            if let first = pendingCalls.first { phase = .tool(name: first.name, argument: first.primaryArgument) }
        case .toolFinished(let record):
            tracker.completeTool(record)
            pendingCalls.removeAll { $0.id == record.id }
            if let next = pendingCalls.first { phase = .tool(name: next.name, argument: next.primaryArgument) }
        case .usage(let u):
            tracker.conversation.apply(u)
        }
    }

    private func finish(_ message: Message, conversation: Conversation, context: ModelContext,
                        error: Error?, tracker: TurnTracker? = nil) {
        if let error { message.errorText = error.localizedDescription }
        conversation.updatedAt = .now
        try? context.save()
        phase = .idle
        pendingCalls = []
        activeMessageID = nil
        activeConversationID = nil
        task = nil
    }
}

/// Feeds streamed deltas into the render models and measures thinking time.
/// Persisted fields (`text`, `reasoning`) are written once, when the turn ends.
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
    private var finishedRecords: [ToolCallRecord] = []
    private(set) var completedSteps: [ToolStep] = []

    init(message: Message, conversation: Conversation, render: MessageRenderState) {
        self.message = message
        self.conversation = conversation
        self.render = render
    }

    func beginRound(_ n: Int) {
        finishThinking()
        roundContent = ""
        roundHasReasoning = false
        if n > 0 { render.markdown.reset() } // intermediate text lives in the tool step
    }

    func addReasoning(_ r: String) {
        if thinkingStart == nil { thinkingStart = .now }
        if !roundHasReasoning {
            roundHasReasoning = true
            if !reasoningAll.isEmpty { reasoningAll += "\n\n"; render.reasoning.beginSection() }
        }
        reasoningAll += r
        render.reasoning.append(r)
    }

    func addContent(_ c: String) {
        finishThinking()
        roundContent += c
        render.markdown.append(c)
    }

    func finishThinking() {
        guard let start = thinkingStart else { return }
        thinkingTotal += (ContinuousClock.now - start).seconds
        thinkingStart = nil
        message.thinkingSeconds = thinkingTotal
    }

    func beginTools(_ calls: [ToolCall]) {
        requested = calls
        finishedRecords = []
    }

    func completeTool(_ record: ToolCallRecord) {
        finishedRecords.append(record)
        if finishedRecords.count == requested.count {
            completedSteps.append(ToolStep(assistantContent: roundContent, calls: finishedRecords))
            message.steps = completedSteps
        }
    }

    /// Persist the final text and reasoning and reconcile the render models.
    func complete(finalText: String?) {
        let text = finalText ?? render.markdown.text
        message.text = text
        message.reasoning = reasoningAll
        render.markdown.finish(finalText: text)
        render.reasoning.revealAll()
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
