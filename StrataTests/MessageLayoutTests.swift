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
    private func items(_ segments: [ProcessSegment], hasThought: Bool = true, liveCalls: Bool = false, streaming: Bool = false,
                       working: Bool = false, answer: Bool = true) -> [MessageLayout.Item] {
        MessageLayout.items(hasThought: hasThought, parts: MessageLayout.parts(segments: segments, hasLiveCalls: liveCalls),
                            isStreaming: streaming, isWorking: working, hasAnswer: answer)
    }

    @Test func aManyRoundTurnShowsEachRoundInOrder() {
        let segments = manyRounds(3)
        #expect(items(segments) == [.reasoning(0), .note(1), .feed(0), .reasoning(3), .note(4), .feed(1),
                                    .reasoning(6), .note(7), .feed(2), .text])
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
        #expect(items(segments) == [.reasoning(0), .text])
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

    @Test func theLiveLineClosesTheWorkWhileTheModelWorks() {
        let round: [ProcessSegment] = [.init(index: 0, kind: .thinking, text: "a", seconds: 2),
                                       .init(index: 1, kind: .toolRound, calls: [search("s")])]
        #expect(items([], hasThought: false, streaming: true, working: true, answer: false) == [.working])
        #expect(items(round, liveCalls: true, streaming: true, working: true, answer: false) == [.reasoning(0), .feed(0), .working])
        // Once the answer is being written the live line goes; the round's thought line stays where it was.
        #expect(items(round, streaming: true, working: false) == [.reasoning(0), .feed(0), .text])
        #expect(items(round) == [.reasoning(0), .feed(0), .text])
        // A finished answer without reasoning or tools is just the text.
        #expect(items([], hasThought: false) == [.text])
        // A stopped turn with steps but no answer keeps its lines and cards.
        #expect(items(round, answer: false) == [.reasoning(0), .feed(0)])
    }

    @Test func aMessageWithoutRoundThinkingKeepsOneLineOnTop() {
        let round: [ProcessSegment] = [.init(index: 0, kind: .toolRound, calls: [search("s")])]
        #expect(items(round) == [.thought, .feed(0), .text])
        #expect(items(round, hasThought: false) == [.feed(0), .text])
    }

    @Test func theTextBeingWrittenKeepsItsIdentityWhenTheAnswerIsFinal() {
        let round: [ProcessSegment] = [.init(index: 0, kind: .thinking, text: "a"), .init(index: 1, kind: .toolRound, calls: [search("s")])]
        #expect(items(round, streaming: true) == items(round))
    }

    @Test func theAnswerStartsWhenTextArrivesWithNoCallRunning() {
        #expect(!MessageLayout.answerStarted(isStreaming: false, pendingCount: 0, hasRoundText: true))
        #expect(!MessageLayout.answerStarted(isStreaming: true, pendingCount: 2, hasRoundText: true), "a preamble before calls is not the answer")
        #expect(MessageLayout.answerStarted(isStreaming: true, pendingCount: 0, hasRoundText: true))
        #expect(!MessageLayout.answerStarted(isStreaming: true, pendingCount: 0, hasRoundText: false))
    }

    @Test func thinkingBetweenRoundsSplitsTheFeed() {
        let segments: [ProcessSegment] = [.init(index: 0, kind: .toolRound, calls: [search("a")]),
                                          .init(index: 1, kind: .thinking, text: "next", seconds: 3),
                                          .init(index: 2, kind: .toolRound, calls: [search("b")])]
        #expect(items(segments) == [.feed(0), .reasoning(1), .feed(1), .text])
        #expect(MessageLayout.parts(segments: segments, hasLiveCalls: false)[1] == .thought(segment: 1, seconds: 3, line: "next"))
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
        try connections.setAPIKey("k", for: Connection.testID)
        var strata = connections.testGateway()
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let call = ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}")])
        let streamer = ProgrammableStreamer([([ChatDelta(content: "Let me search."), call], .finish), ([ChatDelta(content: "The answer.")], .finish)])
        let gate = GateTools()
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults), streamer: streamer, tools: gate)
        let conversation = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
        context.insert(conversation)
        controller.send(text: "hi", images: [], conversation: conversation, context: context)

        for _ in 0..<400 where controller.pendingCalls.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let assistant = try #require(conversation.sortedMessages.last { $0.role == .assistant })
        let render = controller.renderState(for: assistant)
        // The preamble has been folded into a segment and the round's text view is empty: no duplicate.
        #expect(assistant.segments.map(\.kind) == [.text])
        #expect(assistant.segments.first?.text == "Let me search.")
        #expect(!render.markdown.hasContent)
        #expect(!MessageLayout.answerStarted(isStreaming: controller.isStreaming, pendingCount: controller.pendingCalls.count,
                                             hasRoundText: render.markdown.hasContent), "a preamble round is still working")
        #expect(controller.roundRequested.map(\.id) == ["c1"])
        let running = FeedCall.ordered(finished: assistant.segments.flatMap(\.calls), requested: controller.roundRequested,
                                       roundFinished: controller.roundRecords)
        #expect(running.map(\.status) == [.running], "the running search has its card")
        // The preamble stays on screen, as a note above the running round's feed.
        let liveParts = MessageLayout.parts(segments: assistant.segments, hasLiveCalls: !controller.roundRequested.isEmpty)
        #expect(MessageLayout.items(hasThought: false, parts: liveParts, isStreaming: true, isWorking: true, hasAnswer: false)
                == [.note(0), .feed(0), .working])

        gate.release()
        await controller.waitUntilIdle()
        let liveCalls = FeedCall.ordered(finished: assistant.segments.flatMap(\.calls), requested: [], roundFinished: [])
        let liveFinal = MessageLayout.items(hasThought: false, parts: MessageLayout.parts(segments: assistant.segments, hasLiveCalls: false),
                                            isStreaming: false, isWorking: false, hasAnswer: render.markdown.hasContent)
        #expect(liveFinal == [.note(0), .feed(0), .text])
        #expect(MessageLayout.fullText(segments: assistant.segments, answer: assistant.text) == "Let me search.\n\nThe answer.")
        #expect(assistant.text == "The answer.")
        #expect(assistant.segments.filter { $0.kind == .text }.map(\.text) == ["Let me search."])

        // Reloading the saved message gives the same layout and the same content.
        try context.save()
        let fresh = ModelContext(container)
        let reloaded = try #require(fresh.fetch(FetchDescriptor<Message>()).first { $0.role == .assistant })
        #expect(reloaded.segments == assistant.segments)
        let reloadedRender = controller.renderState(for: reloaded)
        let reloadedCalls = FeedCall.ordered(finished: reloaded.segments.flatMap(\.calls), requested: [], roundFinished: [])
        #expect(reloadedCalls == liveCalls)
        let reloadedLayout = MessageLayout.items(hasThought: false, parts: MessageLayout.parts(segments: reloaded.segments, hasLiveCalls: false),
                                                 isStreaming: false, isWorking: false, hasAnswer: reloadedRender.markdown.hasContent)
        #expect(reloadedLayout == liveFinal)
        #expect(ProcessSummary(segments: reloaded.segments) == ProcessSummary(segments: assistant.segments))
        #expect(ProcessSummary(segments: reloaded.segments).searches == 1)
    }
}

struct MessagePartsTests {
    @Test func newWordsOfAThoughtFadeIn() {
        let now = Date()
        let spans = [StreamingMarkdownModel.FreshSpan(length: 3, born: now.addingTimeInterval(-1), duration: 0.15),
                     StreamingMarkdownModel.FreshSpan(length: 4, born: now, duration: 0.15)]
        let out = ReasoningLinePreview.fading("Hello world", spans: spans, now: now, color: .gray)
        #expect(String(out.characters) == "Hello world")
        let faded = out.runs.filter { $0.foregroundColor != nil }.map { String(out[$0.range].characters) }
        #expect(faded == ["orld"], "only the newest, still fading span is faint")
    }

    @Test func workLinesAreOneListAndTextStandsOff() {
        #expect(MessageLayout.gap(above: .reasoning(0), after: nil) == 0)
        let lines = [MessageLayout.gap(above: .feed(0), after: .reasoning(0)), MessageLayout.gap(above: .reasoning(3), after: .feed(0)),
                     MessageLayout.gap(above: .working, after: .feed(0)), MessageLayout.gap(above: .feed(0), after: .thought)]
        #expect(Set(lines) == [MessageLayout.lineGap])
        let text = [MessageLayout.gap(above: .note(1), after: .reasoning(0)), MessageLayout.gap(above: .feed(0), after: .note(1)),
                    MessageLayout.gap(above: .text, after: .reasoning(3))]
        #expect(Set(text) == [16])
    }

    @Test func aThoughtLineIsItsLastLineWithoutMarkdown() {
        #expect(MessageLayout.lastLine(of: "**Planning**\n\nFirst I search.\nThen I read `the page`.\n\n") == "Then I read the page.")
        #expect(MessageLayout.lastLine(of: "## Checking sources\n- ") == "Checking sources")
        #expect(MessageLayout.lastLine(of: "- **Also** Marmot?") == "Also Marmot?")
        #expect(MessageLayout.lastLine(of: " \n\n") == nil)
    }

    @Test @MainActor func aNewSectionDropsTheOldSentenceFromThePreview() {
        let model = ReasoningChunkModel(smoothing: false)
        model.isDisplayActive = { false }
        model.append("Also Marmot?")
        model.revealAll()
        #expect(model.thought?.text == "Also Marmot?")
        model.beginSection()
        #expect(model.thought == nil)
        model.append("Now the reviews.")
        model.revealAll()
        #expect(model.thought?.text == "Now the reviews.")
    }

    private func search(_ id: String) -> ToolCallRecord {
        ToolCallRecord(id: id, name: "web_search", arguments: "{\"query\":\"q\"}", result: "", isError: false)
    }

    @Test func notesSplitTheFeedInStreamOrder() {
        let segments: [ProcessSegment] = [
            .init(index: 0, kind: .thinking, text: "hmm"),
            .init(index: 1, kind: .toolRound, calls: [search("a")]),
            .init(index: 2, kind: .toolRound, calls: [search("b")]),
            .init(index: 3, kind: .text, text: "Found it. Checking one more thing."),
            .init(index: 4, kind: .toolRound, calls: [search("c")]),
        ]
        let parts = MessageLayout.parts(segments: segments, hasLiveCalls: false)
        #expect(parts == [.thought(segment: 0, seconds: nil, line: "hmm"), .calls([search("a"), search("b")]),
                          .note(segment: 3, text: "Found it. Checking one more thing."), .calls([search("c")])])
        #expect(MessageLayout.items(hasThought: true, parts: parts, isStreaming: false, isWorking: false, hasAnswer: true)
                == [.reasoning(0), .feed(0), .note(3), .feed(1), .text])
    }

    @Test func liveCallsAfterANoteStartANewFeed() {
        let note: [ProcessSegment] = [.init(index: 0, kind: .text, text: "Let me look.")]
        #expect(MessageLayout.parts(segments: note, hasLiveCalls: true) == [.note(segment: 0, text: "Let me look."), .calls([])])
        #expect(MessageLayout.parts(segments: [], hasLiveCalls: true) == [.calls([])])
        let round: [ProcessSegment] = [.init(index: 0, kind: .toolRound, calls: [search("a")])]
        #expect(MessageLayout.parts(segments: round, hasLiveCalls: true) == [.calls([search("a")])])
    }

    @Test func timelineShowsTheNoteBeforeItsCalls() {
        let step = ToolStep(assistantContent: " Let me check. ", calls: [search("a")], reasoningParagraphs: 1)
        let items = TimelineItem.build(chunks: ["p0", "p1"], steps: [step], pending: [], sources: [:])
        #expect(items.map(\.id) == ["t0", "n0", "a", "t1"])
    }
}

struct ReplyNotificationTests {
    @Test func theBodyIsTheStartOfTheAnswerAsPlainText() {
        let body = ChatController.notificationBody("## Result\n\n**Yes**, it works.\n\n- one\n- two", limit: 20)
        #expect(!body.contains("**") && !body.contains("##"))
        #expect(body.hasPrefix("Result Yes, it works"))
        #expect(body.hasSuffix("…"))
        #expect(ChatController.notificationBody("Short.") == "Short.")
    }
}
