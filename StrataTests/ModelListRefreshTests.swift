import Testing
import Foundation
@testable import Strata

/// Serves a canned `/models` list, or fails, for the picker's refresh.
private final class RefreshStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var ids: [String] = []
    nonisolated(unsafe) static var failingHosts: Set<String> = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let host = request.url?.host(), Self.failingHosts.contains(host) {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
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
struct ModelListRefreshTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")! }

    private func store(_ d: UserDefaults) -> ConnectionStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefreshStub.self]
        return ConnectionStore(defaults: d, keys: InMemoryKeyStore(), session: URLSession(configuration: config))
    }

    @Test func aListIsStaleAfterADayOrWhenNeverFetched() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ModelListRefresh.isStale(fetchedAt: nil, now: now))
        #expect(!ModelListRefresh.isStale(fetchedAt: now.addingTimeInterval(-60), now: now))
        #expect(!ModelListRefresh.isStale(fetchedAt: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(ModelListRefresh.isStale(fetchedAt: now.addingTimeInterval(-24 * 3600), now: now))
        #expect(ModelListRefresh.isStale(fetchedAt: now.addingTimeInterval(-3 * 86400), now: now))
    }

    @Test func aRecentAttemptHoldsOffTheQuietRefresh() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // A server that's off isn't asked again on every opening of the picker.
        #expect(!ModelListRefresh.isStale(fetchedAt: nil, lastAttempt: now.addingTimeInterval(-60), now: now))
        #expect(ModelListRefresh.isStale(fetchedAt: nil, lastAttempt: now.addingTimeInterval(-11 * 60), now: now))
    }

    @Test func whichConnectionsHaveAListToFetch() {
        let server = Connection(name: "Local", baseURL: "http://localhost:11434/v1")
        let blank = Connection(name: "New", baseURL: "https://")
        let anthropic = Connection.anthropic()
        let chatGPT = Connection.chatGPT()
        let openCode = Connection.openCode()
        let onDevice = Connection(kind: .appleOnDevice, name: "Apple", baseURL: "")

        // A compatible server needs only an address; Anthropic a key; accounts a sign-in.
        #expect(ModelListRefresh.canRefresh(server, hasKey: false, signedIn: false))
        #expect(!ModelListRefresh.canRefresh(blank, hasKey: true, signedIn: false))
        #expect(!ModelListRefresh.canRefresh(anthropic, hasKey: false, signedIn: false))
        #expect(ModelListRefresh.canRefresh(anthropic, hasKey: true, signedIn: false))
        #expect(!ModelListRefresh.canRefresh(chatGPT, hasKey: false, signedIn: false))
        #expect(ModelListRefresh.canRefresh(chatGPT, hasKey: false, signedIn: true))
        #expect(ModelListRefresh.canRefresh(openCode, hasKey: false, signedIn: true))
        #expect(!ModelListRefresh.canRefresh(onDevice, hasKey: true, signedIn: true))

        // A typed id survives a refresh only where the list keeps hand-added models.
        #expect(ModelListRefresh.canAddModelID(server) && ModelListRefresh.canAddModelID(anthropic))
        #expect(!ModelListRefresh.canAddModelID(chatGPT) && !ModelListRefresh.canAddModelID(openCode))
        #expect(!ModelListRefresh.canAddModelID(onDevice))
    }

    @Test func theDateStaysOutOfTheConnectionAndOldPayloadsDecode() throws {
        // A payload from before the picker refresh (and any other device's): nothing new to read.
        let id = UUID()
        let json = #"[{"id":"\#(id.uuidString)","name":"Local","baseURL":"http://localhost/v1","models":[{"id":"m"}]}]"#
        let d = defaults()
        d.set(Data(json.utf8), forKey: "connections.v1")
        let s = store(d)
        #expect(s.connection(id)?.models.map(\.id) == ["m"])
        #expect(s.modelsFetchedAt[id] == nil)
        #expect(ModelListRefresh.isStale(fetchedAt: s.modelsFetchedAt[id]))

        // What goes to iCloud carries no date, so a refresh alone never changes the synced copy.
        let local = try #require(s.connection(id))
        let synced = try #require(ConnectionSync.encode(local))
        let object = try #require(try JSONSerialization.jsonObject(with: synced) as? [String: Any])
        #expect(!object.keys.contains("modelsFetchedAt"))
    }

    @Test func aRefreshRecordsItsDateAcrossLaunches() async throws {
        let d = defaults()
        let s = store(d)
        let c = Connection(name: "Local", baseURL: "http://refresh-ok.test/v1")
        s.upsert(c)
        RefreshStub.ids = ["a", "b"]
        RefreshStub.failingHosts = []
        let errors = await s.refreshModels(of: [c.id])
        #expect(errors.isEmpty)
        #expect(s.connection(c.id)?.models.map(\.id) == ["a", "b"])
        let fetched = try #require(s.modelsFetchedAt[c.id])
        #expect(!ModelListRefresh.isStale(fetchedAt: fetched))

        let reloaded = store(d)
        #expect(reloaded.modelsFetchedAt[c.id] == fetched)

        // A deleted connection forgets it.
        reloaded.delete(c.id)
        #expect(store(d).modelsFetchedAt[c.id] == nil)
    }

    @Test func refreshingSeveralReportsOnlyTheOnesThatFailed() async {
        let s = store(defaults())
        let ok = Connection(name: "OK", baseURL: "http://refresh-ok.test/v1")
        let down = Connection(name: "Down", baseURL: "http://refresh-down.test/v1")
        s.upsert(ok)
        s.upsert(down)
        RefreshStub.ids = ["x"]
        RefreshStub.failingHosts = ["refresh-down.test"]
        let errors = await s.refreshModels(of: [ok.id, down.id])
        #expect(Set(errors.keys) == [down.id])
        #expect(s.modelsFetchedAt[ok.id] != nil && s.modelsFetchedAt[down.id] == nil)
        #expect(s.modelFetches[down.id]?.finished != nil) // a failed attempt holds off the quiet retry
        RefreshStub.failingHosts = []
    }

    @Test func theQuietRefreshSkipsFreshListsAndOnDevice() async {
        let s = store(defaults())
        let fresh = Connection(name: "Fresh", baseURL: "http://refresh-ok.test/v1")
        let stale = Connection(name: "Stale", baseURL: "http://refresh-stale.test/v1")
        s.upsert(fresh)
        s.upsert(stale)
        s.upsert(Connection(kind: .appleOnDevice, name: "Apple", baseURL: ""))
        RefreshStub.ids = ["one"]
        RefreshStub.failingHosts = []
        await s.refreshModels(of: [fresh.id])
        RefreshStub.ids = ["two"]
        await s.refreshStaleModels()
        #expect(s.connection(fresh.id)?.models.map(\.id) == ["one"])
        #expect(s.connection(stale.id)?.models.map(\.id) == ["two"])
    }

    @Test func aTypedModelIDIsAddedOnceAndKeptThroughARefresh() async {
        let s = store(defaults())
        let c = Connection(name: "No list", baseURL: "http://refresh-ok.test/v1")
        s.upsert(c)
        #expect(s.addManualModel("  my-model  ", connectionID: c.id))
        #expect(!s.addManualModel("my-model", connectionID: c.id))
        #expect(!s.addManualModel("   ", connectionID: c.id))
        RefreshStub.ids = ["listed"]
        RefreshStub.failingHosts = []
        await s.refreshModels(of: [c.id])
        #expect(s.connection(c.id)?.models.map(\.id) == ["listed", "my-model"])
    }
}
