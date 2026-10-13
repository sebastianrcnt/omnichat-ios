import Testing
import Foundation
import SwiftData
@testable import Strata

/// Streams the given deltas, then either finishes, throws, or hangs until cancelled.
final class ProgrammableStreamer: ChatStreaming, @unchecked Sendable {
    enum End { case finish, fail(Error), hang, finishAfter(Duration) }
    private let lock = NSLock()
    private var plans: [([ChatDelta], End)]
    private(set) var requests: [ChatRequest] = []
    init(_ plans: [([ChatDelta], End)]) { self.plans = plans }

    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        let (deltas, end): ([ChatDelta], End) = lock.withLock {
            requests.append(request)
            return plans.isEmpty ? ([ChatDelta(content: "ok")], .finish) : plans.removeFirst()
        }
        return AsyncThrowingStream { c in
            for d in deltas { c.yield(d) }
            switch end {
            case .finish: c.finish()
            case .fail(let e): c.finish(throwing: e)
            case .hang: break // never finishes on its own; cancelling the consuming task ends iteration
            case .finishAfter(let delay): Task { try? await Task.sleep(for: delay); c.finish() }
            }
        }
    }
}

/// A tool that takes "forever" but ends promptly when its task is cancelled.
struct SlowTools: ToolExecuting {
    func execute(name: String, arguments: String) async -> ToolOutput {
        do { try await Task.sleep(for: .seconds(60)) } catch { return ToolOutput(text: "Error: cancelled", isError: true) }
        return ToolOutput(text: "late")
    }
}

@MainActor
struct ChatControllerTests {
    private struct Rig {
        let container: ModelContainer // must outlive the context
        let controller: ChatController
        let context: ModelContext
        let conversation: Conversation
        let streamer: ProgrammableStreamer
    }

    private func rig(_ plans: [([ChatDelta], ProgrammableStreamer.End)], tools: any ToolExecuting = FakeTools()) throws -> Rig {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let keys = InMemoryKeyStore()
        let connections = ConnectionStore(defaults: defaults, keys: keys)
        try connections.setAPIKey("k", for: Connection.strataID)
        var strata = connections.connection(Connection.strataID)!
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let streamer = ProgrammableStreamer(plans)
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults),
                                        streamer: streamer, tools: tools)
        let conversation = Conversation(connectionID: Connection.strataID, modelID: "m", effort: .medium)
        context.insert(conversation)
        return Rig(container: container, controller: controller, context: context, conversation: conversation, streamer: streamer)
    }

    private func assistant(_ r: Rig) -> Message? { r.conversation.sortedMessages.last { $0.role == .assistant } }

    private func toolDelta() -> ChatDelta {
        ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}")])
    }

    private func settle(_ r: Rig) async { await r.controller.waitUntilIdle() }

    @Test func stopBeforeFirstByteMarksStopped() async throws {
        let r = try rig([([], .hang)])
        r.controller.send(text: "hi", images: [], conversation: r.conversation, context: r.context)
        #expect(r.controller.isStreaming)
        try await Task.sleep(for: .milliseconds(50))
        r.controller.stop()
        await settle(r)
        let m = try #require(assistant(r))
        #expect(m.stoppedByUser && m.errorText == nil)
        #expect(!r.controller.isStreaming)
    }

    @Test func stopWhileThinkingKeepsPartialReasoning() async throws {
        let r = try rig([([ChatDelta(reasoning: "pondering the question")], .hang)])
        r.controller.send(text: "hi", images: [], conversation: r.conversation, context: r.context)
        try await Task.sleep(for: .milliseconds(100))
        r.controller.stop()
        await settle(r)
        let m = try #require(assistant(r))
        #expect(m.stoppedByUser)
        #expect(m.reasoning.contains("pondering"))
    }

    @Test func stopWhileWritingKeepsPartialText() async throws {
        let r = try rig([([ChatDelta(content: "Partial answer so far")], .hang)])
        r.controller.send(text: "hi", images: [], conversation: r.conversation, context: r.context)
        try await Task.sleep(for: .milliseconds(100))
        r.controller.stop()
        await settle(r)
        let m = try #require(assistant(r))
        #expect(m.stoppedByUser && m.text == "Partial answer so far")
    }

    @Test func stopDuringToolCancelsTheToolAndDropsItsResult() async throws {
        let r = try rig([([toolDelta()], .finish)], tools: SlowTools())
        r.controller.send(text: "hi", images: [], conversation: r.conversation, context: r.context)
        try await Task.sleep(for: .milliseconds(150))
        if case .tool = r.controller.phase {} else { Issue.record("expected tool phase, got \(r.controller.phase)") }
        let started = ContinuousClock.now
        r.controller.stop()
        await settle(r)
        #expect(ContinuousClock.now - started < .seconds(2), "stop must not wait for the 60s tool")
        let m = try #require(assistant(r))
        #expect(m.stoppedByUser)
        #expect(m.steps.isEmpty, "half-finished tool result is not recorded")
        #expect(r.controller.pendingCalls.isEmpty)
    }

    @Test func stopImmediatelyAfterSendEndsCleanlyAndAllowsANewSend() async throws {
        let r = try rig([([ChatDelta(content: "never shown")], .hang)])
        r.controller.send(text: "one", images: [], conversation: r.conversation, context: r.context)
        r.controller.stop() // before the request even started
        await settle(r)
        #expect(!r.controller.isStreaming)
        #expect(assistant(r)?.stoppedByUser == true)
        r.controller.send(text: "two", images: [], conversation: r.conversation, context: r.context)
        #expect(r.controller.isStreaming)
        r.controller.stop()
        await settle(r)
        #expect(!r.controller.isStreaming)
    }
}
