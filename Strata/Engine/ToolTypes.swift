import Foundation

/// A web result a tool found. The turn runner turns these into numbered `<source>` blocks.
struct SourceCandidate: Sendable, Equatable, Codable {
    var title: String
    var url: String
    var content: String
}

/// Result of running a tool on device.
struct ToolOutput: Sendable, Equatable {
    var text: String
    var isError: Bool = false
    /// Web results behind `text`. When present and a `SourceStore` is available, `text` is replaced by
    /// `<source id="N" ...>` blocks with conversation-wide stable ids.
    var sources: [SourceCandidate] = []
}

/// A tool result that finished before the results ahead of it in the round, held (and checkpointed) until it can be
/// numbered in call order.
struct RawToolResult: Codable, Sendable, Equatable {
    var callID: String
    var text: String
    var isError: Bool
    var sources: [SourceCandidate]

    init(callID: String, output: ToolOutput) {
        self.callID = callID
        text = output.text
        isError = output.isError
        sources = output.sources
    }

    var output: ToolOutput { ToolOutput(text: text, isError: isError, sources: sources) }
}

protocol ToolExecuting: Sendable {
    /// WebKit tools may need to wait for an active scene if no continued-processing lease is available.
    var usesWebKit: Bool { get }
    func execute(name: String, arguments: String) async -> ToolOutput
}

extension ToolExecuting { var usesWebKit: Bool { false } }

/// A persisted tool call plus its result, shown in the tool row and replayed in later requests.
struct ToolCallRecord: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var arguments: String
    var result: String
    var isError: Bool
    /// Ids of the sources this call produced (see `SourceStore`).
    var sourceIDs: [Int] = []

    init(id: String, name: String, arguments: String, result: String, isError: Bool, sourceIDs: [Int] = []) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.sourceIDs = sourceIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        arguments = try c.decode(String.self, forKey: .arguments)
        result = try c.decode(String.self, forKey: .result)
        isError = try c.decode(Bool.self, forKey: .isError)
        sourceIDs = try c.decodeIfPresent([Int].self, forKey: .sourceIDs) ?? []
    }

    /// Human-readable argument (the query or URL).
    var primaryArgument: String {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return arguments }
        switch name {
        case "web_search": return (obj["query"] as? String) ?? arguments
        case "web_fetch": return (obj["url"] as? String) ?? arguments
        default: return arguments
        }
    }

    /// `offset` argument of a `web_fetch` call (0 for a first read).
    var fetchOffset: Int { Self.fetchOffset(in: arguments) }

    static func fetchOffset(in arguments: String) -> Int {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        if let n = obj["offset"] as? Int { return n }
        if let d = obj["offset"] as? Double { return Int(d) }
        if let s = obj["offset"] as? String, let n = Int(s) { return n }
        return 0
    }

    var toolCall: ToolCall { ToolCall(id: id, name: name, arguments: arguments) }

    /// The record without its result text: all a process row needs, so segments never hold fetched page bodies.
    var displayOnly: ToolCallRecord {
        ToolCallRecord(id: id, name: name, arguments: arguments, result: "", isError: isError, sourceIDs: sourceIDs)
    }
}

/// One tool round: the assistant message that requested tools, and the results.
struct ToolStep: Codable, Hashable, Sendable {
    var assistantContent: String
    var calls: [ToolCallRecord]
    /// How many reasoning paragraphs preceded this step (places the step in the timeline).
    var reasoningParagraphs: Int = 0

    init(assistantContent: String, calls: [ToolCallRecord], reasoningParagraphs: Int = 0) {
        self.assistantContent = assistantContent
        self.calls = calls
        self.reasoningParagraphs = reasoningParagraphs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assistantContent = try c.decode(String.self, forKey: .assistantContent)
        calls = try c.decode([ToolCallRecord].self, forKey: .calls)
        reasoningParagraphs = try c.decodeIfPresent(Int.self, forKey: .reasoningParagraphs) ?? 0
    }
}

enum ToolNames {
    static let webSearch = "web_search"
    static let webFetch = "web_fetch"
}

/// Plain-value message used to build API history without touching SwiftData.
struct HistoryMessage: Sendable, Equatable {
    var role: String          // "user" | "assistant"
    var text: String
    var images: [Data] = []   // JPEG
    /// Ready-made data URLs for persisted attachments (from `ImageDataURLCache`); used instead of `images` when set.
    var imageDataURLs: [String] = []
    var steps: [ToolStep] = []
}

enum MessageAssembler {
    /// Convert stored conversation messages to API messages, expanding tool steps.
    static func apiMessages(from history: [HistoryMessage], systemPrompt: String = "") -> [APIMessage] {
        var out: [APIMessage] = []
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty { out.append(.system(trimmedPrompt)) }
        for m in history {
            switch m.role {
            case "user":
                let urls = m.imageDataURLs.isEmpty ? m.images.map { ContentPart.dataURLString(jpeg: $0) } : m.imageDataURLs
                if urls.isEmpty {
                    out.append(.user(m.text))
                } else {
                    var parts: [ContentPart] = urls.map { ContentPart.imageURL($0) }
                    if !m.text.isEmpty { parts.append(.text(m.text)) }
                    out.append(.user(parts: parts))
                }
            case "assistant":
                for step in m.steps {
                    appendToolRound(to: &out, assistantContent: step.assistantContent,
                                    calls: step.calls.map(\.toolCall),
                                    results: step.calls.map { ToolOutput(text: $0.result, isError: $0.isError) })
                }
                if !m.text.isEmpty || m.steps.isEmpty { out.append(.assistant(m.text)) }
            default:
                break
            }
        }
        return out
    }

    /// Append the assistant message carrying `tool_calls`, then one `tool` message per call.
    static func appendToolRound(to messages: inout [APIMessage], assistantContent: String,
                                calls: [ToolCall], results: [ToolOutput]) {
        messages.append(.assistant(assistantContent, toolCalls: calls))
        for (call, result) in zip(calls, results) {
            messages.append(.tool(callID: call.id, content: result.text))
        }
    }
}
