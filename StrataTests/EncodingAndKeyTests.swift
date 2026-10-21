import Testing
import Foundation
@testable import Strata

struct EncodingTests {
    private func json(_ message: APIMessage) throws -> [String: Any] {
        let data = try ChatRequest.encoder.encode(message)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func imagePartEncodesAsDataURL() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let msg = APIMessage.user(parts: [.jpegDataURL(jpeg), .text("What is this?")])
        let obj = try json(msg)
        #expect(obj["role"] as? String == "user")
        let parts = try #require(obj["content"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts[0]["type"] as? String == "image_url")
        let url = (parts[0]["image_url"] as? [String: Any])?["url"] as? String
        #expect(url == "data:image/jpeg;base64," + jpeg.base64EncodedString())
        #expect(parts[1]["type"] as? String == "text")
        #expect(parts[1]["text"] as? String == "What is this?")
    }

    @Test func plainUserMessageEncodesStringContent() throws {
        let obj = try json(.user("hi"))
        #expect(obj["content"] as? String == "hi")
    }

    @Test func assistantToolCallsAndToolMessage() throws {
        let call = ToolCall(id: "c1", name: "web_search", arguments: "{\"query\":\"x\"}")
        let a = try json(.assistant("", toolCalls: [call]))
        let calls = try #require(a["tool_calls"] as? [[String: Any]])
        #expect(calls[0]["id"] as? String == "c1")
        #expect(calls[0]["type"] as? String == "function")
        let fn = try #require(calls[0]["function"] as? [String: Any])
        #expect(fn["name"] as? String == "web_search")
        #expect(fn["arguments"] as? String == "{\"query\":\"x\"}")
        let t = try json(.tool(callID: "c1", content: "result"))
        #expect(t["role"] as? String == "tool")
        #expect(t["tool_call_id"] as? String == "c1")
    }

    @Test func requestShape() throws {
        var req = ChatRequest(model: "m", messages: [.user("hi")])
        req.reasoningEffort = "high"
        req.tools = ToolDefinition.standard
        let obj = try JSONSerialization.jsonObject(with: req.encoded()) as! [String: Any]
        #expect(obj["stream"] as? Bool == true)
        #expect((obj["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        #expect(obj["reasoning_effort"] as? String == "high")
        #expect((obj["tools"] as? [[String: Any]])?.count == 3)
        #expect(obj["tool_choice"] == nil)
    }

    @Test func toolDefinitionsAreByteStable() throws {
        let a = try ChatRequest.encoder.encode(ToolDefinition.standard)
        let b = try ChatRequest.encoder.encode([ToolDefinition.webSearch, ToolDefinition.webFetch, ToolDefinition.runPlugin])
        #expect(a == b)
        let text = String(decoding: a, as: UTF8.self)
        #expect(text.hasPrefix("[{\"function\":{\"description\":"))
        #expect(text.contains("\"name\":\"web_search\""))
        #expect(text.contains("\"name\":\"web_fetch\""))
    }

    @Test func effortCaps() {
        #expect(Effort.allCases.map(\.thinkingTokenCap) == [1024, 4096, 8192, 16384, nil])
        #expect(Effort.allCases.map(\.apiValue) == ["low", "medium", "high", "xhigh", "max"])
    }
}

struct KeyStorageTests {
    @Test func inMemoryKeysAreIsolatedPerConnection() throws {
        let store = InMemoryKeyStore()
        let a = UUID(), b = UUID()
        try store.setKey("key-a", for: a)
        try store.setKey("key-b", for: b)
        #expect(store.key(for: a) == "key-a")
        #expect(store.key(for: b) == "key-b")
        try store.setKey(nil, for: a)
        #expect(store.key(for: a) == nil)
        #expect(store.key(for: b) == "key-b")
    }

    @Test func keychainKeysAreIsolatedPerConnection() throws {
        let store = KeychainKeyStore(service: "cc.coolservices.strata.tests.\(UUID().uuidString)")
        let a = UUID(), b = UUID()
        defer { try? store.setKey(nil, for: a); try? store.setKey(nil, for: b) }
        try store.setKey("  secret-a \n", for: a)
        try store.setKey("secret-b", for: b)
        #expect(store.key(for: a) == "secret-a")
        #expect(store.key(for: b) == "secret-b")
        try store.setKey("rotated", for: a)
        #expect(store.key(for: a) == "rotated")
        #expect(store.key(for: b) == "secret-b")
        try store.setKey("", for: a)
        #expect(store.key(for: a) == nil)
    }

    @MainActor
    @Test func connectionStoreKeepsKeysPerConnectionAndDeletesThem() throws {
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let keys = InMemoryKeyStore()
        let store = ConnectionStore(defaults: defaults, keys: keys)
        #expect(store.connections.isEmpty) // nothing is built in
        store.testGateway()
        let extra = Connection(name: "Other", baseURL: "http://localhost:1234/v1/", customHeaders: "X-Org: acme\nbad line")
        store.upsert(extra)
        try store.setAPIKey("one", for: Connection.testID)
        try store.setAPIKey("two", for: extra.id)
        #expect(store.apiKey(for: Connection.testID) == "one")
        #expect(store.apiKey(for: extra.id) == "two")
        let endpoint = try #require(store.endpoint(connectionID: extra.id, modelID: "m"))
        #expect(endpoint.apiKey == "two")
        #expect(endpoint.headers == ["X-Org": "acme"])
        #expect(endpoint.baseURL.absoluteString == "http://localhost:1234/v1")
        store.delete(extra.id)
        #expect(keys.key(for: extra.id) == nil)
        #expect(store.apiKey(for: Connection.testID) == "one")
        // Persisted
        let reloaded = ConnectionStore(defaults: defaults, keys: keys)
        #expect(reloaded.connections.map(\.id) == [Connection.testID])
        // Every connection can be deleted, and nothing comes back in its place.
        reloaded.delete(Connection.testID)
        #expect(reloaded.connections.isEmpty)
        #expect(keys.key(for: Connection.testID) == nil)
        #expect(ConnectionStore(defaults: defaults, keys: keys).connections.isEmpty)
    }

    @Test func modelCapabilityDefaultsAndContextResolution() {
        var configured = Connection.testGateway()
        configured.imagesByDefault = true
        configured.effortByDefault = true
        let d = configured.defaultModel(id: "m", fetchedContextLength: nil)
        #expect(d.supportsEffort && d.supportsImages)
        // What /models says wins over the connection's defaults.
        let said = configured.defaultModel(id: "m", fetchedContextLength: nil, fetchedImages: false, fetchedEffort: false)
        #expect(!said.supportsEffort && !said.supportsImages)
        let other = Connection(name: "x", baseURL: "https://x")
        let m = other.defaultModel(id: "m", fetchedContextLength: 1000)
        #expect(!m.supportsEffort && !m.supportsImages && m.supportsTools)
        #expect(m.effectiveContextLength(default: 262_144) == 1000)
        var o = m; o.contextLength = 5
        #expect(o.effectiveContextLength(default: 262_144) == 5)
        #expect(ModelInfo(id: "z").effectiveContextLength(default: 262_144) == 262_144)
    }
}
