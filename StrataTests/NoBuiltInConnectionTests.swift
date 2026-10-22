import Testing
import Foundation
@testable import Strata

/// Serves a fixed `/models` body to `ConnectionStore.refreshModels`.
private final class CapabilityModelsStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: [String: Any] = ["data": []]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = try! JSONSerialization.data(withJSONObject: Self.body)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The connection that used to be built in becomes an ordinary one, and nothing is added in its place.
@MainActor
struct BuiltInConnectionMigrationTests {
    private let legacyID = LegacyBuiltInConnection.id

    private func defaults(_ json: String) -> UserDefaults {
        let d = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        d.set(Data(json.utf8), forKey: "connections.v1")
        return d
    }

    /// As an older version saved it: no `supportsResumable` (it defaulted to on for this id), no capability defaults,
    /// models with the effort the app gave them.
    private var legacyJSON: String {
        """
        [{"id":"\(legacyID.uuidString)","name":"Strata","baseURL":"https://gateway.invalid/v1","customHeaders":"",
          "models":[{"id":"qwen","supportsImages":true,"supportsEffort":true,"supportsTools":true,"isManual":false},
                    {"id":"plain","supportsImages":false,"supportsEffort":false,"supportsTools":true,"isManual":false}],
          "modelAliases":{"qwen":"Qwen"}},
         {"id":"0F6A1A52-1111-4000-8000-000000000002","name":"Local","baseURL":"http://192.168.0.2:8080/v1","models":[]}]
        """
    }

    @Test func theOldConnectionStaysWithEverythingItHad() throws {
        let d = defaults(legacyJSON)
        let keys = InMemoryKeyStore()
        try keys.setKey("saved-key", for: legacyID)
        let store = ConnectionStore(defaults: d, keys: keys)
        #expect(store.connections.map(\.id) == [legacyID, UUID(uuidString: "0F6A1A52-1111-4000-8000-000000000002")!])
        let c = try #require(store.connection(legacyID))
        #expect(c.name == "Strata")
        #expect(c.baseURL == "https://gateway.invalid/v1")
        #expect(store.apiKey(for: legacyID) == "saved-key")
        #expect(c.models.map(\.id) == ["qwen", "plain"])
        #expect(c.alias(forModel: "qwen") == "Qwen")
        // What it did as the built-in connection is now its own settings.
        #expect(c.imagesByDefault && c.effortByDefault && c.supportsResumable)
        #expect(c.models[0].supportsImages && c.models[0].supportsEffort)
        #expect(!c.models[1].supportsEffort && c.models[1].supportsEffortUserSet) // kept as it was
        #expect(store.endpoint(connectionID: legacyID, modelID: "qwen")?.supportsResumable == true)
        // Other connections are untouched.
        let local = try #require(store.connections.last)
        #expect(!local.imagesByDefault && !local.effortByDefault && !local.supportsResumable)
        #expect(d.bool(forKey: ConnectionStore.builtInMigrationKey))
    }

    @Test func resumableRepliesTurnedOffStayOff() throws {
        let json = legacyJSON.replacingOccurrences(of: #""customHeaders":"","#, with: #""customHeaders":"","supportsResumable":false,"#)
        let store = ConnectionStore(defaults: defaults(json), keys: InMemoryKeyStore())
        let c = try #require(store.connection(legacyID))
        #expect(!c.supportsResumable)
        #expect(c.imagesByDefault && c.effortByDefault)
    }

    @Test func itRunsOnceAndTheConnectionCanBeChangedOrDeleted() throws {
        let d = defaults(legacyJSON)
        let keys = InMemoryKeyStore()
        try keys.setKey("saved-key", for: legacyID)
        var store = ConnectionStore(defaults: d, keys: keys)
        var c = try #require(store.connection(legacyID))
        c.imagesByDefault = false
        c.supportsResumable = false
        store.upsert(c)
        store = ConnectionStore(defaults: d, keys: keys) // relaunch: the user's changes stay
        c = try #require(store.connection(legacyID))
        #expect(!c.imagesByDefault && !c.supportsResumable && c.effortByDefault)
        store.delete(legacyID)
        #expect(keys.key(for: legacyID) == nil)
        store = ConnectionStore(defaults: d, keys: keys)
        #expect(store.connection(legacyID) == nil) // never re-added
        #expect(store.connections.count == 1)
    }

    @Test func aFreshInstallHasNoConnections() {
        let d = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let store = ConnectionStore(defaults: d, keys: InMemoryKeyStore())
        #expect(store.connections.isEmpty)
        #expect(ConnectionStore(defaults: d, keys: InMemoryKeyStore()).connections.isEmpty)
        #expect(ModelSelection.resolve(connections: store.connections, preferredConnectionID: nil, preferredModelID: nil) == nil)
    }

    @Test func aKeylessServerIsNotBlockedByTheApp() throws {
        let store = ConnectionStore(defaults: defaults(legacyJSON), keys: InMemoryKeyStore())
        let endpoint = try #require(store.endpoint(connectionID: legacyID, modelID: "qwen"))
        #expect(!ChatController.needsKey(endpoint, connections: store)) // the server says if it wants a key
    }
}

/// Capabilities read from `/models`, and how they merge with the connection's settings and the user's choices.
@MainActor
@Suite(.serialized)
struct ModelCapabilityDetectionTests {
    private func entry(_ item: [String: Any]) throws -> ModelsAPI.Entry {
        let data = try JSONSerialization.data(withJSONObject: ["data": [item.merging(["id": "m"]) { a, _ in a }]])
        return try #require(try ModelsAPI.parse(data).first)
    }

    @Test func readsTheKnownShapes() throws {
        // LiteLLM-style flags
        var e = try entry(["supports_vision": true, "supports_reasoning_effort": false])
        #expect(e.supportsImages == true && e.supportsEffort == false)
        // A capabilities object
        e = try entry(["capabilities": ["vision": false, "reasoning_effort": true]])
        #expect(e.supportsImages == false && e.supportsEffort == true)
        // A capabilities list (Ollama style): complete, so a missing name means no
        e = try entry(["capabilities": ["completion", "vision", "tools"]])
        #expect(e.supportsImages == true && e.supportsEffort == false)
        e = try entry(["capabilities": ["completion", "Thinking"]])
        #expect(e.supportsImages == false && e.supportsEffort == true)
        // OpenRouter
        e = try entry(["architecture": ["input_modalities": ["text", "image"]], "supported_parameters": ["tools", "reasoning"]])
        #expect(e.supportsImages == true && e.supportsEffort == true)
        e = try entry(["architecture": ["modality": "text->text"], "supported_parameters": ["tools", "temperature"]])
        #expect(e.supportsImages == false && e.supportsEffort == false)
        e = try entry(["supported_parameters": ["reasoning_effort"]])
        #expect(e.supportsEffort == true && e.supportsImages == nil)
    }

    @Test func unknownShapesSayNothing() throws {
        for item: [String: Any] in [[:], ["capabilities": "vision"], ["capabilities": ["vision": "yes"]],
                                    ["supports_vision": "true"], ["architecture": "text+image"], ["supported_parameters": "reasoning"],
                                    ["reasoning": ["enabled": true]]] {
            let e = try entry(item)
            #expect(e.supportsImages == nil && e.supportsEffort == nil)
        }
    }

    private func store(_ connection: Connection) -> ConnectionStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapabilityModelsStub.self]
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!,
                                    keys: InMemoryKeyStore(), session: URLSession(configuration: config))
        store.upsert(connection)
        return store
    }

    @Test func detectionFillsNewModelsAndTheConnectionDefaultsTheRest() async throws {
        var c = Connection(name: "Router", baseURL: "https://router.invalid/v1")
        c.imagesByDefault = true
        let store = store(c)
        CapabilityModelsStub.body = ["data": [
            ["id": "said-no", "architecture": ["input_modalities": ["text"]], "supported_parameters": ["tools"]],
            ["id": "said-yes", "supports_vision": true, "supports_reasoning_effort": true],
            ["id": "silent"]]]
        try await store.refreshModels(for: c.id)
        let models = try #require(store.connection(c.id)).models
        #expect(models.map(\.supportsImages) == [false, true, true])
        #expect(models.map(\.supportsEffort) == [false, true, false])
    }

    @Test func theUsersChoicesWinOverDetection() async throws {
        var images = ModelInfo(id: "a", supportsImages: false)
        images.supportsImagesUserSet = true
        var effort = ModelInfo(id: "b", supportsEffort: false)
        effort.supportsEffortUserSet = true
        let detected = ModelInfo(id: "c", supportsImages: false, supportsEffort: false)
        let c = Connection(name: "Router", baseURL: "https://router.invalid/v1", models: [images, effort, detected])
        let store = store(c)
        CapabilityModelsStub.body = ["data": ["a", "b", "c"].map { ["id": $0, "supports_vision": true, "supports_reasoning_effort": true] }]
        try await store.refreshModels(for: c.id)
        let models = try #require(store.connection(c.id)).models
        #expect(models.map(\.supportsImages) == [false, true, true])
        #expect(models.map(\.supportsEffort) == [true, false, true])
    }

    @Test func modelsSavedBeforeEffortDetectionKeepTheirEffort() throws {
        let saved = #"{"id":"m","supportsImages":false,"supportsEffort":false,"supportsTools":true,"isManual":false}"#
        #expect(try JSONDecoder().decode(ModelInfo.self, from: Data(saved.utf8)).supportsEffortUserSet)
        let roundTrip = try JSONDecoder().decode(ModelInfo.self, from: JSONEncoder().encode(ModelInfo(id: "n")))
        #expect(!roundTrip.supportsEffortUserSet)
    }

    @Test func theConnectionsAPIPickAppliesToModelsWithoutTheirOwn() {
        var c = Connection(name: "R", baseURL: "https://r.invalid/v1")
        #expect(c.chatAPI(forModel: "m") == .chatCompletions && c.pickedAPI(forModel: "m") == nil)
        c.defaultChatAPI = .responses
        #expect(c.chatAPI(forModel: "m") == .responses && c.pickedAPI(forModel: "m") == .responses)
        c.setAPIOverride(.chatCompletions, forModel: "m")
        #expect(c.chatAPI(forModel: "m") == .chatCompletions)
        let decoded = try? JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(c))
        #expect(decoded?.defaultChatAPI == .responses)
    }
}

struct AddConnectionLinkTests {
    private func parse(_ s: String) -> Result<AddConnectionLink, AddConnectionLink.Failure> {
        AddConnectionLink.parse(URL(string: s)!)
    }

    @Test func readsAFullLink() throws {
        let link = try parse("openchat://add-connection?name=My%20Server&url=https%3A%2F%2Fllm.example.com%2Fv1%2F&api=openai&images=1&resumable=1").get()
        #expect(link.name == "My Server")
        #expect(link.baseURL.absoluteString == "https://llm.example.com/v1")
        #expect(link.api == nil && link.images && link.resumable && !link.effort && !link.droppedKey)
        #expect(!link.isPlainHTTP && !link.isPrivateAddress)
        let c = link.makeConnection()
        #expect(c.name == "My Server" && c.baseURL == "https://llm.example.com/v1" && c.kind == .openAICompatible)
        #expect(c.imagesByDefault && !c.effortByDefault && c.supportsResumable && c.defaultChatAPI == nil)
        #expect(c.models.isEmpty)
    }

    @Test func defaultsAndOptions() throws {
        let link = try parse("OpenChat://add-connection?url=https://api.example.org/v1&api=responses&effort=true").get()
        #expect(link.name == "api.example.org") // no name: the host
        #expect(link.api == .responses && link.effort && !link.images && !link.resumable)
        #expect(link.makeConnection().defaultChatAPI == .responses)
    }

    @Test func aKeyIsNeverTaken() throws {
        let link = try parse("openchat://add-connection?url=https://x.example/v1&key=sk-secret").get()
        #expect(link.droppedKey)
        let c = link.makeConnection()
        let encoded = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(!encoded.contains("sk-secret"))
        // Credentials inside the URL are refused too.
        #expect(parse("openchat://add-connection?url=https%3A%2F%2Fuser%3Apass%40x.example%2Fv1") == .failure(.credentialsInURL))
        #expect(parse("openchat://add-connection?url=https%3A%2F%2Fx.example%2Fv1%3Fapi_key%3Dsecret") == .failure(.credentialsInURL))
    }

    @Test func flagsPlainHTTPAndPrivateAddresses() throws {
        let lan = try parse("openchat://add-connection?url=http://192.168.1.20:11434/v1").get()
        #expect(lan.isPlainHTTP && lan.isPrivateAddress)
        let local = try parse("openchat://add-connection?url=http://localhost:1234/v1").get()
        #expect(local.isPrivateAddress)
        let mdns = try parse("openchat://add-connection?url=https://studio.local/v1").get()
        #expect(!mdns.isPlainHTTP && mdns.isPrivateAddress)
        let publicHTTP = try parse("openchat://add-connection?url=http://203.0.113.9/v1").get()
        #expect(publicHTTP.isPlainHTTP)
    }

    @Test func rejectsWhatItCantUse() {
        #expect(parse("openchat://add-connection?name=x") == .failure(.missingURL))
        #expect(parse("openchat://add-connection?url=") == .failure(.missingURL))
        #expect(parse("openchat://add-connection?url=ftp://x.example/v1") == .failure(.invalidURL))
        #expect(parse("openchat://add-connection?url=javascript:alert(1)") == .failure(.invalidURL))
        #expect(parse("openchat://add-connection?url=file:///etc/passwd") == .failure(.invalidURL))
        #expect(parse("openchat://add-connection?url=not%20a%20url") == .failure(.invalidURL))
        #expect((try? parse("openchat://add-connection?url=https://x.example/v1&api=anthropic").get())?.anthropic == true)
        #expect(parse("openchat://add-connection?url=https://x.example/v1&api=grpc") == .failure(.unsupportedAPI("grpc")))
        #expect(parse("openchat://other?url=https://x.example/v1") == .failure(.notAnAddLink))
        #expect(parse("https://add-connection?url=https://x.example/v1") == .failure(.notAnAddLink))
    }

    @Test func presetsPrefillTheEditors() throws {
        // The OpenAI-compatible services are the presets of the built-in connections package.
        let presets = try #require(PackageStore.bundled().first { $0.manifest.id == BuiltInPackages.connections }).manifest.connections
        #expect(presets.map(\.name) == ["OpenAI", "OpenRouter", "Groq", "Ollama", "LM Studio"])
        let byName = Dictionary(uniqueKeysWithValues: presets.map { ($0.name, $0) })
        #expect(byName["Ollama"]?.makeConnection().baseURL == "http://localhost:11434/v1")
        #expect(byName["LM Studio"]?.makeConnection().baseURL == "http://localhost:1234/v1")
        #expect(byName["OpenAI"]?.makeConnection().baseURL == "https://api.openai.com/v1")
        #expect(byName["Ollama"]?.isLocal == true && byName["OpenAI"]?.isLocal == false)
        #expect(byName["Groq"]?.subtitleText == "API key from console.groq.com")
        #expect(byName["Ollama"]?.subtitleText.contains("11434") == true)
        #expect(ConnectionPreset.chatGPT.makeConnection().isChatGPT)
        #expect(ConnectionPreset.openCode.makeConnection().isOpenCode)
        #expect(ConnectionPreset.custom.makeConnection().baseURL == "https://")
        for c in ConnectionPreset.allCases.map({ $0.makeConnection() }) + presets.map({ $0.makeConnection() }) {
            #expect(!c.supportsResumable && !c.imagesByDefault && !c.effortByDefault)
            #expect(c.models.isEmpty)
        }
    }
}
