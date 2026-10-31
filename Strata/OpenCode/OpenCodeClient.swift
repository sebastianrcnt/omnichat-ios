import Foundation

/// Streams a turn from an OpenCode gateway with the connection's token, in the API family of the model: Chat
/// Completions (open models), the Responses API (GPT, Grok, Muse Spark) or the Messages API (Claude, Qwen, MiniMax on
/// Go). A 401 before the stream opens refreshes the session and retries once.
struct OpenCodeClient: ChatStreaming {
    var session: URLSession = .shared
    var tokens: any OpenCodeTokenProviding = OpenCodeAuth.shared

    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let api = endpoint.openCodeAPI
                    guard api.isSupported else {
                        throw APIError.server(String(localized: "OmniChat can't talk to \(endpoint.model.id) yet. Choose another model."))
                    }
                    let body = try Self.body(request, endpoint: endpoint)
                    OpenCodeAuth.log.debug("""
                        request model=\(request.model, privacy: .public) api=\(api.rawValue, privacy: .public) \
                        effort=\(Self.effort(request, model: endpoint.model) ?? "-", privacy: .public)
                        """)
                    var token = try await tokens.accessToken(connectionID: endpoint.connectionID)
                    var retried = false
                    while true {
                        let req = Self.urlRequest(endpoint: endpoint, token: token, body: body)
                        let (bytes, response) = try await session.bytes(for: req)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if (200..<300).contains(status) {
                            try await Self.consume(bytes, api: api, model: endpoint.model, into: continuation)
                            break
                        }
                        var errorData = Data()
                        for try await b in bytes { errorData.append(b); if errorData.count > 8192 { break } }
                        OpenCodeAuth.log.debug("request status=\(status, privacy: .public)")
                        if status == 401 && !retried {
                            retried = true
                            token = try await tokens.tokenAfterRejection(connectionID: endpoint.connectionID, rejected: token)
                            continue
                        }
                        throw OpenCodeErrorMapper.error(status: status, data: errorData, gateway: endpoint.openCodeGateway)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as OpenCodeAuthError {
                    switch error {
                    case .signInRequired, .sessionExpired, .invalidAPIKey:
                        continuation.finish(throwing: APIError.openCodeSignInRequired(connection: endpoint.connectionName))
                    default:
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Requests

    /// The effort to send: the requested level as one the model offers (nil when it offers none). The title request's
    /// "none" is its lowest level: the catalog lists levels only.
    static func effort(_ request: ChatRequest, model: ModelInfo) -> String? {
        guard let raw = request.reasoningEffort, let effort = Effort(rawValue: raw) else { return nil }
        let levels = model.effortLevels(.modelDecides)
        return levels.isEmpty ? nil : effort.resolved(in: levels).apiValue
    }

    /// The body in the model's API. Chat Completions keeps the request as the app built it (same bytes as other
    /// connections, so the cached prefix holds) minus vLLM's `chat_template_kwargs`, with the effort the model offers
    /// and, for interleaved-reasoning models, the turn's reasoning on the assistant messages.
    static func body(_ request: ChatRequest, endpoint: Endpoint) throws -> Data {
        var request = request
        request.reasoningEffort = effort(request, model: endpoint.model)
        request.chatTemplateKwargs = nil
        switch endpoint.openCodeAPI {
        case .responses:
            return try ResponsesRequest(request, reasoning: request.reasoningEffort != nil, namespacedTools: false).encoded()
        case .messages:
            return try MessagesRequest(request, effort: request.reasoningEffort,
                                       maxOutputTokens: endpoint.model.maxOutputTokens).encoded()
        case .chatCompletions, .gemini:
            guard endpoint.model.openCode?.interleavedReasoning == true else { return try request.encoded() }
            let encoder = JSONEncoder()
            encoder.outputFormatting = ChatRequest.encoder.outputFormatting
            encoder.userInfo[APIMessage.echoReasoningKey] = true
            return try encoder.encode(request)
        }
    }

    static func urlRequest(endpoint: Endpoint, token: String, body: Data) -> URLRequest {
        var req = URLRequest(url: endpoint.requestURL)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 300
        for (k, v) in endpoint.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if endpoint.openCodeAPI == .messages {
            // The Anthropic-style key header too: the older /zen paths read the key from it for this API.
            req.setValue(token, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return req
    }

    // MARK: Responses

    private static func consume(_ bytes: URLSession.AsyncBytes, api: OpenCodeModelAPI, model: ModelInfo,
                                into continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation) async throws {
        switch api {
        case .responses:
            try await ResponsesClient.consume(bytes, into: continuation,
                                              incomplete: String(localized: "The OpenCode response ended before it was complete. Try again."))
        case .messages:
            try await MessagesEventDecoder.consume(bytes, incomplete: String(localized: "The OpenCode response ended before it was complete. Try again."),
                                                   into: continuation)
        case .chatCompletions, .gemini:
            // An interleaved-reasoning model gets this answer's reasoning back with its tool results: it rides on the
            // assistant message as a reasoning item, like the Responses API's.
            var reasoning = ""
            var calledTools = false
            try await ChatClient.consume(bytes) { delta in
                if let r = delta.reasoning { reasoning += r }
                if !delta.toolCalls.isEmpty { calledTools = true }
                continuation.yield(delta)
            }
            if model.openCode?.interleavedReasoning == true, calledTools, !reasoning.isEmpty {
                continuation.yield(ChatDelta(reasoningItems: [ReasoningItem(summary: [reasoning], encryptedContent: nil)]))
            }
        }
    }
}

// MARK: - Errors

/// Maps gateway errors to messages the chat shows. The gateway's own source isn't public, so this reads the status and
/// the error's `type` and `message` (`{"type": "error", "error": {"type": "FreeTierError", "message": …}}` or
/// `{"error": {"type": "server_error", "message": …}}`), keeping the server's text for anything else (so a
/// context-length error is still recognized by compaction).
enum OpenCodeErrorMapper {
    static func error(status: Int, data: Data, gateway: OpenCodeGateway) -> APIError {
        let (type, serverMessage) = parse(data)
        let text = "\(type ?? "") \(serverMessage ?? "")".lowercased()
        let message: String
        if type == "FreeTierError" {
            message = String(localized: "OpenCode's free models only work in the OpenCode app. Choose a paid model.")
        } else if status == 401 {
            message = String(localized: "OpenCode didn't accept the sign-in. Sign in again in Settings.")
        } else if gateway == .go && (text.contains("subscri") || text.contains("not on go") || text.contains("requires go")) {
            message = String(localized: "This OpenCode account has no Go subscription. Subscribe in the OpenCode Console, or switch this connection to Pay as you go in Settings.")
        } else if status == 429 || text.contains("usage limit") || text.contains("rate limit") || text.contains("ratelimit")
                    || text.contains("quota") || text.contains("limit reached") || text.contains("limit exceeded") {
            message = gateway == .go
                ? String(localized: "You've reached an OpenCode Go usage limit. Limits reset over time; check your usage in the OpenCode Console.")
                : String(localized: "You've reached an OpenCode usage or spending limit. Check your workspace in the OpenCode Console.")
        } else if status == 402 || text.contains("balance") || text.contains("insufficient") || text.contains("billing")
                    || text.contains("payment") {
            message = String(localized: "Your OpenCode workspace has no credit left. Add credit or billing details in the OpenCode Console.")
        } else if status == 403 && gateway == .go {
            message = String(localized: "OpenCode Go refused the request. Check that this workspace has a Go subscription in the OpenCode Console.")
        } else {
            message = serverMessage ?? HTTP.errorMessage(from: data)
        }
        return .http(status: status, message: message)
    }

    private static func parse(_ data: Data) -> (type: String?, message: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        if let error = root["error"] as? [String: Any] {
            return ((error["type"] as? String) ?? (error["code"] as? String), error["message"] as? String)
        }
        return ((root["_tag"] as? String) ?? (root["error"] as? String), root["message"] as? String)
    }
}
