import Foundation
import os

// OpenAI-compatible connections speak Chat Completions, but some models there only answer the Responses API
// (api.openai.com's *-pro, deep-research and codex models; gateways that only implement /responses). A Chat
// Completions request that is refused in a way that clearly means "use the Responses API" is sent once more as a
// standard Responses request (flat tools, `store: false`), and when that one is accepted, the model is remembered as a
// Responses model on its connection, so later requests go there directly. The user can also pick the API per model.

/// The API a model of an OpenAI-compatible connection is talked to with.
enum ChatAPI: String, Codable, Sendable, CaseIterable {
    case chatCompletions
    case responses

    var title: String {
        switch self {
        case .chatCompletions: String(localized: "Chat Completions")
        case .responses: String(localized: "Responses API")
        }
    }

    /// Lenient decoding of a saved `[model id: ChatAPI]` map: unknown values (from a newer version) are dropped instead
    /// of failing the whole connection.
    static func decodeMap<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) -> [String: ChatAPI] {
        guard let raw = try? c.decodeIfPresent([String: String].self, forKey: key) else { return [:] }
        return raw.compactMapValues(ChatAPI.init(rawValue:))
    }
}

/// The API one endpoint's requests use, shared by every request made with copies of that endpoint (all rounds of a
/// turn, its compaction and its title request), so a switch found in the first round holds for the rest.
final class ChatAPIRoute: @unchecked Sendable {
    /// False when the user picked the API: no detection, no switching.
    let automatic: Bool
    private let lock = NSLock()
    private var api: ChatAPI
    private let onDetect: @Sendable (ChatAPI) -> Void

    init(api: ChatAPI = .chatCompletions, automatic: Bool = true, onDetect: @escaping @Sendable (ChatAPI) -> Void = { _ in }) {
        self.api = api
        self.automatic = automatic
        self.onDetect = onDetect
    }

    var current: ChatAPI { lock.withLock { api } }

    /// Records that `newAPI` worked where the current one was refused, and reports it once (to be saved).
    func detected(_ newAPI: ChatAPI) {
        let changed = lock.withLock { () -> Bool in
            guard api != newAPI else { return false }
            api = newAPI
            return true
        }
        if changed { onDetect(newAPI) }
    }
}

/// When a refused Chat Completions request is worth one more try as a Responses request.
///
/// The rule, on the status and the error body (`error.message`, `error.code`, `error.type`, `message`, `detail`, or the
/// raw text), compared lowercased:
/// 1. **The server names the Responses API.** Status 400, 404, 405, 422 or 501, the text mentions it (`/responses`,
///    `responses api`, `responses endpoint`, `responses-only`), and says the request isn't supported or should go there
///    (`only supported`, `not supported`, `unsupported`, `does not support`, `not available`, `instead`, `please use`).
///    OpenAI: 404 "This model is only supported in v1/responses and not in v1/chat/completions."
/// 2. **The server says Chat Completions isn't supported for the request.** Status 400, 404, 405 or 501, the text
///    mentions Chat Completions (`chat/completions`, `chat completions`, `chatcompletion`, `chat_completions`) together
///    with `not supported`, `unsupported`, `does not support`, `only supported` or `does not work` (Azure: "The
///    chatCompletion operation does not work with the specified model"). Not when it says the model isn't a chat
///    model at all ("not a chat model … v1/completions"): that one needs the legacy Completions API.
/// 3. **The endpoint is missing.** Status 404, 405 or 501, the text does not mention a model (a 404 "The model `x`
///    does not exist" must not switch), and it is empty or reads like a missing route: `not found`, `no route`,
///    `cannot post`, `unknown url`, `invalid url`, `unknown endpoint`, `not implemented`,
///    `method not allowed`.
/// 4. **The server says the endpoint isn't supported.** Status 400, 404, 405 or 501 and `unsupported endpoint`,
///    `unsupported_endpoint` or `endpoint not supported` / `endpoint is not supported` (also when it names the model:
///    "unsupported endpoint for this model").
///
/// Never on 401, 403, 429, other 5xx, or anything else (context length, bad parameters, content filters). A false
/// positive costs one extra request: the switch is only remembered when the Responses request is accepted, and when
/// that one is refused as missing too (404/405/501) the original Chat Completions error is what the chat shows.
enum ResponsesFallback {
    static func shouldSwitch(status: Int, body: Data) -> Bool {
        let text = errorText(body)
        func any(_ needles: [String]) -> Bool { needles.contains { text.contains($0) } }
        let refusal = ["only supported", "not supported", "unsupported", "does not support", "doesn't support",
                       "not available", "instead", "please use", "does not work"]
        let namesResponses = any(["/responses", "responses api", "responses endpoint", "responses-only", "responses only"])
        if [400, 404, 405, 422, 501].contains(status), namesResponses, any(refusal) { return true }
        let namesChat = any(["chat/completions", "chat completions", "chatcompletion", "chat_completions", "chat.completions"])
        if [400, 404, 405, 501].contains(status), namesChat, any(refusal),
           !(text.contains("not a chat model") || text.contains("v1/completions?")) {
            return true
        }
        if [400, 404, 405, 501].contains(status),
           any(["unsupported endpoint", "unsupported_endpoint", "endpoint not supported", "endpoint is not supported"]) {
            return true
        }
        if [404, 405, 501].contains(status), !text.contains("model") {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return true }
            return any(["not found", "no route", "cannot post", "unknown url", "unknown_url", "invalid url",
                        "unknown endpoint", "not implemented", "method not allowed"])
        }
        return false
    }

    /// Everything the body says about the error, lowercased.
    static func errorText(_ data: Data) -> String {
        var parts: [String] = []
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = root["error"] as? [String: Any] {
                for key in ["message", "code", "type"] { if let s = error[key] as? String { parts.append(s) } }
            } else if let s = root["error"] as? String {
                parts.append(s)
            }
            for key in ["message", "detail"] { if let s = root[key] as? String { parts.append(s) } }
        } else {
            parts.append(String(decoding: data.prefix(2048), as: UTF8.self))
        }
        return parts.joined(separator: " ").lowercased()
    }
}

/// The standard Responses API (`POST {base}/responses`) for an OpenAI-compatible connection: the connection's key and
/// headers, flat function tools, `store: false` with the whole history in `input`. Not resumable.
enum StandardResponses {
    static let log = Logger(subsystem: "cc.coolservices.strata", category: "responses")

    /// The request body. Like the ChatGPT route, the chat's first system message becomes `instructions` and the tools
    /// keep their order, so the prefix stays the same across a chat's requests. Effort (and with it the reasoning
    /// summary and encrypted reasoning) goes only when the request carries one; reasoning items without encrypted
    /// content are left out of the history, since with `store: false` they refer to nothing the server could use.
    static func body(_ request: ChatRequest) throws -> Data {
        var translated = ResponsesRequest(request, reasoning: request.reasoningEffort != nil, namespacedTools: false)
        translated.input.removeAll { if case .reasoning(let item) = $0 { item.encryptedContent == nil } else { false } }
        translated.maxOutputTokens = request.maxTokens
        return try translated.encoded()
    }

    static func urlRequest(endpoint: Endpoint, body: Data) -> URLRequest {
        var req = HTTP.makeRequest(url: endpoint.baseURL.appendingPathComponent("responses"), endpoint: endpoint,
                                   method: "POST", body: body)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 300
        return req
    }

    /// Sends the request and streams the answer into `continuation`. `onAccepted` runs once the server accepted it
    /// (2xx), before any of the answer. With `fallbackError` (this is the retry of a refused Chat Completions
    /// request), a Responses endpoint that is missing too throws that original error instead.
    static func run(_ request: ChatRequest, endpoint: Endpoint, session: URLSession,
                    into continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation,
                    fallbackError: APIError? = nil, onAccepted: () -> Void = {}) async throws {
        let body = try body(request)
        log.debug("standard request model=\(request.model, privacy: .public) fallback=\(fallbackError != nil, privacy: .public)")
        let (bytes, response) = try await session.bytes(for: urlRequest(endpoint: endpoint, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var errorData = Data()
            for try await b in bytes { errorData.append(b); if errorData.count > 4096 { break } }
            if let fallbackError, [404, 405, 501].contains(status) { throw fallbackError }
            throw APIError.http(status: status, message: HTTP.errorMessage(from: errorData))
        }
        onAccepted()
        try await ResponsesClient.consume(bytes, into: continuation,
                                          incomplete: String(localized: "The response ended before it was complete. Try again."))
    }
}
