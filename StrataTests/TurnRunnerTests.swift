import Testing
import Foundation
@testable import Strata

/// Scripted streamer: each request pops the next list of deltas and is recorded.
final class ScriptedStreamer: ChatStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [[ChatDelta]]
    private(set) var requests: [ChatRequest] = []
    init(_ script: [[ChatDelta]]) { self.script = script }

    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        let deltas: [ChatDelta] = lock.withLock {
            requests.append(request)
            return script.isEmpty ? [ChatDelta(content: "done")] : script.removeFirst()
        }
        return AsyncThrowingStream { c in
            for d in deltas { c.yield(d) }
            c.finish()
        }
    }
}

struct FakeTools: ToolExecuting {
    func execute(name: String, arguments: String) async -> ToolOutput {
        ToolOutput(text: "result of \(name) \(arguments)")
    }
}

private func toolDelta(_ id: String, _ name: String, _ args: String) -> ChatDelta {
    ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: id, name: name, arguments: args)])
}

@MainActor
struct TurnRunnerTests {
    private func endpoint(tools: Bool = true, effort: Bool = true) -> Endpoint {
        Endpoint(connectionID: UUID(), connectionName: "t", baseURL: URL(string: "http://localhost/v1")!, apiKey: nil, headers: [:],
                 model: ModelInfo(id: "m", supportsEffort: effort, supportsTools: tools))
    }

    @Test func toolLoopAssemblesMessagesAndContinues() async throws {
        let streamer = ScriptedStreamer([
            [ChatDelta(reasoning: "need data"), toolDelta("c1", "web_search", "{\"query\":\"q\"}")],
            [ChatDelta(content: "Answer"), ChatDelta(usage: Usage(promptTokens: 50, completionTokens: 5, cachedTokens: 40))],
        ])
        let runner = TurnRunner(streamer: streamer, tools: FakeTools())
        var events: [String] = []
        let outcome = try await runner.run(endpoint: endpoint(), messages: [.user("hi")], effort: .high) { e in
            switch e {
            case .reasoning: events.append("reasoning")
            case .content: events.append("content")
            case .toolsRequested: events.append("tools")
            case .toolFinished: events.append("toolDone")
            case .usage: events.append("usage")
            case .roundStarted(let n): events.append("round\(n)")
            }
        }
        #expect(outcome.finalContent == "Answer")
        #expect(outcome.lastUsage?.cachedTokens == 40)
        #expect(outcome.steps.count == 1)
        #expect(outcome.steps[0].calls[0].result == "result of web_search {\"query\":\"q\"}")
        #expect(events == ["round0", "reasoning", "tools", "toolDone", "round1", "content", "usage"])

        #expect(streamer.requests.count == 2)
        let second = streamer.requests[1].messages
        #expect(second.count == 3)
        #expect(second[0] == .user("hi"))
        #expect(second[1] == .assistant("", toolCalls: [ToolCall(id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}")]))
        #expect(second[2] == .tool(callID: "c1", content: "result of web_search {\"query\":\"q\"}"))
        // Tools and effort are sent on every request, byte-identical.
        let a = try streamer.requests[0].tools.map { try ChatRequest.encoder.encode($0) }
        let b = try streamer.requests[1].tools.map { try ChatRequest.encoder.encode($0) }
        #expect(a != nil && a == b)
        #expect(streamer.requests.allSatisfy { $0.reasoningEffort == "high" })
    }

    @Test func capsToolRoundsAtEight() async throws {
        let script = (0..<20).map { [toolDelta("c\($0)", "web_fetch", "{\"url\":\"https://e.com/\($0)\"}")] }
        let streamer = ScriptedStreamer(script)
        let runner = TurnRunner(streamer: streamer, tools: FakeTools())
        let outcome = try await runner.run(endpoint: endpoint(), messages: [.user("go")], effort: nil) { _ in }
        #expect(outcome.steps.count == TurnRunner.maxToolRounds)
        #expect(outcome.hitToolCap)
        #expect(streamer.requests.count == TurnRunner.maxToolRounds + 1)
        #expect(streamer.requests.last?.toolChoice == "none")
        #expect(streamer.requests.dropLast().allSatisfy { $0.toolChoice == nil })
    }

    @Test func modelWithoutToolsOrEffortGetsNeither() async throws {
        let streamer = ScriptedStreamer([[ChatDelta(content: "x")]])
        let runner = TurnRunner(streamer: streamer, tools: FakeTools())
        _ = try await runner.run(endpoint: endpoint(tools: false, effort: false), messages: [.user("hi")], effort: .max) { _ in }
        #expect(streamer.requests[0].tools == nil)
        #expect(streamer.requests[0].reasoningEffort == nil)
    }

    @Test func historyExpandsToolStepsAndImages() throws {
        let call = ToolCallRecord(id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}", result: "R", isError: false)
        let jpeg = Data([1, 2, 3])
        let history = [
            HistoryMessage(role: "user", text: "look", images: [jpeg]),
            HistoryMessage(role: "assistant", text: "final", steps: [ToolStep(assistantContent: "", calls: [call])]),
            HistoryMessage(role: "user", text: "next"),
        ]
        let api = MessageAssembler.apiMessages(from: history)
        #expect(api.count == 5)
        #expect(api[0] == .user(parts: [.jpegDataURL(jpeg), .text("look")]))
        #expect(api[1] == .assistant("", toolCalls: [call.toolCall]))
        #expect(api[2] == .tool(callID: "c1", content: "R"))
        #expect(api[3] == .assistant("final"))
        #expect(api[4] == .user("next"))
    }

    @Test func toolCallRecordPrimaryArgument() {
        let s = ToolCallRecord(id: "1", name: "web_search", arguments: "{\"query\":\"hello\"}", result: "", isError: false)
        let f = ToolCallRecord(id: "2", name: "web_fetch", arguments: "{\"url\":\"https://a.b\"}", result: "", isError: false)
        #expect(s.primaryArgument == "hello")
        #expect(f.primaryArgument == "https://a.b")
    }
}

struct ConversationTests {
    @Test func autoTitleTruncates() {
        #expect(Conversation.autoTitle(from: "Short") == "Short")
        let long = String(repeating: "word ", count: 30)
        let t = Conversation.autoTitle(from: long)
        #expect(t.hasSuffix("…") && t.count <= 41)
        #expect(Conversation.autoTitle(from: "line one\nline two") == "line one line two")
    }

    @Test func tokenFormat() {
        #expect(TokenFormat.short(900) == "900")
        #expect(TokenFormat.short(149_000) == "149k")
        #expect(TokenFormat.short(262_144) == "262k")
        #expect(TokenFormat.short(1_500) == "1.5k")
    }
}
