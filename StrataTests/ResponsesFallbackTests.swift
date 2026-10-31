import Testing
import Foundation
@testable import Strata

/// Answers `/chat/completions` and `/responses` from a per-path script, recording each request's path and body.
private final class APIStub: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var body: String }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var log: [(path: String, body: Data)] = []

    static func reset(chat: [Reply] = [], responses: [Reply] = []) {
        lock.withLock { scripts = ["chat/completions": chat, "responses": responses]; log = [] }
    }
    static var paths: [String] { lock.withLock { log.map(\.path) } }
    static func bodies(_ suffix: String) -> [[String: Any]] {
        lock.withLock { log.filter { $0.path.hasSuffix(suffix) }.map(\.body) }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        let key = path.hasSuffix("chat/completions") ? "chat/completions" : path.hasSuffix("responses") ? "responses" : path
        let reply = Self.lock.withLock { () -> Reply in
            Self.log.append((path, body))
            guard var list = Self.scripts[key], !list.isEmpty else { return Reply(status: 404, body: "") }
            let r = list.removeFirst()
            Self.scripts[key] = list
            return r
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": reply.status == 200 ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [APIStub.self]
        return URLSession(configuration: config)
    }
}

private func sse(_ events: [String]) -> String { events.map { "data: \($0)\n\n" }.joined() }

private let responsesOnly = #"{"error":{"message":"This model is only supported in v1/responses and not in v1/chat/completions.","type":"invalid_request_error","param":"model","code":null}}"#

private func responsesAnswer(_ text: String) -> String {
    sse([#"{"type":"response.created"}"#,
         #"{"type":"response.output_text.delta","delta":"\#(text)"}"#,
         #"{"type":"response.completed","response":{"usage":{"input_tokens":12,"output_tokens":3,"input_tokens_details":{"cached_tokens":8}}}}"#])
}

private let chatAnswer = sse([#"{"choices":[{"delta":{"content":"chat"},"finish_reason":"stop"}]}"#, "[DONE]"])

private func endpoint(route: ChatAPIRoute?, effort: Bool = false) -> Endpoint {
    Endpoint(connectionID: UUID(), connectionName: "t", baseURL: URL(string: "http://stub.test/v1")!, apiKey: "sk-test",
             headers: ["X-Extra": "1"], model: ModelInfo(id: "o9-pro", supportsEffort: effort), apiRoute: route)
}

private func collect(_ stream: AsyncThrowingStream<ChatDelta, Error>) async throws -> (text: String, usage: Usage?) {
    var text = ""
    var usage: Usage?
    for try await d in stream { text += d.content ?? ""; if let u = d.usage { usage = u } }
    return (text, usage)
}

/// Thread-safe list of what a route reported.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [ChatAPI] = []
    func add(_ api: ChatAPI) { lock.withLock { list.append(api) } }
    var all: [ChatAPI] { lock.withLock { list } }
}

struct ResponsesFallbackRuleTests {
    private func switches(_ status: Int, _ body: String) -> Bool {
        ResponsesFallback.shouldSwitch(status: status, body: Data(body.utf8))
    }

    @Test func switchesOnErrorsThatMeanUseResponses() {
        #expect(switches(404, responsesOnly))
        #expect(switches(400, responsesOnly))
        #expect(switches(400, #"{"error":{"message":"Chat Completions is not supported for this model. Use the Responses API instead."}}"#))
        #expect(switches(400, #"{"error":{"code":"OperationNotSupported","message":"The chatCompletion operation does not work with the specified model, gpt-5-codex. Please choose different model and try again."}}"#))
        #expect(switches(400, #"{"error":"unsupported endpoint"}"#))
        #expect(switches(400, #"{"detail":"Unsupported endpoint for model o9-pro"}"#))
        // The route itself is missing (a gateway that only implements /responses).
        #expect(switches(404, ""))
        #expect(switches(404, "<html><body><h1>404 Not Found</h1></body></html>"))
        #expect(switches(404, "Cannot POST /v1/chat/completions"))
        #expect(switches(405, #"{"detail":"Method Not Allowed"}"#))
        #expect(switches(501, "Not Implemented"))
        #expect(switches(404, #"{"error":{"message":"Invalid URL (POST /v1/chat/completions)","code":"unknown_url"}}"#))
    }

    @Test func keepsOtherErrors() {
        // A missing model is not a missing endpoint.
        #expect(!switches(404, #"{"error":{"message":"The model `gpt-9` does not exist or you do not have access to it.","code":"model_not_found"}}"#))
        #expect(!switches(404, #"{"error":"model 'qwen' not found, try pulling it first"}"#))
        // A legacy Completions model needs another API, not Responses.
        #expect(!switches(404, #"{"error":{"message":"This is not a chat model and thus not supported in the v1/chat/completions endpoint. Did you mean to use v1/completions?"}}"#))
        // Auth, limits, server trouble, request content.
        #expect(!switches(401, responsesOnly))
        #expect(!switches(403, responsesOnly))
        #expect(!switches(429, #"{"error":{"message":"Rate limit reached"}}"#))
        #expect(!switches(500, #"{"error":{"message":"Not found"}}"#))
        #expect(!switches(503, ""))
        #expect(!switches(400, #"{"error":{"message":"This model's maximum context length is 128000 tokens."}}"#))
        #expect(!switches(400, #"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."}}"#))
        #expect(!switches(400, ""))
        #expect(!switches(422, #"{"detail":"Not found"}"#))
    }
}

@Suite(.serialized)
struct ResponsesFallbackClientTests {
    @Test func refusedChatRetriesOnceOnResponsesAndRemembers() async throws {
        APIStub.reset(chat: [.init(status: 404, body: responsesOnly)],
                      responses: [.init(status: 200, body: responsesAnswer("hi")), .init(status: 200, body: responsesAnswer("again"))])
        let reports = Reports()
        let route = ChatAPIRoute(onDetect: { reports.add($0) })
        let ep = endpoint(route: route)
        let client = ChatClient(session: APIStub.session)
        let first = try await collect(client.stream(ChatRequest(model: "o9-pro", messages: [.system("S"), .user("q")]), endpoint: ep))
        #expect(first.text == "hi")
        #expect(first.usage == Usage(promptTokens: 12, completionTokens: 3, cachedTokens: 8, reasoningTokens: nil))
        #expect(route.current == .responses && reports.all == [.responses])
        #expect(ep.requestURL.absoluteString == "http://stub.test/v1/responses")
        // The next request (a later round of the same turn) goes straight to /responses.
        let second = try await collect(client.stream(ChatRequest(model: "o9-pro", messages: [.user("q2")]), endpoint: ep))
        #expect(second.text == "again")
        #expect(APIStub.paths == ["/v1/chat/completions", "/v1/responses", "/v1/responses"])
        #expect(reports.all == [.responses])
    }

    @Test func otherErrorsAreNotRetried() async throws {
        APIStub.reset(chat: [.init(status: 401, body: #"{"error":{"message":"bad key"}}"#)])
        let route = ChatAPIRoute()
        let client = ChatClient(session: APIStub.session)
        await #expect(throws: APIError.http(status: 401, message: "bad key")) {
            _ = try await collect(client.stream(ChatRequest(model: "m", messages: [.user("q")]), endpoint: endpoint(route: route)))
        }
        #expect(APIStub.paths == ["/v1/chat/completions"])
        #expect(route.current == .chatCompletions)
    }

    @Test func missingResponsesTooShowsTheOriginalErrorAndForgetsNothing() async throws {
        APIStub.reset(chat: [.init(status: 404, body: "Cannot POST /v1/chat/completions")],
                      responses: [.init(status: 404, body: "Cannot POST /v1/responses")])
        let route = ChatAPIRoute()
        let client = ChatClient(session: APIStub.session)
        await #expect(throws: APIError.http(status: 404, message: "Cannot POST /v1/chat/completions")) {
            _ = try await collect(client.stream(ChatRequest(model: "m", messages: [.user("q")]), endpoint: endpoint(route: route)))
        }
        #expect(APIStub.paths == ["/v1/chat/completions", "/v1/responses"])
        #expect(route.current == .chatCompletions)
    }

    @Test func aResponsesRefusalIsShownAndNotRemembered() async throws {
        APIStub.reset(chat: [.init(status: 404, body: responsesOnly)],
                      responses: [.init(status: 400, body: #"{"error":{"message":"Invalid input"}}"#)])
        let route = ChatAPIRoute()
        let client = ChatClient(session: APIStub.session)
        await #expect(throws: APIError.http(status: 400, message: "Invalid input")) {
            _ = try await collect(client.stream(ChatRequest(model: "m", messages: [.user("q")]), endpoint: endpoint(route: route)))
        }
        #expect(route.current == .chatCompletions)
    }

    @Test func aPickedAPINeverSwitches() async throws {
        APIStub.reset(chat: [.init(status: 404, body: responsesOnly)])
        let client = ChatClient(session: APIStub.session)
        let pinned = ChatAPIRoute(api: .chatCompletions, automatic: false)
        await #expect(throws: APIError.self) {
            _ = try await collect(client.stream(ChatRequest(model: "m", messages: [.user("q")]), endpoint: endpoint(route: pinned)))
        }
        #expect(APIStub.paths == ["/v1/chat/completions"])
        // No route (probe endpoints, other callers): Chat Completions only, as before.
        APIStub.reset(chat: [.init(status: 404, body: responsesOnly)])
        await #expect(throws: APIError.self) {
            _ = try await collect(client.stream(ChatRequest(model: "m", messages: [.user("q")]), endpoint: endpoint(route: nil)))
        }
        #expect(APIStub.paths == ["/v1/chat/completions"])
        // Picked Responses: straight there.
        APIStub.reset(responses: [.init(status: 200, body: responsesAnswer("r"))])
        let text = try await collect(client.stream(ChatRequest(model: "m", messages: [.user("q")]),
                                                   endpoint: endpoint(route: ChatAPIRoute(api: .responses, automatic: false)))).text
        #expect(text == "r" && APIStub.paths == ["/v1/responses"])
    }

    @Test func neverRetriesOnceTheAnswerStarted() async throws {
        // 200 and part of an answer, then the connection ends without a finish: an error, and no second request.
        APIStub.reset(chat: [.init(status: 200, body: sse([#"{"choices":[{"delta":{"content":"par"}}]}"#]))])
        let route = ChatAPIRoute()
        let client = ChatClient(session: APIStub.session)
        await #expect(throws: APIError.transport(ChatClient.cutOffMessage)) {
            _ = try await collect(client.stream(ChatRequest(model: "m", messages: [.user("q")]), endpoint: endpoint(route: route)))
        }
        #expect(APIStub.paths == ["/v1/chat/completions"])
        #expect(route.current == .chatCompletions)
    }

    @Test func standardBodyIsFlatStableAndCarriesTheKey() throws {
        let tools = [ToolDefinition(function: .init(name: "web_search", description: "Search", parameters: .init(properties: [:], required: [])))]
        var request = ChatRequest(model: "o9-pro", messages: [
            .system("You are Strata."), .user("q"),
            .assistant("", toolCalls: [ToolCall(id: "c1", name: "web_search", arguments: "{}")]),
            .tool(callID: "c1", content: "result"),
        ])
        request.messages[2].reasoningItems = [ReasoningItem(summary: ["s"], encryptedContent: "enc"),
                                              ReasoningItem(summary: [], encryptedContent: nil)]
        request.tools = tools
        request.reasoningEffort = "high"
        let body = try #require(try JSONSerialization.jsonObject(with: StandardResponses.body(request)) as? [String: Any])
        #expect(body["instructions"] as? String == "You are Strata.")
        #expect(body["store"] as? Bool == false && body["stream"] as? Bool == true)
        #expect(body["max_output_tokens"] == nil)
        let toolList = try #require(body["tools"] as? [[String: Any]])
        #expect(toolList.count == 1 && toolList[0]["type"] as? String == "function" && toolList[0]["name"] as? String == "web_search")
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == ["message", "reasoning", "function_call", "function_call_output"])
        #expect(input[1]["encrypted_content"] as? String == "enc") // the item without encrypted content is left out
        #expect(input[2]["namespace"] == nil)
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect(body["include"] as? [String] == ["reasoning.encrypted_content"])

        // The prefix stays byte-identical as the chat grows.
        var later = request
        later.messages.append(.assistant("answer"))
        later.messages.append(.user("next"))
        let a = String(decoding: try StandardResponses.body(request), as: UTF8.self)
        let b = String(decoding: try StandardResponses.body(later), as: UTF8.self)
        let instructionsAndTools = { (s: String) in s.components(separatedBy: "\"input\"")[0] }
        #expect(instructionsAndTools(a) == instructionsAndTools(b))

        // A side request's cap, no effort: no reasoning fields.
        var title = ChatRequest(model: "o9-pro", messages: [.system("Name it"), .user("conversation")])
        title.maxTokens = 32
        let titleBody = try #require(try JSONSerialization.jsonObject(with: StandardResponses.body(title)) as? [String: Any])
        #expect(titleBody["max_output_tokens"] as? Int == 32)
        #expect(titleBody["reasoning"] == nil && titleBody["include"] == nil && titleBody["tools"] == nil)

        let req = StandardResponses.urlRequest(endpoint: endpoint(route: nil), body: Data())
        #expect(req.url?.absoluteString == "http://stub.test/v1/responses")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(req.value(forHTTPHeaderField: "X-Extra") == "1")
    }

    /// A whole turn through the turn runner: the first round switches, the tool results go back as Responses items, the
    /// second round goes straight to /responses.
    @MainActor
    @Test func toolRoundsRunThroughResponses() async throws {
        let call = sse([
            #"{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Look it up."}],"encrypted_content":"ENC"}}"#,
            #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_1","name":"web_search","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"query\":\"q\"}"}"#,
            #"{"type":"response.completed","response":{"usage":{"input_tokens":20,"output_tokens":5}}}"#,
        ])
        APIStub.reset(chat: [.init(status: 404, body: responsesOnly)],
                      responses: [.init(status: 200, body: call), .init(status: 200, body: responsesAnswer("Done"))])
        let route = ChatAPIRoute()
        let runner = TurnRunner(streamer: ChatClient(session: APIStub.session), tools: FakeTools())
        var reasoning = ""
        let outcome = try await runner.run(endpoint: endpoint(route: route, effort: true),
                                           messages: [.system("S"), .user("hi")], effort: .high) { e in
            if case .reasoning(let r) = e { reasoning += r }
        }
        #expect(outcome.finalContent == "Done")
        #expect(outcome.steps.first?.calls.first?.name == "web_search")
        #expect(outcome.lastUsage?.promptTokens == 12)
        #expect(reasoning.contains("Look it up."))
        #expect(APIStub.paths == ["/v1/chat/completions", "/v1/responses", "/v1/responses"])
        let second = try #require(APIStub.bodies("responses").last)
        let input = try #require(second["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == ["message", "reasoning", "function_call", "function_call_output"])
        #expect(input[1]["encrypted_content"] as? String == "ENC")
        #expect(input[2]["call_id"] as? String == "call_1" && input[2]["namespace"] == nil)
        #expect(input[3]["call_id"] as? String == "call_1")
        #expect(second["instructions"] as? String == "S")
    }
}

@MainActor
@Suite(.serialized)
struct ResponsesFallbackStoreTests {
    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")! }

    @Test func oldAndUnknownSavedDataDecodes() throws {
        let old = #"{"id":"0F6A1A52-1111-4000-8000-000000000002","name":"Local","baseURL":"http://x/v1","models":[]}"#
        let c = try JSONDecoder().decode(Connection.self, from: Data(old.utf8))
        #expect(c.detectedModelAPIs.isEmpty && c.modelAPIOverrides.isEmpty)
        #expect(c.chatAPI(forModel: "m") == .chatCompletions)
        // A value from a newer version is dropped, not the connection.
        let newer = #"{"id":"0F6A1A52-1111-4000-8000-000000000002","name":"Local","baseURL":"http://x/v1","models":[],"detectedModelAPIs":{"a":"responses","b":"realtime"},"modelAPIOverrides":["junk"]}"#
        let n = try JSONDecoder().decode(Connection.self, from: Data(newer.utf8))
        #expect(n.detectedModelAPIs == ["a": .responses] && n.modelAPIOverrides.isEmpty)
        // Round trip.
        var r = Connection(name: "R", baseURL: "http://x/v1")
        r.detectedModelAPIs = ["a": .responses]
        r.modelAPIOverrides = ["b": .chatCompletions]
        #expect(try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(r)) == r)
    }

    @Test func detectionIsSavedAndUsedByLaterEndpoints() async throws {
        let defaults = freshDefaults()
        let store = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        var c = Connection(name: "OpenAI", baseURL: "https://api.example.test/v1", models: [ModelInfo(id: "o9-pro")], supportsResumable: true)
        store.upsert(c)
        let first = try #require(store.endpoint(connectionID: c.id, modelID: "o9-pro"))
        #expect(first.chatAPI == .chatCompletions && first.apiRoute?.automatic == true && first.supportsResumable)

        first.apiRoute?.detected(.responses) // what the client does once /responses accepted the retry
        for _ in 0..<100 where store.connection(c.id)?.detectedModelAPIs["o9-pro"] == nil { await Task.yield() }
        #expect(store.connection(c.id)?.detectedModelAPIs == ["o9-pro": .responses])
        let later = try #require(store.endpoint(connectionID: c.id, modelID: "o9-pro"))
        #expect(later.chatAPI == .responses && !later.supportsResumable)
        #expect(later.requestURL.absoluteString == "https://api.example.test/v1/responses")
        #expect(store.connection(c.id)?.modelRowSubtitle(ModelInfo(id: "o9-pro"))?.contains("Responses API") == true)

        // Saved: a fresh store reads it back.
        let reloaded = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        #expect(reloaded.endpoint(connectionID: c.id, modelID: "o9-pro")?.chatAPI == .responses)

        // Picking Chat Completions wins and stops detection; Automatic forgets what was detected.
        store.setModelAPIOverride(.chatCompletions, connectionID: c.id, modelID: "o9-pro")
        let pinned = try #require(store.endpoint(connectionID: c.id, modelID: "o9-pro"))
        #expect(pinned.chatAPI == .chatCompletions && pinned.apiRoute?.automatic == false && pinned.supportsResumable)
        store.recordDetectedAPI(.responses, connectionID: c.id, modelID: "o9-pro")
        #expect(store.connection(c.id)?.modelAPIOverrides == ["o9-pro": .chatCompletions])
        store.setModelAPIOverride(nil, connectionID: c.id, modelID: "o9-pro")
        c = try #require(store.connection(c.id))
        #expect(c.modelAPIOverrides.isEmpty && c.detectedModelAPIs.isEmpty)
        #expect(store.endpoint(connectionID: c.id, modelID: "o9-pro")?.apiRoute?.automatic == true)
        // Picking Responses: straight there, not resumable.
        store.setModelAPIOverride(.responses, connectionID: c.id, modelID: "o9-pro")
        let picked = try #require(store.endpoint(connectionID: c.id, modelID: "o9-pro"))
        #expect(picked.chatAPI == .responses && picked.apiRoute?.automatic == false && !picked.supportsResumable)
    }

    @Test func otherKindsHaveNoRoute() throws {
        let store = ConnectionStore(defaults: freshDefaults(), keys: InMemoryKeyStore(), chatGPT: ChatGPTAuth(store: .inMemory()))
        let gpt = Connection.chatGPT()
        store.upsert(gpt)
        #expect(store.endpoint(connectionID: gpt.id, modelID: "x")?.apiRoute == nil)
    }
}

/// Same stub as the Responses tests, so in their serialized suite.
extension ResponsesFallbackClientTests {
    private static let autoOnly = #"{"error":{"message":"only `\"auto\"` is supported for `tool_choice`. `\"none\"`, `\"required\"`, and named function choices are not currently supported"}}"#

    private var autoOnly: String { Self.autoOnly }

    private func autoOnlyEndpoint() -> Endpoint {
        Endpoint(connectionID: UUID(), connectionName: "t", baseURL: URL(string: "http://stub.test/v1")!, apiKey: "sk-test",
                 headers: [:], model: ModelInfo(id: "auto-only-\(UUID().uuidString)", supportsTools: true))
    }

    private func capped() -> ChatRequest {
        var r = ChatRequest(model: "m", messages: [.system("S"), .user("q")])
        r.toolChoice = "none"
        return r
    }

    @Test func aServerThatTakesOnlyAutoGetsTheRequestWithoutItAndANote() async throws {
        APIStub.reset(chat: [.init(status: 400, body: autoOnly), .init(status: 200, body: chatAnswer), .init(status: 200, body: chatAnswer)])
        let ep = autoOnlyEndpoint()
        let client = ChatClient(session: APIStub.session)
        #expect(try await collect(client.stream(capped(), endpoint: ep)).text == "chat")
        // Remembered: the next capped request goes without it at once.
        #expect(try await collect(client.stream(capped(), endpoint: ep)).text == "chat")
        let bodies = APIStub.bodies("chat/completions")
        #expect(bodies.count == 3)
        #expect(bodies[0]["tool_choice"] as? String == "none")
        for body in bodies.dropFirst() {
            #expect(body["tool_choice"] == nil)
            let last = (body["messages"] as? [[String: Any]])?.last
            #expect(last?["role"] as? String == "user" && last?["content"] as? String == ToolChoiceFallback.nudge)
        }
    }

    @Test func otherRefusalsAndAutoRequestsAreNotRetried() async throws {
        #expect(!ToolChoiceFallback.shouldRetry(capped(), status: 400, body: Data(#"{"error":{"message":"context too long"}}"#.utf8)))
        #expect(!ToolChoiceFallback.shouldRetry(ChatRequest(model: "m", messages: []), status: 400, body: Data(autoOnly.utf8)))
        #expect(!ToolChoiceFallback.shouldRetry(capped(), status: 401, body: Data(autoOnly.utf8)))
        #expect(ToolChoiceFallback.shouldRetry(capped(), status: 400, body: Data(autoOnly.utf8)))
    }
}

/// Off's thinking controls on a server that refuses them: same stub, same serialized suite.
extension ResponsesFallbackClientTests {
    private static let unknownKwargs = #"{"error":{"message":"Unrecognized request argument supplied: chat_template_kwargs"}}"#

    private func thinkingOff() -> ChatRequest {
        var r = ChatRequest(model: "m", messages: [.system("S"), .user("q")])
        r.setEffort(.off)
        return r
    }

    @Test func offIsSentAsNoneAndEnableThinkingFalse() {
        let r = thinkingOff()
        #expect(r.reasoningEffort == "none" && r.chatTemplateKwargs == .init(enableThinking: false))
        var low = ChatRequest(model: "m", messages: [])
        low.setEffort(.low)
        #expect(low.reasoningEffort == "low" && low.chatTemplateKwargs == nil)
    }

    @Test func aServerThatRefusesOffsControlsGetsTheRequestWithoutThem() async throws {
        APIStub.reset(chat: [.init(status: 400, body: Self.unknownKwargs), .init(status: 200, body: chatAnswer),
                             .init(status: 200, body: chatAnswer)])
        let ep = autoOnlyEndpoint()
        let client = ChatClient(session: APIStub.session)
        #expect(try await collect(client.stream(thinkingOff(), endpoint: ep)).text == "chat")
        #expect(try await collect(client.stream(thinkingOff(), endpoint: ep)).text == "chat") // remembered
        let bodies = APIStub.bodies("chat/completions")
        #expect(bodies.count == 3)
        #expect(bodies[0]["reasoning_effort"] as? String == "none" && bodies[0]["chat_template_kwargs"] != nil)
        for body in bodies.dropFirst() { #expect(body["reasoning_effort"] == nil && body["chat_template_kwargs"] == nil) }
    }

    @Test func onlyOffRequestsRefusedForTheirControlsAreRetried() {
        let body = Data(Self.unknownKwargs.utf8)
        #expect(ThinkingOffFallback.shouldRetry(thinkingOff(), status: 400, body: body))
        #expect(!ThinkingOffFallback.shouldRetry(thinkingOff(), status: 400, body: Data(#"{"error":{"message":"context too long"}}"#.utf8)))
        #expect(!ThinkingOffFallback.shouldRetry(ChatRequest(model: "m", messages: []), status: 400, body: body))
        #expect(!ThinkingOffFallback.shouldRetry(thinkingOff(), status: 401, body: body))
    }
}
