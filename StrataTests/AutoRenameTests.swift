import Testing
import Foundation
import SwiftData
@testable import Strata

struct AutoRenameCleanTests {
    @Test(arguments: [
        ("Docker Compose Networking Basics", "Docker Compose Networking Basics"),
        ("  \"Docker Compose Networking\"  ", "Docker Compose Networking"),
        ("Title: Fixing the Login Bug", "Fixing the Login Bug"),
        ("name:   Fixing the Login Bug", "Fixing the Login Bug"),
        ("TITLE:\tFixing", "Fixing"),
        ("# **Streaming Markdown Perf**", "Streaming Markdown Perf"),
        ("`Rust Borrow Checker`", "Rust Borrow Checker"),
        ("Planning a trip to Kyoto.", "Planning a trip to Kyoto"),
        ("\u{201C}SQL NULL handling\u{201D}", "SQL NULL handling"),
        ("First line\nSecond line", "First line"),
        ("\n\n  Leading blanks\nrest", "Leading blanks"),
        ("Too    many     spaces", "Too many spaces"),
        ("SQL 집계 함수와 NULL 처리", "SQL 집계 함수와 NULL 처리"),
        ("", ""),
        ("   \n  ", ""),
        ("\"\"", ""),
        ("Title:", ""),
    ])
    func cleans(input: String, expected: String) {
        #expect(AutoRename.cleanName(input) == expected)
    }

    @Test(arguments: [
        ("<think>pondering</think>\nKyoto Trip Plan", "Kyoto Trip Plan"),
        ("<think>still pondering", ""),
        ("\u{300C}교토 여행 계획\u{300D}", "교토 여행 계획"),
        ("교토 여행 계획.", "교토 여행 계획"),
    ])
    func dropsThinkingAndOtherQuotes(input: String, expected: String) {
        #expect(AutoRename.cleanName(input) == expected)
    }

    @Test func capsAtFortyCharactersOnAWordBoundary() {
        let cleaned = AutoRename.cleanName("Comparing PostgreSQL and MySQL replication strategies in depth")
        #expect(cleaned == "Comparing PostgreSQL and MySQL")
        let long = AutoRename.cleanName(String(repeating: "word ", count: 30))
        #expect(long.count <= 40 && !long.hasSuffix(" "))
        // No spaces to back up to (or only early ones): a hard cut at 40.
        let solid = AutoRename.cleanName(String(repeating: "가", count: 60))
        #expect(solid.count == 40)
        #expect(AutoRename.cleanName("A " + String(repeating: "x", count: 60)).count == 40)
        // A cut never ends on a dangling separator.
        #expect(AutoRename.cleanName("Notes on caching layers and eviction, invalidation") == "Notes on caching layers and eviction")
    }
}

struct AutoRenamePromptTests {
    @Test func usesTheFirstUserMessageAndTheStartOfItsAnswer() throws {
        let p = try #require(AutoRename.prompt(lines: [
            .init(role: .user, text: "How do I center a div?"), .init(role: .assistant, text: "Use flexbox."),
            .init(role: .user, text: "And vertically?"), .init(role: .assistant, text: "align-items."),
        ]))
        #expect(p == "The conversation:\n\nUser: How do I center a div?\n\nAssistant: Use flexbox.\n\nTitle:")
    }

    @Test func clipsUserTo600AndTheAnswerTo400WithAnEllipsis() throws {
        let p = try #require(AutoRename.prompt(lines: [
            .init(role: .user, text: String(repeating: "u", count: 700)),
            .init(role: .assistant, text: String(repeating: "a", count: 500)),
        ]))
        #expect(p.contains("User: " + String(repeating: "u", count: 600) + "\u{2026}"))
        #expect(!p.contains(String(repeating: "u", count: 601)))
        #expect(p.contains("Assistant: " + String(repeating: "a", count: 400) + "\u{2026}"))
        #expect(!p.contains(String(repeating: "a", count: 401)))
        let short = try #require(AutoRename.prompt(lines: [.init(role: .user, text: String(repeating: "u", count: 600))]))
        #expect(!short.contains("\u{2026}"), "exactly at the limit is not clipped")
    }

    @Test func nothingToNameWithoutAUserMessage() {
        #expect(AutoRename.prompt(lines: []) == nil)
        #expect(AutoRename.prompt(lines: [.init(role: .assistant, text: "hi")]) == nil)
    }

    @Test func requestIsStandaloneSmallAndTurnsThinkingOff() throws {
        let r = AutoRename.request(model: "m", prompt: "P", thinking: .off, supportsEffort: true)
        #expect(r.maxTokens == 32 && r.reasoningEffort == "none" && r.tools == nil && r.toolChoice == nil)
        #expect(r.chatTemplateKwargs == .init(enableThinking: false))
        #expect(r.messages.count == 2)
        let json = try String(decoding: r.encoded(), as: UTF8.self)
        #expect(json.contains("\"max_tokens\":32") && json.contains(AutoRename.system))
        #expect(json.contains("\"chat_template_kwargs\":{\"enable_thinking\":false}"))
        // Without effort support, no reasoning_effort; the fallback sends no thinking controls and has room to think.
        #expect(AutoRename.request(model: "m", prompt: "P", thinking: .off, supportsEffort: false).reasoningEffort == nil)
        let fallback = AutoRename.request(model: "m", prompt: "P", thinking: .unchanged, supportsEffort: true)
        #expect(fallback.reasoningEffort == nil && fallback.chatTemplateKwargs == nil && fallback.maxTokens == AutoRename.fallbackMaxTokens)
        // Chat requests mention neither, so their bytes are unchanged.
        let chat = try String(decoding: ChatRequest(model: "m", messages: [.user("hi")]).encoded(), as: UTF8.self)
        #expect(!chat.contains("max_tokens") && !chat.contains("chat_template_kwargs"))
    }
}

struct AutoRenameTriggerTests {
    @Test func runsOnlyAfterTheFirstAnswerWhenOnAndNeverOverAUserTitle() {
        #expect(AutoRename.shouldRunAutomatically(enabled: true, titleIsUserSet: false, alreadyAutoNamed: false, completedAnswers: 1))
        #expect(!AutoRename.shouldRunAutomatically(enabled: true, titleIsUserSet: false, alreadyAutoNamed: false, completedAnswers: 0))
        #expect(!AutoRename.shouldRunAutomatically(enabled: true, titleIsUserSet: false, alreadyAutoNamed: false, completedAnswers: 2))
        #expect(!AutoRename.shouldRunAutomatically(enabled: true, titleIsUserSet: true, alreadyAutoNamed: false, completedAnswers: 1))
        #expect(!AutoRename.shouldRunAutomatically(enabled: true, titleIsUserSet: false, alreadyAutoNamed: true, completedAnswers: 1))
        #expect(!AutoRename.shouldRunAutomatically(enabled: false, titleIsUserSet: false, alreadyAutoNamed: false, completedAnswers: 1))
    }

    @Test @MainActor func theSettingIsOnByDefault() {
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        #expect(AppSettings(defaults: defaults).generateTitles)
        defaults.set(false, forKey: "generateTitles")
        #expect(!AppSettings(defaults: defaults).generateTitles)
    }

    @Test func userTitlesSetTheFlagAndStoppedOrFailedAnswersDoNotCount() {
        let c = Conversation()
        #expect(!c.titleIsUserSet && !c.autoRenameDone)
        c.setUserTitle("Mine")
        #expect(c.titleIsUserSet && c.title == "Mine")
        let ok = Message(role: .assistant, text: "answer", sortIndex: 1)
        let stopped = Message(role: .assistant, text: "part", sortIndex: 2); stopped.stoppedByUser = true
        let failed = Message(role: .assistant, text: "", sortIndex: 3); failed.errorText = "boom"
        c.messages = [ok, stopped, failed, Message(role: .user, text: "q", sortIndex: 0)]
        #expect(c.completedAnswerCount == 1)
        #expect(c.namingLines.map(\.role) == [.user, .assistant, .assistant])
    }
}

@MainActor
struct AutoRenameFlowTests {
    private func endpoint(effort: Bool) -> Endpoint {
        Endpoint(connectionID: UUID(), connectionName: "c", baseURL: URL(string: "https://x.test/v1")!, apiKey: "k", headers: [:],
                 model: ModelInfo(id: "m", supportsEffort: effort))
    }

    @Test func retriesOnceWithoutThinkingControlsAfterAFailure() async {
        let streamer = ProgrammableStreamer([
            ([], .fail(APIError.http(status: 400, message: "reasoning_effort not supported"))),
            ([ChatDelta(reasoning: "Let me think."), ChatDelta(content: "\"Fixing Login Bug\"\n")], .finish),
        ])
        let name = await AutoRename.generate(prompt: "P", endpoint: endpoint(effort: true), streamer: streamer)
        #expect(name == "Fixing Login Bug")
        #expect(streamer.requests.count == 2)
        #expect(streamer.requests[0].reasoningEffort == "none" && streamer.requests[1].reasoningEffort == nil)
        #expect(streamer.requests[0].maxTokens == 32 && streamer.requests[1].maxTokens == AutoRename.fallbackMaxTokens)
    }

    @Test func anEmptyReplyAlsoGetsTheRoomierRetry() async {
        // Thinking that ignored the switch and used up the 32 tokens: no content.
        let streamer = ProgrammableStreamer([
            ([ChatDelta(reasoning: "Hmm, the user asks", finishReason: "length")], .finish),
            ([ChatDelta(content: "Kyoto Trip")], .finish),
        ])
        #expect(await AutoRename.generate(prompt: "P", endpoint: endpoint(effort: true), streamer: streamer) == "Kyoto Trip")
        #expect(streamer.requests.count == 2)
    }

    @Test func modelsWithoutEffortNeverSendIt() async {
        let streamer = ProgrammableStreamer([([ChatDelta(content: "Name")], .finish)])
        _ = await AutoRename.generate(prompt: "P", endpoint: endpoint(effort: false), streamer: streamer)
        #expect(streamer.requests.map(\.reasoningEffort) == [nil])
    }

    @Test func failureTwiceOrAnEmptyNameChangesNothing() async {
        let failing = ProgrammableStreamer([([], .fail(APIError.transport("x"))), ([], .fail(APIError.transport("y")))])
        #expect(await AutoRename.generate(prompt: "P", endpoint: endpoint(effort: true), streamer: failing) == nil)
        let blank = ProgrammableStreamer([([ChatDelta(content: "  \"\" ")], .finish), ([ChatDelta(content: ".")], .finish)])
        #expect(await AutoRename.generate(prompt: "P", endpoint: endpoint(effort: false), streamer: blank) == nil)
    }

    @Test func logsEachRequestLikeTheChatRequests() async {
        let streamer = ProgrammableStreamer([([ChatDelta(content: "Name", usage: Usage(promptTokens: 50, completionTokens: 3), finishReason: "stop")], .finish)])
        let log = EventLog()
        _ = await AutoRename.generate(prompt: "P", endpoint: endpoint(effort: false), streamer: streamer) { log.events.append($0) }
        let events = log.events
        guard events.count == 2, case .sent(let id, let url, let body) = events[0],
              case .finished(let fid, let reason, let usage) = events[1] else { Issue.record("events: \(events)"); return }
        #expect(id == fid && url == "https://x.test/v1/chat/completions" && reason == "stop" && usage?.completionTokens == 3)
        #expect(String(decoding: body, as: UTF8.self).contains(AutoRename.system))
    }

    @Test func aHungRequestTimesOutWithoutBlocking() async {
        let hang = ProgrammableStreamer([([], .hang), ([], .hang)])
        let started = ContinuousClock.now
        let name = await AutoRename.generate(prompt: "P", endpoint: endpoint(effort: true), streamer: hang, timeout: .milliseconds(100))
        #expect(name == nil)
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}

@MainActor private final class EventLog { var events: [RequestLogEvent] = [] }

/// The controller's side: the transient "titling" state, the setting, and a hand rename racing the request.
@MainActor
struct AutoRenameControllerTests {
    private struct Rig {
        let container: ModelContainer
        let controller: ChatController
        let context: ModelContext
        let conversation: Conversation
        let streamer: ProgrammableStreamer
        let settings: AppSettings
    }

    private func rig(_ plans: [([ChatDelta], ProgrammableStreamer.End)], titles: Bool = true) throws -> Rig {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.strataID)
        var strata = connections.connection(Connection.strataID)!
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let settings = AppSettings(defaults: defaults)
        settings.generateTitles = titles
        let streamer = ProgrammableStreamer(plans)
        let controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
        controller.requestRing = RequestRing()
        let conversation = Conversation(connectionID: Connection.strataID, modelID: "m")
        container.mainContext.insert(conversation)
        return Rig(container: container, controller: controller, context: container.mainContext,
                   conversation: conversation, streamer: streamer, settings: settings)
    }

    private func waitForTitle(_ r: Rig) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while r.controller.isTitling(r.conversation.id), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func titlesAfterTheFirstAnswerWhileShowingTheTitlingState() async throws {
        let r = try rig([([ChatDelta(content: "Use flexbox.")], .finish), ([ChatDelta(content: "Centering a Div")], .finish)])
        r.controller.send(text: "How do I center a div?", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(r.conversation.title == "How do I center a div?") // the placeholder while the request runs
        #expect(r.controller.isTitling(r.conversation.id))
        await waitForTitle(r)
        #expect(!r.controller.isTitling(r.conversation.id))
        #expect(r.conversation.title == "Centering a Div" && !r.conversation.titleIsUserSet)
        // The title request is separate: the history holds only the exchange, and the ring logged both requests.
        #expect(r.conversation.messages.count == 2)
        #expect(r.controller.requestRing.recent(for: r.conversation.id).count == 2)
        #expect(r.streamer.requests[1].tools == nil && r.streamer.requests[1].messages.first?.role == "system")
    }

    @Test func aFailureKeepsThePlaceholderAndStopsTheTitlingState() async throws {
        let r = try rig([([ChatDelta(content: "Use flexbox.")], .finish),
                         ([], .fail(APIError.transport("x"))), ([], .fail(APIError.transport("y")))])
        r.controller.send(text: "How do I center a div?", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        await waitForTitle(r)
        #expect(!r.controller.isTitling(r.conversation.id))
        #expect(r.conversation.title == "How do I center a div?")
        #expect(r.conversation.messages.allSatisfy { $0.errorText == nil })
    }

    @Test func offInSettingsMeansNoRequestButRegenerateStillWorks() async throws {
        let r = try rig([([ChatDelta(content: "Use flexbox.")], .finish), ([ChatDelta(content: "Flexbox Centering")], .finish)], titles: false)
        r.controller.send(text: "How do I center a div?", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(!r.controller.isTitling(r.conversation.id) && r.streamer.requests.count == 1)
        r.conversation.setUserTitle("Mine")
        r.controller.autoRename(conversation: r.conversation, context: r.context, force: true)
        #expect(r.controller.isTitling(r.conversation.id))
        await waitForTitle(r)
        #expect(r.conversation.title == "Flexbox Centering" && !r.conversation.titleIsUserSet)
    }

    @Test func aHandRenameDuringTheRequestWins() async throws {
        let r = try rig([([ChatDelta(content: "Use flexbox.")], .finish),
                         ([ChatDelta(content: "Centering a Div")], .finishAfter(.milliseconds(300)))])
        r.controller.send(text: "How do I center a div?", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(r.controller.isTitling(r.conversation.id))
        // A second request for the same chat is ignored while one runs.
        r.controller.autoRename(conversation: r.conversation, context: r.context, force: true)
        r.conversation.setUserTitle("Mine")
        await waitForTitle(r)
        #expect(r.streamer.requests.count == 2)
        #expect(!r.controller.isTitling(r.conversation.id))
        #expect(r.conversation.title == "Mine" && r.conversation.titleIsUserSet)
    }
}
