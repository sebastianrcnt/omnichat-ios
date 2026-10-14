import Foundation

/// Streams a turn from the Responses API with a ChatGPT account's OAuth token (see `ResponsesAPI.swift`). A 401 before
/// the stream opens refreshes the token and retries once.
struct ResponsesClient: ChatStreaming {
    var session: URLSession = .shared
    var tokens: any ChatGPTTokenProviding = ChatGPTAuth.shared

    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let translated = ResponsesRequest(request, reasoning: endpoint.model.supportsEffort)
                    ResponsesEventDecoder.log.debug("""
                        request model=\(translated.model, privacy: .public) \
                        effort=\(translated.reasoning?.effort ?? "-", privacy: .public) \
                        summary=\(translated.reasoning?.summary ?? "-", privacy: .public)
                        """)
                    let body = try translated.encoded()
                    var token = try await tokens.accessToken(connectionID: endpoint.connectionID)
                    var retried = false
                    while true {
                        let req = Self.urlRequest(endpoint: endpoint, token: token, body: body)
                        let (bytes, response) = try await session.bytes(for: req)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if (200..<300).contains(status) {
                            try await Self.consume(bytes, into: continuation)
                            break
                        }
                        var errorData = Data()
                        for try await b in bytes { errorData.append(b); if errorData.count > 8192 { break } }
                        if status == 401 && !retried {
                            retried = true
                            token = try await tokens.tokenAfterRejection(connectionID: endpoint.connectionID, rejected: token)
                            continue
                        }
                        throw ResponsesErrorMapper.error(status: status, data: errorData)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as ChatGPTAuthError {
                    continuation.finish(throwing: error == .signInRequired || error == .sessionExpired
                                        ? APIError.chatGPTSignInRequired(connection: endpoint.connectionName) : error)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func urlRequest(endpoint: Endpoint, token: String, body: Data) -> URLRequest {
        var req = URLRequest(url: endpoint.baseURL.appendingPathComponent("responses"))
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 300
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return req
    }

    /// Reads the event stream through its terminal event. A stream that ends without `response.completed` (or
    /// `response.incomplete`) is an interrupted answer, not a finished one.
    static func consume(_ bytes: URLSession.AsyncBytes,
                        into continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation) async throws {
        var parser = SSEParser()
        var decoder = ResponsesEventDecoder()
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
            if byte == 0x0A {
                try handle(parser.feed(line))
                line.removeAll(keepingCapacity: true)
                if decoder.finished { return }
            }
        }
        if !line.isEmpty { try handle(parser.feed(line)) }
        try handle(parser.finish())
        if !decoder.finished {
            throw APIError.transport(String(localized: "The ChatGPT response ended before it was complete. Try again."))
        }
    }
}
