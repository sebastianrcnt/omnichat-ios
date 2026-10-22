import Testing
import Foundation
import SwiftData
@testable import Strata

/// Serves a canned `/models` list for `ConnectionStore.refreshModels`.
private final class ModelsStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var ids: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = try! JSONSerialization.data(withJSONObject: ["data": Self.ids.map { ["id": $0] }])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct ModelAliasTests {
    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")! }

    @Test func normalizationTrimsCapsAndTreatsBlankAsNone() {
        #expect(ModelAlias.normalized(nil) == nil)
        #expect(ModelAlias.normalized("") == nil)
        #expect(ModelAlias.normalized("   \n\t ") == nil)
        #expect(ModelAlias.normalized("  Flash  ") == "Flash")
        let long = String(repeating: "x", count: ModelAlias.maxLength + 20)
        #expect(ModelAlias.normalized(long)?.count == ModelAlias.maxLength)
    }

    @Test func resolvesAliasOrFallsBackToID() {
        var c = Connection(name: "Local", baseURL: "http://localhost/v1", models: [ModelInfo(id: "qwen3.8-flash-next")])
        #expect(c.displayName(forModel: "qwen3.8-flash-next") == "qwen3.8-flash-next")
        #expect(c.alias(forModel: "qwen3.8-flash-next") == nil)
        c.setAlias(" Flash ", forModel: "qwen3.8-flash-next")
        #expect(c.displayName(forModel: "qwen3.8-flash-next") == "Flash")
        #expect(c.alias(forModel: "qwen3.8-flash-next") == "Flash")
        #expect(c.displayName(forModel: "other") == "other")
    }

    @Test func emptyAliasResets() {
        let store = ConnectionStore(defaults: freshDefaults(), keys: InMemoryKeyStore())
        store.testGateway()
        store.setModelAlias("Flash", connectionID: Connection.testID, modelID: "m")
        #expect(store.displayName(connectionID: Connection.testID, modelID: "m") == "Flash")
        store.setModelAlias("   ", connectionID: Connection.testID, modelID: "m")
        #expect(store.displayName(connectionID: Connection.testID, modelID: "m") == "m")
        #expect(store.connection(Connection.testID)?.modelAliases.isEmpty == true)
        store.setModelAlias("Flash", connectionID: Connection.testID, modelID: "m")
        store.setModelAlias(nil, connectionID: Connection.testID, modelID: "m")
        #expect(store.connection(Connection.testID)?.alias(forModel: "m") == nil)
        #expect(store.displayName(connectionID: Connection.testID, modelID: nil) == nil)
    }

    @Test func aliasesPersistAcrossRelaunchPerConnection() throws {
        let defaults = freshDefaults()
        let keys = InMemoryKeyStore()
        let store = ConnectionStore(defaults: defaults, keys: keys)
        store.testGateway()
        let other = Connection(name: "Other", baseURL: "http://localhost/v1", models: [ModelInfo(id: "m")])
        store.upsert(other)
        store.setModelAlias("Strata M", connectionID: Connection.testID, modelID: "m")
        store.setModelAlias("Other M", connectionID: other.id, modelID: "m")

        let reloaded = ConnectionStore(defaults: defaults, keys: keys)
        #expect(reloaded.displayName(connectionID: Connection.testID, modelID: "m") == "Strata M")
        #expect(reloaded.displayName(connectionID: other.id, modelID: "m") == "Other M")
    }

    @Test func oldStoredConnectionsDecodeWithoutAliases() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","name":"x","baseURL":"https://x","models":[{"id":"m"}]}]"#
        let decoded = try JSONDecoder().decode([Connection].self, from: Data(json.utf8))
        #expect(decoded.first?.modelAliases.isEmpty == true)
    }

    @Test func refreshingTheModelListKeepsAliases() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelsStub.self]
        let store = ConnectionStore(defaults: freshDefaults(), keys: InMemoryKeyStore(), session: URLSession(configuration: config))
        let conn = Connection(name: "Local", baseURL: "http://localhost:9/v1")
        store.upsert(conn)

        ModelsStub.ids = ["qwen3.8-flash-next", "b"]
        try await store.refreshModels(for: conn.id)
        store.setModelAlias("Flash", connectionID: conn.id, modelID: "qwen3.8-flash-next")

        ModelsStub.ids = ["b", "qwen3.8-flash-next", "c"]
        try await store.refreshModels(for: conn.id)
        #expect(store.displayName(connectionID: conn.id, modelID: "qwen3.8-flash-next") == "Flash")

        // Even a model that drops out of the list and comes back keeps its name.
        ModelsStub.ids = ["b"]
        try await store.refreshModels(for: conn.id)
        ModelsStub.ids = ["b", "qwen3.8-flash-next"]
        try await store.refreshModels(for: conn.id)
        #expect(store.connection(conn.id)?.models.map(\.id) == ["b", "qwen3.8-flash-next"])
        #expect(store.displayName(connectionID: conn.id, modelID: "qwen3.8-flash-next") == "Flash")
    }

    @Test func endpointKeepsTheRealModelID() throws {
        let store = ConnectionStore(defaults: freshDefaults(), keys: InMemoryKeyStore())
        var strata = store.testGateway()
        strata.models = [ModelInfo(id: "qwen3.8-flash-next")]
        store.upsert(strata)
        store.setModelAlias("Flash", connectionID: Connection.testID, modelID: "qwen3.8-flash-next")
        let endpoint = try #require(store.endpoint(connectionID: Connection.testID, modelID: "qwen3.8-flash-next"))
        #expect(endpoint.model.id == "qwen3.8-flash-next")
    }

    /// Sends one message and returns the encoded request body.
    private func sentBody(alias: String?) async throws -> (ChatRequest, String) {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let defaults = freshDefaults()
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.testID)
        var strata = connections.testGateway()
        strata.models = [ModelInfo(id: "qwen3.8-flash-next", supportsTools: true)]
        connections.upsert(strata)
        connections.setModelAlias(alias, connectionID: Connection.testID, modelID: "qwen3.8-flash-next")
        let streamer = ProgrammableStreamer([([ChatDelta(content: "ok")], .finish)])
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults),
                                        streamer: streamer, tools: FakeTools())
        let conversation = Conversation(connectionID: Connection.testID, modelID: "qwen3.8-flash-next", effort: .medium)
        context.insert(conversation)
        controller.send(text: "hi", images: [], conversation: conversation, context: context)
        await controller.waitUntilIdle()
        #expect(conversation.modelID == "qwen3.8-flash-next")
        let request = try #require(streamer.requests.first)
        return (request, String(decoding: try request.encoded(), as: UTF8.self))
    }

    @Test func requestBodyUsesTheRealIDAndIsUnchangedByAnAlias() async throws {
        let (plainRequest, plain) = try await sentBody(alias: nil)
        let (aliasedRequest, aliased) = try await sentBody(alias: "My Flash Alias")
        #expect(aliasedRequest.model == "qwen3.8-flash-next")
        #expect(!aliased.contains("My Flash Alias"))
        #expect(plainRequest.model == aliasedRequest.model)
        #expect(try String(decoding: ChatRequest.encoder.encode(plainRequest.messages), as: UTF8.self)
                == String(decoding: ChatRequest.encoder.encode(aliasedRequest.messages), as: UTF8.self))
        #expect(try String(decoding: ChatRequest.encoder.encode(plainRequest.tools), as: UTF8.self)
                == String(decoding: ChatRequest.encoder.encode(aliasedRequest.tools), as: UTF8.self))
        #expect(plain == aliased)
    }
}
