import Testing
import Foundation
@testable import Strata

/// Serves `/models` per host, after `delay`: `a.test` and `b.test` list different models.
private final class HostModelsStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var ids: [String: [String]] = [:]
    nonisolated(unsafe) static var delay: TimeInterval = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let ids = Self.ids[request.url?.host() ?? ""] ?? []
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
            let body = try! JSONSerialization.data(withJSONObject: ["data": ids.map { ["id": $0] }])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct OpenAIPlatformTests {
    private func store() -> ConnectionStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HostModelsStub.self]
        return ConnectionStore(defaults: UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!, keys: InMemoryKeyStore(),
                               session: URLSession(configuration: config))
    }

    private func json(_ request: ChatRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: try request.encoded()) as? [String: Any])
    }

    @Test func outputCapsAndEffortAreWhatOpenAITakes() throws {
        var title = AutoRename.request(model: "o3", prompt: "p", thinking: .off, supportsEffort: true)
        var body = try json(OpenAIPlatform.adapted(title))
        #expect(body["max_completion_tokens"] as? Int == AutoRename.maxTokens && body["max_tokens"] == nil)
        #expect(body["reasoning_effort"] as? String == "low" && body["chat_template_kwargs"] == nil)
        title.model = "gpt-5"
        #expect(try json(OpenAIPlatform.adapted(title))["reasoning_effort"] as? String == "minimal")
        title.model = "gpt-5.1"
        #expect(try json(OpenAIPlatform.adapted(title))["reasoning_effort"] as? String == "none")

        var chat = ChatRequest(model: "o3", messages: [.user("hi")])
        chat.reasoningEffort = Effort.max.apiValue
        body = try json(OpenAIPlatform.adapted(chat))
        #expect(body["reasoning_effort"] as? String == "high" && body["max_completion_tokens"] == nil)
        chat.reasoningEffort = Effort.xhigh.apiValue
        #expect(try json(OpenAIPlatform.adapted(chat))["reasoning_effort"] as? String == "high")
        chat.model = "gpt-5.2"
        #expect(try json(OpenAIPlatform.adapted(chat))["reasoning_effort"] as? String == "xhigh")
        // Unadapted requests (any other server) keep `max_tokens`.
        #expect(try json(title)["max_tokens"] as? Int == AutoRename.maxTokens)
    }

    @Test func onlyOpenAIsOwnAPIIsAdapted() {
        let openAI = Connection(name: "OpenAI", baseURL: "https://api.openai.com/v1", models: [ModelInfo(id: "o3", supportsEffort: true)])
        let gateway = Connection(name: "Gateway", baseURL: "https://gateway.example/v1", models: [ModelInfo(id: "o3", supportsEffort: true)])
        #expect(openAI.effortStyle == .openAI && gateway.effortStyle == .tokenCaps)
        #expect(openAI.models[0].effortLevels(openAI.effortStyle) == [.low, .medium, .high])
        #expect(gateway.models[0].effortLevels(gateway.effortStyle) == Effort.allCases)
        #expect(ModelInfo(id: "gpt-5.2", supportsEffort: true).effortLevels(.openAI) == [.low, .medium, .high, .xhigh])
        let endpoint = Endpoint(connectionID: UUID(), connectionName: "x", baseURL: URL(string: "https://gateway.example/v1")!,
                                apiKey: nil, headers: [:], model: ModelInfo(id: "o3"))
        #expect(!OpenAIPlatform.isHost(endpoint))
    }

    @Test func gpt6LevelsFollowTheModel() {
        let upToXhigh: [Effort] = [.low, .medium, .high, .xhigh]
        for id in ["gpt-6-sol", "gpt-6-astra", "gpt-6-luna"] {
            #expect(OpenAIPlatform.effortLevels(model: id) == upToXhigh, "\(id)")
            #expect(OpenAIPlatform.leastEffort(model: id) == "none", "\(id)")
        }
        for id in ["gpt-6.1-sol", "gpt-5.6-sol"] {
            #expect(OpenAIPlatform.effortLevels(model: id) == Effort.allCases, "\(id)")
            #expect(OpenAIPlatform.leastEffort(model: id) == "low", "\(id): none and minimal are refused")
        }
        #expect(OpenAIPlatform.effortLevels(model: "gpt-5.5") == upToXhigh)
        #expect(OpenAIPlatform.effortLevels(model: "gpt-5") == [.low, .medium, .high])
        #expect(OpenAIPlatform.leastEffort(model: "gpt-5") == "minimal")
        #expect(OpenAIPlatform.leastEffort(model: "gpt-5.1") == "none")
        #expect(OpenAIPlatform.leastEffort(model: "o3") == "low")
        #expect(!OpenAIPlatform.takesMax("gpt-4.1") && !OpenAIPlatform.takesMax("gpt-6-sol"))

        // ChatGPT's own models: Max on those that take it, sent as `max` there and as `xhigh` elsewhere.
        #expect(ModelInfo(id: "gpt-6.1-sol", supportsEffort: true).effortLevels(.modelDecides) == Effort.allCases)
        #expect(ModelInfo(id: "gpt-6-sol", supportsEffort: true).effortLevels(.modelDecides) == upToXhigh)
        #expect(ResponsesRequest.effort("max", model: "gpt-6.1-sol") == "max")
        #expect(ResponsesRequest.effort("max", model: "gpt-6-sol") == "xhigh")
        #expect(ResponsesRequest.effort("high", model: "gpt-6-sol") == "high")
    }

    @Test func nonChatModelsAreLeftOutForKnownProviders() async throws {
        let s = store()
        HostModelsStub.delay = 0
        HostModelsStub.ids = [
            "api.openai.com": ["gpt-5", "text-embedding-3-small", "whisper-1", "tts-1", "gpt-4o-mini-tts", "gpt-4o-transcribe",
                               "dall-e-3", "gpt-image-1", "omni-moderation-latest", "gpt-realtime", "o3", "davinci-002"],
            "api.groq.com": ["llama-3.3-70b-versatile", "whisper-large-v3", "whisper-large-v3-turbo", "playai-tts"],
            "localhost": ["nomic-embed-text", "qwen3"],
        ]
        var openAI = Connection(name: "OpenAI", baseURL: "https://api.openai.com/v1")
        var manual = ModelInfo(id: "whisper-1")
        manual.isManual = true
        openAI.models = [manual]
        let groq = Connection(name: "Groq", baseURL: "https://api.groq.com/openai/v1")
        let local = Connection(name: "Local", baseURL: "http://localhost:9/v1")
        for c in [openAI, groq, local] {
            s.upsert(c)
            try await s.refreshModels(for: c.id)
        }
        #expect(s.connection(openAI.id)?.models.map(\.id) == ["gpt-5", "o3", "whisper-1"], "a model added by hand stays")
        #expect(s.connection(groq.id)?.models.map(\.id) == ["llama-3.3-70b-versatile"])
        #expect(s.connection(local.id)?.models.map(\.id) == ["nomic-embed-text", "qwen3"], "other servers are taken as they are")
    }

    @Test func aListFetchedBeforeAnEditIsDropped() async throws {
        let s = store()
        HostModelsStub.ids = ["a.test": ["a-model"], "b.test": ["b-model"]]
        HostModelsStub.delay = 0.3
        defer { HostModelsStub.delay = 0 }
        var c = Connection(name: "Server", baseURL: "http://a.test/v1")
        s.upsert(c)
        let fetch = Task { try await s.refreshModels(for: c.id) }
        try await Task.sleep(for: .milliseconds(50))
        c.baseURL = "http://b.test/v1"
        s.upsert(c)
        await #expect(throws: CancellationError.self) { try await fetch.value }
        #expect(s.connection(c.id)?.models.isEmpty == true)
        try await s.refreshModels(for: c.id)
        #expect(s.connection(c.id)?.models.map(\.id) == ["b-model"])
    }
}
