import Foundation
import SwiftData
import Testing
@testable import Strata

/// Views in one chat aren't locked by a reply running in another, and what they send goes out in their own chat.
@MainActor
struct OpenUIMultiChatTests {
    private struct Rig {
        let container: ModelContainer // must outlive the context
        let controller: ChatController
        let context: ModelContext
        let streamer: ManualStreamer
        let a: Conversation
        let b: Conversation
    }

    private func rig() throws -> Rig {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.testID)
        var strata = connections.testGateway()
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let streamer = ManualStreamer()
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults),
                                        streamer: streamer, tools: FakeTools())
        let chats = (0..<2).map { _ in
            let c = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
            c.titleIsUserSet = true // no naming requests among the streams
            c.autoRenameDone = true
            context.insert(c)
            return c
        }
        return Rig(container: container, controller: controller, context: context, streamer: streamer, a: chats[0], b: chats[1])
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func answer(_ c: Conversation) -> Message? { c.sortedMessages.last { $0.role == .assistant } }

    private static let view = "Pick one:\n\n```openui\nroot = Card([Buttons([Button(\"Short\"), Button(\"Detailed\")])])\n```"

    @Test func anotherChatsReplyDoesntLockAView() async throws {
        let r = try rig()
        // Chat B gets an answer with a view and finishes.
        r.controller.send(text: "qb", images: [], conversation: r.b, context: r.context)
        await waitFor { r.streamer.started.contains("qb") }
        r.streamer.send("qb", ChatDelta(content: Self.view))
        r.streamer.finish("qb")
        await r.controller.waitUntilIdle(r.b)
        let viewAnswer = try #require(answer(r.b))
        #expect(OpenUIChat.isInteractive(isLast: true, conversation: r.b, controller: r.controller))

        // Chat A starts replying: B's view still works, A's own latest answer doesn't.
        r.controller.send(text: "qa", images: [], conversation: r.a, context: r.context)
        await waitFor { r.streamer.started.contains("qa") }
        #expect(r.controller.isStreaming(r.a) && !r.controller.isStreaming(r.b))
        #expect(OpenUIChat.isInteractive(isLast: true, conversation: r.b, controller: r.controller),
                "a reply in another chat doesn't lock this chat's view")
        #expect(!OpenUIChat.isInteractive(isLast: true, conversation: r.a, controller: r.controller))
        #expect(!OpenUIChat.isInteractive(isLast: false, conversation: r.b, controller: r.controller), "only the latest answer")

        // Pressing a button in B sends in B, through B's own run, while A keeps going.
        let rendered = OUIRendered.make(source: "root = Card([Buttons([Button(\"Short\"), Button(\"Detailed\")])])")
        let submission = try #require(OUIRuntime().perform(nil, label: "Detailed", form: nil, rendered: rendered, open: { _ in }))
        #expect(OpenUIChat.send(submission, block: 2, from: viewAnswer, in: r.b, controller: r.controller, context: r.context))
        await waitFor { r.streamer.started.contains("Detailed") }
        #expect(r.streamer.started == ["qb", "qa", "Detailed"])
        #expect(r.controller.isStreaming(r.a) && r.controller.isStreaming(r.b))
        #expect(viewAnswer.openUIStates[2]?.label == "Detailed")
        #expect(r.b.sortedMessages.contains { $0.role == .user && $0.text == "Detailed" })
        #expect(!r.a.sortedMessages.contains { $0.text == "Detailed" })
        #expect(!OpenUIChat.isInteractive(isLast: false, conversation: r.b, controller: r.controller),
                "the view's answer is no longer the latest")

        // While B replies, a second press in B is refused and nothing is saved over the first choice.
        let again = OUISubmission(text: "Short", saved: OUISavedState(label: "Short"))
        #expect(!OpenUIChat.send(again, block: 2, from: viewAnswer, in: r.b, controller: r.controller, context: r.context))
        #expect(viewAnswer.openUIStates[2]?.label == "Detailed")

        r.streamer.finish("Detailed")
        r.streamer.finish("qa")
        await r.controller.waitUntilIdle()
        #expect(r.streamer.started.count == 3)
    }
}
