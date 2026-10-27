import Testing
import Foundation
import SwiftData
@testable import Strata

/// An unsigned ID token as the Keychain keeps one (it was verified when saved): only its claims are read.
private func idToken(sub: String, aud: String, workspace: String? = nil) -> String {
    var claims: [String: Any] = ["iss": "https://auth.openai.com", "sub": sub, "aud": aud, "exp": 2_000_000_000]
    if let workspace { claims["https://api.openai.com/auth"] = ["chatgpt_account_id": workspace] }
    let header = try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "k"])
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    return header.base64URLEncodedString() + "." + payload.base64URLEncodedString() + "." + Data("sig".utf8).base64URLEncodedString()
}

private func tokens(_ access: String, clientID: String? = nil, idToken: String? = nil) -> ChatGPTTokens {
    ChatGPTTokens(accessToken: access, refreshToken: "r-" + access, idToken: idToken, expiresAt: .distantFuture,
                  scopes: ["offline_access", ChatGPTOAuth.planScope], savedAt: .now, clientID: clientID)
}

private func chatGPT(_ id: String, account: ChatGPTAccount? = nil, models: [String] = []) -> Connection {
    var c = Connection.chatGPT(name: "ChatGPT \(id.prefix(1))")
    c.id = UUID(uuidString: id)!
    c.chatGPTAccount = account
    c.models = models.map { ModelInfo(id: $0) }
    return c
}

private func defaults() -> UserDefaults { UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")! }

private let low = "00000000-0000-4000-8000-000000000001"
private let mid = "00000000-0000-4000-8000-000000000002"
private let high = "00000000-0000-4000-8000-000000000003"

// MARK: - The plan

struct ChatGPTDedupePlanTests {
    private let me = ChatGPTAccount(subject: "user-1", email: "Me@Example.com")!

    @Test func oneAccountKeepsItsSmallestIDWhateverTheOrder() {
        let a = chatGPT(high, account: me), b = chatGPT(low, account: me), c = chatGPT(mid, account: me)
        let other = chatGPT("00000000-0000-4000-8000-000000000000", account: ChatGPTAccount(subject: "user-2", email: "x@y.z"))
        let expected = [UUID(uuidString: high)!: b.id, UUID(uuidString: mid)!: b.id]
        // Each device has its own order: every one of them collapses to the same connection.
        for list in [[a, b, c, other], [other, c, b, a], [b, other, a, c]] {
            #expect(ChatGPTDedupe.plan(list) == expected)
        }
    }

    @Test func accountsAreToldApartBySubjectEmailAndWorkspace() {
        let byEmail = ChatGPTAccount(subject: "other-sub", email: "me@example.com")!
        #expect(me.email == "me@example.com")
        #expect(me.isSame(as: byEmail)) // the email still names one account
        let team = ChatGPTAccount(subject: "user-1", workspace: "ws-team", email: "me@example.com")!
        let personal = ChatGPTAccount(subject: "user-1", workspace: "ws-personal", email: "me@example.com")!
        #expect(!team.isSame(as: personal))
        #expect(!team.isSame(as: me)) // not until the device signed in fills in the workspace
        #expect(me.filled(from: team) == ChatGPTAccount(subject: "user-1", workspace: "ws-team", email: "me@example.com"))
        #expect(ChatGPTAccount(subject: nil, email: " ") == nil)
        // Without a recorded account, or another kind, nothing merges.
        var key = chatGPT(mid)
        key.kind = .openAICompatible
        key.chatGPTAccount = me
        #expect(ChatGPTDedupe.plan([chatGPT(low, account: me), chatGPT(high), key]).isEmpty)
    }

    @Test func aConnectionDroppedBySyncMergesIntoOneStillHereAndNeverStays() {
        let kept = chatGPT(mid, account: me)
        let dropped = [chatGPT(high, account: me), chatGPT(low, account: me), chatGPT("00000000-0000-4000-8000-000000000009")]
        #expect(ChatGPTDedupe.plan([kept], dropped: dropped) == [UUID(uuidString: high)!: kept.id, UUID(uuidString: low)!: kept.id])
    }

    @Test func theSurvivorTakesWhatOnlyTheLoserHad() {
        var survivor = chatGPT(low, account: ChatGPTAccount(subject: "user-1", email: nil))
        survivor.modelAliases = ["gpt-a": "Mine"]
        var loser = chatGPT(high, account: ChatGPTAccount(subject: "user-1", workspace: nil, email: "me@example.com"), models: ["gpt-a"])
        loser.modelAliases = ["gpt-a": "Theirs", "gpt-b": "B"]
        loser.hiddenModelIDs = ["gpt-a"]
        let merged = ChatGPTDedupe.merged(survivor, absorbing: loser)
        #expect(merged.id == survivor.id && merged.name == survivor.name)
        #expect(merged.modelAliases == ["gpt-a": "Mine", "gpt-b": "B"])
        #expect(merged.models.map(\.id) == ["gpt-a"] && merged.hiddenModelIDs == ["gpt-a"])
        #expect(merged.chatGPTAccount?.email == "me@example.com")
    }

    @Test func theAccountRoundTripsWithTheConnectionAndOlderListsDecode() throws {
        let c = chatGPT(low, account: me)
        #expect(try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(c)).chatGPTAccount == me)
        let old = #"{"id":"\#(low)","kind":"chatGPT","name":"ChatGPT","baseURL":"https://api.openai.com/v1","models":[]}"#
        #expect(try JSONDecoder().decode(Connection.self, from: Data(old.utf8)).chatGPTAccount == nil)
    }
}

// MARK: - The store

@MainActor
struct ChatGPTDedupeStoreTests {
    private func store(_ credentials: ChatGPTCredentialStore = .inMemory(), defaults: UserDefaults = defaults()) -> ConnectionStore {
        ConnectionStore(defaults: defaults, keys: InMemoryKeyStore(), chatGPT: ChatGPTAuth(store: credentials))
    }

    @Test func signingInToAnAccountAlreadyConnectedReusesThatConnection() throws {
        let credentials = ChatGPTCredentialStore.inMemory()
        let connections = store(credentials)
        var merges: [[UUID: UUID]] = []
        connections.onMerge = { merges.append($0) }
        let existing = chatGPT(high, models: ["gpt-a"])
        connections.upsert(existing)
        try credentials.setRegistration(ChatGPTRegistration(clientID: "c_old", subject: "user-1", email: "old@example.com"), existing.id)
        try credentials.setTokens(tokens("old", clientID: "c_old"), existing.id)
        connections.collapseDuplicateAccounts()
        #expect(connections.connection(existing.id)?.chatGPTAccount?.subject == "user-1")

        // "Add a connection" > ChatGPT, then a sign-in to the same account (a fresh registration, as a new one gets).
        let added = chatGPT(low)
        connections.upsert(added)
        try credentials.setRegistration(ChatGPTRegistration(clientID: "c_new", subject: "user-1", email: "me@example.com", name: "Me"), added.id)
        try credentials.setTokens(tokens("new", clientID: "c_new"), added.id)
        #expect(connections.finishChatGPTSignIn(added.id) == existing.id)

        #expect(connections.connections.map(\.id) == [existing.id])
        #expect(credentials.tokens(existing.id)?.accessToken == "new") // the fresh sign-in, with the client it came from
        #expect(credentials.tokens(existing.id)?.clientID == "c_new")
        let registration = try #require(credentials.registration(existing.id))
        #expect(registration.clientID == "c_old" && registration.email == "me@example.com" && registration.name == "Me")
        #expect(credentials.tokens(added.id) == nil && credentials.registration(added.id) == nil)
        #expect(connections.mergedIDs == [added.id: existing.id])
        #expect(merges == [[added.id: existing.id]])

        // Another account is a connection of its own.
        let second = chatGPT(mid)
        connections.upsert(second)
        try credentials.setRegistration(ChatGPTRegistration(clientID: "c_2", subject: "user-2", email: "two@example.com"), second.id)
        try credentials.setTokens(tokens("two", clientID: "c_2"), second.id)
        #expect(connections.finishChatGPTSignIn(second.id) == second.id)
        #expect(connections.connections.count == 2)
        #expect(connections.connection(second.id)?.chatGPTAccount == ChatGPTAccount(subject: "user-2", email: "two@example.com"))
    }

    /// The phone has both connections signed in (the reported bug): one stays, with its own sign-in.
    @Test func duplicatesHereKeepTheSurvivorsSignInAndDropTheOthers() throws {
        let credentials = ChatGPTCredentialStore.inMemory()
        let connections = store(credentials)
        for (id, client) in [(high, "c_h"), (low, "c_l")] {
            connections.upsert(chatGPT(id))
            try credentials.setRegistration(ChatGPTRegistration(clientID: client, subject: "user-1", email: "me@example.com"), UUID(uuidString: id)!)
            try credentials.setTokens(tokens(client), UUID(uuidString: id)!)
        }
        #expect(connections.collapseDuplicateAccounts())
        let survivor = UUID(uuidString: low)!
        #expect(connections.connections.map(\.id) == [survivor])
        #expect(credentials.tokens(survivor)?.accessToken == "c_l")
        #expect(credentials.tokens(UUID(uuidString: high)!) == nil && credentials.registration(UUID(uuidString: high)!) == nil)
        #expect(!connections.collapseDuplicateAccounts()) // nothing more to do
    }

    /// Only the loser is signed in here, with tokens from before they recorded their client, and its registration is
    /// already gone (another device removed it with the loser): the ID token names the client.
    @Test func theSurvivorAdoptsTheLosersSignInWithItsOwnClient() throws {
        let credentials = ChatGPTCredentialStore.inMemory()
        let connections = store(credentials)
        let account = ChatGPTAccount(subject: "user-1", email: "me@example.com")
        let survivor = chatGPT(low, account: account), loser = chatGPT(high, account: account)
        connections.upsert(survivor)
        connections.upsert(loser)
        try credentials.setRegistration(ChatGPTRegistration(clientID: "c_survivor", subject: "user-1", email: "me@example.com"), survivor.id)
        try credentials.setTokens(tokens("mine", idToken: idToken(sub: "user-1", aud: "c_loser")), loser.id)
        connections.collapseDuplicateAccounts()
        let adopted = try #require(credentials.tokens(survivor.id))
        #expect(adopted.accessToken == "mine" && adopted.clientID == "c_loser" && adopted.subject == "user-1")
        #expect(credentials.registration(survivor.id)?.clientID == "c_survivor") // other devices' client stays
        #expect(credentials.tokens(loser.id) == nil)
    }

    @Test func tokensThatCantBeRefreshedAreNotAdopted() throws {
        let credentials = ChatGPTCredentialStore.inMemory()
        let survivor = UUID(), loser = UUID()
        try credentials.setTokens(tokens("orphan"), loser) // no client anywhere
        #expect(!credentials.adopt(loser, into: survivor))
        try credentials.setTokens(tokens("theirs", clientID: "c1"), loser)
        try credentials.setTokens(tokens("kept", clientID: "c2"), survivor)
        #expect(!credentials.adopt(loser, into: survivor)) // the survivor's own sign-in stays
        #expect(credentials.tokens(survivor)?.accessToken == "kept")
        #expect(credentials.adopt(loser, into: survivor, replacing: true))
        #expect(credentials.tokens(survivor)?.accessToken == "theirs")
    }

    /// Adopted tokens refresh (and are revoked) with the client they were issued to, not the survivor's registration.
    @Test func adoptedTokensRefreshWithTheirOwnClient() async throws {
        let credentials = ChatGPTCredentialStore.inMemory()
        let id = UUID()
        try credentials.setRegistration(ChatGPTRegistration(clientID: "c_other_device", subject: "user-1"), id)
        var t = tokens("a1", clientID: "c_here")
        t.expiresAt = Date(timeIntervalSince1970: 0)
        try credentials.setTokens(t, id)
        let http = FakeAuthHTTP { request in
            if request.url == ChatGPTOAuth.revocationEndpoint { return (Data(), 200) }
            let body = try! JSONSerialization.data(withJSONObject: ["access_token": "a2", "refresh_token": "r2", "token_type": "Bearer",
                                                                     "expires_in": 3600])
            return (body, 200)
        }
        let auth = ChatGPTAuth(store: credentials, http: http)
        #expect(try await auth.accessToken(connectionID: id) == "a2")
        #expect(http.form(http.requests[0])["client_id"] == "c_here")
        #expect(credentials.tokens(id)?.clientID == "c_here") // kept through the refresh
        #expect(await auth.signOut(connectionID: id))
        #expect(http.form(http.requests[1])["client_id"] == "c_here")
    }
}

// MARK: - Two devices

@MainActor
struct ChatGPTDedupeSyncTests {
    /// The Mac and the phone each signed in to one account on their own. Registrations sync (iCloud Keychain), sign-ins
    /// stay on each device. Both end with the Mac's connection (the smaller id), each signed in with its own tokens.
    @Test func bothDevicesConvergeOnOneConnectionWithoutPingPong() throws {
        let cloud = InMemoryKeyValueStore(), headers = InMemoryKeyStore()
        let registrations = InMemoryKeyStore()
        func credentials() -> ChatGPTCredentialStore {
            ChatGPTCredentialStore(registrations: registrations, tokenStore: InMemoryKeyStore(),
                                   hostIDStore: HostIDStore(defaults: defaults()))
        }
        let macKeys = credentials(), phoneKeys = credentials()
        let mac = ConnectionStore(defaults: defaults(), keys: InMemoryKeyStore(), chatGPT: ChatGPTAuth(store: macKeys))
        let phone = ConnectionStore(defaults: defaults(), keys: InMemoryKeyStore(), chatGPT: ChatGPTAuth(store: phoneKeys))
        let onMac = chatGPT(low, models: ["gpt-a"]), onPhone = chatGPT(high, models: ["gpt-a"])
        mac.upsert(onMac)
        phone.upsert(onPhone)
        try macKeys.setRegistration(ChatGPTRegistration(clientID: "c_mac", subject: "user-1", email: "me@example.com"), onMac.id)
        try macKeys.setTokens(tokens("mac", clientID: "c_mac"), onMac.id)
        try phoneKeys.setRegistration(ChatGPTRegistration(clientID: "c_phone", subject: "user-1", email: "me@example.com"), onPhone.id)
        // Saved by an older version: no client recorded with the tokens, only in the ID token.
        try phoneKeys.setTokens(tokens("phone", idToken: idToken(sub: "user-1", aud: "c_phone")), onPhone.id)
        var phoneMerges: [UUID: UUID] = [:]
        phone.onMerge = { phoneMerges.merge($0) { $1 } }

        // Launch on each (`CloudSync.start`), then sync.
        mac.collapseDuplicateAccounts()
        phone.collapseDuplicateAccounts()
        let macSync = ConnectionSync(store: mac, cloud: cloud, defaults: defaults(), headers: headers)
        let phoneSync = ConnectionSync(store: phone, cloud: cloud, defaults: defaults(), headers: headers)
        phoneSync.start()
        macSync.start()
        phoneSync.pull()

        for store in [mac, phone] { #expect(store.connections.map(\.id) == [onMac.id]) }
        #expect(Set(ConnectionSync.cloudConnections(cloud).keys) == [onMac.id])
        #expect(macKeys.tokens(onMac.id)?.accessToken == "mac")
        let adopted = try #require(phoneKeys.tokens(onMac.id))
        #expect(adopted.accessToken == "phone" && adopted.clientID == "c_phone")
        #expect(phoneKeys.tokens(onPhone.id) == nil && registrations.key(for: onPhone.id) == nil)
        #expect(phoneMerges == [onPhone.id: onMac.id])
        #expect(phone.mergedIDs == [onPhone.id: onMac.id] && mac.mergedIDs == [onPhone.id: onMac.id])

        // Settled: more rounds change nothing on either side.
        let settled = (mac.connections, phone.connections, ConnectionSync.cloudConnections(cloud))
        for _ in 0..<2 {
            macSync.pull(); phoneSync.pull()
            macSync.push(mac.connections); phoneSync.push(phone.connections)
        }
        #expect(mac.connections == settled.0 && phone.connections == settled.1)
        #expect(ConnectionSync.cloudConnections(cloud) == settled.2)
        macSync.stop()
        phoneSync.stop()
    }
}

extension ChatGPTDedupeSyncTests {
    /// Both devices already syncing; the phone then adds the account again (a version without sign-in reuse). The Mac's
    /// next pull merges it and removes it from the cloud at once, and the phone's pull follows.
    @Test func aDuplicateArrivingLaterLeavesTheCloudOnTheNextPull() throws {
        let cloud = InMemoryKeyValueStore(), headers = InMemoryKeyStore(), registrations = InMemoryKeyStore()
        let macKeys = ChatGPTCredentialStore(registrations: registrations, tokenStore: InMemoryKeyStore(), hostIDStore: HostIDStore(defaults: defaults()))
        let phoneKeys = ChatGPTCredentialStore(registrations: registrations, tokenStore: InMemoryKeyStore(), hostIDStore: HostIDStore(defaults: defaults()))
        let mac = ConnectionStore(defaults: defaults(), keys: InMemoryKeyStore(), chatGPT: ChatGPTAuth(store: macKeys))
        let phone = ConnectionStore(defaults: defaults(), keys: InMemoryKeyStore(), chatGPT: ChatGPTAuth(store: phoneKeys))
        let account = ChatGPTAccount(subject: "user-1", email: "me@example.com")
        let onMac = chatGPT(low, account: account)
        mac.upsert(onMac)
        let macSync = ConnectionSync(store: mac, cloud: cloud, defaults: defaults(), headers: headers)
        let phoneSync = ConnectionSync(store: phone, cloud: cloud, defaults: defaults(), headers: headers)
        macSync.start()
        phoneSync.start()
        #expect(phone.connections.map(\.id) == [onMac.id])

        let again = chatGPT(high, account: account)
        phone.upsert(again) // goes up
        try phoneKeys.setTokens(tokens("phone", clientID: "c_phone"), again.id)
        macSync.pull()
        #expect(mac.connections.map(\.id) == [onMac.id])
        #expect(Set(ConnectionSync.cloudConnections(cloud).keys) == [onMac.id])
        phoneSync.pull()
        #expect(phone.connections.map(\.id) == [onMac.id])
        #expect(phoneKeys.tokens(onMac.id)?.accessToken == "phone")
        macSync.stop()
        phoneSync.stop()
    }
}

// MARK: - References

@MainActor
struct ChatGPTDedupeReferenceTests {
    @Test func chatsAndSettingsFollowTheMerge() throws {
        let loser = UUID(), survivor = UUID(), other = UUID()
        let merged = [loser: survivor]
        let container = try ModelContainer(for: StrataStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let chats = [Conversation(connectionID: loser, modelID: "gpt-a"), Conversation(connectionID: survivor, modelID: "gpt-a"),
                     Conversation(connectionID: other, modelID: "m"), Conversation()]
        chats.forEach(context.insert)
        try context.save()
        let settings = AppSettings(defaults: defaults())
        settings.lastConnectionID = loser
        settings.dictationConnectionID = other
        settings.recentModels = [RecentModels.key(loser, "gpt-a"), RecentModels.key(other, "m"), RecentModels.key(survivor, "gpt-a"),
                                 RecentModels.key(loser, "gpt-b")]

        ChatGPTDedupe.remapReferences(merged, settings: settings, context: context)
        #expect(chats.map(\.connectionID) == [survivor, survivor, other, nil])
        #expect(settings.lastConnectionID == survivor && settings.dictationConnectionID == other)
        #expect(settings.recentModels == [RecentModels.key(survivor, "gpt-a"), RecentModels.key(other, "m"),
                                          RecentModels.key(survivor, "gpt-b")])
        #expect(try ChatGPTDedupe.remapConversations(context, merged) == 0) // nothing left to move
    }
}
