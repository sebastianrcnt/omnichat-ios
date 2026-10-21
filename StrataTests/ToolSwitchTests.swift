import Testing
import Foundation
import SwiftData
@testable import Strata

struct ToolGroupTests {
    @Test func groupsRoundTripAndNameTheirTools() {
        #expect(ToolGroup.decode(ToolGroup.encode([.python, .web])) == [.web, .python])
        #expect(ToolGroup.encode([.location, .web]) == "web,location", "a fixed order, whatever the set's")
        #expect(ToolGroup.decode("web,bogus") == [.web])
        #expect(ToolGroup.group(of: ToolNames.webFetch) == .web && ToolGroup.group(of: ToolNames.runPlugin) == .web)
        #expect(ToolGroup.group(of: ToolNames.loadSkill) == .browser && ToolGroup.group(of: ToolNames.runSkillScript) == .browser)
        #expect(ToolGroup.group(of: ToolNames.showPlaces) == .browser && ToolGroup.group(of: ToolNames.browserClick) == .browser)
        #expect(ToolGroup.group(of: ToolNames.viewImage) == .python && ToolGroup.group(of: ToolNames.currentLocation) == .location)
        #expect(ToolGroup.group(of: ToolNames.showHTML) == nil, "display only: always offered")
    }

    @Test func theNoteSaysEachChangedGroupsState() {
        #expect(ToolGroup.note([.web], enabled: []) == "[Web search: off]")
        #expect(ToolGroup.note([.python, .web], enabled: [.python]) == "[Web search: off] [Python: on]")
        #expect(ToolGroup.groups(inNote: "[Web search: off] [Python: on]") == [.web, .python])
        #expect(ToolGroup.web.refusal == "The user turned off web search for this chat. Answer without it, or ask them to turn it on.")
    }

    @Test func theLegacyListIsTheGroupsList() {
        #expect(ToolDefinition.available(python: true, images: true, browser: true, location: true)
                == ToolDefinition.available(groups: Set(ToolGroup.allCases).subtracting([.video]), images: true))
        #expect(ToolDefinition.available(python: false, images: false, browser: false, location: true)
                == ToolDefinition.available(groups: [.web], images: false), "location only with the browser")
        let noWeb = ToolDefinition.available(groups: [.python], images: false).map(\.function.name)
        #expect(!noWeb.contains("web_search") && !noWeb.contains("run_plugin") && noWeb.contains("show_html") && noWeb.contains("run_python"))
    }

    @MainActor
    @Test func offeredToolsRefuseASwitchedOffGroup() async throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let chat = Conversation()
        container.mainContext.insert(chat)
        chat.toolSwitches = [.web]
        let all = Set(ToolDefinition.available(groups: Set(ToolGroup.allCases), images: true).map(\.function.name))
        let tools = OfferedTools(base: FakeTools(), names: all, switches: ChatToolSwitches(chat))
        for name in [ToolNames.loadSkill, ToolNames.runSkillScript, ToolNames.browserOpen, ToolNames.showPlaces] {
            let out = await tools.execute(name: name, arguments: "{}")
            #expect(out.isError && out.text == ToolGroup.browser.refusal, "\(name)")
        }
        #expect(await tools.execute(name: ToolNames.runPython, arguments: "{}").text == ToolGroup.python.refusal)
        #expect(await tools.execute(name: ToolNames.webSearch, arguments: "{}").text.hasPrefix("result of"))
        #expect(await tools.execute(name: ToolNames.showHTML, arguments: "{}").text.hasPrefix("result of"))
        chat.toolSwitches = []
        #expect(await tools.execute(name: ToolNames.runPlugin, arguments: "{}").text == ToolGroup.web.refusal,
                "read when the call runs, not when the turn started")
    }
}

@MainActor
struct ChatToolSwitchTests {
    private struct Rig {
        let container: ModelContainer
        let controller: ChatController
        let settings: AppSettings
        let context: ModelContext
        let streamer: ProgrammableStreamer
    }

    private func rig(_ plans: [([ChatDelta], ProgrammableStreamer.End)] = []) throws -> Rig {
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
        settings.interactiveViewsEnabled = false
        settings.generateTitles = false
        let streamer = ProgrammableStreamer(plans)
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

    private func toolsJSON(_ request: ChatRequest) throws -> Data {
        try ChatRequest.encoder.encode(request.tools ?? [])
    }

    private func names(_ request: ChatRequest) -> [String] { (request.tools ?? []).map(\.function.name) }

    @Test func turningAToolOffKeepsTheToolsAndSystemPromptByteIdentical() async throws {
        let r = try rig()
        let chat = newChat(r)
        await send(r, "hi", chat)
        r.controller.setTool(.web, on: false, conversation: chat)
        r.controller.setTool(.browser, on: false, conversation: chat)
        await send(r, "again", chat)
        await send(r, "more", chat)

        let (first, second, third) = (r.streamer.requests[0], r.streamer.requests[1], r.streamer.requests[2])
        #expect(try toolsJSON(second) == toolsJSON(first))
        #expect(try toolsJSON(third) == toolsJSON(first))
        #expect(names(first).contains("web_search") && names(first).contains("browser_open"))
        #expect(system(second) == system(first) && system(third) == system(first))

        // The note goes on the first message after the change only, and stays on it in later requests.
        #expect(users(second) == ["hi", "again\n\n[Web search: off] [Browser: off]"])
        #expect(users(third) == ["hi", "again\n\n[Web search: off] [Browser: off]", "more"])
        // Never in what the chat shows.
        let again = try #require(chat.activePath.first { $0.role == .user && $0.text == "again" })
        #expect(again.text == "again" && again.apiNote == "[Web search: off] [Browser: off]")
        #expect(chat.offeredTools == [.web, .browser, .location])
    }

    @Test func turningItBackOnSaysSo() async throws {
        let r = try rig()
        let chat = newChat(r)
        await send(r, "hi", chat)
        r.controller.setTool(.web, on: false, conversation: chat)
        await send(r, "two", chat)
        r.controller.setTool(.web, on: true, conversation: chat)
        await send(r, "three", chat)
        r.controller.setTool(.web, on: false, conversation: chat)
        r.controller.setTool(.web, on: true, conversation: chat)
        await send(r, "four", chat)
        #expect(users(r.streamer.requests[3]) == ["hi", "two\n\n[Web search: off]", "three\n\n[Web search: on]", "four"],
                "off and on again before sending changes nothing")
    }

    @Test func aCallToASwitchedOffToolIsRefused() async throws {
        let call = ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}")])
        let r = try rig([([ChatDelta(content: "ok")], .finish), ([call], .finish), ([ChatDelta(content: "done")], .finish)])
        let chat = newChat(r)
        await send(r, "hi", chat)
        r.controller.setTool(.web, on: false, conversation: chat)
        await send(r, "search it", chat)
        let continuation = r.streamer.requests[2]
        let result = continuation.messages.last { $0.role == "tool" }
        #expect(result?.content == .text(ToolGroup.web.refusal))
    }

    @Test func turningOnAToolTheChatWasNotOfferedAddsIt() async throws {
        let r = try rig()
        let chat = newChat(r)
        await send(r, "hi", chat)
        #expect(!names(r.streamer.requests[0]).contains("run_python"))
        #expect(!system(r.streamer.requests[0]).contains(AppPrompt.python))
        r.controller.setTool(.python, on: true, conversation: chat)
        await send(r, "calculate", chat)
        let second = r.streamer.requests[1]
        #expect(names(second).contains("run_python"))
        #expect(system(second).contains(AppPrompt.python))
        #expect(chat.offeredTools?.contains(.python) == true)
        #expect(users(second).last == "calculate", "its definition says it all: no note")
        await send(r, "again", chat)
        #expect(try toolsJSON(r.streamer.requests[2]) == toolsJSON(second))
    }

    @Test func videoTranscriptsComeWithTheirPromptLineAndStayOutOfOlderChats() async throws {
        let r = try rig()
        let old = newChat(r)
        await send(r, "hi", old)
        r.settings.videoTranscriptsEnabled = true
        await send(r, "again", old)
        #expect(!names(r.streamer.requests[1]).contains("video_transcript"), "a chat keeps the tools it started with")
        let chat = newChat(r)
        await send(r, "watch this", chat)
        let request = r.streamer.requests[2]
        #expect(names(request).last == "video_transcript" && system(request).contains(AppPrompt.video))
        #expect(!system(r.streamer.requests[1]).contains(AppPrompt.video))
    }

    @Test func aNewChatStartsWithTheDefaultsAndOffGroupsAreNotOffered() async throws {
        let r = try rig()
        r.settings.webSearchEnabled = false
        let chat = newChat(r)
        #expect(r.controller.toolSwitches(chat) == [.browser, .location])
        _ = r.controller.contextSplit(conversation: chat, total: 1000)
        #expect(chat.offeredTools == nil && chat.toolSwitches == nil, "an estimate freezes nothing")
        await send(r, "hi", chat)
        #expect(!names(r.streamer.requests[0]).contains("web_search"))
        #expect(chat.offeredTools == [.browser, .location] && chat.toolSwitches == [.browser, .location])
        r.settings.webSearchEnabled = true
        await send(r, "again", chat)
        #expect(!names(r.streamer.requests[1]).contains("web_search"), "a chat keeps its own switches")
    }

    @Test func anExistingChatFreezesWhatItWasSending() async throws {
        let r = try rig()
        r.settings.browserEnabled = false // location on by default, but it only ever came with the browser
        let chat = newChat(r)
        let old = Message(role: .user, text: "before the update", sortIndex: 0)
        r.context.insert(old)
        chat.attach(old, parent: nil)
        let answer = Message(role: .assistant, text: "answer", sortIndex: 1)
        r.context.insert(answer)
        chat.attach(answer, parent: old)
        #expect(chat.toolSwitchesRaw == nil && chat.offeredToolsRaw == nil && chat.announcedToolsRaw == nil)

        await send(r, "after", chat)
        let request = r.streamer.requests[0]
        #expect(request.tools == ToolDefinition.available(python: false, images: false, browser: false, location: true))
        #expect(system(request).hasPrefix(AppPrompt.text(tools: true, python: false)))
        #expect(chat.offeredTools == [.web] && chat.toolSwitches == [.web])
        #expect(users(request) == ["before the update", "after"])
    }
}
