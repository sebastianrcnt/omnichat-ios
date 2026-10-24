import Testing
import Foundation
import SwiftData
@testable import Strata

struct AnswerNowPolicyTests {
    @Test func theInstructionIsTheAgreedText() {
        #expect(AnswerNow.instruction == "Answer now using only the information gathered so far. Do not call tools.")
    }

    @Test func offeredAfterTenSecondsOrTwoSearchesOnceToolsRun() {
        #expect(!AnswerNow.isOffered(elapsed: 10, completedToolRounds: 1, searches: 1, phase: .thinking)) // "more than" 10 s
        #expect(AnswerNow.isOffered(elapsed: 10.1, completedToolRounds: 1, searches: 1, phase: .thinking))
        #expect(!AnswerNow.isOffered(elapsed: 3, completedToolRounds: 1, searches: 1, phase: .thinking))
        #expect(AnswerNow.isOffered(elapsed: 3, completedToolRounds: 1, searches: 2, phase: .thinking))
        #expect(AnswerNow.isOffered(elapsed: 3, completedToolRounds: 0, searches: 2, phase: .tool(name: "web_search", argument: "q")))
        #expect(AnswerNow.isOffered(elapsed: 12, completedToolRounds: 0, searches: 0, phase: .tool(name: "web_fetch", argument: "u")))
        #expect(AnswerNow.isOffered(elapsed: 12, completedToolRounds: 2, searches: 0, phase: .waiting))
    }

    @Test func notOfferedBeforeAnyToolRuns() {
        #expect(!AnswerNow.isOffered(elapsed: 30, completedToolRounds: 0, searches: 0, phase: .thinking))
        #expect(!AnswerNow.isOffered(elapsed: 30, completedToolRounds: 0, searches: 0, phase: .waiting))
    }

    @Test func notOfferedOnceTheAnswerIsBeingWrittenOrWhileSummarizing() {
        #expect(!AnswerNow.isOffered(elapsed: 60, completedToolRounds: 4, searches: 4, phase: .writing))
        #expect(!AnswerNow.isOffered(elapsed: 60, completedToolRounds: 4, searches: 4, phase: .compacting))
        #expect(!AnswerNow.isOffered(elapsed: 60, completedToolRounds: 4, searches: 4, phase: .idle))
    }
}

@MainActor
struct AnswerNowTurnTests {
    /// Calls named in the arguments finish at once; the one with "slow" never does.
    struct MixedTools: ToolExecuting {
        func execute(name: String, arguments: String) async -> ToolOutput {
            if arguments.contains("slow") {
                do { try await Task.sleep(for: .seconds(60)) } catch { return ToolOutput(text: "cancelled", isError: true) }
            }
            return ToolOutput(text: "result \(arguments)")
        }
    }

    /// Containers must outlive everything that touches their models.
    nonisolated(unsafe) private static var containers: [ModelContainer] = []

    private struct Rig {
        let container: ModelContainer
        let controller: ChatController
        let context: ModelContext
        let conversation: Conversation
        let streamer: ProgrammableStreamer
    }

    private func rig(_ plans: [([ChatDelta], ProgrammableStreamer.End)], tools: any ToolExecuting = MixedTools()) throws -> Rig {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self, CompactionRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        Self.containers.append(container)
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.testID)
        var strata = connections.testGateway()
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let streamer = ProgrammableStreamer(plans)
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults), streamer: streamer, tools: tools)
        let conversation = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
        conversation.titleIsUserSet = true // no automatic naming request in the middle of the scripted ones
        conversation.autoRenameDone = true
        context.insert(conversation)
        return Rig(container: container, controller: controller, context: context, conversation: conversation, streamer: streamer)
    }

    private func call(_ index: Int, _ id: String, _ query: String) -> ToolCallDelta {
        ToolCallDelta(index: index, id: id, name: "web_search", arguments: "{\"query\":\"\(query)\"}")
    }

    private func json(_ messages: [APIMessage]) throws -> String {
        String(decoding: try ChatRequest.encoder.encode(messages), as: UTF8.self)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Round one finishes a search; round two is still thinking when "Answer now" is tapped.
    private func thinkingAfterOneRound() async throws -> Rig {
        let r = try rig([
            ([ChatDelta(toolCalls: [call(0, "c1", "first")])], .finish),
            ([ChatDelta(reasoning: "Still looking into the second angle")], .hang),
            ([ChatDelta(content: "Here is the answer.")], .finish),
        ])
        r.controller.send(text: "question", images: [], conversation: r.conversation, context: r.context)
        await waitFor { r.streamer.requests.count == 2 && (r.controller.soleRun?.phase ?? .idle) == .thinking }
        return r
    }

    @Test func theContinuationIsOneRequestWithTheSamePrefixAndNoTools() async throws {
        let r = try await thinkingAfterOneRound()
        r.controller.answerNow(r.conversation)
        await r.controller.waitUntilIdle()
        let requests = r.streamer.requests
        try #require(requests.count == 3)
        let cut = requests[1], next = requests[2]
        // Same system prompt, model and tools; the history up to the last completed result; then the instruction.
        #expect(next.model == cut.model)
        #expect(try String(decoding: ChatRequest.encoder.encode(next.tools), as: UTF8.self)
                == String(decoding: ChatRequest.encoder.encode(cut.tools), as: UTF8.self))
        #expect(next.messages == cut.messages + [.user(AnswerNow.instruction)])
        #expect(next.toolChoice == "none")
        #expect(cut.toolChoice == nil)
        #expect(next.reasoningEffort == cut.reasoningEffort)
        // The serialized history is a byte prefix of the continuation's (cache friendly).
        let before = try json(cut.messages), after = try json(next.messages)
        #expect(after.hasPrefix(String(before.dropLast())))
    }

    @Test func theCompletedResultIsKeptAndThePartialReasoningToo() async throws {
        let r = try await thinkingAfterOneRound()
        r.controller.answerNow(r.conversation)
        await r.controller.waitUntilIdle()
        let path = r.conversation.activePath
        #expect(path.map(\.role) == [.user, .assistant, .user, .assistant])
        let cut = path[1]
        #expect(cut.cutForEarlyAnswer && cut.stoppedByUser && !cut.answeredEarly)
        #expect(cut.steps.count == 1 && cut.steps[0].calls.map(\.id) == ["c1"])
        #expect(cut.steps[0].calls[0].result.contains("first"))
        #expect(cut.reasoning.contains("second angle"))
        #expect(cut.text.isEmpty)
        // The next request after the cut one carries the completed round as tool_calls plus its result.
        let sent = r.streamer.requests[2].messages
        #expect(sent.contains { $0.role == "assistant" && $0.toolCalls.map(\.id) == ["c1"] })
        #expect(sent.contains { $0.role == "tool" && $0.toolCallID == "c1" })
    }

    @Test func theAnswerFollowsTheHiddenInstructionAndSaysItCameEarly() async throws {
        let r = try await thinkingAfterOneRound()
        r.controller.answerNow(r.conversation)
        await r.controller.waitUntilIdle()
        let path = r.conversation.activePath
        let instruction = path[2], answer = path[3]
        #expect(instruction.hiddenInstruction && instruction.isHiddenInTranscript && instruction.text == AnswerNow.instruction)
        #expect(answer.answeredEarly && answer.text == "Here is the answer." && !answer.stoppedByUser)
        #expect(!path[1].isHiddenInTranscript) // the cut run has content, so it shows
        #expect(!r.controller.isStreaming)
        #expect(r.streamer.requests.count == 3) // one continuation, no more
    }

    @Test func theInstructionStaysOnThePathForLaterTurnsButNotInTheTranscript() async throws {
        let r = try await thinkingAfterOneRound()
        r.controller.answerNow(r.conversation)
        await r.controller.waitUntilIdle()
        r.controller.send(text: "thanks, and one more thing", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        let history = try #require(r.streamer.requests.last).messages
        let users = history.filter { $0.role == "user" }
        #expect(users.count == 3) // question, instruction, follow-up
        let index = try #require(history.firstIndex { $0 == .user(AnswerNow.instruction) })
        #expect(history[index + 1] == .assistant("Here is the answer."))
        // Reading it back from the store.
        let fresh = ModelContext(r.container)
        let loaded = try fresh.fetch(FetchDescriptor<Message>()).filter { $0.hiddenInstruction }
        #expect(loaded.count == 1 && loaded[0].text == AnswerNow.instruction)
        #expect(!r.conversation.transcript.contains("Answer now using"))
        #expect(!r.conversation.namingLines.contains { $0.text.contains("Answer now using") })
    }

    @Test func aToolCallThatWasStillRunningIsDropped() async throws {
        let r = try rig([
            ([ChatDelta(toolCalls: [call(0, "c1", "slow one")])], .finish),
            ([ChatDelta(content: "From what I know.")], .finish),
        ])
        r.controller.send(text: "question", images: [], conversation: r.conversation, context: r.context)
        await waitFor { if case .tool = (r.controller.soleRun?.phase ?? .idle) { true } else { false } }
        r.controller.answerNow(r.conversation)
        await r.controller.waitUntilIdle()
        let requests = r.streamer.requests
        try #require(requests.count == 2)
        #expect(requests[1].messages == requests[0].messages + [.user(AnswerNow.instruction)])
        #expect(!requests[1].messages.contains { !$0.toolCalls.isEmpty || $0.role == "tool" }, "no dangling tool call goes back")
        let path = r.conversation.activePath
        #expect(path[1].steps.isEmpty && path[1].cutForEarlyAnswer)
        #expect(path.last?.text == "From what I know.")
    }

    @Test func aRoundCutShortKeepsTheCallsThatFinished() async throws {
        let r = try rig([
            ([ChatDelta(toolCalls: [call(0, "c1", "fast one"), call(1, "c2", "slow two")])], .finish),
            ([ChatDelta(content: "Answer from the fast one.")], .finish),
        ])
        r.controller.send(text: "question", images: [], conversation: r.conversation, context: r.context)
        await waitFor { (r.controller.soleRun?.roundRecords ?? []).count == 1 }
        #expect((r.controller.soleRun?.roundRecords ?? []).map(\.id) == ["c1"])
        r.controller.answerNow(r.conversation)
        await r.controller.waitUntilIdle()
        let cut = r.conversation.activePath[1]
        #expect(cut.steps.count == 1 && cut.steps[0].calls.map(\.id) == ["c1"])
        let sent = try #require(r.streamer.requests.last).messages
        let assistant = try #require(sent.first { $0.role == "assistant" })
        #expect(assistant.toolCalls.map(\.id) == ["c1"]) // the unfinished c2 is not offered back
        #expect(sent.filter { $0.role == "tool" }.map(\.toolCallID) == ["c1"])
        #expect(sent.last == .user(AnswerNow.instruction))
    }

    /// From the audit: Stop (not only Answer now) keeps the calls of a round that finished, also one that finished
    /// while an earlier call still ran; later turns send them back.
    @Test func stopKeepsTheCallsThatFinishedInAnOpenRound() async throws {
        let r = try rig([
            ([ChatDelta(toolCalls: [call(0, "c1", "slow one"), call(1, "c2", "fast two")])], .finish),
            ([ChatDelta(content: "next")], .finish),
        ])
        r.controller.send(text: "question", images: [], conversation: r.conversation, context: r.context)
        await waitFor { if case .tool(let name, _) = (r.controller.soleRun?.phase ?? .idle) { name == "web_search" } else { false } }
        try await Task.sleep(for: .milliseconds(100)) // c2 has finished and waits behind c1
        r.controller.stop(r.conversation)
        await r.controller.waitUntilIdle()
        let stopped = r.conversation.activePath[1]
        #expect(stopped.stoppedByUser && !stopped.cutForEarlyAnswer)
        #expect(stopped.steps.count == 1 && stopped.steps[0].calls.map(\.id) == ["c2"])
        r.controller.send(text: "go on", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        let sent = try #require(r.streamer.requests.last).messages
        #expect(sent.contains { $0.role == "assistant" && $0.toolCalls.map(\.id) == ["c2"] })
        #expect(sent.filter { $0.role == "tool" }.map(\.toolCallID) == ["c2"])
    }

    @Test func aRunCutBeforeItProducedAnythingIsHiddenAndLeavesNoGap() async throws {
        let r = try rig([([], .hang), ([ChatDelta(content: "Quick answer.")], .finish)])
        r.controller.send(text: "question", images: [], conversation: r.conversation, context: r.context)
        await waitFor { r.streamer.requests.count == 1 }
        r.controller.answerNow(r.conversation)
        await r.controller.waitUntilIdle()
        let path = r.conversation.activePath
        #expect(path.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(path[1].isHiddenInTranscript && path[2].isHiddenInTranscript)
        #expect(!path[3].isHiddenInTranscript && path[3].text == "Quick answer.")
        // The empty cut run is not sent: question, then the instruction.
        #expect(r.streamer.requests[1].messages.map(\.role) == ["system", "user", "user"])
    }

    @Test func anEarlyAnswerIsNotOfferedAnotherAnswerNow() async throws {
        let r = try rig([
            ([], .hang),
            ([ChatDelta(reasoning: "thinking again")], .hang),
        ])
        r.controller.send(text: "question", images: [], conversation: r.conversation, context: r.context)
        await waitFor { r.streamer.requests.count == 1 }
        r.controller.answerNow(r.conversation)
        await waitFor { (r.controller.soleRun?.isEarly ?? false) }
        #expect((r.controller.soleRun?.isEarly ?? false))
        #expect(!(r.controller.soleRun?.canAnswerNow ?? false))
        r.controller.answerNow(r.conversation) // ignored
        r.controller.stop()
        await r.controller.waitUntilIdle()
        #expect(r.streamer.requests.count == 2)
    }

    @Test func callsTheModelMakesAnywayAreIgnoredInTheContinuation() async throws {
        let r = try rig([
            ([ChatDelta(reasoning: "hmm")], .hang),
            ([ChatDelta(content: "Done.", toolCalls: [call(0, "x1", "again")])], .finish),
        ])
        r.controller.send(text: "question", images: [], conversation: r.conversation, context: r.context)
        await waitFor { (r.controller.soleRun?.phase ?? .idle) == .thinking }
        r.controller.answerNow(r.conversation)
        await r.controller.waitUntilIdle()
        #expect(r.streamer.requests.count == 2) // no third request for a tool round
        let answer = try #require(r.conversation.activePath.last)
        #expect(answer.text == "Done." && answer.steps.isEmpty)
    }

    @Test func regeneratingAnEarlyAnswerStaysEarly() async throws {
        let r = try await thinkingAfterOneRound()
        r.controller.answerNow(r.conversation)
        await r.controller.waitUntilIdle()
        r.controller.regenerate(conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        let again = try #require(r.streamer.requests.last)
        #expect(again.toolChoice == "none")
        #expect(again.messages.last == .user(AnswerNow.instruction))
        #expect(r.conversation.activePath.last?.answeredEarly == true)
    }

    @Test func aNormalTurnIsUntouched() async throws {
        let r = try rig([([ChatDelta(content: "plain")], .finish)])
        r.controller.send(text: "hi", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(r.streamer.requests[0].toolChoice == nil)
        let m = try #require(r.conversation.activePath.last)
        #expect(!m.answeredEarly && !m.cutForEarlyAnswer && !m.hiddenInstruction && !m.isHiddenInTranscript)
    }
}
