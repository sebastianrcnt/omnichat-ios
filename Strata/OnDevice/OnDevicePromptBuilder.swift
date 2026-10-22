import Foundation

/// Turns a chat request (built for an API model: the app's long system prompt, every tool, the whole history) into a
/// prompt the on-device model can take: a few-thousand-token window, a ~3B model, and a session that runs its own tool
/// loop. Pure, so it is tested without the model.
///
/// - The app's system prompt becomes short instructions that keep the date and the user's preferences; any other
///   system message (titles, a compaction) is kept as it is.
/// - Earlier turns keep the user's text and the final answer; their tool calls and results are left out.
/// - The current turn is the last user message. Tool rounds after it (the session stopped at a tool call, the app ran
///   it) are written into the prompt as text, so the model answers from the results.
/// - Everything is fitted to the window: the oldest turns go first, then long tool results, then long messages are cut.
enum OnDevicePromptBuilder {
    /// Tools the on-device model is offered when the chat offers them. The rest (browser, Python, SSH, …) need more
    /// reasoning and context than a ~3B model with a 4K window has; their descriptions alone would take a good part
    /// of it. Short descriptions on purpose: they go into the window too.
    static let toolSpecs: [OnDeviceToolSpec] = [
        OnDeviceToolSpec(name: ToolNames.webSearch,
                         description: "Search the web. Use for current events, recent facts or anything you are unsure about.",
                         parameters: [.init(name: "query", description: "The search query.")]),
        OnDeviceToolSpec(name: ToolNames.webFetch,
                         description: "Read a web page's text by its URL.",
                         parameters: [.init(name: "url", description: "The absolute http(s) URL.")]),
    ]

    /// The tools to offer for `request`: those it lists that the on-device model can use, none when it may not call
    /// tools (`tool_choice: none`, as capped rounds, compactions and title follow-ups send).
    static func tools(for request: ChatRequest) -> [OnDeviceToolSpec] {
        guard request.toolChoice != "none", let listed = request.tools, !listed.isEmpty else { return [] }
        let names = Set(listed.map(\.function.name))
        return toolSpecs.filter { names.contains($0.name) }
    }

    static let imageNote = "[The user attached an image here.]"
    static let unreadableImageNote = "[The user attached an image, but this model can't see images.]"
    static let truncated = "\n[…cut to fit the on-device model's context]"

    // MARK: Instructions

    /// The first line of the app's system prompt (`AppPrompt.base`): a chat request, whose prompt is replaced.
    static var appPromptMarker: String { AppPrompt.base.components(separatedBy: "\n").first ?? AppPrompt.base }

    /// Short instructions in place of the app's system prompt, keeping its date line and the user's preferences.
    /// Any other system message is kept as it is.
    static func instructions(from system: String, tools: [OnDeviceToolSpec]) -> String {
        guard system.hasPrefix(appPromptMarker) else { return system }
        var parts = ["You are a helpful assistant in OpenChat, running privately on the user's device."]
        if let date = system.components(separatedBy: "\n").last(where: { $0.hasPrefix("Current date:") }) {
            parts.append(date)
        }
        var rules = """
        - Reply in the language of the user's message. Use Markdown. Be clear and concise.
        - If you don't know something, say so instead of guessing.
        """
        if !tools.isEmpty {
            rules += "\n- Use the tools for current or uncertain facts. Tool results wrap sources like <source id=\"1\" ...>. "
                + "Cite them inline as [1] after the statement they support; never invent ids."
        }
        parts.append(rules)
        if let preferences = userPreferences(in: system) {
            parts.append("The user's instructions for you (follow them):\n\(preferences)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// The text inside `<userPreferences>` (`AppPrompt.preferences`), if the system prompt has some.
    static func userPreferences(in system: String) -> String? {
        guard let open = system.range(of: "<userPreferences>"),
              let close = system.range(of: "</userPreferences>", range: open.upperBound..<system.endIndex) else { return nil }
        let text = system[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: Building

    /// Rough tokens of a text: UTF-8 bytes / 3 (`Compaction.estimateChars` counts dense text higher). On the safe side
    /// of the model's tokenizer for English; a request that still overflows is built again with less room.
    static func estimateTokens(_ text: String) -> Int { (Compaction.estimateChars(text) + 2) / 3 }

    /// Tokens a turn costs besides its text (role markers).
    static let turnOverhead = 8
    /// Tokens a tool costs in the instructions (its name, description and schema).
    static let toolOverhead = 60

    /// The room kept for the answer: what the request caps it at, else a quarter of the window (at least 512 tokens).
    static func answerRoom(contextSize: Int, maxTokens: Int?) -> Int {
        let quarter = max(contextSize / 4, min(512, contextSize / 2))
        guard let maxTokens, maxTokens > 0 else { return quarter }
        return min(maxTokens, quarter)
    }

    /// The prompt for `request`, fitted into `contextSize` tokens with room for the answer. `squeeze` (0 < s ≤ 1)
    /// shrinks the room for the prompt, for a retry after the model said it didn't fit.
    static func build(_ request: ChatRequest, contextSize: Int, readsImages: Bool, tools: [OnDeviceToolSpec],
                      squeeze: Double = 1) -> OnDevicePrompt {
        var messages = request.messages
        let system = messages.first?.role == "system" ? Compaction.text(of: messages.removeFirst()) : ""
        let room = answerRoom(contextSize: contextSize, maxTokens: request.maxTokens)
        let budget = max(Int(Double(contextSize - room) * min(max(squeeze, 0.05), 1)), 64)
        var left = budget - tools.count * toolOverhead

        // Instructions: at most a quarter of the room.
        var instructions = instructions(from: system, tools: tools)
        instructions = cut(instructions, toTokens: max(left / 4, 32))
        left -= estimateTokens(instructions) + turnOverhead

        // The current turn: the last user message that doesn't follow a tool result (those are images a tool attached
        // or an empty-answer nudge), and what came after it.
        let current = messages.indices.last { i in
            messages[i].role == "user" && (i == 0 || messages[i - 1].role != "tool")
        }
        let earlier = current.map { Array(messages[..<$0]) } ?? messages
        let turn = current.map { Array(messages[$0...]) } ?? []

        var images: [Data] = []
        var question = ""
        if let user = turn.first {
            question = text(of: user, readsImages: readsImages, images: &images)
        }
        // Tool rounds of this turn, and any user note after them (an empty-answer nudge).
        var results: [(call: String, output: String)] = []
        var calls: [String: ToolCall] = [:]
        var notes: [String] = []
        for m in turn.dropFirst() {
            switch m.role {
            case "assistant":
                for call in m.toolCalls { calls[call.id] = call }
            case "tool":
                let call = m.toolCallID.flatMap { calls[$0] }
                let label = call.map { "\($0.name) \($0.arguments)" } ?? "tool"
                results.append((label, Compaction.text(of: m)))
            case "user":
                var ignored: [Data] = []
                let note = text(of: m, readsImages: false, images: &ignored)
                if !note.isEmpty { notes.append(note) }
            default: break
            }
        }

        // The user's own words get up to half of what's left; tool results share what remains after them.
        question = cut(question, toTokens: max(left / 2, 32), keepEnd: true)
        left -= estimateTokens(question) + turnOverhead
        let notesText = notes.joined(separator: "\n\n")
        left -= estimateTokens(notesText)
        var prompt = question
        if !results.isEmpty {
            let header = "\n\n[Tool results]\n"
            let footer = "\n\nAnswer the request above using these results."
            left -= estimateTokens(header + footer)
            let share = max(left * 3 / 4 / results.count, 48)
            let body = results.map { result in
                let head = result.call + "\n"
                return head + cut(result.output, toTokens: max(share - estimateTokens(head), 24))
            }.joined(separator: "\n\n")
            left -= estimateTokens(body)
            prompt += header + body + footer
        }
        if !notesText.isEmpty { prompt += "\n\n" + notesText }

        // Earlier turns, newest first, while they fit. Consecutive messages of one role are joined.
        var history: [OnDevicePrompt.Turn] = []
        for m in earlier {
            let role: OnDevicePrompt.Turn.Role
            var text: String
            switch m.role {
            case "user":
                role = .user
                var ignored: [Data] = []
                text = self.text(of: m, readsImages: false, images: &ignored, imagesAsNotes: true)
            case "assistant":
                role = .assistant
                text = Compaction.text(of: m)
            default: continue // tool results of earlier turns
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if let last = history.last, last.role == role {
                history[history.count - 1].text += "\n\n" + text
            } else {
                history.append(.init(role: role, text: text))
            }
        }
        var kept: [OnDevicePrompt.Turn] = []
        for turn in history.reversed() {
            let cost = estimateTokens(turn.text) + turnOverhead
            if cost > left { break }
            left -= cost
            kept.insert(turn, at: 0)
        }
        // The history starts with the user, as a conversation does.
        while kept.first?.role == .assistant { kept.removeFirst() }

        return OnDevicePrompt(instructions: instructions, history: kept, prompt: prompt, images: images,
                              maxTokens: request.maxTokens.map { min($0, room) })
    }

    /// A user message's text; its images go to `images` for a model that reads them, else become a note.
    private static func text(of message: APIMessage, readsImages: Bool, images: inout [Data],
                             imagesAsNotes: Bool = false) -> String {
        guard case .parts(let parts) = message.content else { return Compaction.text(of: message) }
        var lines: [String] = []
        for part in parts {
            switch part {
            case .text(let s): lines.append(s)
            case .imageURL(let url):
                if readsImages, !imagesAsNotes, let data = imageData(url) {
                    images.append(data)
                } else {
                    lines.append(imagesAsNotes || readsImages ? imageNote : unreadableImageNote)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The bytes of a `data:` URL (`ContentPart.jpegDataURL`).
    static func imageData(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    /// `text` cut to about `tokens`, with a note. `keepEnd` keeps its start and its end (a pasted text's question is
    /// often at the end), else the start.
    static func cut(_ text: String, toTokens tokens: Int, keepEnd: Bool = false) -> String {
        guard estimateTokens(text) > tokens else { return text }
        // Bytes per character of this text, so the cut lands near the budget in any script.
        let perChar = max(Double(Compaction.estimateChars(text)) / Double(max(text.count, 1)), 1)
        let chars = max(Int(Double(tokens * 3) / perChar) - truncated.count, 16)
        if keepEnd {
            let head = text.prefix(chars * 2 / 3)
            let tail = text.suffix(chars / 3)
            return head + truncated + "\n" + tail
        }
        return text.prefix(chars) + truncated
    }
}
