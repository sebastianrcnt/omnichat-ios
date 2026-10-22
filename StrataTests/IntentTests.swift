import Foundation
import SwiftData
import Testing
@testable import Strata

private struct Boom: LocalizedError {
    var errorDescription: String? { "The server fell over." }
}

private struct Declined: Error {}

@MainActor
struct IntentChatTests {
    private struct Rig {
        let container: ModelContainer // must outlive the context
        let controller: ChatController
        let connections: ConnectionStore
        let settings: AppSettings
        let context: ModelContext
        let streamer: ProgrammableStreamer
        @MainActor var chat: IntentChat { IntentChat(controller: controller, connections: connections, settings: settings, context: context) }
    }

    private func rig(_ plans: [([ChatDelta], ProgrammableStreamer.End)] = [], models: Bool = true) throws -> Rig {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        if models {
            try connections.setAPIKey("k", for: Connection.testID)
            var gateway = connections.testGateway()
            gateway.models = [ModelInfo(id: "m", supportsTools: true), ModelInfo(id: "m2", supportsTools: true)]
            connections.upsert(gateway)
        }
        let settings = AppSettings(defaults: defaults)
        settings.generateTitles = false // no naming requests among the streams
        let streamer = ProgrammableStreamer(plans)
        let controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
        return Rig(container: container, controller: controller, connections: connections, settings: settings, context: context,
                   streamer: streamer)
    }

    private func existing(_ r: Rig, tools: Set<ToolGroup>? = nil) -> Conversation {
        let c = Conversation(title: "Trip planning", connectionID: Connection.testID, modelID: "m", effort: .medium)
        c.titleIsUserSet = true
        c.toolSwitches = tools
        r.context.insert(c)
        return c
    }

    // MARK: The conversation

    @Test func aNewChatTakesTheDefaultModelAndTheAnswerComesBack() async throws {
        let r = try rig([([ChatDelta(content: "Hello "), ChatDelta(content: "there")], .finish)])
        let conversation = try await r.chat.conversation(existing: nil, model: nil)
        #expect(conversation.connectionID == Connection.testID && conversation.modelID == "m")
        try r.chat.send("  hi  ", in: conversation)
        #expect(ReplyBackgroundExecution.quietConversations.contains(conversation.id), "the intent delivers the answer itself")
        let answer = try await r.chat.answer(conversation, inApp: false, canContinueInForeground: false,
                                             continueInForeground: { Issue.record("no need to come forward") }, show: { _ in })
        #expect(answer == "Hello there")
        #expect(conversation.activePath.map(\.role) == [.user, .assistant])
        #expect(conversation.activePath.first?.text == "hi")
        #expect(conversation.title == "hi")
        #expect(!ReplyBackgroundExecution.quietConversations.contains(conversation.id))
        #expect(IntentChat.fetch(conversation.id, in: r.context) === conversation)
    }

    @Test func aNewChatHasTheDefaultToolsWithoutViewsPlusWhatTheIntentNeeds() async throws {
        let r = try rig()
        r.settings.webSearchEnabled = true
        r.settings.interactiveViewsEnabled = true
        r.settings.videoTranscriptsEnabled = false
        r.settings.pythonEnabled = false
        let plain = try await r.chat.conversation(existing: nil, model: nil)
        #expect(plain.toolSwitches?.contains(.web) == true)
        #expect(plain.toolSwitches?.contains(.views) == false, "Siri and shortcuts read the answer as text")
        #expect(plain.toolSwitches?.contains(.python) == false)
        let video = try await r.chat.conversation(existing: nil, model: nil, requiredTools: [.video])
        #expect(video.toolSwitches?.contains(.video) == true)
    }

    @Test func aNewChatUsesTheLastPickedModelAndEffort() async throws {
        let r = try rig()
        r.settings.lastConnectionID = Connection.testID
        r.settings.lastModelID = "m2"
        r.settings.lastEffort = .high
        let conversation = try await r.chat.conversation(existing: nil, model: nil)
        #expect(conversation.modelID == "m2")
        #expect(conversation.effort == .high)
    }

    @Test func anExistingChatKeepsItsToolsAndTakesTheModelAsked() async throws {
        let r = try rig([([ChatDelta(content: "Sure")], .finish)])
        let chat = existing(r, tools: [.python])
        let conversation = try await r.chat.conversation(existing: chat.id, model: .init(connectionID: Connection.testID, modelID: "m2"))
        #expect(conversation === chat)
        #expect(chat.modelID == "m2")
        #expect(chat.toolSwitches == [.python])
        try r.chat.send("next question", in: chat)
        let answer = try await r.chat.answer(chat, inApp: true, canContinueInForeground: false, continueInForeground: {}, show: { _ in })
        #expect(answer == "Sure")
        #expect(r.streamer.requests.last?.model == "m2")
        #expect(chat.title == "Trip planning")
    }

    @Test func aChatThatIsGoneOrBusyIsRefused() async throws {
        let r = try rig([([], .hang)])
        await #expect(throws: IntentChat.Failure.chatNotFound) { _ = try await r.chat.conversation(existing: UUID(), model: nil) }
        let chat = existing(r)
        try r.chat.send("first", in: chat)
        await #expect(throws: IntentChat.Failure.chatBusy) { _ = try await r.chat.conversation(existing: chat.id, model: nil) }
        #expect(throws: IntentChat.Failure.chatBusy) { try r.chat.send("second", in: chat) }
        r.controller.stop(chat)
        await r.controller.waitUntilIdle()
        ReplyBackgroundExecution.quietConversations.remove(chat.id)
    }

    @Test func withoutAModelOrAPromptNothingIsSent() async throws {
        let r = try rig(models: false)
        await #expect(throws: IntentChat.Failure.noModel) { _ = try await r.chat.conversation(existing: nil, model: nil) }
        let s = try rig()
        let conversation = try await s.chat.conversation(existing: nil, model: nil)
        #expect(throws: IntentChat.Failure.emptyPrompt) { try s.chat.send(" \n ", in: conversation) }
        #expect(s.streamer.requests.isEmpty)
    }

    // MARK: Waiting

    @Test func aReplyPastTheBackgroundWaitKeepsRunningAndIsAnnouncedLater() async throws {
        let r = try rig([([ChatDelta(content: "slow")], .hang)])
        let conversation = try await r.chat.conversation(existing: nil, model: nil)
        try r.chat.send("long job", in: conversation)
        await #expect(throws: IntentChat.Failure.stillAnswering) {
            try await r.chat.answer(conversation, inApp: false, canContinueInForeground: false, backgroundWait: .milliseconds(150),
                                    continueInForeground: {}, show: { _ in })
        }
        #expect(r.controller.isRunning(conversation.id), "the reply goes on in its chat")
        #expect(!ReplyBackgroundExecution.quietConversations.contains(conversation.id), "its notification says when it's ready")
        r.controller.stop(conversation)
        await r.controller.waitUntilIdle()
    }

    @Test func aSlowReplyContinuesInTheAppAndStillReturnsTheAnswer() async throws {
        let r = try rig([([ChatDelta(content: "worth the wait")], .finishAfter(.milliseconds(500)))])
        let conversation = try await r.chat.conversation(existing: nil, model: nil)
        try r.chat.send("long job", in: conversation)
        var cameForward = false
        var shown: UUID?
        let answer = try await r.chat.answer(conversation, inApp: false, canContinueInForeground: true,
                                             backgroundWait: .milliseconds(100), foregroundWait: .seconds(10),
                                             continueInForeground: { cameForward = true }, show: { shown = $0 })
        #expect(cameForward)
        #expect(shown == conversation.id, "the chat opens in the app")
        #expect(answer == "worth the wait")
    }

    @Test func decliningToContinueLeavesTheReplyRunning() async throws {
        let r = try rig([([], .hang)])
        let conversation = try await r.chat.conversation(existing: nil, model: nil)
        try r.chat.send("long job", in: conversation)
        await #expect(throws: Declined.self) {
            try await r.chat.answer(conversation, inApp: false, canContinueInForeground: true, backgroundWait: .milliseconds(100),
                                    continueInForeground: { throw Declined() }, show: { _ in Issue.record("nothing opens") })
        }
        #expect(r.controller.isRunning(conversation.id))
        #expect(!ReplyBackgroundExecution.quietConversations.contains(conversation.id))
        r.controller.stop(conversation)
        await r.controller.waitUntilIdle()
    }

    @Test func aFailedReplyThrowsTheChatsError() async throws {
        let r = try rig([([], .fail(Boom()))])
        let conversation = try await r.chat.conversation(existing: nil, model: nil)
        try r.chat.send("hi", in: conversation)
        await #expect(throws: IntentChat.Failure.reply("The server fell over.")) {
            try await r.chat.answer(conversation, inApp: true, canContinueInForeground: false, continueInForeground: {}, show: { _ in })
        }
    }

    @Test func aStoppedReplyIsNotAnAnswer() async throws {
        let r = try rig([([ChatDelta(content: "half")], .hang)])
        let conversation = try await r.chat.conversation(existing: nil, model: nil)
        try r.chat.send("hi", in: conversation)
        try await Task.sleep(for: .milliseconds(50))
        r.controller.stop(conversation)
        await #expect(throws: IntentChat.Failure.stopped) {
            try await r.chat.answer(conversation, inApp: true, canContinueInForeground: false, continueInForeground: {}, show: { _ in })
        }
    }

    @Test func siriHearsPlainText() {
        #expect(IntentChat.spoken("## Plan\n- **Fly** to Rome\n- Eat") == "Plan Fly to Rome Eat")
    }
}

// MARK: - Prompts

struct IntentPromptTests {
    @Test func aLinkIsReadWithWebSearch() {
        let page = IntentPrompts.summary(of: " https://example.com/post?id=1 ")
        #expect(page.prompt == "Summarize this page: https://example.com/post?id=1")
        #expect(page.tools == [.web])
        #expect(IntentPrompts.summary(of: "example.com/a").prompt == "Summarize this page: https://example.com/a")
    }

    @Test func aYouTubeLinkIsReadFromItsTranscript() {
        let video = IntentPrompts.summary(of: "https://youtu.be/dQw4w9WgXcQ")
        #expect(video.prompt == "Summarize this video: https://youtu.be/dQw4w9WgXcQ")
        #expect(video.tools == [.video, .web])
    }

    @Test func textIsSummarizedAsItIs() {
        let text = IntentPrompts.summary(of: "The meeting moved to Friday.\nBring the slides.")
        #expect(text.prompt == "Summarize the following text.\n\nThe meeting moved to Friday.\nBring the slides.")
        #expect(text.tools.isEmpty)
        #expect(IntentPrompts.link(in: "word") == nil)
        #expect(IntentPrompts.link(in: "ftp://example.com") == nil)
        #expect(IntentPrompts.link(in: "two words.com") == nil)
    }
}

// MARK: - Entities

@MainActor
struct IntentEntityTests {
    private func store() throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        return (container, container.mainContext)
    }

    @discardableResult
    private func chat(_ title: String, minutesAgo: Double, in context: ModelContext) -> Conversation {
        let c = Conversation(title: title)
        c.updatedAt = Date(timeIntervalSinceNow: -minutesAgo * 60)
        context.insert(c)
        return c
    }

    @Test func recentChatsAreNewestFirstWithoutEmptyOnes() throws {
        let (container, context) = try store()
        _ = container
        chat("Old", minutesAgo: 60, in: context)
        chat("New", minutesAgo: 1, in: context)
        chat("", minutesAgo: 0, in: context)
        try context.save()
        #expect(ConversationQuery.recent(in: context).map(\.title) == ["New", "Old"])
        #expect(ConversationQuery.recent(in: context, limit: 1).map(\.title) == ["New"])
    }

    @Test func chatsAreFoundByTitleAndById() throws {
        let (container, context) = try store()
        _ = container
        let rome = chat("Rome trip", minutesAgo: 5, in: context)
        let paris = chat("Paris trip", minutesAgo: 1, in: context)
        chat("Taxes", minutesAgo: 2, in: context)
        try context.save()
        #expect(ConversationQuery.entities(matching: "trip", in: context).map(\.id) == [paris.id, rome.id])
        #expect(ConversationQuery.entities(matching: "TAX", in: context).map(\.title) == ["Taxes"])
        #expect(ConversationQuery.entities(for: [rome.id, UUID(), paris.id], in: context).map(\.id) == [rome.id, paris.id])
        #expect(ConversationEntity(rome).title == "Rome trip")
    }

    @Test func modelIdsSurviveColonsAndSlashes() throws {
        let connection = UUID()
        let id = ChatModelEntity.id(connectionID: connection, modelID: "ollama/llama3:8b")
        let parsed = try #require(ChatModelEntity.parse(id))
        #expect(parsed.connectionID == connection && parsed.modelID == "ollama/llama3:8b")
        #expect(ChatModelEntity.parse("not-a-uuid:m") == nil)
        #expect(ChatModelEntity.parse("\(connection.uuidString):") == nil)
    }

    @Test func modelsAreListedAsThePickerShowsThem() throws {
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        var gateway = connections.testGateway()
        gateway.models = [ModelInfo(id: "m"), ModelInfo(id: "hidden"), ModelInfo(id: "aliased")]
        gateway.setShowsInPicker(false, forModel: "hidden")
        gateway.setAlias("Fast one", forModel: "aliased")
        connections.upsert(gateway)

        #expect(ChatModelQuery.listed(in: connections).map(\.modelID) == ["m", "aliased"])
        #expect(ChatModelQuery.listed(in: connections).last?.name == "Fast one")
        let hidden = ChatModelEntity.id(connectionID: Connection.testID, modelID: "hidden")
        #expect(ChatModelQuery.entities(for: [hidden], in: connections).first?.modelID == "hidden", "still found by id")
        #expect(ChatModelQuery.entities(matching: "fast", in: connections).map(\.modelID) == ["aliased"])
        #expect(ChatModelQuery.entities(matching: gateway.name, in: connections).count == 3)
        #expect(ChatModelQuery.entities(for: [ChatModelEntity.id(connectionID: UUID(), modelID: "m")], in: connections).isEmpty)
        let entity = try #require(ChatModelQuery.listed(in: connections).first)
        #expect(entity.choice == ModelSelection.Choice(connectionID: Connection.testID, modelID: "m"))
    }
}

// MARK: - Routing

@MainActor
struct IntentRouterTests {
    @Test func aNewChatRequestPutsItsTextInTheComposerOnce() {
        let router = IntentRouter()
        router.startNewChat(text: "  draft me  ")
        let request = router.newChat!
        #expect(request.text == "draft me")
        router.took(request)
        #expect(router.newChat == nil)
        #expect(router.takeDraft() == "draft me")
        #expect(router.takeDraft() == nil)
    }

    @Test func aNewChatWithoutTextLeavesTheComposerAlone() {
        let router = IntentRouter()
        router.startNewChat(text: " ")
        let request = router.newChat!
        #expect(request.text == nil)
        router.took(request)
        #expect(router.draft == nil)
    }

    @Test func anOlderRequestDoesNotClearANewerOne() {
        let router = IntentRouter()
        router.startNewChat(text: "first")
        let first = router.newChat!
        router.startNewChat(text: "second")
        router.took(first)
        #expect(router.newChat?.text == "second")
    }

    @Test func openingAChatGoesThroughTheNotificationRoute() throws {
        let id = UUID()
        IntentRouter().open(id)
        let router = try #require(ReplyNotificationRouter.shared)
        #expect(router.pending == id)
        router.pending = nil
    }
}

// MARK: - Transcripts

private struct OneVideo: TranscriptSource {
    var name: String { "YouTube" }
    func videoID(in url: URL) -> String? { YouTubeURL.videoID(in: url) }
    func canonicalURL(videoID: String) -> String { "https://www.youtube.com/watch?v=" + videoID }
    func transcript(videoID: String, language: String?) async throws -> VideoTranscript {
        VideoTranscript(title: "Talk", channel: "Chan", duration: 65, url: canonicalURL(videoID: videoID),
                        language: language == "ko" ? "Korean" : "English", languageCode: language ?? "en", isAutoGenerated: true,
                        cues: [CaptionCue(start: 0, text: "Hello."), CaptionCue(start: 31, text: "Bye.")])
    }
}

struct IntentTranscriptTests {
    @Test func theWholeTranscriptComesBackWithItsDetails() async throws {
        let text = try await IntentTranscripts.text(link: "https://youtu.be/dQw4w9WgXcQ", language: " KO ", sources: [OneVideo()])
        #expect(text == """
            Title: Talk
            URL: https://www.youtube.com/watch?v=dQw4w9WgXcQ

            Channel: Chan
            Duration: 1:05
            Captions: Korean (ko), auto-generated

            [00:00] Hello.

            [00:31] Bye.
            """)
    }

    @Test func otherLinksAreRefused() async {
        await #expect(throws: IntentTranscripts.Failure.unsupportedSite) {
            try await IntentTranscripts.text(link: "https://vimeo.com/1", language: nil, sources: [OneVideo()])
        }
        await #expect(throws: IntentTranscripts.Failure.notAVideoLink) {
            try await IntentTranscripts.text(link: "https://www.youtube.com/feed/library", language: nil, sources: [OneVideo()])
        }
    }
}
