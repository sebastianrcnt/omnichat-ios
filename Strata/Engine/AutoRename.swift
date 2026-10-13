import Foundation

/// Names a conversation with a short side request to its own model. Ported from atto's native_autorename.
/// The request is standalone: it never touches the chat history or the cached prefix.
enum AutoRename {
    static let system = "You name conversations between a user and an assistant. Reply with a title of at most 6 words "
        + "that says what the conversation is about, in the language of the conversation. "
        + "No quotes, no period at the end, nothing else."
    static let userClip = 600
    static let assistantClip = 400
    static let maxNameLength = 40
    /// The budget with thinking turned off: a title is a handful of tokens.
    static let maxTokens = 32
    /// The budget of the fallback request, which cannot turn thinking off: room for a capped round of thinking
    /// (the gateway's lowest effort thinks up to 1024 tokens) and then the title. The reasoning is dropped.
    static let fallbackMaxTokens = 1536
    static let timeout: Duration = .seconds(60)

    struct Line: Equatable, Sendable {
        var role: MessageRole
        var text: String
    }

    // MARK: Cleaning

    /// First line only, minus a thinking block, a leading "Title:" / "Name:", quotes, markdown and a trailing period,
    /// at most 40 characters (cut at a word boundary when there is one).
    static func cleanName(_ reply: String) -> String {
        let leading = CharacterSet(charactersIn: "#*_`\"'\u{201C}\u{201D}\u{2018}\u{2019}\u{300C}\u{300E}")
        let trailing = CharacterSet(charactersIn: "*_`\"'\u{201C}\u{201D}\u{2018}\u{2019}\u{300D}\u{300F}.\u{3002}")
        var name = reply
        // Servers that do not split reasoning out leave it inline; an unclosed block means the title never came.
        if let close = name.range(of: "</think>", options: .backwards) { name = String(name[close.upperBound...]) }
        else if name.contains("<think>") { return "" }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = name.firstIndex(where: \.isNewline) { name = String(name[..<newline]) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: "^(title|name)\\s*:\\s*", options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(range)
        }
        name = trim(name, leading: leading.union(.whitespacesAndNewlines), trailing: trailing.union(.whitespacesAndNewlines))
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if name.count > maxNameLength {
            var cut = String(name.prefix(maxNameLength))
            // Back up to the last space when it keeps most of the text; scripts without spaces are cut hard.
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= maxNameLength / 2 {
                cut = String(cut[..<space])
            }
            name = trim(cut, leading: .whitespacesAndNewlines, trailing: trailing.union(.whitespacesAndNewlines).union(.punctuationCharacters))
        }
        return name
    }

    private static func trim(_ s: String, leading: CharacterSet, trailing: CharacterSet) -> String {
        var scalars = Substring(s).unicodeScalars
        while let f = scalars.first, leading.contains(f) { scalars.removeFirst() }
        while let l = scalars.last, trailing.contains(l) { scalars.removeLast() }
        return String(scalars)
    }

    // MARK: Prompt

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\u{2026}" : text
    }

    /// The first user message and the first answer after it, from a conversation's lines in order.
    static func firstExchange(_ lines: [Line]) -> [Line] {
        guard let u = lines.firstIndex(where: { $0.role == .user }) else { return [] }
        let answer = lines[(u + 1)...].first(where: { $0.role == .assistant })
        return [lines[u]] + (answer.map { [$0] } ?? [])
    }

    /// The user message for the naming request: the first user message and the start of the answer, clipped.
    /// Nil when there is nothing to name yet (no user message).
    static func prompt(lines: [Line]) -> String? {
        let exchange = firstExchange(lines)
        guard !exchange.isEmpty else { return nil }
        let convo = exchange.map { line -> String in
            line.role == .user ? "User: " + clip(line.text, userClip) : "Assistant: " + clip(line.text, assistantClip)
        }
        return "The conversation:\n\n" + convo.joined(separator: "\n\n") + "\n\nTitle:"
    }

    /// How a request tries to keep thinking from eating the budget.
    enum Thinking: Equatable, Sendable {
        /// `reasoning_effort: "none"` (models that take effort) and `chat_template_kwargs.enable_thinking: false`
        /// (vLLM, llama.cpp and the Strata gateway), with the small budget.
        case off
        /// No thinking controls (a server that rejected them), a budget with room for thinking; reasoning is dropped.
        case unchanged
    }

    static func request(model: String, prompt: String, thinking: Thinking, supportsEffort: Bool) -> ChatRequest {
        var r = ChatRequest(model: model, messages: [.system(system), .user(prompt)])
        switch thinking {
        case .off:
            if supportsEffort { r.reasoningEffort = "none" }
            r.chatTemplateKwargs = .init(enableThinking: false)
            r.maxTokens = maxTokens
        case .unchanged:
            r.maxTokens = fallbackMaxTokens
        }
        return r
    }

    // MARK: Trigger rules

    /// Automatic naming runs once, after the first completed answer, while the title is not user-set and the setting is on.
    static func shouldRunAutomatically(enabled: Bool, titleIsUserSet: Bool, alreadyAutoNamed: Bool, completedAnswers: Int) -> Bool {
        enabled && !titleIsUserSet && !alreadyAutoNamed && completedAnswers == 1
    }

    // MARK: Request

    /// Asks the model for a name: first with thinking off, then, after an error or an empty reply, once more without
    /// thinking controls and with room to think. Returns nil on failure or an empty name (the caller keeps the old title).
    /// `log` sees each request as it is sent and as it ends, like the chat requests in the request ring.
    static func generate(prompt: String, endpoint: Endpoint, streamer: any ChatStreaming,
                         timeout: Duration = AutoRename.timeout,
                         log: (@MainActor @Sendable (RequestLogEvent) -> Void)? = nil) async -> String? {
        let url = endpoint.baseURL.appendingPathComponent("chat/completions").absoluteString
        for thinking in [Thinking.off, .unchanged] {
            if Task.isCancelled { return nil }
            let request = request(model: endpoint.model.id, prompt: prompt, thinking: thinking,
                                  supportsEffort: endpoint.model.supportsEffort)
            let id = UUID()
            if let log, let body = try? request.encoded() { await log(.sent(id: id, url: url, body: body)) }
            do {
                let reply = try await collect(request, endpoint: endpoint, streamer: streamer, timeout: timeout)
                if let log { await log(.finished(id: id, finishReason: reply.finishReason, usage: reply.usage)) }
                let name = cleanName(reply.text)
                if !name.isEmpty { return name }
            } catch {
                if error is CancellationError { return nil }
            }
        }
        return nil
    }

    private struct Reply: Sendable { var text = ""; var finishReason: String?; var usage: Usage? }

    /// Content only: reasoning deltas are dropped.
    private static func collect(_ request: ChatRequest, endpoint: Endpoint, streamer: any ChatStreaming, timeout: Duration) async throws -> Reply {
        try await withThrowingTaskGroup(of: Reply.self) { group in
            group.addTask {
                var reply = Reply()
                for try await delta in streamer.stream(request, endpoint: endpoint) {
                    if let c = delta.content { reply.text += c }
                    if let f = delta.finishReason { reply.finishReason = f }
                    if let u = delta.usage { reply.usage = u }
                }
                return reply
            }
            group.addTask { try await Task.sleep(for: timeout); throw WebToolError.timeout }
            defer { group.cancelAll() }
            return try await group.next() ?? Reply()
        }
    }
}
