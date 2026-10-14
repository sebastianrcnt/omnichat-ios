import Testing
import Foundation
@testable import Strata

@MainActor
struct ChatGPTConnectionTests {
    /// A connection saved before `kind` existed.
    private let legacyJSON = """
    [{"id":"5712A7A0-0000-4000-8000-000000000001","name":"Strata","baseURL":"https://llm-api.coolservices.cc/v1",
      "customHeaders":"","models":[{"id":"qwen","supportsImages":true,"supportsEffort":true,"supportsTools":true,"isManual":false}],
      "supportsResumable":true},
     {"id":"0F6A1A52-1111-4000-8000-000000000002","name":"Local","baseURL":"http://192.168.0.2:8080/v1","models":[]}]
    """

    @Test func oldConnectionsDecodeAsOpenAICompatible() throws {
        let decoded = try JSONDecoder().decode([Connection].self, from: Data(legacyJSON.utf8))
        #expect(decoded.map(\.kind) == [.openAICompatible, .openAICompatible])
        #expect(decoded[0].models[0].fetchedDisplayName == nil)
        #expect(decoded[0].supportsResumable)
    }

    @Test func storeLoadsOldConnections() throws {
        let defaults = UserDefaults(suiteName: "conn.\(UUID().uuidString)")!
        defaults.set(Data(legacyJSON.utf8), forKey: "connections.v1")
        let store = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore(), chatGPT: ChatGPTAuth(store: .inMemory()))
        #expect(store.connections.count == 2)
        #expect(store.connections.allSatisfy { !$0.isChatGPT })
        #expect(store.endpoint(connectionID: store.connections[1].id, modelID: "x")?.kind == .openAICompatible)
    }

    @Test func chatGPTConnectionRoundTripsAndRoutesToResponses() throws {
        var c = Connection.chatGPT()
        c.models = [ModelInfo(id: "gpt-6.1-sol")]
        c.models[0].fetchedDisplayName = "GPT-6.1 Sol"
        let decoded = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(c))
        #expect(decoded.kind == .chatGPT)
        #expect(!decoded.supportsResumable)
        #expect(decoded.displayName(forModel: "gpt-6.1-sol") == "GPT-6.1 Sol")
        var aliased = decoded
        aliased.setAlias("Sol", forModel: "gpt-6.1-sol")
        #expect(aliased.displayName(forModel: "gpt-6.1-sol") == "Sol")

        let auth = ChatGPTAuth(store: .inMemory())
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "conn.\(UUID().uuidString)")!, keys: InMemoryKeyStore(), chatGPT: auth)
        store.upsert(decoded)
        let endpoint = try #require(store.endpoint(connectionID: decoded.id, modelID: "gpt-6.1-sol"))
        #expect(endpoint.kind == .chatGPT)
        #expect(endpoint.requestURL.absoluteString == "https://api.openai.com/v1/responses")
        #expect(endpoint.apiKey == nil && endpoint.headers.isEmpty && !endpoint.supportsResumable)

        // Signed out: the chat asks for a sign-in instead of sending.
        #expect(ChatController.needsKey(endpoint, connections: store))
        try auth.store.setTokens(ChatGPTTokens(accessToken: "a", refreshToken: "r", idToken: nil, expiresAt: .distantFuture,
                                               scopes: [ChatGPTOAuth.planScope], savedAt: .now), decoded.id)
        #expect(!ChatController.needsKey(endpoint, connections: store))
        #expect(APIError.chatGPTSignInRequired(connection: "ChatGPT").needsSettings)

        // Deleting the connection forgets the account.
        try auth.store.setRegistration(ChatGPTRegistration(clientID: "oaiapp_1"), decoded.id)
        store.delete(decoded.id)
        #expect(auth.store.registration(decoded.id) == nil && auth.store.tokens(decoded.id) == nil)
    }

    @Test func newChatGPTModelsDefaultToImagesEffortAndTools() {
        let m = Connection.chatGPT().defaultModel(id: "gpt-x", fetchedContextLength: nil)
        #expect(m.supportsImages && m.supportsEffort && m.supportsTools)
        let local = Connection(name: "L", baseURL: "http://x").defaultModel(id: "m", fetchedContextLength: nil)
        #expect(!local.supportsImages && !local.supportsEffort)
    }

    @Test func modelCatalogKeepsListedModelsInOrder() throws {
        let data = Data("""
        {"models":[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","visibility":"list","context_window":400000,"input_modalities":["text","image"]},
                   {"slug":"internal","display_name":"Hidden","visibility":"hide"},
                   {"slug":"gpt-6-astra","display_name":"GPT-6 Astra","visibility":"list"}]}
        """.utf8)
        let entries = try ChatGPTModelsAPI.parse(data)
        #expect(entries == [.init(slug: "gpt-6.1-sol", displayName: "GPT-6.1 Sol", contextLength: 400000, supportsImages: true),
                            .init(slug: "gpt-6-astra", displayName: "GPT-6 Astra", contextLength: nil, supportsImages: nil)])
        #expect(throws: APIError.self) { try ChatGPTModelsAPI.parse(Data(#"{"data":[]}"#.utf8)) }
    }
}
