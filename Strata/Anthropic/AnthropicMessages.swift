import Foundation
import os

// The Anthropic Messages API, spoken to Anthropic itself (`AnthropicClient`, an Anthropic connection) and to the OpenCode
// gateways for their Claude, Qwen and (on Go) MiniMax models (`OpenCodeClient`): a `system` prompt, alternating
// user/assistant `messages` of content blocks, tool calls as `tool_use` blocks and their results as `tool_result` blocks
// in the next user message, a required `max_tokens`, and `output_config.effort` for models that list effort levels. The
// turn engine keeps speaking Chat Completions (`ChatRequest`, `ChatDelta`); this file translates both ways, like
// `ResponsesAPI.swift` does for the Responses API. Only an Anthropic connection asks for prompt-cache breakpoints and a
// `thinking` configuration (`Options`): the OpenCode requests stay byte for byte what they were.

/// `POST /messages` body.
struct MessagesRequest: Encodable, Sendable {
    /// Room for the answer when neither the request nor the catalog gives a cap.
    static let defaultMaxTokens = 16384
    /// The most `cache_control` breakpoints one request may carry.
    static let maxBreakpoints = 4

    var model: String
    var system: String?
    var messages: [Message]
    var maxTokens: Int
    var tools: [Tool]?
    var toolChoice: ToolChoice?
    var outputConfig: OutputConfig?
    var thinking: Thinking?
    /// Prompt-cache breakpoints: the last tool, the system prompt and the newest messages (`placeBreakpoints`).
    var caching = false
    var stream = true

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, stream, thinking
        case maxTokens = "max_tokens", toolChoice = "tool_choice", outputConfig = "output_config"
    }

    /// What only an Anthropic connection sends.
    struct Options: Sendable, Equatable {
        var thinking: Thinking?
        var caching = false
    }

    struct Message: Encodable, Sendable, Equatable {
        var role: String
        var content: [Block]
        /// Ends in a cache breakpoint: `cache_control` goes on its last block that can carry one (not a thinking block).
        var cacheBreakpoint = false

        init(role: String, content: [Block], cacheBreakpoint: Bool = false) {
            self.role = role
            self.content = content
            self.cacheBreakpoint = cacheBreakpoint
        }

        private enum Keys: String, CodingKey { case role, content }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(role, forKey: .role)
            let marked = cacheBreakpoint ? content.lastIndex(where: \.canCache) : nil
            try c.encode(content.enumerated().map { CachedBlock(block: $1, cache: $0 == marked) }, forKey: .content)
        }
    }

    struct Tool: Encodable, Sendable, Equatable {
        var name: String
        var description: String
        var inputSchema: ToolDefinition.Function.Parameters
        /// The tool list's breakpoint (set on the last tool): the tools are frozen per chat, so they always hit.
        var cache = false
        enum CodingKeys: String, CodingKey { case name, description, inputSchema = "input_schema", cache = "cache_control" }

        init(name: String, description: String, inputSchema: ToolDefinition.Function.Parameters, cache: Bool = false) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.cache = cache
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(description, forKey: .description)
            try c.encode(inputSchema, forKey: .inputSchema)
            if cache { try c.encode(CacheControl(), forKey: .cache) }
        }
    }

    /// `{"type": "ephemeral"}`: the default five-minute cache, which every request of a chat refreshes.
    struct CacheControl: Encodable, Sendable { var type = "ephemeral" }

    struct ToolChoice: Encodable, Sendable, Equatable { var type: String }
    struct OutputConfig: Encodable, Sendable, Equatable { var effort: String }

    /// The `thinking` configuration. Adaptive thinking (Claude 4.6 and later) is steered by `output_config.effort`; the
    /// older models think against a token budget. Summarized display, so the reasoning UI has text to show (the newest
    /// models omit it by default).
    enum Thinking: Encodable, Sendable, Equatable {
        case adaptive
        case budget(Int)

        private enum Keys: String, CodingKey { case type, display, budgetTokens = "budget_tokens" }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .adaptive:
                try c.encode("adaptive", forKey: .type)
                try c.encode("summarized", forKey: .display)
            case .budget(let tokens):
                try c.encode("enabled", forKey: .type)
                try c.encode(tokens, forKey: .budgetTokens)
            }
        }
    }

    /// One content block.
    enum Block: Encodable, Sendable, Equatable {
        case text(String)
        /// Base64 image data with its media type, or an image URL.
        case image(mediaType: String?, data: String)
        case toolUse(id: String, name: String, input: JSONValue)
        case toolResult(toolUseID: String, content: String)
        case thinking(text: String, signature: String)
        case redactedThinking(data: String)

        private enum Keys: String, CodingKey {
            case type, text, source, id, name, input, content, thinking, signature, data
            case toolUseID = "tool_use_id", cacheControl = "cache_control"
        }
        private enum SourceKeys: String, CodingKey { case type, mediaType = "media_type", data, url }

        /// Thinking blocks can't carry `cache_control`.
        var canCache: Bool {
            switch self {
            case .thinking, .redactedThinking: false
            default: true
            }
        }

        var isThinking: Bool { !canCache }

        func encode(to encoder: Encoder) throws { try encode(to: encoder, cache: false) }

        func encode(to encoder: Encoder, cache: Bool) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .text(let text):
                try c.encode("text", forKey: .type)
                try c.encode(text, forKey: .text)
            case .image(let mediaType, let data):
                try c.encode("image", forKey: .type)
                var source = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                if let mediaType {
                    try source.encode("base64", forKey: .type)
                    try source.encode(mediaType, forKey: .mediaType)
                    try source.encode(data, forKey: .data)
                } else {
                    try source.encode("url", forKey: .type)
                    try source.encode(data, forKey: .url)
                }
            case .toolUse(let id, let name, let input):
                try c.encode("tool_use", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(name, forKey: .name)
                try c.encode(input, forKey: .input)
            case .toolResult(let id, let content):
                try c.encode("tool_result", forKey: .type)
                try c.encode(id, forKey: .toolUseID)
                try c.encode(content, forKey: .content)
            case .thinking(let text, let signature):
                try c.encode("thinking", forKey: .type)
                try c.encode(text, forKey: .thinking)
                try c.encode(signature, forKey: .signature)
            case .redactedThinking(let data):
                try c.encode("redacted_thinking", forKey: .type)
                try c.encode(data, forKey: .data)
            }
            if cache { try c.encode(CacheControl(), forKey: .cacheControl) }
        }
    }

    /// A block with or without its breakpoint.
    private struct CachedBlock: Encodable {
        var block: Block
        var cache: Bool
        func encode(to encoder: Encoder) throws { try block.encode(to: encoder, cache: cache) }
    }

    /// Marks a reasoning item that holds a `redacted_thinking` block's data rather than a signature.
    static let redactedPrefix = "redacted:"

    /// Translates a Chat Completions request. The first system message becomes `system`, unchanged (so the cached
    /// prefix starts with the same bytes); a later one becomes user text. Consecutive messages of one role are merged,
    /// as the API wants them alternating.
    /// - Parameters:
    ///   - effort: the level to send as `output_config.effort`, or nil.
    ///   - maxOutputTokens: the model's output cap from the catalog.
    ///   - options: thinking and prompt caching, for an Anthropic connection.
    init(_ request: ChatRequest, effort: String?, maxOutputTokens: Int?, options: Options = Options()) {
        model = request.model
        var history = request.messages[...]
        if let first = history.first, first.role == "system" {
            system = first.content.plainText
            history = history.dropFirst()
        }
        messages = Self.messages(Array(history))
        maxTokens = request.maxTokens ?? maxOutputTokens ?? Self.defaultMaxTokens
        if let defs = request.tools, !defs.isEmpty {
            tools = defs.map { Tool(name: $0.function.name, description: $0.function.description, inputSchema: $0.function.parameters) }
            if let choice = request.toolChoice { toolChoice = ToolChoice(type: choice == "none" ? "none" : "auto") }
        }
        outputConfig = effort.map(OutputConfig.init)
        thinking = options.thinking
        caching = options.caching
        if caching { placeBreakpoints() }
    }

    /// Prompt-cache breakpoints, at most four: the end of the tools and of the system prompt (frozen per chat, so every
    /// request of the chat reads them), the newest message (written for the next request to read), and the message the
    /// previous request ended with (the user message before the newest assistant reply), so each request is sure to
    /// find the previous one's cache however much the last reply added. The engine rebuilds the same history byte for
    /// byte, so everything up to that earlier breakpoint is a cache read; the markers themselves are not part of what is
    /// cached.
    private mutating func placeBreakpoints() {
        if var list = tools, !list.isEmpty {
            list[list.count - 1].cache = true
            tools = list
        }
        guard !messages.isEmpty else { return }
        messages[messages.count - 1].cacheBreakpoint = true
        let budget = Self.maxBreakpoints - (tools?.isEmpty == false ? 1 : 0) - (system?.isEmpty == false ? 1 : 0) - 1
        if budget > 0, messages.count >= 3 { messages[messages.count - 3].cacheBreakpoint = true }
    }

    /// Whether any message sends thinking back.
    var hasThinkingBlocks: Bool { messages.contains { $0.content.contains(where: \.isThinking) } }

    /// The same request with every thinking block left out: the API's own way out when it refuses the blocks sent back
    /// (their signature no longer matches the history before them). The model answers without that reasoning.
    func strippingThinking() -> MessagesRequest {
        var copy = self
        copy.messages = messages.compactMap { m in
            var m = m
            m.content.removeAll(where: \.isThinking)
            return m.content.isEmpty ? nil : m
        }
        return copy
    }

    static func messages(_ history: [APIMessage]) -> [Message] {
        var out: [Message] = []
        func append(_ role: String, _ blocks: [Block]) {
            // An empty text block is refused by the API; nothing is lost by leaving it out.
            let blocks = blocks.filter { $0 != .text("") }
            guard !blocks.isEmpty else { return }
            if out.last?.role == role { out[out.count - 1].content += blocks } else { out.append(Message(role: role, content: blocks)) }
        }
        for m in history {
            switch m.role {
            case "system", "developer":
                append("user", [.text(m.content.plainText)])
            case "user":
                switch m.content {
                case .text(let t): append("user", [.text(t)])
                case .parts(let parts): append("user", parts.map(block))
                }
            case "assistant":
                // Signed thinking first, then the text, then the calls: the order the answer produced them in.
                var blocks: [Block] = m.reasoningItems.compactMap { item in
                    guard let sealed = item.encryptedContent, !sealed.isEmpty else { return nil }
                    if sealed.hasPrefix(redactedPrefix) { return .redactedThinking(data: String(sealed.dropFirst(redactedPrefix.count))) }
                    return .thinking(text: item.summary.joined(separator: "\n\n"), signature: sealed)
                }
                let text = m.content.plainText
                if !text.isEmpty { blocks.append(.text(text)) }
                blocks += m.toolCalls.map { .toolUse(id: $0.id, name: $0.name, input: JSONValue.object(parsing: $0.arguments)) }
                append("assistant", blocks)
            case "tool":
                append("user", [.toolResult(toolUseID: m.toolCallID ?? "", content: m.content.plainText)])
            default:
                break
            }
        }
        return out
    }

    /// `data:image/jpeg;base64,…` becomes base64 data with its media type; anything else is sent as a URL.
    private static func block(_ part: ContentPart) -> Block {
        switch part {
        case .text(let t): return .text(t)
        case .imageURL(let url):
            if url.hasPrefix("data:"), let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64") {
                let mediaType = url[url.index(url.startIndex, offsetBy: 5)..<comma].dropLast(";base64".count)
                return .image(mediaType: String(mediaType), data: String(url[url.index(after: comma)...]))
            }
            return .image(mediaType: nil, data: url)
        }
    }

    private enum SystemKeys: String, CodingKey { case type, text, cacheControl = "cache_control" }

    /// The system prompt is a plain string, or with caching one text block carrying its breakpoint.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        if let system {
            if caching && !system.isEmpty {
                var list = c.nestedUnkeyedContainer(forKey: .system)
                var block = list.nestedContainer(keyedBy: SystemKeys.self)
                try block.encode("text", forKey: .type)
                try block.encode(system, forKey: .text)
                try block.encode(CacheControl(), forKey: .cacheControl)
            } else {
                try c.encode(system, forKey: .system)
            }
        }
        try c.encode(messages, forKey: .messages)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try c.encodeIfPresent(outputConfig, forKey: .outputConfig)
        try c.encodeIfPresent(thinking, forKey: .thinking)
        try c.encode(stream, forKey: .stream)
    }

    func encoded() throws -> Data { try ChatRequest.encoder.encode(self) }
}

/// Any JSON value: a tool call's `input`, which the API takes as an object rather than the string Chat Completions uses.
enum JSONValue: Encodable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    /// The arguments string of a call as an object; `{}` when it is empty or not an object.
    static func object(parsing text: String) -> JSONValue {
        guard let any = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
              case .object(let object) = JSONValue(any) else { return .object([:]) }
        return .object(object)
    }

    init(_ any: Any) {
        switch any {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init))
        default: self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Stream events

/// Turns Messages stream events into `ChatDelta`s. Stateful: blocks are tracked by index (tool calls are numbered in
/// the order they appear), thinking blocks are separated by a blank line, and the input usage from `message_start` is
/// reported with the output usage of `message_delta`.
struct MessagesEventDecoder: Sendable {
    /// Event types only, never content.
    static let log = Logger(subsystem: "cc.coolservices.strata", category: "messages")

    private enum Kind { case text, thinking, toolUse, redacted, other }
    private struct Open { var kind: Kind; var toolIndex: Int?; var thinking = ""; var signature = ""; var redacted = ""; var sawInput = false
        var initialInput: String? }

    private var blocks: [Int: Open] = [:]
    private var toolCount = 0
    private var reasoningWritten = false
    private var inputTokens = 0
    private var cachedTokens: Int?
    private var cacheWriteTokens: Int?
    private var stopReason: String?
    private(set) var finished = false

    init() {}

    private struct Event: Decodable {
        struct Block: Decodable {
            var type: String?
            var id: String?
            var name: String?
            var data: String?
            var input: AnyJSON?
            /// Some gateways put the start of a text or thinking block (or all of it) here rather than in deltas.
            var text: String?
            var thinking: String?
            var signature: String?
        }
        struct Delta: Decodable {
            var type: String?
            var text: String?
            var thinking: String?
            var signature: String?
            var partialJSON: String?
            var stopReason: String?
            enum CodingKeys: String, CodingKey {
                case type, text, thinking, signature
                case partialJSON = "partial_json", stopReason = "stop_reason"
            }
        }
        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheRead: Int?
            var cacheCreation: Int?
            var outputDetails: OutputDetails?
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens", outputTokens = "output_tokens"
                case cacheRead = "cache_read_input_tokens", cacheCreation = "cache_creation_input_tokens"
                case outputDetails = "output_tokens_details"
            }
        }
        /// The final `message_delta` may say how many of the output tokens were thinking.
        struct OutputDetails: Decodable {
            var thinkingTokens: Int?
            enum CodingKeys: String, CodingKey { case thinkingTokens = "thinking_tokens" }
        }
        struct Message: Decodable { var usage: Usage? }
        struct ErrorBody: Decodable { var type: String?; var message: String? }
        var type: String
        var index: Int?
        var contentBlock: Block?
        var delta: Delta?
        var usage: Usage?
        var message: Message?
        var error: ErrorBody?
        enum CodingKeys: String, CodingKey {
            case type, index, delta, usage, message, error
            case contentBlock = "content_block"
        }
    }

    /// The raw JSON of a field, kept as text.
    private struct AnyJSON: Decodable {
        var text: String
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(DecodedJSON.self)
            text = String(decoding: (try? JSONSerialization.data(withJSONObject: value.any, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
        }
    }

    /// Decodes one SSE `data:` payload. Throws `APIError.server` for an `error` event.
    mutating func decode(_ payload: String) throws -> ChatDelta {
        guard let data = payload.data(using: .utf8), let event = try? JSONDecoder().decode(Event.self, from: data) else {
            return ChatDelta()
        }
        Self.log.debug("event \(event.type, privacy: .public) \(event.contentBlock?.type ?? event.delta?.type ?? "", privacy: .public)")
        var delta = ChatDelta()
        switch event.type {
        case "message_start":
            let usage = event.message?.usage
            inputTokens = ContextLimits.add(usage?.inputTokens ?? 0, usage?.cacheRead ?? 0, usage?.cacheCreation ?? 0)
            cachedTokens = usage?.cacheRead
            cacheWriteTokens = usage?.cacheCreation
        case "content_block_start":
            guard let index = event.index, let block = event.contentBlock else { break }
            switch block.type {
            case "text":
                blocks[index] = Open(kind: .text)
                if let t = block.text, !t.isEmpty { delta.content = t }
            case "thinking":
                var open = Open(kind: .thinking)
                if reasoningWritten { delta.reasoning = "\n\n" }
                if let t = block.thinking, !t.isEmpty {
                    open.thinking = t
                    reasoningWritten = true
                    delta.reasoning = (delta.reasoning ?? "") + t
                }
                open.signature = block.signature ?? ""
                blocks[index] = open
            case "redacted_thinking":
                blocks[index] = Open(kind: .redacted, redacted: block.data ?? "")
            case "tool_use":
                let tool = toolCount
                toolCount += 1
                let input = block.input?.text
                blocks[index] = Open(kind: .toolUse, toolIndex: tool, initialInput: input == "{}" ? nil : input)
                delta.toolCalls = [ToolCallDelta(index: tool, id: block.id, name: block.name ?? "")]
            default:
                blocks[index] = Open(kind: .other)
            }
        case "content_block_delta":
            guard let index = event.index, let d = event.delta, var open = blocks[index] else { break }
            switch d.type {
            case "text_delta":
                delta.content = d.text
            case "thinking_delta":
                if let t = d.thinking, !t.isEmpty {
                    open.thinking += t
                    reasoningWritten = true
                    delta.reasoning = (delta.reasoning ?? "") + t
                }
            case "signature_delta":
                open.signature += d.signature ?? ""
            case "input_json_delta":
                if let json = d.partialJSON, !json.isEmpty, let tool = open.toolIndex {
                    open.sawInput = true
                    delta.toolCalls = [ToolCallDelta(index: tool, arguments: json)]
                }
            default:
                break
            }
            blocks[index] = open
        case "content_block_stop":
            guard let index = event.index, let open = blocks[index] else { break }
            switch open.kind {
            case .thinking:
                delta.reasoningItems = [ReasoningItem(summary: open.thinking.isEmpty ? [] : [open.thinking],
                                                      encryptedContent: open.signature.isEmpty ? nil : open.signature)]
            case .redacted:
                delta.reasoningItems = [ReasoningItem(summary: [], encryptedContent: MessagesRequest.redactedPrefix + open.redacted)]
            case .toolUse:
                // Input that arrived whole on the start event instead of as deltas.
                if !open.sawInput, let input = open.initialInput, let tool = open.toolIndex {
                    delta.toolCalls = [ToolCallDelta(index: tool, arguments: input)]
                }
            case .text, .other:
                break
            }
        case "message_delta":
            stopReason = event.delta?.stopReason ?? stopReason
            // `input_tokens` counts only what was neither read from nor written to the cache: the prompt is the sum, and
            // the part read from the cache is reported like other APIs' cached tokens.
            if let output = event.usage?.outputTokens {
                delta.usage = Usage(promptTokens: inputTokens, completionTokens: output, cachedTokens: cachedTokens,
                                    reasoningTokens: event.usage?.outputDetails?.thinkingTokens, cacheWriteTokens: cacheWriteTokens)
            }
            delta.finishReason = switch stopReason {
            case "tool_use": "tool_calls"
            case "max_tokens", "model_context_window_exceeded": "length"
            case "refusal": "content_filter"
            case nil: toolCount > 0 ? "tool_calls" : "stop"
            default: "stop"
            }
        case "message_stop":
            finished = true
        case "error":
            throw APIError.server(Self.errorText(type: event.error?.type, message: event.error?.message))
        default:
            break
        }
        return delta
    }

    /// What the chat shows for an `error` event in the middle of a stream.
    static func errorText(type: String?, message: String?) -> String {
        if type == "overloaded_error" {
            return String(localized: "The model's servers are overloaded right now. Try again in a moment.")
        }
        return message ?? type ?? String(localized: "The model reported an error.")
    }

    /// Reads the event stream through `message_stop`. A stream that ends before it is an interrupted answer, and says
    /// `incomplete`.
    static func consume<Bytes: AsyncSequence>(_ bytes: Bytes, incomplete: String,
                                              into continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation) async throws
        where Bytes.Element == UInt8 {
        var parser = SSEParser()
        var decoder = MessagesEventDecoder()
        var line = Data()
        func handle(_ events: [SSEEvent]) throws {
            for event in events {
                let delta = try decoder.decode(event.data)
                if !delta.isEmpty { continuation.yield(delta) }
                if decoder.finished { return }
            }
        }
        for try await byte in bytes {
            line.append(byte)
            if byte == 0x0A || byte == 0x0D { // SSE lines may end in CR alone; the parser joins CRLF across feeds
                try handle(parser.feed(line))
                line.removeAll(keepingCapacity: true)
                if decoder.finished { return }
            }
        }
        if !line.isEmpty { try handle(parser.feed(line)) }
        try handle(parser.finish())
        if !decoder.finished { throw APIError.transport(incomplete) }
    }
}

/// Decodes any JSON into Foundation values (for a tool's whole `input`).
private struct DecodedJSON: Decodable {
    let any: Any
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var out: [Any] = []
            while !array.isAtEnd { out.append(try array.decode(DecodedJSON.self).any) }
            any = out
        } else if let object = try? decoder.container(keyedBy: AnyKey.self) {
            var out: [String: Any] = [:]
            for key in object.allKeys { out[key.stringValue] = try object.decode(DecodedJSON.self, forKey: key).any }
            any = out
        } else {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { any = NSNull() }
            else if let b = try? c.decode(Bool.self) { any = b }
            else if let n = try? c.decode(Double.self) { any = n }
            else { any = try c.decode(String.self) }
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
