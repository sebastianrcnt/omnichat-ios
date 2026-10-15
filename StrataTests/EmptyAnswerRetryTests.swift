import Testing
import Foundation
@testable import Strata

@MainActor
@Suite(.serialized)
struct EmptyAnswerRetryTests {
    private func endpoint() -> Endpoint {
        Endpoint(connectionID: UUID(), connectionName: "t", baseURL: URL(string: "http://localhost/v1")!, apiKey: nil, headers: [:],
                 model: ModelInfo(id: "m", supportsEffort: true, supportsTools: true))
    }

    private func search(_ id: String) -> ChatDelta {
        ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: id, name: "web_search", arguments: "{\"query\":\"q\"}")])
    }

    private let empty: [ChatDelta] = [ChatDelta(reasoning: "thinking it over"), ChatDelta(content: "  \n"), ChatDelta(finishReason: "stop")]

    @Test func policy() {
        #expect(EmptyAnswerRetry.shouldRetry(enabled: true, round: 1, alreadyRetried: false, content: ""))
        #expect(EmptyAnswerRetry.shouldRetry(enabled: true, round: 3, alreadyRetried: false, content: " \n\t"))
        #expect(!EmptyAnswerRetry.shouldRetry(enabled: false, round: 1, alreadyRetried: false, content: ""))
        #expect(!EmptyAnswerRetry.shouldRetry(enabled: true, round: 0, alreadyRetried: false, content: "")) // no tools yet
        #expect(!EmptyAnswerRetry.shouldRetry(enabled: true, round: 1, alreadyRetried: true, content: ""))
        #expect(!EmptyAnswerRetry.shouldRetry(enabled: true, round: 1, alreadyRetried: false, content: "Answer"))
    }

    @Test func retriesOnceWithTheNudgeAppendedAndToolsOff() async throws {
        let streamer = ScriptedStreamer([[search("c1")], empty, [ChatDelta(content: "Answer")]])
        var runner = TurnRunner(streamer: streamer, tools: FakeTools())
        runner.continueOnEmptyAnswer = true
        var finishes: [String?] = []
        runner.requestLog = { event in if case .finished(_, let reason, _) = event { finishes.append(reason) } }
        var rounds: [Int] = []
        let outcome = try await runner.run(endpoint: endpoint(), messages: [.system("sys"), .user("hi")], effort: .high) { e in
            if case .roundStarted(let n) = e { rounds.append(n) }
        }
        #expect(outcome.finalContent == "Answer")
        #expect(streamer.requests.count == 3)
        #expect(rounds == [0, 1, 2])
        let emptyRound = streamer.requests[1], retry = streamer.requests[2]
        // Only appended to: the history up to the empty round is the retry's prefix, then the nudge.
        #expect(Array(retry.messages.dropLast()) == emptyRound.messages)
        #expect(retry.messages.last == .user(EmptyAnswerRetry.nudge))
        // Same tools and system prompt, but no calling them.
        #expect(retry.tools == emptyRound.tools)
        #expect(retry.tools == ToolDefinition.standard + ToolDefinition.display)
        #expect(retry.messages.first == .system("sys"))
        #expect(emptyRound.toolChoice == nil)
        #expect(retry.toolChoice == "none")
        #expect(retry.reasoningEffort == emptyRound.reasoningEffort)
        // The empty round's finish reason is logged like any other.
        #expect(finishes.count == 3)
        #expect(finishes[1] == "stop")
        #expect(!outcome.hitToolCap)
    }

    @Test func neverRetriesTwice() async throws {
        let streamer = ScriptedStreamer([[search("c1")], empty, empty])
        var runner = TurnRunner(streamer: streamer, tools: FakeTools())
        runner.continueOnEmptyAnswer = true
        let outcome = try await runner.run(endpoint: endpoint(), messages: [.user("hi")], effort: nil) { _ in }
        #expect(streamer.requests.count == 3)
        #expect(outcome.finalContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func offByDefault() async throws {
        let streamer = ScriptedStreamer([[search("c1")], empty])
        let runner = TurnRunner(streamer: streamer, tools: FakeTools())
        #expect(!runner.continueOnEmptyAnswer)
        _ = try await runner.run(endpoint: endpoint(), messages: [.user("hi")], effort: nil) { _ in }
        #expect(streamer.requests.count == 2)
    }

    @Test func noRetryWithoutToolsEarlierInTheTurn() async throws {
        let streamer = ScriptedStreamer([empty])
        var runner = TurnRunner(streamer: streamer, tools: FakeTools())
        runner.continueOnEmptyAnswer = true
        _ = try await runner.run(endpoint: endpoint(), messages: [.user("hi")], effort: nil) { _ in }
        #expect(streamer.requests.count == 1)
    }

    @Test func retryFlagSurvivesACheckpointRoundTrip() throws {
        var checkpoint = TurnCheckpoint()
        checkpoint.round = 2
        checkpoint.emptyAnswerRetry = true
        checkpoint.requestData = try ChatRequest(model: "m", messages: [.user("hi"), .user(EmptyAnswerRetry.nudge)]).encoded()
        checkpoint.submissionStarted = true
        let restored = try TurnCheckpoint.restore(staticData: TurnCheckpoint.encodeStatic(checkpoint), dynamicData: nil)
        #expect(restored.emptyAnswerRetry == true)
        #expect(restored.round == 2)
    }
}
