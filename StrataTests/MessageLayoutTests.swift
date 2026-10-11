import Foundation
import SwiftData
import Testing
@testable import Strata

private func search(_ id: String, sources: [Int] = [1, 2]) -> ToolCallRecord {
    ToolCallRecord(id: id, name: ToolNames.webSearch, arguments: "{\"query\":\"q\"}", result: "", isError: false, sourceIDs: sources)
}
private func fetch(_ id: String, offset: Int = 0) -> ToolCallRecord {
    ToolCallRecord(id: id, name: ToolNames.webFetch, arguments: "{\"url\":\"https://e.com/\",\"offset\":\(offset)}", result: "", isError: false)
}

/// A turn of `rounds` rounds: thinking, a preamble, then a search (and a page read on even rounds).
private func manyRounds(_ rounds: Int) -> [ProcessSegment] {
    var out: [ProcessSegment] = []
    func add(_ kind: ProcessSegment.Kind, text: String = "", seconds: Double? = nil, calls: [ToolCallRecord] = []) {
        out.append(ProcessSegment(index: out.count, kind: kind, text: text, seconds: seconds, calls: calls))
    }
    for r in 0..<rounds {
        add(.thinking, text: "thought \(r)", seconds: 10)
        add(.text, text: "preamble \(r)")
        add(.toolRound, calls: r % 2 == 0 ? [search("s\(r)"), fetch("f\(r)")] : [search("s\(r)")])
    }
    return out
}

@MainActor
struct MessageLayoutTests {
    @Test func aManyRoundTurnIsOneSummaryRowAndTheAnswer() {
        let segments = manyRounds(8)
        #expect(segments.count == 24)
        let items = MessageLayout.items(segmentCount: segments.count, tail: .none, isStreaming: false, hasAnswer: true)
        #expect(items == [.summary, .divider, .text])
    }

    @Test func summaryCountsAndTitle() {
        let summary = ProcessSummary(segments: manyRounds(8))
        #expect(summary.searches == 8 && summary.pages == 4)
        #expect(summary.seconds == 80)
        #expect(summary.title == "Thought for 1m 20s · 8 searches · 4 pages")
        // Continuations are not new pages.
        let more = ProcessSummary(segments: [.init(index: 0, kind: .toolRound, calls: [fetch("a"), fetch("b", offset: 100)])])
        #expect(more.pages == 1 && more.title == "1 page")
    }

    @Test func aSingleThinkingRoundIsOneRow() {
        let segments: [ProcessSegment] = [.init(index: 0, kind: .thinking, text: "hm", seconds: 4)]
        #expect(ProcessSummary(segments: segments).title == "Thought for 4s")
        #expect(MessageLayout.items(segmentCount: 1, tail: .none, isStreaming: false, hasAnswer: true) == [.summary, .divider, .text])
        // The time falls back to the message's total when the segment has none.
        let bare: [ProcessSegment] = [.init(index: 0, kind: .thinking, text: "hm")]
        #expect(ProcessSummary(segments: bare, fallbackSeconds: 7).seconds == 7)
    }

    @Test func durationFormat() {
        #expect(ProcessSummary.duration(0.2) == "1s")
        #expect(ProcessSummary.duration(59) == "59s")
        #expect(ProcessSummary.duration(60) == "1m 0s")
        #expect(ProcessSummary.duration(82) == "1m 22s")
    }

    @Test func noDividerWhileStreamingAndNoSummaryBeforeAnythingFinished() {
        #expect(MessageLayout.items(segmentCount: 0, tail: .thinking, isStreaming: true, hasAnswer: false) == [.liveThinking])
        #expect(MessageLayout.items(segmentCount: 3, tail: .text, isStreaming: true, hasAnswer: true) == [.summary, .text])
        #expect(MessageLayout.items(segmentCount: 3, tail: .tools, isStreaming: true, hasAnswer: false) == [.summary, .liveTools])
        #expect(MessageLayout.items(segmentCount: 0, tail: .none, isStreaming: false, hasAnswer: true) == [.text], "no summary, no divider")
        // A stopped turn with steps but no answer is just the summary.
        #expect(MessageLayout.items(segmentCount: 2, tail: .none, isStreaming: false, hasAnswer: false) == [.summary])
    }

    @Test func theTextBeingWrittenKeepsItsIdentityWhenTheAnswerIsFinal() {
        let live = MessageLayout.items(segmentCount: 5, tail: .text, isStreaming: true, hasAnswer: true)
        let done = MessageLayout.items(segmentCount: 5, tail: .none, isStreaming: false, hasAnswer: true)
        #expect(live.last?.id == done.last?.id)
    }

    @Test func tailRules() {
        #expect(MessageLayout.tail(isStreaming: false, pendingCount: 2, hasRoundText: true) == .none)
        #expect(MessageLayout.tail(isStreaming: true, pendingCount: 2, hasRoundText: true) == .tools, "tool rows stay visible even with a preamble")
        #expect(MessageLayout.tail(isStreaming: true, pendingCount: 0, hasRoundText: true) == .text)
        #expect(MessageLayout.tail(isStreaming: true, pendingCount: 0, hasRoundText: false) == .thinking)
    }

    @Test func aMultiRoundStreamNeverGrowsAListAndFoldsEachStep() {
        // think -> text -> tools -> think -> text -> tools -> final text
        let all = manyRounds(2)
        func items(_ done: Int, _ tail: MessageLayout.Tail, streaming: Bool = true, answer: Bool = false) -> [MessageLayout.Item] {
            MessageLayout.items(segmentCount: done, tail: tail, isStreaming: streaming, hasAnswer: answer)
        }
        let states: [[MessageLayout.Item]] = [
            items(0, .thinking), items(1, .text), items(2, .tools), items(3, .thinking), items(4, .text), items(5, .tools),
            items(6, .thinking), items(6, .text), items(6, .none, streaming: false, answer: true),
        ]
        #expect(all.count == 6)
        #expect(states.map(\.count) == [1, 2, 2, 2, 2, 2, 2, 2, 3], "one summary and one tail at most; the divider only at the end")
        #expect(states.dropLast().allSatisfy { !$0.contains(.divider) })
        #expect(states.last == [.summary, .divider, .text])
    }

    @Test func inlineExpansionIsCappedAndOrdered() {
        let segments = manyRounds(8)
        let shown = ProcessSummaryBlock.visible(segments)
        #expect(shown.count == ProcessSummaryBlock.inlineLimit)
        #expect(shown.map(\.index) == Array(0..<12))
        let preambles = segments.filter { $0.kind == .text }.map(\.text)
        #expect(Set(preambles).count == preambles.count, "each preamble appears once")
    }
}

/// Gates a tool call so the running state can be inspected.
private final class GateTools: ToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func release() { lock.withLock { open = true } }
    func execute(name: String, arguments: String) async -> ToolOutput {
        while !lock.withLock({ open }) { try? await Task.sleep(for: .milliseconds(5)) }
        return ToolOutput(text: "result")
    }
}

@MainActor
struct MessageLayoutControllerTests {
    @Test func aPreambleRoundShowsItsToolRowsAndTheTextExistsOnce() async throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.strataID)
        var strata = connections.connection(Connection.strataID)!
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let call = ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}")])
        let streamer = ProgrammableStreamer([([ChatDelta(content: "Let me search."), call], .finish), ([ChatDelta(content: "The answer.")], .finish)])
        let gate = GateTools()
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults), streamer: streamer, tools: gate)
        let conversation = Conversation(connectionID: Connection.strataID, modelID: "m", effort: .medium)
        context.insert(conversation)
        controller.send(text: "hi", images: [], conversation: conversation, context: context)

        for _ in 0..<400 where controller.pendingCalls.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let assistant = try #require(conversation.sortedMessages.last { $0.role == .assistant })
        let render = controller.renderState(for: assistant)
        // The preamble has been folded into a segment and the round's text view is empty: no duplicate.
        #expect(assistant.segments.map(\.kind) == [.text])
        #expect(assistant.segments.first?.text == "Let me search.")
        #expect(!render.markdown.hasContent)
        let tail = MessageLayout.tail(isStreaming: controller.isStreaming, pendingCount: controller.pendingCalls.count,
                                      hasRoundText: render.markdown.hasContent)
        #expect(tail == .tools, "the running tool row is visible although the round had a preamble")
        #expect(controller.roundRequested.map(\.id) == ["c1"])
        #expect(MessageLayout.items(segmentCount: assistant.segments.count, tail: tail, isStreaming: true, hasAnswer: false) == [.summary, .liveTools])

        gate.release()
        await controller.waitUntilIdle()
        let liveFinal = MessageLayout.items(segmentCount: assistant.segments.count, tail: .none, isStreaming: false,
                                            hasAnswer: render.markdown.hasContent)
        #expect(liveFinal == [.summary, .divider, .text])
        #expect(assistant.text == "The answer.")
        #expect(assistant.segments.filter { $0.kind == .text }.map(\.text) == ["Let me search."])

        // Reloading the saved message gives the same layout and the same content.
        try context.save()
        let fresh = ModelContext(container)
        let reloaded = try #require(fresh.fetch(FetchDescriptor<Message>()).first { $0.role == .assistant })
        #expect(reloaded.segments == assistant.segments)
        let reloadedRender = controller.renderState(for: reloaded)
        let reloadedLayout = MessageLayout.items(segmentCount: reloaded.segments.count, tail: .none, isStreaming: false,
                                                 hasAnswer: reloadedRender.markdown.hasContent)
        #expect(reloadedLayout == liveFinal)
        #expect(ProcessSummary(segments: reloaded.segments) == ProcessSummary(segments: assistant.segments))
        #expect(ProcessSummary(segments: reloaded.segments).searches == 1)
    }
}
