import Foundation

/// Streams a turn from the Anthropic Messages API (`POST /v1/messages`) with the connection's API key: the engine's Chat
/// Completions request translated by `MessagesRequest`, with the model's thinking and effort (`AnthropicModels.controls`)
/// and prompt-cache breakpoints, and the Messages events translated back (`MessagesEventDecoder`). Not resumable: the API
/// can't replay a stream, so a dropped connection is an error the user retries.
struct AnthropicClient: ChatStreaming {
    /// The API version every request names.
    static let version = "2023-06-01"

    var session: URLSession = .shared

    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = endpoint.apiKey, !key.isEmpty else {
                        throw APIError.missingAPIKey(connection: endpoint.connectionName)
                    }
                    var body = Self.body(request, model: endpoint.model)
                    var retries = Set<Retry>()
                    while true {
                        var req = Self.request(url: endpoint.requestURL, endpoint: endpoint, key: key)
                        req.httpBody = try body.encoded()
                        let (bytes, response) = try await session.bytes(for: req)
                        let http = response as? HTTPURLResponse
                        let status = http?.statusCode ?? 0
                        if (200..<300).contains(status) {
                            try await MessagesEventDecoder.consume(
                                bytes, incomplete: String(localized: "The Anthropic response ended before it was complete. Try again."),
                                into: continuation)
                            break
                        }
                        var data = Data()
                        for try await b in bytes { data.append(b); if data.count > 8192 { break } }
                        // Refused for what it sent back or asked for, not for what the user wrote: once more without it.
                        if status == 400, let retry = Retry.after(data, body: body), retries.insert(retry).inserted {
                            body = retry.apply(to: body)
                            continue
                        }
                        throw AnthropicErrorMapper.error(status: status, data: data, retryAfter: http?.value(forHTTPHeaderField: "retry-after"),
                                                         connection: endpoint.connectionName)
                    }
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

    // MARK: Requests

    /// The body for `model`: its output cap as `max_tokens` (the API requires one), the chat's level as its thinking and
    /// effort, and cache breakpoints.
    static func body(_ request: ChatRequest, model: ModelInfo) -> MessagesRequest {
        let maxTokens = request.maxTokens ?? model.maxOutputTokens ?? AnthropicModels.family(of: model.id)?.maxOutputTokens
            ?? MessagesRequest.defaultMaxTokens
        let controls = AnthropicModels.controls(for: model, requested: request.reasoningEffort, maxTokens: maxTokens)
        var request = request
        request.maxTokens = maxTokens
        return MessagesRequest(request, effort: controls.effort, maxOutputTokens: maxTokens,
                               options: .init(thinking: controls.thinking, caching: true))
    }

    /// A request with the key and version headers, after the connection's own headers (which can't replace them).
    /// The key never goes anywhere else: not in the URL, not in logs.
    static func request(url: URL, endpoint: Endpoint, key: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        for (k, v) in endpoint.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(version, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(url.lastPathComponent == "messages" ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// A 400 that one change to the request can get past, each tried at most once per request.
    enum Retry: Hashable {
        /// The thinking blocks sent back were refused (their signature no longer matches the history before them, as
        /// after an edit, a compaction or a model switch): the API's documented way out is to leave them all out.
        case stripThinking
        /// The model refused the `thinking` configuration (a proxy or a model the app's table gets wrong).
        case dropThinking
        /// The model refused `output_config.effort`.
        case dropEffort

        static func after(_ data: Data, body: MessagesRequest) -> Retry? {
            let message = AnthropicErrorMapper.parse(data).message?.lowercased() ?? ""
            if body.hasThinkingBlocks, message.contains("signature") || message.contains("thinking` block")
                || message.contains("thinking block") || message.contains("cannot be modified") {
                return .stripThinking
            }
            if body.thinking != nil, message.contains("thinking") { return .dropThinking }
            if body.outputConfig != nil, message.contains("effort") { return .dropEffort }
            return nil
        }

        func apply(to body: MessagesRequest) -> MessagesRequest {
            switch self {
            case .stripThinking: return body.strippingThinking()
            case .dropThinking:
                var copy = body
                copy.thinking = nil
                return copy
            case .dropEffort:
                var copy = body
                copy.outputConfig = nil
                return copy
            }
        }
    }
}

// MARK: - Errors

/// Anthropic's errors (`{"type": "error", "error": {"type": "rate_limit_error", "message": …}, "request_id": …}`) as
/// messages the chat shows. A 400's own text is kept, so compaction still recognizes "prompt is too long".
enum AnthropicErrorMapper {
    static func error(status: Int, data: Data, retryAfter: String?, connection: String) -> APIError {
        let (type, serverMessage) = parse(data)
        let text = (serverMessage ?? "").lowercased()
        let message: String
        if status == 401 || type == "authentication_error" {
            return .rejectedAPIKey(connection: connection)
        } else if status == 402 || type == "billing_error" || text.contains("credit balance") {
            message = String(localized: "Your Anthropic credit balance is too low. Add credits or billing details in the Anthropic Console.")
        } else if status == 403 || type == "permission_error" {
            message = String(localized: "This API key isn't allowed to do that (\(serverMessage ?? "permission denied")). Check the key's workspace in the Anthropic Console.")
        } else if status == 429 || type == "rate_limit_error" {
            if let seconds = retryAfter.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }).map({ Int($0.rounded(.up)) }), seconds > 0 {
                message = String(localized: "You've hit Anthropic's rate limit for this API key. Try again in \(seconds) seconds.")
            } else {
                message = String(localized: "You've hit Anthropic's rate limit for this API key. Wait a moment and try again.")
            }
        } else if status == 529 || type == "overloaded_error" {
            message = String(localized: "Anthropic's servers are overloaded right now. Try again in a moment.")
        } else if status == 413 || type == "request_too_large" {
            message = String(localized: "The request is too large for the Anthropic API. Remove some images, or start a new chat.")
                + (serverMessage.map { " (\($0))" } ?? "")
        } else if status == 404 || type == "not_found_error" {
            message = serverMessage.map { String(localized: "Anthropic doesn't know this model or address: \($0)") }
                ?? String(localized: "Anthropic doesn't know this model or address. Fetch the models again, or check the base URL.")
        } else if status >= 500 || type == "api_error" {
            message = String(localized: "Anthropic had a problem on its side. Try again.") + (serverMessage.map { " (\($0))" } ?? "")
        } else {
            message = serverMessage ?? HTTP.errorMessage(from: data)
        }
        return .http(status: status, message: message)
    }

    /// The error's `type` and `message`.
    static func parse(_ data: Data) -> (type: String?, message: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return (nil, nil) }
        return (error["type"] as? String, error["message"] as? String)
    }
}
