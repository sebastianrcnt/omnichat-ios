import Testing
import Foundation
import SwiftUI
@testable import Strata

@MainActor
@Suite(.serialized)
struct ChatSettingsTests {
    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")! }

    // MARK: Effort gauge

    @Test(arguments: [1, 2, 3, 5, 7, 12])
    func gaugeFractionStepsEvenlyForAnyLevelCount(count: Int) {
        let fractions = (0..<count).map { EffortScale.fraction(index: $0, count: count) }
        #expect(fractions.first == 1 / Double(count)) // the lowest level still shows a sliver
        #expect(fractions.last == 1)
        for (a, b) in zip(fractions, fractions.dropFirst()) {
            #expect(b > a)
            #expect(abs((b - a) - 1 / Double(count)) < 1e-9)
        }
    }

    @Test func gaugeFractionClampsAndHandlesNoLevels() {
        #expect(EffortScale.fraction(index: 0, count: 0) == 0)
        #expect(EffortScale.fraction(index: -3, count: 4) == 0.25)
        #expect(EffortScale.fraction(index: 9, count: 4) == 1)
    }

    @Test func gaugeFractionForEffortLevels() {
        let all = Effort.allCases
        #expect(EffortScale.fraction(of: .low, in: all) == 0.2)
        #expect(EffortScale.fraction(of: .high, in: all) == 0.6)
        #expect(EffortScale.fraction(of: .max, in: all) == 1)
        #expect(EffortScale.fraction(of: .high, in: []) == 0)
        // A level the model does not offer reads as the default's position.
        #expect(EffortScale.fraction(of: .max, in: [.low, .medium, .high]) == EffortScale.fraction(index: 1, count: 3))
        #expect(ModelInfo(id: "m", supportsEffort: false).effortLevels.isEmpty)
        #expect(ModelInfo(id: "m", supportsEffort: true).effortLevels == Effort.allCases)
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
        var strata = try #require(store.connection(Connection.strataID))
        strata.models = [ModelInfo(id: "m1"), ModelInfo(id: "m2")]
        store.upsert(strata)
        store.setModelShownInPicker(false, connectionID: Connection.strataID, modelID: "m2")

        let reloaded = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        let c = try #require(reloaded.connection(Connection.strataID))
        #expect(c.showsInPicker("m1"))
        #expect(!c.showsInPicker("m2"))

        reloaded.setModelShownInPicker(true, connectionID: Connection.strataID, modelID: "m2")
        #expect(ConnectionStore(defaults: defaults, keys: InMemoryKeyStore()).connection(Connection.strataID)?.showsInPicker("m2") == true)

        // Connections saved before the flag existed decode with every model shown.
        let old = #"{"id":"\#(UUID().uuidString)","name":"Old","baseURL":"http://x/v1","models":[{"id":"x"}]}"#
        let decoded = try JSONDecoder().decode(Connection.self, from: Data(old.utf8))
        #expect(decoded.hiddenModelIDs.isEmpty)
        #expect(decoded.showsInPicker("x"))
    }

    // MARK: Reset to defaults

    @Test func resetRestoresEffortAndSearchEngineButKeepsTheModel() {
        let settings = AppSettings(defaults: freshDefaults())
        settings.lastEffort = .max
        settings.searchEngine = .naver
        settings.lastModelID = "keep-me"
        let conversation = Conversation(connectionID: Connection.strataID, modelID: "chat-model", effort: .low)
        #expect(!ChatDefaults.isAtDefaults(effort: conversation.effort, supportsEffort: true, settings: settings))

        ChatDefaults.reset(settings: settings, conversation: conversation)

        #expect(settings.lastEffort == .default)
        #expect(conversation.effort == .default)
        #expect(settings.searchEngine == .auto)
        #expect(settings.lastModelID == "keep-me")
        #expect(conversation.modelID == "chat-model")
        #expect(conversation.connectionID == Connection.strataID)
        #expect(ChatDefaults.isAtDefaults(effort: conversation.effort, supportsEffort: true, settings: settings))
    }

    @Test func effortIsIgnoredForDefaultsWhenTheModelHasNone() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(ChatDefaults.isAtDefaults(effort: .max, supportsEffort: false, settings: settings))
        settings.searchEngine = .bing
        #expect(!ChatDefaults.isAtDefaults(effort: .max, supportsEffort: false, settings: settings))
        ChatDefaults.reset(settings: settings, conversation: nil)
        #expect(settings.searchEngine == .auto)
    }

    @Test func composerExpandsWhenFocusedOrHoldingADraft() {
        #if os(iOS)
        #expect(!ComposerBar<EmptyView>.isExpanded(focused: false, text: "", hasAttachments: false, isEditing: false))
        #endif
        #expect(ComposerBar<EmptyView>.isExpanded(focused: true, text: "", hasAttachments: false, isEditing: false))
        #expect(ComposerBar<EmptyView>.isExpanded(focused: false, text: "hi", hasAttachments: false, isEditing: false))
        #expect(ComposerBar<EmptyView>.isExpanded(focused: false, text: "", hasAttachments: true, isEditing: false))
        #expect(ComposerBar<EmptyView>.isExpanded(focused: false, text: "", hasAttachments: false, isEditing: true))
    }
}
