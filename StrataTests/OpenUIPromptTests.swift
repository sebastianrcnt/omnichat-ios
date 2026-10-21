import Testing
import Foundation
import SwiftData
@testable import Strata

struct OpenUIPromptTextTests {
    @Test func theSectionIsAppendedOnlyWhenOn() {
        let off = AppPrompt.text(tools: true, python: false)
        let on = AppPrompt.text(tools: true, python: false, views: true)
        #expect(!off.contains(AppPrompt.views))
        #expect(on == off + "\n\n" + AppPrompt.views, "at the end, so the rest of the prompt is unchanged")
        #expect(AppPrompt.text(tools: true, python: true, browser: true, skills: true, video: true, views: true).hasSuffix(AppPrompt.views))
    }

    @Test func theSectionStaysCompactAndPointsFullPagesToShowHTML() {
        // About 3.5k characters (roughly 900-1,000 tokens); a guard against it growing unnoticed.
        #expect(AppPrompt.views.count < 4_000)
        #expect(AppPrompt.views.contains("show_html") && AppPrompt.views.contains("```openui"))
    }

    @Test func everyComponentThePromptNamesIsDrawn() throws {
        let regex = try NSRegularExpression(pattern: #"(?<![@\w])([A-Z][A-Za-z]+)\("#)
        let text = AppPrompt.views
        let names = Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
        #expect(names.count > 30)
        for name in names.subtracting(["Action"]) {
            #expect(OUILibrary.openChat.spec(name) != nil, "\(name) is in the library")
        }
    }

    @Test func thePromptsExampleRendersCleanly() throws {
        let rendered = OUIRendered.make(source: AppPrompt.viewsExample)
        #expect(rendered.root?.type == "Card")
        #expect(rendered.problems.isEmpty && rendered.unresolved.isEmpty)
    }
}

/// The views group in a chat: offered from the setting, frozen at the first send like the other tool groups.
@MainActor
struct OpenUIToggleTests {
    private struct Rig {
        let container: ModelContainer
        let controller: ChatController
        let settings: AppSettings
        let context: ModelContext
        let streamer: ProgrammableStreamer
    }

    private func rig() throws -> Rig {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.testID)
        var strata = connections.testGateway()
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let settings = AppSettings(defaults: defaults)
        settings.pythonEnabled = false
        settings.videoTranscriptsEnabled = false
        settings.generateTitles = false
        let streamer = ProgrammableStreamer([])
        let controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
        controller.skills = SkillStore(builtIn: [], directory: nil)
        return Rig(container: container, controller: controller, settings: settings, context: container.mainContext, streamer: streamer)
    }

    private func newChat(_ r: Rig) -> Conversation {
        let c = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
        r.context.insert(c)
        return c
    }

    private func send(_ r: Rig, _ text: String, _ chat: Conversation) async {
        r.controller.send(text: text, images: [], conversation: chat, context: r.context)
        await r.controller.waitUntilIdle()
    }

    private func system(_ request: ChatRequest) -> String {
        guard let first = request.messages.first, first.role == "system", case .text(let t) = first.content else { return "" }
        return t
    }

    private func users(_ request: ChatRequest) -> [String] {
        request.messages.filter { $0.role == "user" }.compactMap { if case .text(let t) = $0.content { t } else { nil } }
    }

    @Test func onByDefaultForNewChats() async throws {
        let r = try rig()
        #expect(r.settings.interactiveViewsEnabled)
        let chat = newChat(r)
        await send(r, "hi", chat)
        #expect(system(r.streamer.requests[0]).contains(AppPrompt.views))
        #expect(chat.offeredTools?.contains(.views) == true)
        #expect(ToolDefinition.available(groups: [.views], images: true) == ToolDefinition.available(groups: [], images: true),
                "it adds no tools")
    }

    @Test func offInSettingsLeavesItOut() async throws {
        let r = try rig()
        r.settings.interactiveViewsEnabled = false
        let chat = newChat(r)
        await send(r, "hi", chat)
        #expect(!system(r.streamer.requests[0]).contains(AppPrompt.views))
        #expect(chat.offeredTools?.contains(.views) == false)
    }

    @Test func turningItOffKeepsThePromptAndSaysSoInANote() async throws {
        let r = try rig()
        let chat = newChat(r)
        await send(r, "hi", chat)
        r.controller.setTool(.views, on: false, conversation: chat)
        await send(r, "again", chat)
        let (first, second) = (r.streamer.requests[0], r.streamer.requests[1])
        #expect(system(second) == system(first), "frozen at the first send: the cached prefix holds")
        #expect(users(second) == ["hi", "again\n\n[Interactive views: off]"])
    }

    @Test func aChatKeepsWhatItStartedWith() async throws {
        let r = try rig()
        let chat = newChat(r)
        await send(r, "hi", chat)
        r.settings.interactiveViewsEnabled = false
        await send(r, "again", chat)
        #expect(system(r.streamer.requests[1]).contains(AppPrompt.views), "the setting is for new chats")
        let later = newChat(r)
        await send(r, "new", later)
        #expect(!system(r.streamer.requests[2]).contains(AppPrompt.views))
    }

    @Test func turningItOnInAChatThatStartedWithoutItAddsTheSection() async throws {
        let r = try rig()
        r.settings.interactiveViewsEnabled = false
        let chat = newChat(r)
        await send(r, "hi", chat)
        r.controller.setTool(.views, on: true, conversation: chat)
        await send(r, "show me", chat)
        #expect(system(r.streamer.requests[1]).contains(AppPrompt.views))
        #expect(users(r.streamer.requests[1]).last == "show me", "the section says it all: no note")
    }
}
