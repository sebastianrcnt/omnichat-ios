import Testing
import Foundation
@testable import Strata

// MARK: - Connections

@MainActor
struct OpenCodeConnectionTests {
    private func store(_ auth: OpenCodeAuth = OpenCodeAuth(store: .inMemory())) -> ConnectionStore {
        ConnectionStore(defaults: UserDefaults(suiteName: "oc.\(UUID().uuidString)")!, keys: InMemoryKeyStore(),
                        chatGPT: ChatGPTAuth(store: .inMemory()), openCode: auth)
    }

    /// Saved before OpenCode existed: no gateway, no per-model OpenCode info.
    @Test func olderConnectionsAndModelsDecodeUnchanged() throws {
        let legacy = """
        [{"id":"0F6A1A52-1111-4000-8000-000000000002","kind":"chatGPT","name":"ChatGPT","baseURL":"https://api.openai.com/v1",
          "models":[{"id":"gpt-6.1-sol","supportsImages":true,"supportsEffort":true,"supportsTools":true,"isManual":false}]},
         {"id":"0F6A1A52-1111-4000-8000-000000000003","name":"Local","baseURL":"http://192.168.0.2:8080/v1","models":[]}]
        """
        let decoded = try JSONDecoder().decode([Connection].self, from: Data(legacy.utf8))
        #expect(decoded.map(\.kind) == [.chatGPT, .openAICompatible])
        #expect(decoded.allSatisfy { $0.openCodeGateway == nil && !$0.isOpenCode })
        #expect(decoded[0].models[0].openCode == nil)
        #expect(decoded[0].models[0].effortLevels(.modelDecides) == [.low, .medium, .high, .xhigh])
    }

    @Test func openCodeConnectionRoundTrips() throws {
        var c = Connection.openCode(gateway: .console)
        var model = ModelInfo(id: "gpt-5.5", supportsImages: true, supportsEffort: true)
        model.openCode = OpenCodeModelInfo(api: .responses, efforts: [.low, .medium, .high, .xhigh])
        model.fetchedDisplayName = "GPT-5.5"
        c.models = [model]
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(Connection.self, from: data)
        #expect(decoded.kind == .openCode && decoded.isOpenCode)
        #expect(decoded.openCodeGateway == .console)
        #expect(!decoded.supportsResumable)
        #expect(decoded.models[0].openCode == model.openCode)
        #expect(decoded.effortStyle == .modelDecides)
        #expect(decoded.displayName(forModel: "gpt-5.5") == "GPT-5.5")
        // A kind this build doesn't know would fail to decode, so older builds never see one: nothing to migrate back.
        #expect(String(decoding: data, as: UTF8.self).contains("\"kind\":\"openCode\""))
    }

    @Test func endpointGoesToTheGatewayWithSessionHeaders() throws {
        let auth = OpenCodeAuth(store: .inMemory())
        let store = store(auth)
        var c = Connection.openCode()
        var chat = ModelInfo(id: "glm-5.3", supportsEffort: false)
        chat.openCode = OpenCodeModelInfo(api: .chatCompletions)
        var gpt = ModelInfo(id: "gpt-6-luna", supportsEffort: true)
        gpt.openCode = OpenCodeModelInfo(api: .responses, efforts: [.low, .medium, .high])
        c.models = [chat, gpt]
        store.upsert(c)

        let endpoint = try #require(store.endpoint(connectionID: c.id, modelID: "glm-5.3", sessionID: "conv-1"))
        #expect(endpoint.kind == .openCode)
        #expect(endpoint.baseURL.absoluteString == "https://opencode.ai/inference/go/v1")
        #expect(endpoint.requestURL.absoluteString == "https://opencode.ai/inference/go/v1/chat/completions")
        #expect(endpoint.headers["x-opencode-session"] == "conv-1")
        #expect(endpoint.headers["x-opencode-client"] == "strata")
        #expect(endpoint.headers["User-Agent"]?.hasPrefix("Strata/") == true)
        #expect(endpoint.apiKey == nil && !endpoint.supportsResumable)
        #expect(endpoint.openCodeGateway == .go)

        let responses = try #require(store.endpoint(connectionID: c.id, modelID: "gpt-6-luna"))
        #expect(responses.requestURL.absoluteString == "https://opencode.ai/inference/go/v1/responses")
        #expect(responses.headers["x-opencode-session"] == c.id.uuidString) // no conversation: still stable

        c.openCodeGateway = .console
        store.upsert(c)
        let console = try #require(store.endpoint(connectionID: c.id, modelID: "glm-5.3"))
        #expect(console.requestURL.absoluteString == "https://opencode.ai/inference/v1/chat/completions")
        #expect(console.openCodeGateway == .console)
    }

    @Test func signedOutAsksForASignInAndDeletingForgetsTheCredentials() throws {
        let auth = OpenCodeAuth(store: .inMemory())
        let store = store(auth)
        let c = Connection.openCode()
        store.upsert(c)
        let endpoint = try #require(store.endpoint(connectionID: c.id, modelID: "glm-5.3"))
        #expect(ChatController.needsKey(endpoint, connections: store))
        #expect(ChatController.credentialError(endpoint) == .openCodeSignInRequired(connection: "OpenCode"))
        #expect(APIError.openCodeSignInRequired(connection: "OpenCode").needsSettings)

        try auth.store.setAPIKey("oc_sk_x", c.id)
        #expect(!ChatController.needsKey(endpoint, connections: store))
        store.delete(c.id)
        #expect(!auth.store.hasCredential(c.id))
    }
}

// MARK: - Model catalog and routing

struct OpenCodeRoutingTests {
    @Test func npmPackagesPickTheAPI() {
        #expect(OpenCodeModelAPI(npm: "@ai-sdk/openai-compatible") == .chatCompletions)
        #expect(OpenCodeModelAPI(npm: "@ai-sdk/openai") == .responses)
        #expect(OpenCodeModelAPI(npm: "@ai-sdk/anthropic") == .messages)
        #expect(OpenCodeModelAPI(npm: "@ai-sdk/google") == .gemini)
        #expect(OpenCodeModelAPI(npm: "@ai-sdk/mistral") == nil)
    }

    /// The docs' endpoint tables, for models the catalog doesn't describe.
    @Test func guessesFollowTheDocsTables() {
        #expect(OpenCodeModelAPI.guess(model: "gpt-6-luna", gateway: .go) == .responses)
        #expect(OpenCodeModelAPI.guess(model: "grok-4.7", gateway: .console) == .responses)
        #expect(OpenCodeModelAPI.guess(model: "muse-spark-1.3", gateway: .console) == .responses)
        #expect(OpenCodeModelAPI.guess(model: "claude-haiku-5-5", gateway: .go) == .messages)
        #expect(OpenCodeModelAPI.guess(model: "gemini-4-argon", gateway: .console) == .gemini)
        #expect(OpenCodeModelAPI.guess(model: "qwen3.8-max", gateway: .console) == .chatCompletions)
        #expect(OpenCodeModelAPI.guess(model: "qwen3.8-max", gateway: .go) == .messages)
        #expect(OpenCodeModelAPI.guess(model: "qwen3.7-plus", gateway: .console) == .messages)
        #expect(OpenCodeModelAPI.guess(model: "minimax-m3", gateway: .go) == .messages)
        #expect(OpenCodeModelAPI.guess(model: "minimax-m3", gateway: .console) == .chatCompletions)
        #expect(OpenCodeModelAPI.guess(model: "kimi-k3", gateway: .go) == .chatCompletions)
        #expect(OpenCodeModelAPI.chatCompletions.path(model: "x") == "chat/completions")
        #expect(OpenCodeModelAPI.gemini.path(model: "gemini-3") == "models/gemini-3:streamGenerateContent")
    }

    /// A trimmed models.dev `api.json` with the fields Strata reads.
    private let metadata = Data("""
    {"opencode-go": {"id": "opencode-go", "npm": "@ai-sdk/openai-compatible", "api": "https://opencode.ai/inference/go/v1",
      "models": {
        "glm-5.3": {"id": "glm-5.3", "name": "GLM-5.3", "reasoning": true, "reasoning_options": [{"type": "toggle"}],
                    "tool_call": true, "interleaved": {"field": "reasoning_content"},
                    "modalities": {"input": ["text"], "output": ["text"]}, "limit": {"context": 200000, "output": 131072}},
        "gpt-6-luna": {"id": "gpt-6-luna", "name": "GPT 6 Luna", "reasoning": true,
                       "reasoning_options": [{"type": "effort", "values": ["none", "low", "medium", "high", "xhigh"]}],
                       "tool_call": true, "provider": {"npm": "@ai-sdk/openai"},
                       "modalities": {"input": ["text", "image", "pdf"]}, "limit": {"context": 1050000, "output": 128000}},
        "claude-haiku-5-5": {"id": "claude-haiku-5-5", "name": "Claude Haiku 5.5", "reasoning": true,
                             "reasoning_options": [{"type": "effort", "values": ["low", "medium", "high", "max"]}],
                             "provider": {"npm": "@ai-sdk/anthropic"}, "limit": {"context": 200000, "output": 64000}},
        "gemini-4-argon-contributor": {"id": "gemini-4-argon-contributor", "provider": {"npm": "@ai-sdk/google"}},
        "kimi-k3": {"id": "kimi-k3", "name": "Kimi K3", "reasoning": false,
                    "reasoning_options": [{"type": "effort", "values": ["low", "high"]}], "tool_call": true}
      }},
     "opencode": {"models": {"big-pickle": {"id": "big-pickle"}}}}
    """.utf8)

    @Test func catalogDescribesEachModel() throws {
        let entries = OpenCodeModelsAPI.parseMetadata(metadata, gateway: .go)
        #expect(entries.count == 5)
        let glm = try #require(entries["glm-5.3"])
        #expect(glm.name == "GLM-5.3" && glm.info.api == .chatCompletions)
        #expect(glm.info.efforts.isEmpty && glm.info.interleavedReasoning) // a toggle is no effort control
        #expect(glm.contextLength == 200000 && glm.maxOutputTokens == 131072)
        #expect(glm.supportsImages == false && glm.supportsTools == true)
        let gpt = try #require(entries["gpt-6-luna"])
        #expect(gpt.info.api == .responses && gpt.info.efforts == [.low, .medium, .high, .xhigh] && gpt.supportsImages == true)
        #expect(entries["claude-haiku-5-5"]?.info.efforts == [.low, .medium, .high, .max])
        #expect(entries["claude-haiku-5-5"]?.info.api == .messages)
        #expect(entries["gemini-4-argon-contributor"]?.info.api == .gemini)
        #expect(entries["kimi-k3"]?.info.efforts == []) // reasoning off: no levels whatever the options say
        #expect(OpenCodeModelsAPI.parseMetadata(metadata, gateway: .console).keys.sorted() == ["big-pickle"])
        #expect(OpenCodeModelsAPI.parseMetadata(Data("[]".utf8), gateway: .go).isEmpty)
    }

    @Test func mergeKeepsTheGatewayOrderAndSetsAsideUnsupportedAPIs() throws {
        let meta = OpenCodeModelsAPI.parseMetadata(metadata, gateway: .go)
        let ids = try OpenCodeModelsAPI.parseIDs(Data("""
        {"object":"list","data":[{"id":"kimi-k3","object":"model"},{"id":"gpt-6-luna"},{"id":"gemini-4-argon-contributor"},
                                 {"id":"claude-haiku-5-5"},{"id":"new-model"},{"id":"kimi-k3"}]}
        """.utf8))
        let merged = OpenCodeModelsAPI.merge(ids: ids, metadata: meta, gateway: .go)
        #expect(merged.supported.map(\.id) == ["kimi-k3", "gpt-6-luna", "new-model"])
        #expect(merged.supported[2].info.api == .chatCompletions && merged.supported[2].name == nil) // unknown: guessed
        #expect(merged.unsupported == ["gemini-4-argon-contributor", "claude-haiku-5-5"])
        // Without the gateway's list, the catalog's own ids.
        #expect(OpenCodeModelsAPI.merge(ids: nil, metadata: meta, gateway: .go).supported.map(\.id) == ["glm-5.3", "gpt-6-luna", "kimi-k3"])
        #expect(throws: APIError.self) { try OpenCodeModelsAPI.parseIDs(Data(#"{"models":[]}"#.utf8)) }
    }

    @Test func modelsOfferTheirOwnEffortLevels() {
        var m = ModelInfo(id: "claude-haiku-5-5", supportsEffort: true)
        m.openCode = OpenCodeModelInfo(api: .messages, efforts: [.low, .medium, .high, .max])
        #expect(m.effortLevels(.modelDecides) == [.low, .medium, .high, .max])
        m.supportsEffort = false
        #expect(m.effortLevels(.modelDecides).isEmpty)
        // A level the model doesn't offer reads as the nearest one below it.
        #expect(Effort.xhigh.resolved(in: [.low, .medium, .high]) == .high)
        #expect(Effort.max.resolved(in: [.low, .medium, .high, .xhigh]) == .xhigh)
        #expect(Effort.low.resolved(in: [.medium, .high]) == .medium)
        #expect(Effort.xhigh.resolved(in: []) == .xhigh)
    }
}

// MARK: - Requests and errors

struct OpenCodeRequestTests {
    private func endpoint(_ id: String, api: OpenCodeModelAPI, efforts: [Effort] = [], interleaved: Bool = false,
                          gateway: OpenCodeGateway = .go) -> Endpoint {
        var model = ModelInfo(id: id, supportsEffort: !efforts.isEmpty)
        model.openCode = OpenCodeModelInfo(api: api, efforts: efforts, interleavedReasoning: interleaved)
        return Endpoint(connectionID: UUID(), connectionName: "OpenCode", baseURL: gateway.baseURL, apiKey: nil,
                        headers: ["User-Agent": "Strata/1.0 (iOS)", "x-opencode-session": "conv-1", "x-opencode-client": "strata"],
                        model: model, kind: .openCode)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func chatCompletionsBodyClampsEffortAndDropsTemplateKwargs() throws {
        var request = ChatRequest(model: "deepseek-v4-pro", messages: [.system("S"), .user("Hi")])
        request.reasoningEffort = "xhigh"
        request.chatTemplateKwargs = .init(enableThinking: false)
        request.tools = ToolDefinition.standard
        let sent = try object(OpenCodeClient.body(request, endpoint: endpoint("deepseek-v4-pro", api: .chatCompletions,
                                                                               efforts: [.low, .medium, .high])))
        #expect(sent["reasoning_effort"] as? String == "high")
        #expect(sent["chat_template_kwargs"] == nil)
        #expect(sent["stream"] as? Bool == true)
        #expect((sent["tools"] as? [[String: Any]])?.count == 3)

        // No levels, or a value that isn't a level (the title request's "none"): no effort at all.
        request.reasoningEffort = "medium"
        #expect(try object(OpenCodeClient.body(request, endpoint: endpoint("glm-5.3", api: .chatCompletions)))["reasoning_effort"] == nil)
        request.reasoningEffort = "none"
        #expect(try object(OpenCodeClient.body(request, endpoint: endpoint("x", api: .chatCompletions, efforts: [.low])))["reasoning_effort"] == nil)
    }

    /// The same request is byte-identical to the one other connections send when nothing needs changing.
    @Test func chatCompletionsBodyKeepsTheAppsBytes() throws {
        let request = ChatRequest(model: "kimi-k3", messages: [.system("S"), .user("Hi")])
        #expect(try OpenCodeClient.body(request, endpoint: endpoint("kimi-k3", api: .chatCompletions)) == request.encoded())
    }

    @Test func interleavedModelsGetTheirReasoningBack() throws {
        var assistant = APIMessage.assistant("", toolCalls: [ToolCall(id: "c1", name: "web_search", arguments: "{}")])
        assistant.reasoningItems = [ReasoningItem(summary: ["Let me search."], encryptedContent: nil)]
        let request = ChatRequest(model: "glm-5.3", messages: [.user("Q"), assistant, .tool(callID: "c1", content: "R")])
        let sent = try object(OpenCodeClient.body(request, endpoint: endpoint("glm-5.3", api: .chatCompletions, interleaved: true)))
        let messages = try #require(sent["messages"] as? [[String: Any]])
        #expect(messages[1]["reasoning_content"] as? String == "Let me search.")
        #expect(messages[0]["reasoning_content"] == nil && messages[2]["reasoning_content"] == nil)
        // Not for other models, and never in the app's own encoding.
        let plain = try object(OpenCodeClient.body(request, endpoint: endpoint("kimi-k3", api: .chatCompletions)))
        #expect((plain["messages"] as? [[String: Any]])?[1]["reasoning_content"] == nil)
        #expect(!String(decoding: try request.encoded(), as: UTF8.self).contains("reasoning_content"))
    }

    @Test func responsesBodySendsFlatToolsAndCalls() throws {
        var request = ChatRequest(model: "gpt-6-luna", messages: [
            .system("S"), .user("Q"), .assistant("", toolCalls: [ToolCall(id: "c1", name: "web_fetch", arguments: "{}")]),
            .tool(callID: "c1", content: "page"),
        ])
        request.tools = ToolDefinition.standard
        request.reasoningEffort = "max"
        let sent = try object(OpenCodeClient.body(request, endpoint: endpoint("gpt-6-luna", api: .responses,
                                                                               efforts: [.low, .medium, .high, .xhigh])))
        #expect(sent["instructions"] as? String == "S")
        #expect(sent["store"] as? Bool == false && sent["stream"] as? Bool == true)
        #expect((sent["reasoning"] as? [String: Any])?["effort"] as? String == "xhigh")
        #expect(sent["include"] as? [String] == ["reasoning.encrypted_content"])
        let tools = try #require(sent["tools"] as? [[String: Any]])
        #expect(tools.map { $0["type"] as? String } == ["function", "function", "function"])
        #expect(tools.map { $0["name"] as? String } == ["web_search", "web_fetch", "run_plugin"])
        let input = try #require(sent["input"] as? [[String: Any]])
        let call = try #require(input.first { $0["type"] as? String == "function_call" })
        #expect(call["name"] as? String == "web_fetch" && call["namespace"] == nil && call["call_id"] as? String == "c1")

        // A model without levels gets no reasoning block.
        let none = try object(OpenCodeClient.body(request, endpoint: endpoint("grok-4.7", api: .responses)))
        #expect(none["reasoning"] == nil && none["include"] == nil)
    }

    @Test func chatGPTResponsesStillUseTheNamespace() throws {
        var request = ChatRequest(model: "gpt", messages: [.user("Q"), .assistant("", toolCalls: [ToolCall(id: "c", name: "web_search", arguments: "{}")])])
        request.tools = ToolDefinition.standard
        let sent = try object(ResponsesRequest(request, reasoning: false).encoded())
        #expect((sent["tools"] as? [[String: Any]])?.first?["type"] as? String == "namespace")
        #expect((sent["input"] as? [[String: Any]])?.last?["namespace"] as? String == "strata")
    }

    @Test func urlRequestCarriesTheTokenAndSessionHeaders() {
        let ep = endpoint("gpt-6-luna", api: .responses)
        let req = OpenCodeClient.urlRequest(endpoint: ep, token: "tok", body: Data("{}".utf8))
        #expect(req.url?.absoluteString == "https://opencode.ai/inference/go/v1/responses")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "x-opencode-session") == "conv-1")
        #expect(req.value(forHTTPHeaderField: "x-opencode-client") == "strata")
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "Strata/1.0 (iOS)")
        #expect(req.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func gatewayErrorsBecomeClearMessages() {
        func message(_ status: Int, _ body: String, _ gateway: OpenCodeGateway = .go) -> String {
            guard case .http(_, let m) = OpenCodeErrorMapper.error(status: status, data: Data(body.utf8), gateway: gateway) else { return "" }
            return m
        }
        #expect(message(400, #"{"type":"error","error":{"type":"FreeTierError","message":"OpenCode's free tier can only be used from within OpenCode."}}"#)
                .contains("free models"))
        #expect(message(401, #"{"error":{"type":"server_error","message":"Upstream request failed: Invalid credential"}}"#)
                .contains("Sign in again"))
        #expect(message(403, #"{"error":{"type":"server_error","message":"Go subscription required"}}"#).contains("no Go subscription"))
        #expect(message(403, #"{"error":{"type":"Forbidden"}}"#).contains("Go subscription"))
        #expect(message(429, #"{"error":{"type":"RateLimitError","message":"slow down"}}"#).contains("Go usage limit"))
        #expect(message(400, #"{"error":{"message":"Monthly usage limit reached"}}"#, .console).contains("usage or spending limit"))
        #expect(message(402, #"{"error":{"message":"Insufficient balance"}}"#, .console).contains("no credit"))
        // Anything else keeps the server's words (a context-length error must stay recognizable).
        #expect(message(400, #"{"error":{"message":"This model's maximum context length is 200000 tokens"}}"#)
                == "This model's maximum context length is 200000 tokens")
        #expect(message(500, "plain text") == "plain text")
    }
}
