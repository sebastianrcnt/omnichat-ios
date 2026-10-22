import Foundation
import SwiftData
import Testing
@testable import Strata

@MainActor
struct ReasoningSpacesTests {
    @Test func collapsesRunsOfAsciiSpacesOnly() {
        #expect(ReasoningSpaces.collapse("explanation of  the   name") == "explanation of the name")
        #expect(ReasoningSpaces.collapse("a\tb  \n  c") == "a\tb \n c")
        #expect(ReasoningSpaces.collapse("a\u{00A0}\u{00A0}b \u{2007} c") == "a\u{00A0}\u{00A0}b \u{2007} c", "no-break and figure spaces stay")
        #expect(ReasoningSpaces.collapse("plain text") == "plain text")
    }

    @Test func aRunSplitAcrossDeltasStillCollapses() {
        #expect(ReasoningSpaces.collapse(" next", after: " ") == "next")
        #expect(ReasoningSpaces.collapse("  next", after: " ") == "next")
        #expect(ReasoningSpaces.collapse(" next", after: "x") == " next")
    }

    @Test func theModelCollapsesIncrementallyAndKeepsTheRawTextWithTheCaller() async {
        let m = ReasoningChunkModel(smoothing: false)
        m.append("explanation of ")
        m.append(" the  ")
        m.append(" name.\n\nSecond  para")
        m.revealAll()
        #expect(m.text == "explanation of the name.\n\nSecond para")
        #expect(m.finalized.map(\.text) == ["explanation of the name."])
        #expect(m.tail == "Second para")
        // Loading finished history applies the same display rule.
        #expect(ReasoningChunkModel(text: "a  b").text == "a b")
    }
}

@MainActor
struct DecodeCacheTests {
    @Test func segmentsAreDecodedOnceAndNeverServedStale() throws {
        let m = Message(role: .assistant, sortIndex: 0)
        let a = [ProcessSegment(index: 0, kind: .text, text: "one")]
        m.segments = a
        #expect(m.segments == a)
        #expect(m.segments == a)
        let b = a + [ProcessSegment(index: 1, kind: .text, text: "two")]
        m.segments = b
        #expect(m.segments == b)
    }

    @Test func derivedSegmentsFromOldMessagesAreCached() {
        let m = Message(role: .assistant, sortIndex: 0)
        m.reasoning = "First thought.\n\nSecond thought."
        let call = ToolCallRecord(id: "c", name: ToolNames.webSearch, arguments: "{}", result: String(repeating: "x", count: 5000), isError: false, sourceIDs: [1])
        m.steps = [ToolStep(assistantContent: "Let me look.", calls: [call], reasoningParagraphs: 1)]
        let first = m.segments
        #expect(first == m.segments)
        #expect(first.contains { $0.kind == .toolRound })
        #expect(first.flatMap(\.calls).allSatisfy { $0.result.isEmpty }, "segments hold display data only")
    }

    @Test func segmentsCarryNoToolResultText() throws {
        let call = ToolCallRecord(id: "c", name: ToolNames.webFetch, arguments: "{\"url\":\"https://e.com\"}", result: "PAGE BODY", isError: false, sourceIDs: [3])
        let slim = call.displayOnly
        #expect(slim.result.isEmpty && slim.sourceIDs == [3] && slim.primaryArgument == "https://e.com")
    }
}

@MainActor
struct PendingTurnQueryTests {
    @Test func onlyUnfinishedTurnsAreFetched() throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let conversation = Conversation()
        context.insert(conversation)
        for i in 0..<30 {
            let m = Message(role: .assistant, text: "done \(i)", sortIndex: i)
            m.conversation = conversation
            context.insert(m)
        }
        let pending = Message(role: .assistant, sortIndex: 99)
        pending.conversation = conversation
        pending.resumeData = Data("x".utf8)
        pending.hasResume = true
        let cancelling = Message(role: .assistant, sortIndex: 100)
        cancelling.conversation = conversation
        cancelling.cancelPending = true
        context.insert(pending); context.insert(cancelling)
        try context.save()
        let found = ChatController.pendingMessages(context: context, defaults: defaults)
        #expect(Set(found.map(\.sortIndex)) == [99, 100])
    }

    @Test func turnsSavedBeforeTheFlagAreFlaggedOnce() throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let old = Message(role: .assistant, sortIndex: 1)
        old.resumeData = Data("legacy".utf8) // saved by a build without hasResume
        context.insert(old)
        try context.save()
        #expect(ChatController.pendingMessages(context: context, defaults: defaults).map(\.sortIndex) == [1])
        #expect(old.hasResume)
    }
}

@MainActor
struct CheckpointFormatTests {
    @Test func staticHalfStoresTheBodyAsRawBytesAndRestoresTheHistory() throws {
        let messages: [APIMessage] = [.user("hi"), .assistant("yo"), .user("again")]
        var cp = TurnCheckpoint()
        cp.requestData = try ChatRequest(model: "m", messages: messages).encoded()
        cp.submissionStarted = true
        cp.round = 2
        let data = try TurnCheckpoint.encodeStatic(cp)
        let body = try #require(cp.requestData)
        #expect(data.count < body.count + 200, "raw body, not base64 inside JSON")
        let restored = try TurnCheckpoint.restore(staticData: data, dynamicData: nil)
        #expect(try restored.messages == messages)
        #expect(restored.requestData == body && restored.round == 2 && restored.idempotencyKey == cp.idempotencyKey)
    }

    @Test func theRunnerDoesNotEncodeTheHistoryItself() {
        let cp = TurnCheckpoint()
        #expect(cp.messagesData.isEmpty)
    }
}
