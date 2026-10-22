import Foundation

protocol ChatStreaming: Sendable {
    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error>
}

enum HTTP {
    static func makeRequest(url: URL, endpoint: Endpoint, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in endpoint.headers { req.setValue(v, forHTTPHeaderField: k) }
        if let key = endpoint.apiKey, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return req
    }

    static func errorMessage(from data: Data) -> String {
        struct Wrapper: Decodable {
            struct E: Decodable { var message: String? }
            var error: E?
            var message: String?
            var detail: String?
        }
        if let w = try? JSONDecoder().decode(Wrapper.self, from: data) {
            if let m = w.error?.message ?? w.message ?? w.detail { return m }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

struct ChatClient: ChatStreaming {
    var session: URLSession = .shared
    /// Tokens for ChatGPT connections, whose requests go to the Responses API instead.
    var chatGPTTokens: any ChatGPTTokenProviding = ChatGPTAuth.shared
    /// Tokens for OpenCode connections, whose requests go to the API family of each model.
    var openCodeTokens: any OpenCodeTokenProviding = OpenCodeAuth.shared

    /// Chat Completions (or the Responses API for a model that needs it, see `ResponsesFallback`), or for a ChatGPT
    /// connection the ChatGPT Responses route, or for an OpenCode connection the model's API.
    /// Routing here means every request that goes through the app's streamer (turns, compaction, titles) reaches the
    /// right API.
    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        if endpoint.kind == .chatGPT {
            return ResponsesClient(session: session, tokens: chatGPTTokens).stream(request, endpoint: endpoint)
        }
        if endpoint.kind == .openCode {
            return OpenCodeClient(session: session, tokens: openCodeTokens).stream(request, endpoint: endpoint)
        }
        if endpoint.kind == .appleOnDevice { return OnDeviceClient().stream(request, endpoint: endpoint) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if endpoint.chatAPI == .responses {
                        try await StandardResponses.run(request, endpoint: endpoint, session: session, into: continuation)
                        continuation.finish()
                        return
                    }
                    let body = try request.encoded()
                    var req = HTTP.makeRequest(url: endpoint.baseURL.appendingPathComponent("chat/completions"),
                                               endpoint: endpoint, method: "POST", body: body)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 300
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var errorData = Data()
                        for try await b in bytes { errorData.append(b); if errorData.count > 4096 { break } }
                        let refused = APIError.http(status: http.statusCode, message: HTTP.errorMessage(from: errorData))
                        // Refused before any of the answer: a model that only answers the Responses API gets one try there.
                        guard let route = endpoint.apiRoute, route.automatic,
                              ResponsesFallback.shouldSwitch(status: http.statusCode, body: errorData) else { throw refused }
                        try await StandardResponses.run(request, endpoint: endpoint, session: session, into: continuation,
                                                        fallbackError: refused) { route.detected(.responses) }
                        continuation.finish()
                        return
                    }
                    try await Self.consume(bytes) { continuation.yield($0) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let cutOffMessage = "The connection closed before the reply finished."

    /// Reads a Chat Completions event stream through `[DONE]`, handing on each non-empty delta. A stream that ends
    /// without `[DONE]` counts as finished only if a choice said why it stopped (`finish_reason`; some servers never
    /// send `[DONE]`). Otherwise the connection dropped mid-answer, and a cut-off answer or half-built tool call must
    /// not be saved as complete.
    static func consume<Bytes: AsyncSequence>(_ bytes: Bytes, yield: (ChatDelta) -> Void) async throws where Bytes.Element == UInt8 {
        var parser = SSEParser()
        var line = Data()
        var finished = false
        func handle(_ events: [SSEEvent]) throws -> Bool {
            for event in events {
                let delta = try ChatChunkDecoder.decode(event.data)
                if delta.isDone { return true }
                if delta.finishReason != nil { finished = true }
                if !delta.isEmpty { yield(delta) }
            }
            return false
        }
        for try await byte in bytes {
            line.append(byte)
            if byte == 0x0A || byte == 0x0D { // SSE lines may end in CR alone; the parser joins CRLF across feeds
                let done = try handle(parser.feed(line))
                line.removeAll(keepingCapacity: true)
                if done { return }
            }
        }
        if !line.isEmpty, try handle(parser.feed(line)) { return }
        if try handle(parser.finish()) { return }
        if !finished { throw APIError.transport(cutOffMessage) }
    }
}

/// `GET /models`.
enum ModelsAPI {
    struct Entry: Sendable, Equatable {
        var id: String
        var contextLength: Int?
        var maxOutputTokens: Int?
        /// Whether the model reads images, when the server says (see `imageSupport`); nil when it does not.
        var supportsImages: Bool?
        /// Whether the model takes `reasoning_effort`, when the server says (see `effortSupport`); nil when it does not.
        var supportsEffort: Bool?
    }

    /// Whether a `/models` entry says the model reads images. First that answers wins:
    /// 1. A boolean `supports_vision` / `supports_images` / `supports_image_input` / `vision` (LiteLLM and similar).
    /// 2. `capabilities`: an object with one of those keys or `image_input` / `images`, or a list of names that
    ///    includes `vision` / `image` / `image_input` / `images` (a list counts as complete: no such name means no).
    /// 3. `architecture.input_modalities: ["text","image"]` (OpenRouter, OpenAI style), or
    ///    `architecture.modality: "text+image->text"` (only the input side counts).
    /// Anything else (unknown shapes, wrong types) is nil: the connection's default applies.
    static func imageSupport(in item: [String: Any]) -> Bool? {
        let flags = ["supports_vision", "supports_images", "supports_image_input", "vision"]
        if let flag = firstBool(item, flags) { return flag }
        if let caps = item["capabilities"] as? [String: Any], let flag = firstBool(caps, flags + ["image_input", "images", "image"]) {
            return flag
        }
        if let caps = capabilityNames(item) { return !caps.isDisjoint(with: ["vision", "image", "images", "image_input"]) }
        guard let arch = item["architecture"] as? [String: Any] else { return nil }
        if let inputs = arch["input_modalities"] as? [String] {
            return inputs.contains { $0.lowercased() == "image" }
        }
        if let modality = arch["modality"] as? String {
            let input = modality.components(separatedBy: "->").first ?? modality
            return input.lowercased().contains("image")
        }
        return nil
    }

    /// Whether a `/models` entry says the model takes `reasoning_effort`. First that answers wins:
    /// 1. A boolean `supports_reasoning_effort` / `supports_reasoning` / `reasoning` (LiteLLM and similar).
    /// 2. `capabilities`: an object with `reasoning_effort` / `reasoning` / `thinking`, or a list of names (a list
    ///    counts as complete: none of `reasoning_effort`, `reasoning`, `thinking` means no).
    /// 3. OpenRouter's `supported_parameters`: `reasoning` or `reasoning_effort` listed means yes, else no.
    /// Anything else is nil: the connection's default applies.
    static func effortSupport(in item: [String: Any]) -> Bool? {
        let flags = ["supports_reasoning_effort", "supports_reasoning", "reasoning"]
        if let flag = firstBool(item, flags) { return flag }
        if let caps = item["capabilities"] as? [String: Any],
           let flag = firstBool(caps, ["supports_reasoning_effort", "reasoning_effort", "supports_reasoning", "reasoning", "thinking"]) {
            return flag
        }
        if let caps = capabilityNames(item) { return !caps.isDisjoint(with: ["reasoning_effort", "reasoning", "thinking"]) }
        if let params = item["supported_parameters"] as? [String] {
            return params.contains { ["reasoning", "reasoning_effort"].contains($0.lowercased()) }
        }
        return nil
    }

    /// The first of `keys` that holds a boolean (or a 0/1 number).
    private static func firstBool(_ dict: [String: Any], _ keys: [String]) -> Bool? {
        for key in keys {
            if let flag = dict[key] as? Bool { return flag }
        }
        return nil
    }

    /// `capabilities` given as a list of names (Ollama style: `["completion", "vision", "tools", "thinking"]`), lowercased.
    private static func capabilityNames(_ item: [String: Any]) -> Set<String>? {
        guard let list = item["capabilities"] as? [String] else { return nil }
        return Set(list.map { $0.lowercased() })
    }

    static func parse(_ data: Data) throws -> [Entry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            throw APIError.server(String(localized: "Unexpected response from /models."))
        }
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let keys = ["context_length", "max_model_len", "context_window", "max_context_length"]
            var ctx: Int?
            for k in keys {
                if let n = item[k] as? Int { ctx = n; break }
                if let d = item[k] as? Double { ctx = Int(exactly: d.rounded(.down)).flatMap { $0 > 0 && $0 <= ContextLimits.maxTokens ? $0 : nil }; break }
            }
            if ctx == nil, let meta = item["meta"] as? [String: Any], let n = meta["n_ctx_train"] as? Int { ctx = n }
            var maxOut: Int?
            for k in ["max_output_tokens", "max_completion_tokens", "max_tokens"] {
                if let n = item[k] as? Int, n > 0 { maxOut = n; break }
            }
            if maxOut == nil, let top = item["top_provider"] as? [String: Any], let n = top["max_completion_tokens"] as? Int, n > 0 { maxOut = n }
            return Entry(id: id, contextLength: ctx, maxOutputTokens: maxOut, supportsImages: imageSupport(in: item),
                         supportsEffort: effortSupport(in: item))
        }
    }

    static func fetch(endpoint: Endpoint, session: URLSession = .shared) async throws -> [Entry] {
        var req = HTTP.makeRequest(url: endpoint.baseURL.appendingPathComponent("models"), endpoint: endpoint)
        req.timeoutInterval = 20
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(status: http.statusCode, message: HTTP.errorMessage(from: data))
        }
        return try parse(data)
    }
}

/// Balance lookup, for a gateway that offers one (none does yet).
struct BalanceInfo: Sendable, Equatable {
    var balanceUSD: Double?
    var chatCostUSD: Double?
    var todaySpendUSD: Double?
}

protocol BalanceProviding: Sendable {
    /// Throws `BalanceError.notAvailable` when the connection has no balance endpoint.
    func balance(for connection: Connection, apiKey: String?) async throws -> BalanceInfo
}

enum BalanceError: Error { case notAvailable }

/// No connection has a balance endpoint yet.
struct UnavailableBalanceProvider: BalanceProviding {
    func balance(for connection: Connection, apiKey: String?) async throws -> BalanceInfo {
        throw BalanceError.notAvailable
    }
}
