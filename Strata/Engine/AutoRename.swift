import Foundation

/// Names a conversation with a short side request to its own model. Ported from atto's native_autorename.
/// The request is standalone: it never touches the chat history or the cached prefix.
enum AutoRename {
    static let system = "You name conversations between a user and an assistant. Reply with a title of 3 to 6 words "
        + "that says what the conversation is about, in the language the user writes in. "
        + "No quotes, no punctuation at the end, nothing else."
    static let maxMessages = 30
    static let userClip = 600
    static let assistantClip = 300
    static let maxNameLength = 80
    static let maxTokens = 64
    static let timeout: Duration = .seconds(60)

    struct Line: Equatable, Sendable {
        var role: MessageRole
        var text: String
    }

    // MARK: Cleaning

    /// First line only, minus a leading "Title:" / "Name:", quotes, markdown and a trailing period, at most 80 characters.
    static func cleanName(_ reply: String) -> String {
        let leading = CharacterSet(charactersIn: "#*_`\"'\u{201C}\u{201D}\u{2018}\u{2019}")
        let trailing = CharacterSet(charactersIn: "*_`\"'\u{201C}\u{201D}\u{2018}\u{2019}.")
        var name = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = name.firstIndex(where: \.isNewline) { name = String(name[..<newline]) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: "^(title|name)\\s*:\\s*", options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(range)
        }
        name = trim(name, leading: leading.union(.whitespacesAndNewlines), trailing: trailing.union(.whitespacesAndNewlines))
        if name.count > maxNameLength {
            name = String(name.prefix(maxNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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

    /// The user message for the naming request; nil when there is nothing to name yet (no user message).
    static func prompt(currentTitle: String?, lines: [Line]) -> String? {
        let recent = lines.suffix(maxMessages)
        guard recent.contains(where: { $0.role == .user }) else { return nil }
        let convo = recent.map { line -> String in
            line.role == .user ? "User: " + clip(line.text, userClip) : "Assistant: " + clip(line.text, assistantClip)
        }
        var out = ""
        if let current = currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty {
            out += "The conversation is named \"\(current)\" now.\n\n"
        }
        out += "The conversation so far (latest last):\n\n" + convo.joined(separator: "\n\n") + "\n\nTitle:"
        return out
    }

    static func request(model: String, prompt: String, effort: String?) -> ChatRequest {
        var r = ChatRequest(model: model, messages: [.system(system), .user(prompt)])
        r.reasoningEffort = effort
        r.maxTokens = maxTokens
        return r
    }

    // MARK: Trigger rules

    /// Automatic naming runs once, after the first completed answer, while the title is not user-set.
    static func shouldRunAutomatically(titleIsUserSet: Bool, alreadyAutoNamed: Bool, completedAnswers: Int) -> Bool {
        !titleIsUserSet && !alreadyAutoNamed && completedAnswers == 1
    }

    // MARK: Request

    /// Asks the model for a name. Tries with the lowest reasoning effort the model supports, then once more without.
    /// Returns nil on failure or an empty name (the caller keeps the old title).
    static func generate(prompt: String, endpoint: Endpoint, streamer: any ChatStreaming,
                         timeout: Duration = AutoRename.timeout) async -> String? {
        let efforts: [String?] = endpoint.model.supportsEffort ? ["none", nil] : [nil]
        for effort in efforts {
            if Task.isCancelled { return nil }
            do {
                let reply = try await collect(request(model: endpoint.model.id, prompt: prompt, effort: effort),
                                              endpoint: endpoint, streamer: streamer, timeout: timeout)
                let name = cleanName(reply)
                return name.isEmpty ? nil : name
            } catch {
                if error is CancellationError { return nil }
            }
        }
        return nil
    }

    private static func collect(_ request: ChatRequest, endpoint: Endpoint, streamer: any ChatStreaming, timeout: Duration) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var text = ""
                for try await delta in streamer.stream(request, endpoint: endpoint) { if let c = delta.content { text += c } }
                return text
            }
            group.addTask { try await Task.sleep(for: timeout); throw WebToolError.timeout }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
    }
}
