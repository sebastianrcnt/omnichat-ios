import Testing
import Foundation
import SwiftData
@testable import Strata

@MainActor
struct ProcessSegmentTests {
    private func call(_ id: String, _ name: String, _ args: String, sources: [Int] = []) -> ToolCallRecord {
        ToolCallRecord(id: id, name: name, arguments: args, result: "", isError: false, sourceIDs: sources)
    }

    @Test func deriveKeepsStreamOrderForLegacyMessages() {
        let steps = [
            ToolStep(assistantContent: "Let me search.", calls: [call("a", "web_search", "{\"query\":\"q\"}", sources: [1, 2])], reasoningParagraphs: 1),
            ToolStep(assistantContent: "", calls: [call("b", "web_fetch", "{\"url\":\"https://a.com\"}")], reasoningParagraphs: 2),
        ]
        let segs = ProcessSegments.derive(steps: steps, reasoning: "one\n\ntwo\n\nthree", thinkingSeconds: nil)
        #expect(segs.map(\.kind) == [.thinking, .text, .toolRound, .thinking, .toolRound, .thinking])
        #expect(segs.map(\.index) == [0, 1, 2, 3, 4, 5])
        #expect(segs[0].text == "one" && segs[3].text == "two" && segs[5].text == "three")
        #expect(segs[1].text == "Let me search.")
    }

    @Test func deriveWithoutReasoningOrStepsIsEmpty() {
        #expect(ProcessSegments.derive(steps: [], reasoning: "").isEmpty)
    }

    @Test func singleThinkingSegmentGetsTheTotalSeconds() {
        let segs = ProcessSegments.derive(steps: [], reasoning: "just thinking", thinkingSeconds: 7)
        #expect(segs.count == 1 && segs[0].seconds == 7)
        let two = ProcessSegments.derive(steps: [ToolStep(assistantContent: "", calls: [], reasoningParagraphs: 1)], reasoning: "a\n\nb", thinkingSeconds: 7)
        #expect(two.filter { $0.kind == .thinking }.allSatisfy { $0.seconds == nil })
    }

    @Test func toolTitleCountsDistinctSitesAndPages() {
        let search = call("a", "web_search", "{}", sources: [1, 2, 3, 4, 5])
        #expect(ProcessSegment.toolTitle(calls: [search]) == "Searched 5 sites")
        let fetch = call("b", "web_fetch", "{\"url\":\"https://a.com\"}")
        #expect(ProcessSegment.toolTitle(calls: [search, fetch]) == "Searched 5 sites · Read 1 page")
        #expect(ProcessSegment.toolTitle(calls: [fetch, fetch]) == "Read 2 pages")
        #expect(ProcessSegment.toolTitle(calls: [call("c", "web_search", "{}")]) == "Searched the web")
        // Overlapping results across two searches count once.
        #expect(ProcessSegment.toolTitle(calls: [call("a", "web_search", "{}", sources: [1, 2]), call("b", "web_search", "{}", sources: [2, 3])]) == "Searched 3 sites")
    }

    @Test func segmentsRoundTripThroughTheMessage() throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let m = Message(role: .assistant, sortIndex: 0)
        container.mainContext.insert(m)
        m.segments = [.init(index: 0, kind: .thinking, text: "t", seconds: 3), .init(index: 1, kind: .toolRound, calls: [call("a", "web_search", "{}", sources: [1])])]
        try container.mainContext.save()
        #expect(m.segmentsData != nil)
        #expect(m.segments.map(\.kind) == [.thinking, .toolRound])
        #expect(m.segments[0].seconds == 3 && m.segments[1].calls.first?.sourceIDs == [1])
    }

    @Test func messagesWithoutPersistedSegmentsDeriveThem() {
        let m = Message(role: .assistant, sortIndex: 0)
        m.reasoning = "plan\n\nmore"
        m.steps = [ToolStep(assistantContent: "", calls: [call("a", "web_search", "{}")], reasoningParagraphs: 1)]
        #expect(m.segmentsData == nil)
        #expect(m.segments.map(\.kind) == [.thinking, .toolRound, .thinking])
    }
}

@MainActor
struct ProcessSegmentTurnTests {
    @Test func aStreamedTurnPersistsSegmentsInOrder() async throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.strataID)
        var strata = connections.connection(Connection.strataID)!
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let toolCall = ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}")])
        let streamer = ProgrammableStreamer([
            ([ChatDelta(reasoning: "need data"), ChatDelta(content: "Let me check."), toolCall], .finish),
            ([ChatDelta(reasoning: "got it"), ChatDelta(content: "The answer.")], .finish),
        ])
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults), streamer: streamer, tools: FakeTools())
        let conversation = Conversation(connectionID: Connection.strataID, modelID: "m", effort: .medium)
        context.insert(conversation)
        controller.send(text: "hi", images: [], conversation: conversation, context: context)
        await controller.waitUntilIdle()
        let m = try #require(conversation.sortedMessages.last { $0.role == .assistant })
        #expect(m.text == "The answer.")
        #expect(m.segmentsData != nil)
        let segs = m.segments
        #expect(segs.map(\.kind) == [.thinking, .text, .toolRound, .thinking])
        #expect(segs[0].text == "need data" && segs[1].text == "Let me check." && segs[3].text == "got it")
        #expect(segs[2].calls.map(\.id) == ["c1"])
    }
}
