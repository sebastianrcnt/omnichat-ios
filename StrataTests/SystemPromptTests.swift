import Testing
import Foundation
import SwiftData
@testable import Strata

struct AppPromptTests {
    @Test func toolRulesComeOnlyWithTools() {
        #expect(AppPrompt.text(tools: false, python: true) == AppPrompt.base)
        let tools = AppPrompt.text(tools: true, python: false)
        #expect(tools.hasPrefix(AppPrompt.base) && tools.contains("[1][2]"))
        #expect(!tools.contains("run_python"))
        #expect(AppPrompt.text(tools: true, python: true).hasSuffix(AppPrompt.python))
    }

    @Test func skillOfferComesOnlyWithSkills() {
        #expect(!AppPrompt.text(tools: true, python: true).contains("save_skill"))
        #expect(AppPrompt.text(tools: true, python: true, skills: true).hasSuffix(AppPrompt.skillOffer))
        #expect(AppPrompt.text(tools: false, python: false, skills: true) == AppPrompt.base)
    }

    @Test func itHasNoPersonality() {
        #expect(!AppPrompt.base.localizedCaseInsensitiveContains("helpful"))
    }

    @Test func preferencesAreWrappedOrLeftOut() {
        #expect(AppPrompt.preferences("  \n ") == "")
        let section = AppPrompt.preferences("  Be terse.\n")
        #expect(section.contains("<userPreferences>\nBe terse.\n</userPreferences>"))
        #expect(section.contains("every reply"))
    }
}

@MainActor
struct SystemPromptMigrationTests {
    private func defaults(prompts: [String?]) throws -> UserDefaults {
        let d = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let list: [[String: Any]] = prompts.enumerated().map { i, p in
            var c: [String: Any] = ["id": i == 0 ? Connection.strataID.uuidString : UUID().uuidString,
                                    "name": "c\(i)", "baseURL": "https://h/v1"]
            if let p { c["systemPrompt"] = p }
            return c
        }
        d.set(try JSONSerialization.data(withJSONObject: list), forKey: "connections.v1")
        return d
    }

    private func savedHasPrompt(_ d: UserDefaults) -> Bool {
        String(decoding: d.data(forKey: "connections.v1") ?? Data(), as: UTF8.self).contains("systemPrompt")
    }

    @Test func aWrittenPromptBecomesThePreferences() throws {
        let d = try defaults(prompts: [AppPrompt.legacyCitation, "  Talk like a pirate.  "])
        let store = ConnectionStore(defaults: d, keys: InMemoryKeyStore())
        #expect(store.connections.count == 2)
        #expect(AppSettings(defaults: d).userPreferences == "Talk like a pirate.")
        #expect(!savedHasPrompt(d))
    }

    @Test func theStockPromptIsDropped() throws {
        let d = try defaults(prompts: [AppPrompt.legacyCitation, ""])
        _ = ConnectionStore(defaults: d, keys: InMemoryKeyStore())
        #expect(AppSettings(defaults: d).userPreferences == "")
        #expect(!savedHasPrompt(d))
    }

    @Test func existingPreferencesWin() throws {
        let d = try defaults(prompts: ["Talk like a pirate."])
        d.set("Be terse.", forKey: AppSettings.userPreferencesKey)
        _ = ConnectionStore(defaults: d, keys: InMemoryKeyStore())
        #expect(AppSettings(defaults: d).userPreferences == "Be terse.")
    }
}

@MainActor
struct ConversationPreferencesTests {
    private struct Rig {
        let container: ModelContainer
        let controller: ChatController
        let settings: AppSettings
        let context: ModelContext
        let streamer: ProgrammableStreamer
        let connections: ConnectionStore
    }

    private func rig() throws -> Rig {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.strataID)
        var strata = connections.connection(Connection.strataID)!
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let settings = AppSettings(defaults: defaults)
        settings.pythonEnabled = false
        settings.generateTitles = false // only turn requests
        let streamer = ProgrammableStreamer([])
        let controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
        return Rig(container: container, controller: controller, settings: settings, context: container.mainContext,
                   streamer: streamer, connections: connections)
    }

    private func system(_ request: ChatRequest) -> String {
        guard let first = request.messages.first, first.role == "system", case .text(let t) = first.content else { return "" }
        return t
    }

    private func newChat(_ r: Rig) -> Conversation {
        let c = Conversation(connectionID: Connection.strataID, modelID: "m", effort: .medium)
        r.context.insert(c)
        return c
    }

    @Test func aChatKeepsThePreferencesItStartedWith() async throws {
        let r = try rig()
        r.settings.userPreferences = "Be terse."
        let chat = newChat(r)
        r.controller.send(text: "hi", images: [], conversation: chat, context: r.context)
        await r.controller.waitUntilIdle()
        r.settings.userPreferences = "Be verbose."
        r.controller.send(text: "again", images: [], conversation: chat, context: r.context)
        await r.controller.waitUntilIdle()

        #expect(r.streamer.requests.count == 2)
        let first = system(r.streamer.requests[0])
        #expect(first.hasPrefix(AppPrompt.text(tools: true, python: false)))
        #expect(first.contains("Be terse.") && first.hasSuffix(ConversationDate.line(day: chat.systemDay)))
        #expect(system(r.streamer.requests[1]) == first, "byte-identical, so the cached prefix holds")

        let next = newChat(r)
        r.controller.send(text: "hi", images: [], conversation: next, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(system(r.streamer.requests[2]).contains("Be verbose."))
    }

    @Test func theContextEstimateDoesNotFreeze() throws {
        let r = try rig()
        let chat = newChat(r)
        _ = r.controller.contextSplit(conversation: chat, total: 1000)
        #expect(chat.preferencesSnapshot == nil)
    }
}
