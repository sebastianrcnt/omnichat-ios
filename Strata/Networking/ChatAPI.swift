import Foundation

/// A tool call requested by the model (assembled from streamed deltas).
struct ToolCall: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var arguments: String
}

enum ContentPart: Sendable, Equatable {
    case text(String)
    /// A full URL, normally `data:image/jpeg;base64,...`.
    case imageURL(String)
}

extension ContentPart: Encodable {
    enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url" }
    enum ImageKeys: String, CodingKey { case url }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .imageURL(let url):
            try c.encode("image_url", forKey: .type)
            var inner = c.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageURL)
            try inner.encode(url, forKey: .url)
        }
    }

    static func jpegDataURL(_ jpeg: Data) -> ContentPart { .imageURL(dataURLString(jpeg: jpeg)) }

    static func dataURLString(jpeg: Data) -> String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }
}

enum APIContent: Sendable, Equatable {
    case text(String)
    case parts([ContentPart])
}

/// One chat-completions message.
struct APIMessage: Sendable, Equatable, Encodable {
    var role: String
    var content: APIContent
    var toolCalls: [ToolCall] = []
    var toolCallID: String?

    static func system(_ text: String) -> APIMessage { .init(role: "system", content: .text(text)) }
    static func user(_ text: String) -> APIMessage { .init(role: "user", content: .text(text)) }
    static func user(parts: [ContentPart]) -> APIMessage { .init(role: "user", content: .parts(parts)) }
    static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> APIMessage {
        .init(role: "assistant", content: .text(text), toolCalls: toolCalls)
    }
    static func tool(callID: String, content: String) -> APIMessage {
        .init(role: "tool", content: .text(content), toolCallID: callID)
    }

    enum CodingKeys: String, CodingKey {
        case role, content, toolCalls = "tool_calls", toolCallID = "tool_call_id"
    }
    private enum CallKeys: String, CodingKey { case id, type, function }
    private enum FunctionKeys: String, CodingKey { case name, arguments }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        switch content {
        case .text(let s): try c.encode(s, forKey: .content)
        case .parts(let p): try c.encode(p, forKey: .content)
        }
        if !toolCalls.isEmpty {
            var list = c.nestedUnkeyedContainer(forKey: .toolCalls)
            for call in toolCalls {
                var item = list.nestedContainer(keyedBy: CallKeys.self)
                try item.encode(call.id, forKey: .id)
                try item.encode("function", forKey: .type)
                var fn = item.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
                try fn.encode(call.name, forKey: .name)
                try fn.encode(call.arguments, forKey: .arguments)
            }
        }
        if let toolCallID { try c.encode(toolCallID, forKey: .toolCallID) }
    }
}

/// `POST /chat/completions` body.
struct ChatRequest: Encodable, Sendable {
    struct StreamOptions: Encodable, Sendable { var includeUsage = true
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    var model: String
    var messages: [APIMessage]
    var stream = true
    var streamOptions = StreamOptions()
    var reasoningEffort: String?
    var tools: [ToolDefinition]?
    var toolChoice: String?
    /// Only the side requests (auto-rename) cap output; chat requests leave it unset so the prefix bytes stay identical.
    var maxTokens: Int?
    /// Only the title request sets this (to turn thinking off); chat requests leave it unset.
    var chatTemplateKwargs: ChatTemplateKwargs?

    struct ChatTemplateKwargs: Encodable, Sendable, Equatable {
        var enableThinking: Bool
        enum CodingKeys: String, CodingKey { case enableThinking = "enable_thinking" }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools
        case maxTokens = "max_tokens"
        case chatTemplateKwargs = "chat_template_kwargs"
        case streamOptions = "stream_options"
        case reasoningEffort = "reasoning_effort"
        case toolChoice = "tool_choice"
    }

    /// Deterministic encoding so the prefix (tools + history) is byte-stable across requests.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    func encoded() throws -> Data { try Self.encoder.encode(self) }
}

/// OpenAI function-tool definition.
struct ToolDefinition: Encodable, Sendable, Equatable {
    struct Function: Encodable, Sendable, Equatable {
        struct Parameters: Encodable, Sendable, Equatable {
            struct Property: Encodable, Sendable, Equatable {
                var type = "string"
                var description: String
                /// Allowed values; left out of the JSON when unset.
                var choices: [String]?
                enum CodingKeys: String, CodingKey { case type, description, choices = "enum" }
            }
            var type = "object"
            var properties: [String: Property]
            var required: [String]
        }
        var name: String
        var description: String
        var parameters: Parameters
    }
    var type = "function"
    var function: Function

    /// The two fixed tools. Never change these casually: they are part of the cached prefix.
    static let webSearch = ToolDefinition(function: .init(
        name: "web_search",
        description: "Search the web and return the top results (title, URL, snippet). Use for current events, facts you are unsure about, or to find pages to read.",
        parameters: .init(properties: ["query": .init(description: "The search query."),
                                       "engine": .init(description: "Optional. The search engine to use: naver for Korean topics (Korean news, places, blogs, communities), bing for most other searches, duckduckgo as an alternative to bing. Leave it out to use the user's default.",
                                                       choices: ["naver", "bing", "duckduckgo"])],
                          required: ["query"])))

    static let webFetch = ToolDefinition(function: .init(
        name: "web_fetch",
        description: "Fetch a web page by URL and return its title and main text content. Long pages are returned in slices: when the result ends with a note that more is available, call again with the same url and the given offset to continue.",
        parameters: .init(properties: ["url": .init(description: "The absolute http(s) URL to fetch."),
                                       "offset": .init(type: "integer", description: "Character offset into the page text to start from. Defaults to 0.")],
                          required: ["url"])))

    static let standard: [ToolDefinition] = [webSearch, webFetch]
}

/// Token usage from the final streamed chunk.
struct Usage: Codable, Sendable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
    var cachedTokens: Int?
    var reasoningTokens: Int?

    var totalTokens: Int { promptTokens + completionTokens }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case promptDetails = "prompt_tokens_details"
        case completionDetails = "completion_tokens_details"
    }
    private struct PromptDetails: Codable { var cachedTokens: Int?
        enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" } }
    private struct CompletionDetails: Codable { var reasoningTokens: Int?
        enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" } }

    init(promptTokens: Int, completionTokens: Int, cachedTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        cachedTokens = try c.decodeIfPresent(PromptDetails.self, forKey: .promptDetails)?.cachedTokens
        reasoningTokens = try c.decodeIfPresent(CompletionDetails.self, forKey: .completionDetails)?.reasoningTokens
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(promptTokens, forKey: .promptTokens)
        try c.encode(completionTokens, forKey: .completionTokens)
        if let cachedTokens { try c.encode(PromptDetails(cachedTokens: cachedTokens), forKey: .promptDetails) }
        if let reasoningTokens { try c.encode(CompletionDetails(reasoningTokens: reasoningTokens), forKey: .completionDetails) }
    }
}

enum APIError: Error, LocalizedError, Equatable {
    case invalidBaseURL
    case missingModel
    case missingAPIKey(connection: String)
    case http(status: Int, message: String)
    case server(String)
    case transport(String)

    /// Errors fixed in Settings; the chat shows an "Open Settings" button for these.
    var needsSettings: Bool {
        switch self {
        case .missingModel, .missingAPIKey, .invalidBaseURL: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: String(localized: "The base URL is not valid.")
        case .missingModel: String(localized: "No model available. Add an API key in Settings so models can be fetched, then pick one.")
        case .missingAPIKey(let name): String(localized: "Add an API key for \(name) in Settings.")
        case .http(let status, let message):
            message.isEmpty ? String(localized: "The server returned HTTP \(status).")
                            : String(localized: "HTTP \(status): \(message)")
        case .server(let message): message
        case .transport(let message): message
        }
    }
}
