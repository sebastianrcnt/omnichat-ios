import Testing
import Foundation
@testable import Strata

@MainActor
struct UnconfiguredConnectionTests {
    @Test func anAddedButUnsetServerIsDropped() throws {
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!, keys: InMemoryKeyStore())
        let blank = Connection(name: "New connection", baseURL: "https://")
        let keyed = Connection(name: "Keyed", baseURL: "https://")
        let real = Connection(name: "Real", baseURL: "https://x/v1")
        let account = Connection.openCode(name: "OpenCode")
        for c in [blank, keyed, real, account] { store.upsert(c) }
        try store.setAPIKey("k", for: keyed.id)
        store.removeUnconfigured()
        let ids = Set(store.connections.map(\.id))
        #expect(!ids.contains(blank.id))
        #expect(ids.isSuperset(of: [keyed.id, real.id, account.id, Connection.strataID]))
    }
}

struct ModelPickerTests {
    private func conns() -> [Connection] {
        let a = Connection(name: "A", baseURL: "http://a/v1", models: [
            ModelInfo(id: "a1", supportsImages: true, supportsEffort: true),
            ModelInfo(id: "a2", supportsImages: true, supportsEffort: false)])
        let b = Connection(name: "B", baseURL: "http://b/v1", models: [ModelInfo(id: "b1", supportsImages: true, supportsEffort: true)])
        return [a, b]
    }

    @Test func rowsNoteOnlyWhatAModelLacks() {
        #expect(ModelPickerCatalog.limits(ModelInfo(id: "x", supportsImages: true, supportsEffort: true)) == nil)
        #expect(ModelPickerCatalog.limits(ModelInfo(id: "x", supportsImages: false, supportsEffort: true, supportsTools: false))
                == "No images · No web tools")
    }

    @Test func theFooterNamesWhatEveryModelShares() {
        let groups = ModelPickerCatalog.groups(connections: conns(), currentConnectionID: nil, currentModelID: nil)
        #expect(groups[0].footer == "Every model here takes images and can use web tools.")
        #expect(groups[1].footer == "This model takes images, has effort levels and can use web tools.")
        #expect(ModelPickerCatalog.footer([ModelInfo(id: "x", supportsTools: false)]) == nil)
    }

    @Test func recentLeadsWithTheCurrentModelAndSkipsGoneOnes() {
        let c = conns()
        let groups = ModelPickerCatalog.groups(connections: c, currentConnectionID: nil, currentModelID: nil)
        var keys: [String] = []
        keys = RecentModels.noting(c[0].id, "a1", in: keys)
        keys = RecentModels.noting(c[1].id, "b1", in: keys)
        keys = RecentModels.noting(c[0].id, "gone", in: keys)
        keys = RecentModels.noting(c[1].id, "b1", in: keys) // moves to the front, no duplicate
        #expect(keys.count == 3 && keys[0] == RecentModels.key(c[1].id, "b1"))

        let recent = ModelPickerCatalog.recent(groups: groups, recentKeys: keys, currentConnectionID: c[0].id, currentModelID: "a2")
        #expect(recent.map(\.modelID) == ["a2", "b1", "a1"])
        #expect(ModelPickerCatalog.recent(groups: groups, recentKeys: keys, currentConnectionID: nil, currentModelID: nil,
                                          limit: 1).map(\.modelID) == ["b1"])
    }

    @Test func recentKeepsItsLimit() {
        let id = UUID()
        let keys = (0..<20).reduce(into: [String]()) { list, i in list = RecentModels.noting(id, "m\(i)", in: list) }
        #expect(keys.count == RecentModels.limit && keys[0] == RecentModels.key(id, "m19"))
    }

    @Test func searchMatchesAliasOrId() {
        var a = conns()[0]
        a.setAlias("Fast one", forModel: "a2")
        let items = ModelPickerCatalog.groups(connections: [a], currentConnectionID: nil, currentModelID: nil)[0].items
        #expect(ModelPickerCatalog.filter(items, query: " ").count == 2)
        #expect(ModelPickerCatalog.filter(items, query: "FAST").map(\.modelID) == ["a2"])
        #expect(ModelPickerCatalog.filter(items, query: "a1").map(\.modelID) == ["a1"])
        #expect(ModelPickerCatalog.filter(items, query: "zzz").isEmpty)
    }
}
