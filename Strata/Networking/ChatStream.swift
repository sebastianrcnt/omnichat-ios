import Foundation

/// Partial tool call from a streamed delta.
struct ToolCallDelta: Codable, Equatable, Sendable {
    var index: Int
    var id: String?
    var name: String?
    var arguments: String?
}

/// Decoded content of a single streamed chunk.
struct ChatDelta: Equatable, Sendable {
    var content: String?
    var reasoning: String?
    var toolCalls: [ToolCallDelta] = []
    var usage: Usage?
    var finishReason: String?
    var isDone = false
    var requestID: String?
    var sequence: Int?
    /// Reasoning items to send back with this turn's tool results (Responses API only).
    var reasoningItems: [ReasoningItem] = []

    var isEmpty: Bool {
        (content ?? "").isEmpty && (reasoning ?? "").isEmpty && toolCalls.isEmpty && usage == nil && finishReason == nil
            && reasoningItems.isEmpty
    }
}

enum ChatChunkDecoder {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct TC: Decodable {
                    struct Fn: Decodable { var name: String?; var arguments: String? }
                    var index: Int?
                    var id: String?
                    var function: Fn?
                }
                var content: String?
                var reasoningContent: String?
                var reasoning: String?
                var toolCalls: [TC]?
                enum CodingKeys: String, CodingKey {
                    case content, reasoning
                    case reasoningContent = "reasoning_content"
                    case toolCalls = "tool_calls"
                }
            }
            var delta: Delta?
            var finishReason: String?
            enum CodingKeys: String, CodingKey { case delta; case finishReason = "finish_reason" }
        }
        struct ErrorBody: Decodable { var message: String? }
        var choices: [Choice]?
        var usage: Usage?
        var error: ErrorBody?
    }

    /// Decode one SSE `data:` payload. Throws `APIError.server` for in-band errors.
    static func decode(_ payload: String) throws -> ChatDelta {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" { return ChatDelta(isDone: true) }
        guard let data = trimmed.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else {
            return ChatDelta()
        }
        if let error = chunk.error {
            throw APIError.server(error.message ?? String(localized: "The server reported an error."))
        }
        var delta = ChatDelta()
        if let choice = chunk.choices?.first {
            delta.finishReason = choice.finishReason
            if let d = choice.delta {
                delta.content = d.content
                // `reasoning_content` (vLLM/DeepSeek style) or `reasoning` (OpenRouter style).
                delta.reasoning = d.reasoningContent ?? d.reasoning
                delta.toolCalls = (d.toolCalls ?? []).enumerated().map { offset, tc in
                    ToolCallDelta(index: tc.index ?? offset, id: tc.id, name: tc.function?.name, arguments: tc.function?.arguments)
                }
            }
        }
        delta.usage = chunk.usage
        return delta
    }
}

/// Accumulates streamed deltas into the final content, reasoning, tool calls and usage.
struct StreamAccumulator: Codable, Sendable {
    private(set) var content = ""
    private(set) var reasoning = ""
    private(set) var usage: Usage?
    private(set) var finishReason: String?
    private var calls: [Int: ToolCall] = [:]
    /// Optional so checkpoints saved before it existed still decode.
    private var reasoningItemList: [ReasoningItem]?

    init() {}

    mutating func apply(_ delta: ChatDelta) {
        if let c = delta.content { content += c }
        if let r = delta.reasoning { reasoning += r }
        if let u = delta.usage { usage = u }
        if let f = delta.finishReason { finishReason = f }
        if !delta.reasoningItems.isEmpty { reasoningItemList = (reasoningItemList ?? []) + delta.reasoningItems }
        for tc in delta.toolCalls {
            var call = calls[tc.index] ?? ToolCall(id: "", name: "", arguments: "")
            if let id = tc.id, !id.isEmpty { call.id = id }
            if let name = tc.name { call.name += name }
            if let args = tc.arguments { call.arguments += args }
            calls[tc.index] = call
        }
    }

    /// The response's reasoning items, in order (Responses API only).
    var reasoningItems: [ReasoningItem] { reasoningItemList ?? [] }

    /// Completed tool calls in index order. Calls missing an id get a synthetic one.
    var toolCalls: [ToolCall] {
        calls.keys.sorted().compactMap { idx in
            guard var call = calls[idx], !call.name.isEmpty else { return nil }
            if call.id.isEmpty { call.id = "call_\(idx)" }
            return call
        }
    }
}
