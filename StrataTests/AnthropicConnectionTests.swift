import Testing
import Foundation
@testable import Strata

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func anthropicEndpoint(_ modelID: String = "claude-opus-5-5", key: String? = "sk-ant-test-0000",
                               base: String = AnthropicModels.defaultBaseURL) -> Endpoint {
    Endpoint(connectionID: UUID(), connectionName: "Anthropic", baseURL: URL(string: base)!, apiKey: key, headers: [:],
             model: AnthropicModels.model(id: modelID), kind: .anthropic)
}

private func toolCall(_ id: String, _ name: String, _ args: String) -> ChatDelta {
    ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: id, name: name, arguments: args)])
}

/// A request as the prompt cache reads it: the tools, then the system prompt, then each message, as canonical JSON
/// without the `cache_control` markers (which are not part of the cached prefix), and which messages carried one.
private struct Rendered {
    var tools: Data
    var system: Data
    var messages: [Data]
    var breakpoints: [Int]

    init(_ body: Data) throws {
        let root = try object(body)
        func canonical(_ value: Any?) throws -> Data {
            guard let value else { return Data("null".utf8) }
            return try JSONSerialization.data(withJSONObject: Rendered.stripped(value), options: [.sortedKeys, .fragmentsAllowed])
        }
        tools = try canonical(root["tools"])
        system = try canonical(root["system"])
        let list = root["messages"] as? [Any] ?? []
        messages = try list.map(canonical)
        breakpoints = list.indices.filter { (try? JSONSerialization.data(withJSONObject: list[$0]))
            .map { String(decoding: $0, as: UTF8.self).contains("cache_control") } ?? false }
    }

    static func stripped(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            dict["cache_control"] = nil
            return dict.mapValues(stripped)
        }
        if let list = value as? [Any] { return list.map(stripped) }
        return value
    }

    /// Everything up to and including message `count - 1`, in the order the cache reads it.
    func prefix(messages count: Int) -> Data {
        messages.prefix(count).reduce(tools + system, +)
    }
}

struct AnthropicRequestTests {
    @Test func placesFourBreakpointsAtMost() throws {
        var request = ChatRequest(model: "claude-opus-5-5", messages: [
            .system("You are OmniChat."), .user("one"), .assistant("two"), .user("three"), .assistant("four"), .user("five"),
        ])
        request.tools = ToolDefinition.standard
        let body = try AnthropicClient.body(request, model: AnthropicModels.model(id: "claude-opus-5-5")).encoded()
        let sent = try object(body)
        #expect(String(decoding: body, as: UTF8.self).components(separatedBy: "cache_control").count - 1 == 4)
        let tools = try #require(sent["tools"] as? [[String: Any]])
        #expect(tools.last?["cache_control"] as? [String: String] == ["type": "ephemeral"])
        #expect(tools.dropLast().allSatisfy { $0["cache_control"] == nil })
        let system = try #require(sent["system"] as? [[String: Any]])
        #expect(system.count == 1 && system[0]["text"] as? String == "You are OmniChat.")
        #expect(system[0]["cache_control"] as? [String: String] == ["type": "ephemeral"])
        // The newest message, and the one the previous request ended with.
        #expect(try Rendered(body).breakpoints == [2, 4])

        // Without tools or a system prompt, the same two messages.
        let bare = ChatRequest(model: "claude-opus-5-5", messages: [.user("a"), .assistant("b"), .user("c")])
        #expect(try Rendered(AnthropicClient.body(bare, model: AnthropicModels.model(id: "claude-opus-5-5")).encoded()).breakpoints == [0, 2])
    }

    @Test func aBreakpointSkipsThinkingBlocks() throws {
        var assistant = APIMessage.assistant("", toolCalls: [ToolCall(id: "t1", name: "web_search", arguments: "{}")])
        assistant.reasoningItems = [ReasoningItem(summary: ["Plan."], encryptedContent: "sig")]
        let request = ChatRequest(model: "claude-opus-5-5", messages: [.user("q"), assistant])
        let sent = try object(AnthropicClient.body(request, model: AnthropicModels.model(id: "claude-opus-5-5")).encoded())
        let reply = try #require((sent["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        #expect(reply.map { $0["type"] as? String } == ["thinking", "tool_use"])
        #expect(reply[0]["cache_control"] == nil && reply[1]["cache_control"] != nil)
    }

    /// The point of the breakpoints: each request repeats the previous one byte for byte up to where the previous one
    /// put its last breakpoint, and puts one there itself, so all of it is read from the cache. Checked within a turn
    /// (the tool loop) and across turns (the history rebuilt from the stored steps, thinking included).
    @Test @MainActor func consecutiveRequestsShareTheCachedPrefix() async throws {
        let endpoint = anthropicEndpoint()
        let thinking = ReasoningItem(summary: ["Search first."], encryptedContent: "sig-a")
        let first = ScriptedStreamer([
            [ChatDelta(reasoning: "Search first.", reasoningItems: [thinking]), toolCall("tu_1", "web_search", #"{"query":"q"}"#)],
            [ChatDelta(content: "Answer.")],
        ])
        let opening = MessageAssembler.apiMessages(from: [HistoryMessage(role: "user", text: "hi")], systemPrompt: "S",
                                                   thinkingModel: endpoint.model.id)
        var stepThinking: StepThinking?
        let outcome = try await TurnRunner(streamer: first, tools: FakeTools())
            .run(endpoint: endpoint, messages: opening, effort: .high) { event in
                if case .stepThinking(let t) = event { stepThinking = t }
            }
        #expect(stepThinking == StepThinking(model: endpoint.model.id, items: [thinking]))
        #expect(outcome.steps.first?.thinking == stepThinking)

        let history = [HistoryMessage(role: "user", text: "hi"),
                       HistoryMessage(role: "assistant", text: outcome.finalContent, steps: outcome.steps),
                       HistoryMessage(role: "user", text: "and then?")]
        let second = ScriptedStreamer([[ChatDelta(content: "More.")]])
        _ = try await TurnRunner(streamer: second, tools: FakeTools())
            .run(endpoint: endpoint, messages: MessageAssembler.apiMessages(from: history, systemPrompt: "S", thinkingModel: endpoint.model.id),
                 effort: .high) { _ in }

        let bodies = try (first.requests + second.requests).map { try Rendered(AnthropicClient.body($0, model: endpoint.model).encoded()) }
        #expect(bodies.count == 3)
        for (before, after) in zip(bodies, bodies.dropFirst()) {
            let end = before.messages.count
            #expect(before.breakpoints.last == end - 1)
            #expect(after.breakpoints.contains(end - 1))
            #expect(after.messages.count > end)
            #expect(after.prefix(messages: end) == before.prefix(messages: end))
        }
        // The next turn sends the tool round's thinking back, signature and all.
        let raw = try object(AnthropicClient.body(second.requests[0], model: endpoint.model).encoded())
        let round = try #require((raw["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]])
        #expect(round.first?["type"] as? String == "thinking" && round.first?["signature"] as? String == "sig-a")
    }

    @Test func thinkingGoesBackOnlyToTheModelThatWroteIt() {
        let step = ToolStep(assistantContent: "", calls: [ToolCallRecord(id: "t", name: "web_search", arguments: "{}", result: "r", isError: false)],
                            thinking: StepThinking(model: "claude-opus-5-5", items: [ReasoningItem(summary: ["x"], encryptedContent: "sig")]))
        let history = [HistoryMessage(role: "user", text: "q"), HistoryMessage(role: "assistant", text: "a", steps: [step])]
        func items(_ model: String?) -> [ReasoningItem] {
            MessageAssembler.apiMessages(from: history, thinkingModel: model).flatMap(\.reasoningItems)
        }
        #expect(items("claude-opus-5-5").count == 1)
        #expect(items("claude-sonnet-5-5").isEmpty)
        #expect(items(nil).isEmpty) // every other API: the messages they always had
    }

    @Test func stepThinkingIsOptionalInStoredSteps() throws {
        let old = #"{"assistantContent":"","calls":[]}"#
        let step = try JSONDecoder().decode(ToolStep.self, from: Data(old.utf8))
        #expect(step.thinking == nil)
        #expect(!String(decoding: try JSONEncoder().encode(step), as: UTF8.self).contains("thinking"))
        var signed = step
        signed.thinking = StepThinking(model: "m", items: [ReasoningItem(summary: ["t"], encryptedContent: "s")])
        #expect(try JSONDecoder().decode(ToolStep.self, from: JSONEncoder().encode(signed)) == signed)
        // A malformed value from a later version doesn't lose the step.
        let odd = #"{"assistantContent":"x","calls":[],"thinking":7}"#
        #expect(try JSONDecoder().decode(ToolStep.self, from: Data(odd.utf8)).assistantContent == "x")
    }

    @Test func thinkingAndEffortPerModel() throws {
        func controls(_ id: String, _ level: String?, maxTokens: Int = 64000) -> (MessagesRequest.Thinking?, String?) {
            let c = AnthropicModels.controls(for: AnthropicModels.model(id: id), requested: level, maxTokens: maxTokens)
            return (c.thinking, c.effort)
        }
        // Adaptive thinking steered by effort, at the levels each model takes.
        #expect(controls("claude-opus-5-5", "xhigh") == (.adaptive, "xhigh"))
        #expect(controls("claude-opus-4-6", "xhigh") == (.adaptive, "high")) // no xhigh on 4.6
        #expect(controls("claude-sonnet-4-6", "max") == (.adaptive, "max"))
        #expect(controls("claude-opus-5-5", nil) == (.adaptive, nil)) // effort off: the model's default
        // Budget models: the level picks the budget, below max_tokens.
        #expect(controls("claude-sonnet-4-5-20250929", "medium") == (.budget(4096), nil))
        #expect(controls("claude-sonnet-4-5", "max") == (.budget(32000), nil))
        #expect(controls("claude-sonnet-4-5", "max", maxTokens: 8192) == (.budget(8191), nil))
        #expect(controls("claude-sonnet-4-5", "high", maxTokens: 1024) == (nil, nil)) // no room to think
        #expect(controls("claude-opus-4-5", "xhigh") == (.budget(8192), "high")) // its highest level, and that level's budget
        #expect(controls("claude-3-7-sonnet-latest", "low") == (.budget(1024), nil))
        #expect(controls("claude-3-5-haiku-20241022", "high") == (nil, nil))
        // A title: no thinking at the lowest level.
        #expect(controls("claude-opus-5-5", "none") == (nil, "low"))
        #expect(controls("claude-sonnet-4-5", "none") == (nil, nil))

        let adaptive = try object(ChatRequest.encoder.encode(MessagesRequest.Thinking.adaptive))
        #expect(adaptive as? [String: String] == ["type": "adaptive", "display": "summarized"])
        let budget = try object(ChatRequest.encoder.encode(MessagesRequest.Thinking.budget(2048)))
        #expect(budget["type"] as? String == "enabled" && budget["budget_tokens"] as? Int == 2048)
    }

    @Test func familiesGiveWindowsAndCaps() {
        func family(_ id: String) -> (Int, Int)? { AnthropicModels.family(of: id).map { ($0.contextLength, $0.maxOutputTokens) } }
        #expect(family("claude-opus-5-5")! == (1_000_000, 128_000))
        #expect(family("claude-haiku-5-5")! == (1_000_000, 128_000))
        #expect(family("claude-sonnet-4-6")! == (1_000_000, 64_000))
        #expect(family("claude-opus-4-5-20251101")! == (200_000, 64_000))
        #expect(family("claude-opus-4-1-20250805")! == (200_000, 32_000))
        #expect(family("claude-sonnet-4-20250514")! == (200_000, 64_000))
        #expect(family("claude-3-5-sonnet-20241022")! == (200_000, 8192))
        #expect(family("gpt-5") == nil)
        let model = AnthropicModels.model(id: "claude-sonnet-4-5")
        #expect(model.supportsImages && model.supportsTools && model.supportsEffort)
        #expect(model.effortLevels(.modelDecides) == Effort.allCases)
        #expect(AnthropicModels.model(id: "claude-opus-5-5").effortLevels(.modelDecides) == Effort.allCases)
        #expect(!AnthropicModels.model(id: "claude-3-5-haiku-latest").supportsEffort)
        // max_tokens: the request's, else the model's cap, else the default.
        let body = AnthropicClient.body(ChatRequest(model: "x", messages: [.user("a")]), model: ModelInfo(id: "x"))
        #expect(body.maxTokens == MessagesRequest.defaultMaxTokens)
        #expect(AnthropicClient.body(ChatRequest(model: "claude-opus-4-1", messages: [.user("a")]), model: ModelInfo(id: "claude-opus-4-1")).maxTokens == 32_000)
    }

    @Test func readsTheModelList() throws {
        let page = try AnthropicModelsAPI.parse(Data(#"""
        {"data":[
          {"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","max_input_tokens":1000000,"max_tokens":128000,
           "capabilities":{"image_input":{"supported":true},
             "effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"xhigh":{"supported":true},"max":{"supported":true}},
             "thinking":{"supported":true,"types":{"adaptive":{"supported":true},"enabled":{"supported":false}}}}},
          {"type":"model","id":"claude-sonnet-4-5-20250929","display_name":"Claude Sonnet 4.5",
           "capabilities":{"image_input":{"supported":true},"effort":{"supported":false},
             "thinking":{"supported":true,"types":{"adaptive":{"supported":false},"enabled":{"supported":true}}}}},
          {"type":"model","id":"claude-haiku-9","display_name":"Future"}
        ],"has_more":true,"first_id":"claude-opus-5-5","last_id":"claude-haiku-9"}
        """#.utf8))
        #expect(page.hasMore && page.lastID == "claude-haiku-9")
        #expect(page.entries.map(\.id) == ["claude-opus-5-5", "claude-sonnet-4-5-20250929", "claude-haiku-9"])
        #expect(page.entries[0].info == AnthropicModelInfo(thinking: .adaptive, efforts: Effort.allCases))
        #expect(page.entries[0].contextLength == 1_000_000 && page.entries[0].maxOutputTokens == 128_000)
        #expect(page.entries[1].info == AnthropicModelInfo(thinking: .budget))
        #expect(page.entries[1].contextLength == 200_000) // not listed: the family's
        // No capabilities: what the id says.
        #expect(page.entries[2].info.thinking == .adaptive && page.entries[2].supportsImages == true)
        #expect(throws: APIError.self) { try AnthropicModelsAPI.parse(Data("{}".utf8)) }
        // A model info a later version wrote still decodes.
        let info = try JSONDecoder().decode(AnthropicModelInfo.self, from: Data(#"{"thinking":"telepathy","efforts":["low","ultra"]}"#.utf8))
        #expect(info == AnthropicModelInfo(thinking: .none, efforts: [.low]))
    }

    @Test func errorsReadWell() {
        func error(_ status: Int, _ type: String, _ message: String, retryAfter: String? = nil) -> APIError {
            let body = #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"},"request_id":"req_1"}"#
            return AnthropicErrorMapper.error(status: status, data: Data(body.utf8), retryAfter: retryAfter, connection: "Anthropic")
        }
        #expect(error(401, "authentication_error", "invalid x-api-key") == .rejectedAPIKey(connection: "Anthropic"))
        #expect(APIError.rejectedAPIKey(connection: "Anthropic").needsSettings)
        guard case .http(429, let limited) = error(429, "rate_limit_error", "slow down", retryAfter: "30") else { Issue.record(); return }
        #expect(limited.contains("30 seconds"))
        guard case .http(529, let overloaded) = error(529, "overloaded_error", "Overloaded") else { Issue.record(); return }
        #expect(overloaded.contains("overloaded"))
        guard case .http(403, let forbidden) = error(403, "permission_error", "no access to model") else { Issue.record(); return }
        #expect(forbidden.contains("no access to model"))
        // A 400 keeps the API's text, so compaction still sees an overflow.
        let tooLong = error(400, "invalid_request_error", "prompt is too long: 1000001 tokens > 1000000 maximum")
        #expect(tooLong == .http(status: 400, message: "prompt is too long: 1000001 tokens > 1000000 maximum"))
        #expect(MessagesEventDecoder.errorText(type: "api_error", message: "boom") == "boom")
    }

    @Test func refusedThinkingIsRetriedWithoutIt() throws {
        var assistant = APIMessage.assistant("", toolCalls: [ToolCall(id: "t1", name: "web_search", arguments: "{}")])
        assistant.reasoningItems = [ReasoningItem(summary: ["Plan."], encryptedContent: "sig")]
        var request = ChatRequest(model: "claude-opus-5-5", messages: [.user("q"), assistant, .tool(callID: "t1", content: "r")])
        request.reasoningEffort = "high"
        let body = AnthropicClient.body(request, model: AnthropicModels.model(id: "claude-opus-5-5"))
        func refusal(_ message: String) -> Data { Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"\#(message)"}}"#.utf8) }
        let retry = AnthropicClient.Retry.after(refusal("messages.1.content.0: Invalid `signature` in `thinking` block"), body: body)
        #expect(retry == .stripThinking)
        let stripped = try #require(retry).apply(to: body)
        #expect(!stripped.hasThinkingBlocks && stripped.messages.count == 3)
        #expect(AnthropicClient.Retry.after(refusal("thinking.type: adaptive is not supported"), body: stripped) == .dropThinking)
        #expect(AnthropicClient.Retry.after(refusal("output_config.effort: not supported"), body: stripped) == .dropEffort)
        #expect(AnthropicClient.Retry.after(refusal("messages: roles must alternate"), body: stripped) == nil)
    }

    @Test func usageCountsCacheReadsAndWrites() throws {
        var decoder = MessagesEventDecoder()
        _ = try decoder.decode(#"{"type":"message_start","message":{"usage":{"input_tokens":20,"cache_read_input_tokens":3000,"cache_creation_input_tokens":500,"output_tokens":1}}}"#)
        let end = try decoder.decode(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}"#)
        let usage = try #require(end.usage)
        #expect(usage == Usage(promptTokens: 3520, completionTokens: 9, cachedTokens: 3000, cacheWriteTokens: 500))
        #expect(try JSONDecoder().decode(Usage.self, from: JSONEncoder().encode(usage)) == usage)
        let conversation = Conversation(title: "t")
        conversation.apply(usage)
        #expect(conversation.lastUsage == usage)
    }

    @Test func theConnectionKind() throws {
        let c = Connection.anthropic()
        #expect(c.kind == .anthropic && c.baseURL == "https://api.anthropic.com/v1" && !c.supportsResumable)
        #expect(c.effortStyle == .modelDecides)
        #expect(anthropicEndpoint().requestURL.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(c)).kind == .anthropic)
        // Not synced until it has models (it is still being set up), like an unfinished server.
        #expect(!ConnectionSync.syncs(c))
        var ready = c
        ready.models = [AnthropicModels.model(id: "claude-opus-5-5")]
        #expect(ConnectionSync.syncs(ready))
        #expect(ConnectionPreset.anthropic.makeConnection().isAnthropic)
    }

    @Test func addLinks() throws {
        func parse(_ s: String) -> Result<AddConnectionLink, AddConnectionLink.Failure> { AddConnectionLink.parse(URL(string: s)!) }
        let plain = try parse("omnichat://add-connection?api=anthropic&images=1&resumable=1&key=sk-ant-secret").get()
        #expect(plain.anthropic && plain.name == "Anthropic" && plain.droppedKey)
        #expect(!plain.resumable && !plain.images)
        let c = plain.makeConnection()
        #expect(c.isAnthropic && c.baseURL == "https://api.anthropic.com/v1" && !c.supportsResumable)
        #expect(!String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("sk-ant-secret"))
        let proxy = try parse("omnichat://add-connection?api=anthropic&url=https://gateway.example.com/anthropic/v1&name=Work").get()
        #expect(proxy.makeConnection().baseURL == "https://gateway.example.com/anthropic/v1" && proxy.name == "Work")
        #expect(parse("omnichat://add-connection?api=anthropic&url=ftp://x") == .failure(.invalidURL))
        #expect(parse("omnichat://add-connection?api=openai") == .failure(.missingURL))
    }
}

@MainActor
struct AnthropicSyncTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")! }

    /// What a version before the Anthropic kind does with an Anthropic connection synced from a newer device: a kind it
    /// can't decode. It neither takes it nor removes it from the cloud.
    @Test func aKindThisVersionDoesNotKnowIsLeftAlone() throws {
        var future = Connection.anthropic()
        future.models = [ModelInfo(id: "m")]
        let json = String(decoding: try #require(ConnectionSync.encode(future)), as: UTF8.self)
            .replacingOccurrences(of: #""kind":"anthropic""#, with: #""kind":"teleport""#)
        #expect(json.contains("teleport"))
        let cloud = InMemoryKeyValueStore()
        cloud.set(Data(json.utf8), forKey: ConnectionSync.keyPrefix + future.id.uuidString)
        let store = ConnectionStore(defaults: defaults(), keys: InMemoryKeyStore())
        let mine = Connection(name: "mine", baseURL: "https://mine.example/v1", models: [ModelInfo(id: "m")])
        store.upsert(mine)
        let sync = ConnectionSync(store: store, cloud: cloud, defaults: defaults(), headers: InMemoryKeyStore())
        sync.start()
        store.delete(mine.id)
        #expect(store.connections.allSatisfy { $0.id != future.id })
        #expect(cloud.object(forKey: ConnectionSync.keyPrefix + future.id.uuidString) as? Data == Data(json.utf8))
        sync.stop()
    }
}

/// The Anthropic API, scripted: each request takes the next reply.
private final class AnthropicStub: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var body: String; var headers: [String: String] = [:] }
    struct Seen { var url: URL; var headers: [String: String]; var body: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var log: [Seen] = []

    static func reset(_ list: [Reply]) { lock.withLock { replies = list; log = [] } }
    static var seen: [Seen] { lock.withLock { log } }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        let reply = Self.lock.withLock { () -> Reply in
            Self.log.append(Seen(url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body))
            return Self.replies.isEmpty ? Reply(status: 500, body: "") : Self.replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": reply.status == 200 ? "text/event-stream" : "application/json"]
                                           .merging(reply.headers) { $1 })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func sse(_ events: [String]) -> String { events.map { "event: x\ndata: \($0)\n\n" }.joined() }

private let answer = sse([
    #"{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":2000,"cache_creation_input_tokens":300,"output_tokens":1}}}"#,
    #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
    #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
    #"{"type":"content_block_stop","index":0}"#,
    #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}"#,
    #"{"type":"message_stop"}"#,
])

private func collect(_ stream: AsyncThrowingStream<ChatDelta, Error>) async throws -> (text: String, usage: Usage?) {
    var text = ""
    var usage: Usage?
    for try await d in stream { text += d.content ?? ""; if let u = d.usage { usage = u } }
    return (text, usage)
}

@Suite(.serialized)
struct AnthropicClientTests {
    private let client = AnthropicClient(session: AnthropicStub.session)

    @Test func streamsAndSendsTheKeyOnlyInItsHeader() async throws {
        AnthropicStub.reset([.init(status: 200, body: answer)])
        var request = ChatRequest(model: "claude-opus-5-5", messages: [.system("S"), .user("Hi")])
        request.reasoningEffort = "high"
        let (text, usage) = try await collect(client.stream(request, endpoint: anthropicEndpoint()))
        #expect(text == "Hello")
        #expect(usage == Usage(promptTokens: 2310, completionTokens: 4, cachedTokens: 2000, cacheWriteTokens: 300))
        let seen = try #require(AnthropicStub.seen.first)
        #expect(seen.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(seen.headers["x-api-key"] == "sk-ant-test-0000")
        #expect(seen.headers["anthropic-version"] == "2023-06-01")
        #expect(seen.headers["Authorization"] == nil)
        #expect(!String(decoding: seen.body, as: UTF8.self).contains("sk-ant-test-0000"))
        let body = try object(seen.body)
        #expect(body["max_tokens"] as? Int == 128_000)
        #expect(body["thinking"] as? [String: String] == ["type": "adaptive", "display": "summarized"])
        #expect(body["output_config"] as? [String: String] == ["effort": "high"])
        #expect(body["stream"] as? Bool == true)
    }

    @Test func noKeyNoRequest() async {
        AnthropicStub.reset([])
        await #expect(throws: APIError.missingAPIKey(connection: "Anthropic")) {
            _ = try await collect(client.stream(ChatRequest(model: "m", messages: [.user("a")]), endpoint: anthropicEndpoint(key: nil)))
        }
        #expect(AnthropicStub.seen.isEmpty)
    }

    @Test func refusedThinkingIsSentAgainWithoutIt() async throws {
        let refusal = #"{"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.0: Invalid `signature` in `thinking` block"}}"#
        AnthropicStub.reset([.init(status: 400, body: refusal), .init(status: 200, body: answer)])
        var assistant = APIMessage.assistant("", toolCalls: [ToolCall(id: "t1", name: "web_search", arguments: "{}")])
        assistant.reasoningItems = [ReasoningItem(summary: ["Plan."], encryptedContent: "sig")]
        let request = ChatRequest(model: "claude-opus-5-5", messages: [.user("q"), assistant, .tool(callID: "t1", content: "r")])
        #expect(try await collect(client.stream(request, endpoint: anthropicEndpoint())).text == "Hello")
        let bodies = AnthropicStub.seen.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(bodies.count == 2 && bodies[0].contains(#""signature":"sig""#) && !bodies[1].contains("signature"))
    }

    @Test func statusErrors() async throws {
        AnthropicStub.reset([.init(status: 429, body: #"{"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}"#,
                                   headers: ["retry-after": "12"])])
        do {
            _ = try await collect(client.stream(ChatRequest(model: "claude-opus-5-5", messages: [.user("a")]), endpoint: anthropicEndpoint()))
            Issue.record("no error")
        } catch let APIError.http(status, message) {
            #expect(status == 429 && message.contains("12 seconds"))
        }
        AnthropicStub.reset([.init(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)])
        await #expect(throws: APIError.rejectedAPIKey(connection: "Anthropic")) {
            _ = try await collect(client.stream(ChatRequest(model: "claude-opus-5-5", messages: [.user("a")]), endpoint: anthropicEndpoint()))
        }
        // An error event in the middle of a stream.
        AnthropicStub.reset([.init(status: 200, body: sse([#"{"type":"message_start","message":{"usage":{"input_tokens":1}}}"#,
                                                           #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#]))])
        await #expect(throws: APIError.server(MessagesEventDecoder.errorText(type: "overloaded_error", message: nil))) {
            _ = try await collect(client.stream(ChatRequest(model: "claude-opus-5-5", messages: [.user("a")]), endpoint: anthropicEndpoint()))
        }
    }

    @Test @MainActor func fetchesEveryPageOfModels() async throws {
        let first = #"{"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","max_input_tokens":1000000,"max_tokens":128000}],"has_more":true,"last_id":"claude-opus-5-5"}"#
        let second = #"{"data":[{"type":"model","id":"claude-haiku-4-5-20251001","display_name":"Claude Haiku 4.5"}],"has_more":false,"last_id":"claude-haiku-4-5-20251001"}"#
        AnthropicStub.reset([.init(status: 200, body: first), .init(status: 200, body: second)])
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!, keys: InMemoryKeyStore(),
                                    session: AnthropicStub.session)
        var c = Connection.anthropic()
        var manual = AnthropicModels.model(id: "claude-custom-1")
        manual.isManual = true
        c.models = [manual]
        c.setAlias("Opus", forModel: "claude-opus-5-5")
        store.upsert(c)
        try store.setAPIKey("sk-ant-test-0000", for: c.id)

        #expect(try await store.refreshModels(for: c.id) == 2)
        let urls = AnthropicStub.seen.map(\.url.absoluteString)
        #expect(urls == ["https://api.anthropic.com/v1/models?limit=1000",
                         "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-opus-5-5"])
        #expect(AnthropicStub.seen.allSatisfy { $0.headers["x-api-key"] == "sk-ant-test-0000" })
        let updated = try #require(store.connection(c.id))
        #expect(updated.models.map(\.id) == ["claude-opus-5-5", "claude-haiku-4-5-20251001", "claude-custom-1"])
        #expect(updated.displayName(forModel: "claude-opus-5-5") == "Opus")
        #expect(updated.displayName(forModel: "claude-haiku-4-5-20251001") == "Claude Haiku 4.5")
        #expect(updated.models[1].anthropic == AnthropicModelInfo(thinking: .budget))
        #expect(updated.models[0].maxOutputTokens == 128_000)

        let endpoint = try #require(store.endpoint(connectionID: c.id, modelID: "claude-opus-5-5"))
        #expect(endpoint.kind == .anthropic && !endpoint.supportsResumable && endpoint.apiKey == "sk-ant-test-0000")
        #expect(endpoint.requestURL.absoluteString == "https://api.anthropic.com/v1/messages")
    }
}
