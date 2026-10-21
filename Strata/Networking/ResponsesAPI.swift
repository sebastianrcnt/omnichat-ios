import Foundation
import os

// The Responses API as the ChatGPT plan route takes it (developers.openai.com/siwc/token-sharing-open-source,
// "Preview limitations"): `store: false`, `stream: true`, the whole history in `input` on every request, system text in
// `instructions` (system-role items are rejected), function tools grouped in a namespace, and no sampling or output
// caps (`temperature`, `max_output_tokens`, … are rejected). The turn engine keeps speaking Chat Completions
// (`ChatRequest`, `ChatDelta`); this file translates both ways.

/// A reasoning item from a response, sent back with the tool results of the same turn. With `store: false` the server
/// keeps nothing, so the item travels as its encrypted content (`include: ["reasoning.encrypted_content"]`).
struct ReasoningItem: Codable, Sendable, Equatable, Hashable {
    var summary: [String]
    var encryptedContent: String?
}

/// `POST /v1/responses` body.
struct ResponsesRequest: Encodable, Sendable {
    /// All app tools go in one namespace (the route takes function tools only inside namespaces). Fixed, so the
    /// tools part of the prompt stays byte-identical.
    static let toolNamespace = "strata"
    static let toolNamespaceDescription = "Tools that run in the OpenChat app on the user's device."

    var model: String
    var instructions: String?
    var input: [InputItem]
    var tools: [Tool]?
    var toolChoice: String?
    var reasoning: Reasoning?
    var include: [String]?
    /// Only the standard Responses API takes an output cap (the ChatGPT route rejects it); only side requests set it.
    var maxOutputTokens: Int?
    var store = false
    var stream = true
    /// Not encoded: whether `tools` and the calls in `input` use the `strata` namespace.
    var namespacedTools = true
    static let flatToolsKey = CodingUserInfoKey(rawValue: "strata.responses.flatTools")!

    struct Reasoning: Encodable, Sendable, Equatable {
        var effort: String?
        var summary: String? = "auto"
    }

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, tools, reasoning, include, store, stream
        case toolChoice = "tool_choice"
        case maxOutputTokens = "max_output_tokens"
    }

    /// One `input` item.
    enum InputItem: Encodable, Sendable, Equatable {
        case message(role: String, content: [ContentItem])
        case reasoning(ReasoningItem)
        case functionCall(callID: String, name: String, arguments: String)
        case functionCallOutput(callID: String, output: String)

        enum ContentItem: Encodable, Sendable, Equatable {
            case inputText(String)
            case inputImage(String)
            case outputText(String)

            enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url" }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .inputText(let t): try c.encode("input_text", forKey: .type); try c.encode(t, forKey: .text)
                case .outputText(let t): try c.encode("output_text", forKey: .type); try c.encode(t, forKey: .text)
                case .inputImage(let url): try c.encode("input_image", forKey: .type); try c.encode(url, forKey: .imageURL)
                }
            }
        }

        private enum Keys: String, CodingKey {
            case type, role, content, summary, encryptedContent = "encrypted_content", callID = "call_id", name
            case namespace, arguments, output
        }
        private enum SummaryKeys: String, CodingKey { case type, text }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .message(let role, let content):
                try c.encode("message", forKey: .type)
                try c.encode(role, forKey: .role)
                try c.encode(content, forKey: .content)
            case .reasoning(let item):
                // No `id`: with `store: false` an item id refers to nothing on the server.
                try c.encode("reasoning", forKey: .type)
                var list = c.nestedUnkeyedContainer(forKey: .summary)
                for text in item.summary {
                    var part = list.nestedContainer(keyedBy: SummaryKeys.self)
                    try part.encode("summary_text", forKey: .type)
                    try part.encode(text, forKey: .text)
                }
                if let encrypted = item.encryptedContent { try c.encode(encrypted, forKey: .encryptedContent) }
            case .functionCall(let callID, let name, let arguments):
                try c.encode("function_call", forKey: .type)
                try c.encode(callID, forKey: .callID)
                try c.encode(name, forKey: .name)
                // Tools sent flat were never in the namespace.
                if encoder.userInfo[ResponsesRequest.flatToolsKey] as? Bool != true {
                    try c.encode(ResponsesRequest.toolNamespace, forKey: .namespace)
                }
                try c.encode(arguments, forKey: .arguments)
            case .functionCallOutput(let callID, let output):
                try c.encode("function_call_output", forKey: .type)
                try c.encode(callID, forKey: .callID)
                try c.encode(output, forKey: .output)
            }
        }
    }

    /// `{"type": "namespace", "name": "strata", "tools": [flat function tools]}`.
    struct NamespaceTool: Encodable, Sendable, Equatable {
        struct Function: Encodable, Sendable, Equatable {
            var type = "function"
            var name: String
            var description: String
            var parameters: ToolDefinition.Function.Parameters
            /// Explicitly off: Responses would otherwise make every optional parameter required.
            var strict = false
        }
        var type = "namespace"
        var name = ResponsesRequest.toolNamespace
        var description = ResponsesRequest.toolNamespaceDescription
        var tools: [Function]
    }

    /// A `tools` entry: the namespace (ChatGPT), or a flat function tool (the standard Responses API).
    enum Tool: Encodable, Sendable, Equatable {
        case namespace(NamespaceTool)
        case function(NamespaceTool.Function)

        func encode(to encoder: Encoder) throws {
            switch self {
            case .namespace(let tool): try tool.encode(to: encoder)
            case .function(let tool): try tool.encode(to: encoder)
            }
        }
    }

    /// Effort names the Responses API takes. Strata's top level ("Max") has no equal and asks for the highest.
    static func effort(_ value: String) -> String {
        switch value {
        case "max": "xhigh"
        default: value
        }
    }

    /// Translates a Chat Completions request. The first system message becomes `instructions`, unchanged, so the
    /// prefix the server caches starts with the same bytes on every request of a chat; a later one becomes a developer
    /// message. `reasoning` and the encrypted-reasoning `include` go only to a model that takes effort. Tools go in the
    /// `strata` namespace (the ChatGPT route), or flat for the standard Responses API (`namespacedTools: false`).
    init(_ request: ChatRequest, reasoning supportsReasoning: Bool, namespacedTools: Bool = true) {
        model = request.model
        var messages = request.messages[...]
        if let first = messages.first, first.role == "system", case .text(let text) = first.content {
            instructions = text
            messages = messages.dropFirst()
        }
        input = Self.items(Array(messages))
        if let defs = request.tools, !defs.isEmpty {
            let functions = defs.map {
                NamespaceTool.Function(name: $0.function.name, description: $0.function.description, parameters: $0.function.parameters)
            }
            tools = namespacedTools ? [.namespace(NamespaceTool(tools: functions))] : functions.map(Tool.function)
            toolChoice = request.toolChoice
        }
        self.namespacedTools = namespacedTools
        if supportsReasoning {
            reasoning = Reasoning(effort: request.reasoningEffort.map(Self.effort))
            include = ["reasoning.encrypted_content"]
        }
    }

    static func items(_ messages: [APIMessage]) -> [InputItem] {
        var out: [InputItem] = []
        for m in messages {
            switch m.role {
            case "system", "developer":
                out.append(.message(role: "developer", content: [.inputText(m.content.plainText)]))
            case "user":
                switch m.content {
                case .text(let t): out.append(.message(role: "user", content: [.inputText(t)]))
                case .parts(let parts):
                    out.append(.message(role: "user", content: parts.map {
                        switch $0 {
                        case .text(let t): .inputText(t)
                        case .imageURL(let url): .inputImage(url)
                        }
                    }))
                }
            case "assistant":
                // Reasoning first, then the text, then the calls: the order the response produced them in.
                out.append(contentsOf: m.reasoningItems.map(InputItem.reasoning))
                let text = m.content.plainText
                if !text.isEmpty || m.toolCalls.isEmpty {
                    out.append(.message(role: "assistant", content: [.outputText(text)]))
                }
                out.append(contentsOf: m.toolCalls.map { .functionCall(callID: $0.id, name: $0.name, arguments: $0.arguments) })
            case "tool":
                if let id = m.toolCallID, !id.isEmpty {
                    out.append(.functionCallOutput(callID: id, output: m.content.plainText))
                } else {
                    // A result with no call id (imported history) would make the API reject every later request.
                    out.append(.message(role: "user", content: [.inputText("[Tool result]\n" + m.content.plainText)]))
                }
            default:
                break
            }
        }
        return out
    }

    func encoded() throws -> Data {
        if namespacedTools { return try ChatRequest.encoder.encode(self) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = ChatRequest.encoder.outputFormatting
        encoder.userInfo[Self.flatToolsKey] = true
        return try encoder.encode(self)
    }
}

extension APIContent {
    /// The text of the content (parts joined; images dropped).
    var plainText: String {
        switch self {
        case .text(let t): t
        case .parts(let parts): parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
        }
    }
}

// MARK: - Stream events

/// Turns Responses stream events into `ChatDelta`s. Stateful: function calls are numbered in the order they appear
/// (their output index), and reasoning summary parts are separated by a blank line.
struct ResponsesEventDecoder: Sendable {
    /// Event types only, never their content: `log stream --level debug --predicate 'category == "responses"'`.
    static let log = Logger(subsystem: "cc.coolservices.strata", category: "responses")
    private var callIndex: [Int: Int] = [:]   // output_index → tool call index
    private var callsWithArguments: Set<Int> = []
    private var announcedCalls: Set<Int> = []
    private var reasoningWritten = false
    private var lastSummaryKey: String?
    private var summarizedItems: Set<String> = []   // reasoning items whose summary streamed
    private(set) var finished = false
    private(set) var sawToolCall = false

    init() {}

    private struct Event: Decodable {
        struct Item: Decodable {
            struct Summary: Decodable { var text: String? }
            var type: String?
            var id: String?
            var callID: String?
            var name: String?
            var arguments: String?
            var summary: [Summary]?
            var encryptedContent: String?
            enum CodingKeys: String, CodingKey {
                case type, id, name, arguments, summary
                case callID = "call_id", encryptedContent = "encrypted_content"
            }
        }
        struct Body: Decodable {
            struct Details: Decodable { var reason: String? }
            var usage: ResponsesUsage?
            var error: ResponsesErrorBody?
            var incompleteDetails: Details?
            enum CodingKeys: String, CodingKey { case usage, error, incompleteDetails = "incomplete_details" }
        }
        var type: String
        var delta: String?
        var outputIndex: Int?
        var itemID: String?
        var summaryIndex: Int?
        var item: Item?
        var response: Body?
        var code: String?
        var message: String?
        var param: String?
        var error: ResponsesErrorBody?
        enum CodingKeys: String, CodingKey {
            case type, delta, item, response, code, message, param, error
            case outputIndex = "output_index", itemID = "item_id", summaryIndex = "summary_index"
        }
    }

    /// Decodes one SSE `data:` payload. Throws `APIError` for `response.failed` and `error` events.
    mutating func decode(_ payload: String) throws -> ChatDelta {
        guard let data = payload.data(using: .utf8), let event = try? JSONDecoder().decode(Event.self, from: data) else {
            return ChatDelta()
        }
        Self.log.debug("event \(event.type ?? "?", privacy: .public) \(event.item?.type ?? "", privacy: .public)")
        var delta = ChatDelta()
        switch event.type {
        case "response.output_text.delta":
            delta.content = event.delta
        case "response.refusal.delta":
            // A refusal is the model's answer too: shown as text rather than an empty reply.
            delta.content = event.delta
        case "response.reasoning_summary_part.added":
            // A new summary paragraph (also the first of a later reasoning item) starts after a blank line.
            let key = "\(event.itemID ?? "")#\(event.summaryIndex ?? 0)"
            if reasoningWritten && key != lastSummaryKey { delta.reasoning = "\n\n" }
            lastSummaryKey = key
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            if let d = event.delta, !d.isEmpty {
                reasoningWritten = true
                summarizedItems.insert(event.itemID ?? "")
                delta.reasoning = d
            }
        case "response.output_item.added":
            if let item = event.item, item.type == "function_call" {
                let index = toolIndex(event.outputIndex)
                sawToolCall = true
                announcedCalls.insert(index)
                let args = item.arguments ?? ""
                if !args.isEmpty { callsWithArguments.insert(index) }
                delta.toolCalls = [ToolCallDelta(index: index, id: item.callID, name: Self.stripNamespace(item.name ?? ""),
                                                 arguments: args.isEmpty ? nil : args)]
            }
        case "response.function_call_arguments.delta":
            if let d = event.delta, !d.isEmpty {
                let index = toolIndex(event.outputIndex)
                callsWithArguments.insert(index)
                delta.toolCalls = [ToolCallDelta(index: index, arguments: d)]
            }
        case "response.output_item.done":
            guard let item = event.item else { break }
            if item.type == "reasoning" {
                let summary = (item.summary ?? []).compactMap(\.text).filter { !$0.isEmpty }
                delta.reasoningItems = [ReasoningItem(summary: summary, encryptedContent: item.encryptedContent)]
                // A summary that only arrives whole, on the finished item, is shown then.
                if !summary.isEmpty && !summarizedItems.contains(item.id ?? "") {
                    delta.reasoning = (reasoningWritten ? "\n\n" : "") + summary.joined(separator: "\n\n")
                    reasoningWritten = true
                }
            } else if item.type == "function_call" {
                let index = toolIndex(event.outputIndex)
                sawToolCall = true
                // Whatever the earlier events did not carry: the whole call when it was never announced, else the
                // arguments when none streamed.
                let name = announcedCalls.contains(index) ? nil : Self.stripNamespace(item.name ?? "")
                let args = callsWithArguments.contains(index) ? nil : item.arguments.flatMap { $0.isEmpty ? nil : $0 }
                announcedCalls.insert(index)
                if args != nil { callsWithArguments.insert(index) }
                if name != nil || args != nil {
                    delta.toolCalls = [ToolCallDelta(index: index, id: item.callID, name: name, arguments: args)]
                }
            }
        case "response.completed":
            finished = true
            delta.usage = event.response?.usage?.usage
            delta.finishReason = sawToolCall ? "tool_calls" : "stop"
        case "response.incomplete":
            // Partial output is kept, like a Chat Completions answer that hit its limit.
            finished = true
            delta.usage = event.response?.usage?.usage
            let reason = event.response?.incompleteDetails?.reason
            delta.finishReason = reason == "content_filter" ? "content_filter" : "length"
        case "response.failed":
            throw ResponsesErrorMapper.error(event.response?.error ?? ResponsesErrorBody(), status: nil)
        case "error":
            throw ResponsesErrorMapper.error(event.error ?? ResponsesErrorBody(code: event.code, message: event.message,
                                                                             param: event.param), status: nil)
        default:
            break
        }
        return delta
    }

    private mutating func toolIndex(_ outputIndex: Int?) -> Int {
        let key = outputIndex ?? -1
        if let i = callIndex[key] { return i }
        let i = callIndex.count
        callIndex[key] = i
        return i
    }

    /// A call name may come back qualified with the namespace; the app's tools are looked up by their own name.
    static func stripNamespace(_ name: String) -> String {
        for separator in [".", "__", ":"] where name.hasPrefix(ResponsesRequest.toolNamespace + separator) {
            return String(name.dropFirst(ResponsesRequest.toolNamespace.count + separator.count))
        }
        return name
    }
}

/// `response.usage`.
struct ResponsesUsage: Decodable, Sendable {
    struct InputDetails: Decodable, Sendable { var cachedTokens: Int?
        enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" } }
    struct OutputDetails: Decodable, Sendable { var reasoningTokens: Int?
        enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" } }
    var inputTokens: Int?
    var outputTokens: Int?
    var inputTokensDetails: InputDetails?
    var outputTokensDetails: OutputDetails?
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens", outputTokens = "output_tokens"
        case inputTokensDetails = "input_tokens_details", outputTokensDetails = "output_tokens_details"
    }

    var usage: Usage {
        Usage(promptTokens: inputTokens ?? 0, completionTokens: outputTokens ?? 0,
              cachedTokens: inputTokensDetails?.cachedTokens, reasoningTokens: outputTokensDetails?.reasoningTokens)
    }
}

// MARK: - Errors

struct ResponsesErrorBody: Decodable, Sendable, Equatable {
    var code: String?
    var message: String?
    var param: String?
}

/// Maps the route's errors to messages the chat shows, keeping the code (and the server's text for unknown codes, so
/// a context-length error is still recognized by compaction).
enum ResponsesErrorMapper {
    static func error(_ body: ResponsesErrorBody, status: Int?) -> APIError {
        let code = body.code ?? ""
        let known: String? = switch code {
        case "subscription_sharing_usage_limit_exceeded":
            String(localized: "You've reached a ChatGPT usage limit for Strata. Check your plan usage and app limits at chatgpt.com/settings/usage.")
        case "subscription_sharing_user_not_eligible":
            String(localized: "Using your ChatGPT plan isn't available for this account or workspace.")
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            String(localized: "ChatGPT usage couldn't be checked right now. Try again shortly.")
        case "subscription_sharing_unsupported_capability":
            String(localized: "ChatGPT doesn't support part of this request (\(body.param ?? "unknown")).")
        case "subscription_sharing_route_not_supported":
            String(localized: "ChatGPT doesn't accept this kind of request.")
        case "subscription_sharing_invalid_user", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            String(localized: "ChatGPT didn't accept this account's permission to use the plan. Sign in again in Settings.")
        case "model_not_found":
            String(localized: "This model isn't available for your ChatGPT account. Choose another model.")
        default: nil
        }
        let message = known ?? [body.message, code.isEmpty ? nil : "(\(code))"].compactMap { $0 }.joined(separator: " ")
        if let status { return .http(status: status, message: message) }
        return .server(message.isEmpty ? String(localized: "ChatGPT reported an error.") : message)
    }

    /// An error body before the stream opens: a Responses `error` object, or `{"detail": "..."}` from admission.
    static func error(status: Int, data: Data) -> APIError {
        struct Wrapper: Decodable { var error: ResponsesErrorBody?; var detail: String? }
        let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data)
        if let body = wrapper?.error, body.code != nil || body.message != nil { return error(body, status: status) }
        let detail = wrapper?.detail ?? HTTP.errorMessage(from: data)
        let message: String = switch status {
        case 401: String(localized: "ChatGPT didn't accept the sign-in. Sign in again in Settings.")
        case 403: String(localized: "ChatGPT refused the request: \(detail)")
        case 429: String(localized: "You've reached a ChatGPT usage limit for Strata. Check your plan usage and app limits at chatgpt.com/settings/usage.")
        case 503: String(localized: "ChatGPT is temporarily unavailable. Try again shortly.")
        default: detail
        }
        return .http(status: status, message: message)
    }
}
