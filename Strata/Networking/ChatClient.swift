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

    /// Chat Completions, or for a ChatGPT connection the Responses API. Routing here means every request that goes
    /// through the app's streamer (turns, compaction, titles) reaches the right API.
    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        if endpoint.kind == .chatGPT {
            return ResponsesClient(session: session, tokens: chatGPTTokens).stream(request, endpoint: endpoint)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try request.encoded()
                    var req = HTTP.makeRequest(url: endpoint.baseURL.appendingPathComponent("chat/completions"),
                                               endpoint: endpoint, method: "POST", body: body)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 300
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var errorData = Data()
                        for try await b in bytes { errorData.append(b); if errorData.count > 4096 { break } }
                        throw APIError.http(status: http.statusCode, message: HTTP.errorMessage(from: errorData))
                    }
                    var parser = SSEParser()
                    var line = Data()
                    func handle(_ events: [SSEEvent]) throws -> Bool {
                        for event in events {
                            let delta = try ChatChunkDecoder.decode(event.data)
                            if delta.isDone { return true }
                            if !delta.isEmpty { continuation.yield(delta) }
                        }
                        return false
                    }
                    var done = false
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == 0x0A {
                            done = try handle(parser.feed(line))
                            line.removeAll(keepingCapacity: true)
                            if done { break }
                        }
                    }
                    if !done {
                        if !line.isEmpty { _ = try handle(parser.feed(line)) }
                        _ = try handle(parser.finish())
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
}

/// `GET /models`.
enum ModelsAPI {
    struct Entry: Sendable, Equatable {
        var id: String
        var contextLength: Int?
        var maxOutputTokens: Int?
        /// From `architecture.input_modalities` / `architecture.modality`; nil when the server does not say.
        var supportsImages: Bool?
    }

    /// OpenAI-style `architecture.input_modalities: ["text","image"]`, or an OpenRouter-style
    /// `architecture.modality: "text+image->text"` (only the input side counts).
    static func imageSupport(in item: [String: Any]) -> Bool? {
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
                if let d = item[k] as? Double { ctx = Int(d); break }
            }
            if ctx == nil, let meta = item["meta"] as? [String: Any], let n = meta["n_ctx_train"] as? Int { ctx = n }
            var maxOut: Int?
            for k in ["max_output_tokens", "max_completion_tokens", "max_tokens"] {
                if let n = item[k] as? Int, n > 0 { maxOut = n; break }
            }
            if maxOut == nil, let top = item["top_provider"] as? [String: Any], let n = top["max_completion_tokens"] as? Int, n > 0 { maxOut = n }
            return Entry(id: id, contextLength: ctx, maxOutputTokens: maxOut, supportsImages: imageSupport(in: item))
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

/// Balance lookup, wired to the Strata gateway later.
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

/// The Strata gateway has no balance endpoint yet.
struct UnavailableBalanceProvider: BalanceProviding {
    func balance(for connection: Connection, apiKey: String?) async throws -> BalanceInfo {
        throw BalanceError.notAvailable
    }
}
