import Testing
import Foundation
@testable import Strata

/// Serves `/models` with two models and keeps the headers each host's request came with. Hosts starting with `slow-`
/// answer after half a second.
private final class DraftModelsStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var headers: [String: [String: String]] = [:]
    private static let lock = NSLock()
    static func headers(of host: String) -> [String: String]? { lock.withLock { headers[host] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host() ?? ""
        Self.lock.withLock { Self.headers[host] = request.allHTTPHeaderFields ?? [:] }
        DispatchQueue.global().asyncAfter(deadline: .now() + (host.hasPrefix("slow-") ? 0.5 : 0)) { [self] in
            let body = try! JSONSerialization.data(withJSONObject: ["data": [["id": "model-a"], ["id": "model-b"]]])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private func chatGPTTokens(_ access: String, clientID: String) -> ChatGPTTokens {
    ChatGPTTokens(accessToken: access, refreshToken: "r-" + access, idToken: nil, expiresAt: .distantFuture,
                  scopes: ["offline_access", ChatGPTOAuth.planScope], savedAt: .now, clientID: clientID)
}

/// A connection being added stays in its draft until Add, and Cancel leaves nothing of it.
@MainActor
struct ConnectionDraftTests {
    let keys = InMemoryKeyStore()
    let headers = InMemoryKeyStore()
    let credentials = ChatGPTCredentialStore.inMemory()
    let openCodeCredentials = OpenCodeCredentialStore.inMemory()
    /// Answers the revocation a discarded ChatGPT sign-in sends.
    let authHTTP = FakeAuthHTTP { _ in (Data("{}".utf8), 200) }
    let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!

    private func store() -> ConnectionStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DraftModelsStub.self]
        return ConnectionStore(defaults: defaults, keys: keys, headers: headers, session: URLSession(configuration: config),
                               chatGPT: ChatGPTAuth(store: credentials, http: authHTTP),
                               openCode: OpenCodeAuth(store: openCodeCredentials, http: authHTTP))
    }

    /// A server draft filled in as its editor would: address, headers and key.
    private func serverDraft(host: String) -> ConnectionDraft {
        let draft = ConnectionDraft(ConnectionPreset.custom.makeConnection())
        draft.connection.baseURL = "https://\(host)/v1"
        draft.connection.customHeaders = "X-Team: blue"
        draft.setAPIKey("  sk-draft  ")
        return draft
    }

    @Test func nothingIsSavedBeforeAdd() async throws {
        let store = store()
        var saves = 0
        store.onSave = { _ in saves += 1 }
        let draft = serverDraft(host: "\(UUID().uuidString.lowercased()).test")
        store.edit(draft.id, draft: draft) { $0.name = "Team server" }
        #expect(store.addManualModel("typed-in", connectionID: draft.id, draft: draft))
        #expect(draft.connection.name == "Team server" && draft.connection.models.map(\.id) == ["typed-in"])
        #expect(store.connections.isEmpty && saves == 0)
        #expect(keys.key(for: draft.id) == nil && headers.key(for: draft.id) == nil)
    }

    @Test func addSavesTheConnectionKeyHeadersAndModels() async throws {
        let store = store()
        let host = "\(UUID().uuidString.lowercased()).test"
        let draft = serverDraft(host: host)
        #expect(try await store.refreshModels(for: draft.id, draft: draft) == 2)
        #expect(store.connections.isEmpty)

        #expect(try store.add(draft) == draft.id)
        let saved = try #require(store.connection(draft.id))
        #expect(saved.baseURL == "https://\(host)/v1" && saved.models.map(\.id) == ["model-a", "model-b"])
        #expect(store.apiKey(for: draft.id) == "sk-draft")
        #expect(headers.key(for: draft.id) == "X-Team: blue")
        #expect(store.modelsFetchedAt[draft.id] != nil)
        #expect(!draft.isOpen && !draft.canAdd) // Add once
        #expect(try store.add(draft) == nil)
        #expect(store.connections.count == 1)
    }

    @Test func aDraftFetchesWithItsOwnAddressKeyAndHeaders() async throws {
        let store = store()
        let host = "\(UUID().uuidString.lowercased()).test"
        let draft = serverDraft(host: host)
        draft.connection.models = [ModelInfo(id: "model-a", supportsImages: true)]
        draft.connection.models[0].supportsImagesUserSet = true
        #expect(store.addManualModel("mine", connectionID: draft.id, draft: draft))

        try await store.refreshModels(for: draft.id, draft: draft)
        let sent = try #require(DraftModelsStub.headers(of: host))
        #expect(sent["Authorization"] == "Bearer sk-draft")
        #expect(sent["X-Team"] == "blue")
        // Merged like a saved connection's list: the user's flags and a model added by hand stay.
        #expect(draft.connection.models.map(\.id) == ["model-a", "model-b", "mine"])
        #expect(draft.connection.models[0].supportsImages)
        #expect(store.modelFetches[draft.id]?.count == 2)
        #expect(store.connections.isEmpty)
    }

    @Test func aListForAnEditedAddressIsDropped() async throws {
        let store = store()
        let draft = serverDraft(host: "slow-\(UUID().uuidString.lowercased()).test")
        let fetch = Task { try await store.refreshModels(for: draft.id, draft: draft) }
        try await Task.sleep(for: .milliseconds(150)) // the request is out
        draft.connection.baseURL = "https://elsewhere.test/v1"
        await #expect(throws: CancellationError.self) { try await fetch.value }
        #expect(draft.connection.models.isEmpty)
    }

    @Test func cancelLeavesNothing() async throws {
        let store = store()
        let draft = serverDraft(host: "\(UUID().uuidString.lowercased()).test")
        try await store.refreshModels(for: draft.id, draft: draft)
        await store.discard(draft)
        #expect(store.connections.isEmpty)
        #expect(keys.key(for: draft.id) == nil && headers.key(for: draft.id) == nil)
        #expect(store.modelFetches[draft.id] == nil && store.modelsFetchedAt[draft.id] == nil)
        #expect(!draft.canAdd)
        #expect(try store.add(draft) == nil)
        #expect(store.connections.isEmpty)
    }

    @Test func cancelSignsOutAndRemovesAChatGPTSignIn() async throws {
        let store = store()
        let draft = ConnectionDraft(ConnectionPreset.chatGPT.makeConnection())
        // What the editor's sign-in leaves: the registration and tokens, under the draft's id.
        try credentials.setRegistration(ChatGPTRegistration(clientID: "c_new", subject: "user-1", email: "me@example.com"), draft.id)
        try credentials.setTokens(chatGPTTokens("draft", clientID: "c_new"), draft.id)
        store.checkSignIn(draft)
        #expect(draft.canAdd)

        await store.discard(draft)
        #expect(credentials.tokens(draft.id) == nil && credentials.registration(draft.id) == nil)
        #expect(authHTTP.count == 1) // the refresh token was revoked
        #expect(store.connections.isEmpty)
    }

    @Test func cancelRemovesAnOpenCodeSignIn() async throws {
        let store = store()
        let draft = ConnectionDraft(ConnectionPreset.openCode.makeConnection())
        try openCodeCredentials.setSession(OpenCodeSession(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture,
                                                           savedAt: .now), draft.id)
        store.checkSignIn(draft)
        #expect(draft.canAdd)
        await store.discard(draft)
        #expect(!openCodeCredentials.hasCredential(draft.id))
        #expect(store.connections.isEmpty)
    }

    @Test func anOpenCodeKeyWaitsForAdd() throws {
        let store = store()
        let draft = ConnectionDraft(ConnectionPreset.openCode.makeConnection())
        #expect(!draft.canAdd)
        draft.setAPIKey("oc_sk_draft")
        #expect(draft.canAdd && openCodeCredentials.apiKey(draft.id) == nil)
        #expect(try store.add(draft) == draft.id)
        #expect(openCodeCredentials.apiKey(draft.id) == "oc_sk_draft")
        #expect(store.isOpenCodeSignedIn(draft.id))
    }

    @Test func addingAKnownChatGPTAccountMergesInsteadOfDuplicating() throws {
        let store = store()
        var merges: [[UUID: UUID]] = []
        store.onMerge = { merges.append($0) }
        var existing = Connection.chatGPT(name: "ChatGPT (Me)")
        existing.models = [ModelInfo(id: "gpt-a")]
        store.upsert(existing)
        try credentials.setRegistration(ChatGPTRegistration(clientID: "c_old", subject: "user-1", email: "me@example.com"), existing.id)
        try credentials.setTokens(chatGPTTokens("old", clientID: "c_old"), existing.id)
        store.collapseDuplicateAccounts()

        // A new ChatGPT connection, signed in to the same account.
        let draft = ConnectionDraft(ConnectionPreset.chatGPT.makeConnection())
        try credentials.setRegistration(ChatGPTRegistration(clientID: "c_new", subject: "user-1", email: "me@example.com"), draft.id)
        try credentials.setTokens(chatGPTTokens("new", clientID: "c_new"), draft.id)
        store.checkSignIn(draft)

        #expect(try store.add(draft) == existing.id)
        #expect(store.connections.map(\.id) == [existing.id])
        #expect(store.connection(existing.id)?.name == "ChatGPT (Me)")
        #expect(credentials.tokens(existing.id)?.accessToken == "new") // the fresh sign-in
        #expect(credentials.tokens(draft.id) == nil && credentials.registration(draft.id) == nil)
        // Never saved, so nothing points at it: no merge to record.
        #expect(store.mergedIDs.isEmpty && merges.isEmpty)
    }

    @Test func aNewChatGPTAccountIsAddedWithItsAccount() throws {
        let store = store()
        let draft = ConnectionDraft(ConnectionPreset.chatGPT.makeConnection())
        #expect(!draft.canAdd)
        #expect(try store.add(draft) == nil)
        try credentials.setRegistration(ChatGPTRegistration(clientID: "c_1", subject: "user-2", email: "two@example.com"), draft.id)
        try credentials.setTokens(chatGPTTokens("two", clientID: "c_1"), draft.id)
        store.checkSignIn(draft)
        #expect(try store.add(draft) == draft.id)
        #expect(store.connection(draft.id)?.chatGPTAccount?.subject == "user-2")
        #expect(store.isChatGPTSignedIn(draft.id))
    }

    @Test func addIsEnabledOnceTheConnectionIsUsable() {
        let store = store()
        let server = ConnectionDraft(ConnectionPreset.custom.makeConnection())
        #expect(!server.canAdd) // "https://"
        for url in ["", "http://", "localhost:11434", "https://user:pass@host/v1", "ftp://host/v1"] {
            server.connection.baseURL = url
            #expect(!server.canAdd, "\(url)")
        }
        server.connection.baseURL = "http://192.168.1.20:11434/v1"
        #expect(server.canAdd) // no key needed

        let anthropic = ConnectionDraft(ConnectionPreset.anthropic.makeConnection())
        #expect(!anthropic.canAdd)
        anthropic.setAPIKey("   ")
        #expect(!anthropic.canAdd)
        anthropic.setAPIKey("sk-ant-x")
        #expect(anthropic.canAdd)

        let chatGPT = ConnectionDraft(ConnectionPreset.chatGPT.makeConnection())
        store.checkSignIn(chatGPT)
        #expect(!chatGPT.canAdd)

        let openCode = ConnectionDraft(ConnectionPreset.openCode.makeConnection())
        store.checkSignIn(openCode)
        #expect(!openCode.canAdd)

        #expect(ConnectionDraft(.appleOnDevice(model: FakeOnDeviceModel())).canAdd)
    }

    @Test func aSecondOnDeviceConnectionIsNeverAdded() throws {
        let store = store()
        let existing = store.addOnDeviceConnection(model: FakeOnDeviceModel())
        let draft = ConnectionDraft(.appleOnDevice(model: FakeOnDeviceModel()))
        #expect(try store.add(draft) == existing.id)
        #expect(store.connections.count == 1)
    }
}
