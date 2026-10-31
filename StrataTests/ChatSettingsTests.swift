import Testing
import Foundation
import SwiftUI
@testable import Strata

@MainActor
@Suite(.serialized)
struct ChatSettingsTests {
    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")! }

    // MARK: Effort

    @Test func effortLevelsFollowTheModelAndStyle() {
        #expect(ModelInfo(id: "m", supportsEffort: false).effortLevels(.tokenCaps).isEmpty)
        #expect(ModelInfo(id: "m", supportsEffort: true).effortLevels(.tokenCaps) == [.off] + Effort.allCases)
        // OpenAI's models top out at xhigh: Max would send the same, so it isn't offered, and a chat set to Max reads as Extra.
        let openAI = ModelInfo(id: "m", supportsEffort: true).effortLevels(.modelDecides)
        #expect(openAI == [.low, .medium, .high, .xhigh])
        #expect(Effort.max.resolved(in: openAI) == .xhigh && Effort.high.resolved(in: openAI) == .high)
        #expect(Effort.medium.hint(.tokenCaps).contains("4,096") || Effort.medium.hint(.tokenCaps).contains("4096"))
        #expect(!Effort.medium.hint(.modelDecides).contains("tokens"))
    }

    // MARK: Hidden models

    private func catalogConnections() -> [Connection] {
        var a = Connection(name: "A", baseURL: "http://a/v1", models: [ModelInfo(id: "a1"), ModelInfo(id: "a2"), ModelInfo(id: "a3")])
        a.setAlias("Alpha", forModel: "a1")
        a.setShowsInPicker(false, forModel: "a2")
        var b = Connection(name: "B", baseURL: "http://b/v1", models: [ModelInfo(id: "b1")])
        b.setShowsInPicker(false, forModel: "b1")
        let empty = Connection(name: "Empty", baseURL: "http://c/v1")
        return [a, b, empty]
    }

    @Test func hiddenModelsAreLeftOutOfThePicker() {
        let groups = ModelPickerCatalog.groups(connections: catalogConnections(), currentConnectionID: nil, currentModelID: nil)
        #expect(groups.map(\.name) == ["A"]) // B has nothing visible, Empty has no models
        #expect(groups[0].items.map(\.modelID) == ["a1", "a3"])
        #expect(groups[0].items[0].title == "Alpha")
        #expect(groups[0].items[0].subtitle == "a1")
        #expect(groups[0].items[0].limits == ModelPickerCatalog.limits(ModelInfo(id: "a1")))
        #expect(groups[0].items[1].title == "a3")
        #expect(groups[0].items[1].subtitle == nil)
    }

    @Test func currentHiddenModelIsStillListed() {
        let conns = catalogConnections()
        let groups = ModelPickerCatalog.groups(connections: conns, currentConnectionID: conns[1].id, currentModelID: "b1")
        #expect(groups.map(\.name) == ["A", "B"])
        #expect(groups[1].items.map(\.modelID) == ["b1"])
        // The same id on another connection does not count as current.
        let other = ModelPickerCatalog.groups(connections: conns, currentConnectionID: conns[1].id, currentModelID: "a2")
        #expect(other[0].items.map(\.modelID) == ["a1", "a3"])
    }

    @Test func visibilityFlagPersistsAndSurvivesOldData() throws {
        let defaults = freshDefaults()
        let store = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        var strata = store.testGateway()
        strata.models = [ModelInfo(id: "m1"), ModelInfo(id: "m2")]
        store.upsert(strata)
        store.setModelShownInPicker(false, connectionID: Connection.testID, modelID: "m2")

        let reloaded = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        let c = try #require(reloaded.connection(Connection.testID))
        #expect(c.showsInPicker("m1"))
        #expect(!c.showsInPicker("m2"))

        reloaded.setModelShownInPicker(true, connectionID: Connection.testID, modelID: "m2")
        #expect(ConnectionStore(defaults: defaults, keys: InMemoryKeyStore()).connection(Connection.testID)?.showsInPicker("m2") == true)

        // Connections saved before the flag existed decode with every model shown.
        let old = #"{"id":"\#(UUID().uuidString)","name":"Old","baseURL":"http://x/v1","models":[{"id":"x"}]}"#
        let decoded = try JSONDecoder().decode(Connection.self, from: Data(old.utf8))
        #expect(decoded.hiddenModelIDs.isEmpty)
        #expect(decoded.showsInPicker("x"))
    }
}
