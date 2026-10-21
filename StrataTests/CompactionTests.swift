import Testing
import Foundation
import SwiftData
@testable import Strata

// MARK: - Pure pieces

struct CompactionMathTests {
    @Test func theLimitKeepsTenPercentOrSixteenThousandFree() {
        #expect(Compaction.limit(window: 1_000_000, maxOutput: nil) == 900_000)
        #expect(Compaction.limit(window: 100_000, maxOutput: nil) == 84_000)  // the 16k floor is more than 10%
        #expect(Compaction.limit(window: 20_000, maxOutput: nil) == 18_000)   // too small to give up 16k: 10%
        #expect(Compaction.limit(window: 0, maxOutput: nil) == 0)
    }

    @Test func theOutputLimitCapsTheRoomButAFullAnswerIsNotReserved() {
        // DeepSeek V4.1 Flash: 1M window, 384k output. It used to compact at 616k.
        #expect(Compaction.limit(window: 1_000_000, maxOutput: 384_000) == 900_000)
        #expect(Compaction.limit(window: 100_000, maxOutput: 20_000) == 84_000)
        #expect(Compaction.limit(window: 100_000, maxOutput: 5_000) == 95_000)  // no more room than the reply can take
        #expect(Compaction.limit(window: 10_000, maxOutput: 50_000) == 9_000)   // never 0 (never compacting)
    }

    @Test func theMeterIsLastUsagePlusACharacterEstimateOfWhatCameAfter() {
        var m = ContextMeter(usage: Usage(promptTokens: 1000, completionTokens: 200))
        #expect(m.tokens == 1200)
        m.append(.tool(callID: "c", content: String(repeating: "a b ", count: 100))) // 400 chars
        #expect(m.tokens == 1300)
        m.record(Usage(promptTokens: 2000, completionTokens: 50)) // a new report replaces the estimate
        #expect(m.tokens == 2050)
        m.record(Usage(promptTokens: 0, completionTokens: 0)) // an empty report changes nothing
        #expect(m.tokens == 2050)
    }

    @Test func compactionIsDueAtTheLimitNotBefore() {
        let limit = 1000
        #expect(!Compaction.needsCompaction(ContextMeter(usageTokens: 999), limit: limit))
        #expect(Compaction.needsCompaction(ContextMeter(usageTokens: 1000), limit: limit))
        // The message about to be appended counts too.
        #expect(Compaction.needsCompaction(ContextMeter(usageTokens: 900), limit: limit, extraChars: 400))
        #expect(!Compaction.needsCompaction(ContextMeter(usageTokens: 900), limit: limit, extraChars: 399))
        #expect(!Compaction.needsCompaction(ContextMeter(usageTokens: 5000), limit: limit, hasMessages: false))
        #expect(!Compaction.needsCompaction(ContextMeter(usageTokens: 5000), limit: 0))
    }

    @Test func proseCountsAFourthAndDenseTextAThird() {
        let prose = String(repeating: "word ", count: 100) // 500 chars
        #expect(Compaction.estimateChars(prose) == 500)
        let dense = String(repeating: "a", count: 300) // one long unbroken run
        #expect(Compaction.estimateChars(dense) == 400)
        #expect(Compaction.estimateChars("short") == 5)
    }

    @Test func imagesCountAsTokens() {
        let m = APIMessage.user(parts: [.imageURL("data:image/jpeg;base64,AAAA"), .text("hi")])
        #expect(Compaction.messageChars(m) == Compaction.imageChars + 2)
    }

    @Test func overflowErrorsAreRecognized() {
        #expect(Compaction.isContextOverflow(APIError.http(status: 400, message: "This model's maximum context length is 8192 tokens")))
        #expect(Compaction.isContextOverflow(APIError.server("context_length_exceeded")))
        #expect(!Compaction.isContextOverflow(APIError.http(status: 401, message: "bad key")))
        #expect(!Compaction.isContextOverflow(APIError.transport("offline")))
    }

    @Test func cutNotesAreRecognized() {
        #expect(Compaction.cutReason(finishReason: "length", content: "x") != nil)
        #expect(Compaction.cutReason(finishReason: "tool_calls", content: "x") != nil)
        #expect(Compaction.cutReason(finishReason: "stop", content: "## Goal\nx\n## Next") != nil) // ends with a heading
        #expect(Compaction.cutReason(finishReason: "stop", content: "## Goal\n- x") == nil)
        #expect(Compaction.cutReason(finishReason: nil, content: "fine") == nil)
    }
}

struct CompactionRequestTests {
    private func base() -> ChatRequest {
        var r = ChatRequest(model: "m", messages: [
            .system("sys"), .user("hello"), .assistant("", toolCalls: [ToolCall(id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}")]),
            .tool(callID: "c1", content: "result"), .assistant("answer"),
        ])
        r.reasoningEffort = "high"
        r.tools = ToolDefinition.standard
        return r
    }

    @Test func itIsThePreviousRequestPlusOneMessage() throws {
        let previous = base()
        let c = Compaction.request(from: previous)
        #expect(c.messages.count == previous.messages.count + 1)
        #expect(Array(c.messages.dropLast()) == previous.messages)
        #expect(c.messages.last?.role == "user")
        #expect(Compaction.text(of: c.messages.last!).contains("handoff notes"))
        #expect(Compaction.text(of: c.messages.last!).contains("700 words"))
        #expect(c.toolChoice == "none")
        #expect(c.model == previous.model && c.reasoningEffort == previous.reasoningEffort && c.stream)
        #expect(c.tools == previous.tools) // same tools: the cached prefix includes them
        #expect(c.maxTokens == nil)
    }

    @Test func theRequestBodyKeepsThePreviousBodysPrefixBytes() throws {
        let previous = try base().encoded()
        let compaction = try Compaction.request(from: base()).encoded()
        let text = String(decoding: previous, as: UTF8.self)
        // Everything up to the end of the messages array: the history, byte for byte.
        let end = try #require(text.range(of: "],\"model\""))
        let prefix = String(text[text.startIndex..<end.lowerBound])
        #expect(prefix.hasPrefix("{\"messages\":["))
        #expect(String(decoding: compaction, as: UTF8.self).hasPrefix(prefix + ","))
    }

    @Test func aHistoryThatGrowsKeepsItsPrefixBytes() throws {
        // After a compaction the history is the replacement followed by what came after; adding a turn only appends.
        let replacement = Compaction.replacement(history: [.user("first question"), .assistant("first answer")], notes: "notes", retained: [])
        var messages: [APIMessage] = [.system("sys")] + replacement + [.user("next")]
        let a = try ChatRequest(model: "m", messages: messages).encoded()
        messages += [.assistant("reply"), .user("and then")]
        let b = try ChatRequest(model: "m", messages: messages).encoded()
        let aText = String(decoding: a, as: UTF8.self)
        let end = try #require(aText.range(of: "],\"model\""))
        #expect(String(decoding: b, as: UTF8.self).hasPrefix(String(aText[aText.startIndex..<end.lowerBound])))
    }
}

struct CompactionReplacementTests {
    @Test func keepsRecentUserMessagesThenTheNotes() {
        let history: [APIMessage] = [.user("one"), .assistant("a"), .user("two"), .assistant("b"), .user("three")]
        let r = Compaction.replacement(history: history, notes: "N", retained: [])
        #expect(r.map(Compaction.text(of:)) == ["one", "two", "three", Compaction.summaryPrefix + "N"])
        #expect(r.allSatisfy { $0.role == "user" }) // assistant text is not kept
    }

    @Test func recentMessagesWinTheBudgetNewestFirstInChronologicalOrder() {
        let big = String(repeating: "x", count: 50_000) // 12.5k tokens each
        let history: [APIMessage] = [.user("old " + big), .user("mid " + big), .user("new " + big)]
        let r = Compaction.replacement(history: history, notes: "N", retained: [])
        let texts = r.dropLast().map(Compaction.text(of:))
        // 20k tokens = 80k chars: the newest fits whole, the middle is cut to what is left, the oldest is gone.
        #expect(texts.count == 2)
        #expect(texts[1].hasPrefix("new "))
        #expect(texts[0].hasSuffix(Compaction.truncationNote))
        #expect(texts[0].count < 50_000)
        #expect(!texts.contains { $0.hasPrefix("old ") })
    }

    @Test func imagesBecomeAPlaceholder() {
        let m = APIMessage.user(parts: [.imageURL("data:image/jpeg;base64,AAAA"), .imageURL("data:image/jpeg;base64,BBBB"), .text("what is this")])
        let r = Compaction.replacement(history: [m], notes: "N", retained: [])
        #expect(Compaction.text(of: r[0]) == "what is this\n[image omitted by compaction]\n[image omitted by compaction]")
        if case .text = r[0].content {} else { Issue.record("a kept message is plain text") }
    }

    @Test func earlierNotesAreNotKeptTheNewOnesFoldThemIn() {
        let history: [APIMessage] = [.user("question"), .user(Compaction.summaryPrefix + "old notes"), .user("follow-up")]
        let r = Compaction.replacement(history: history, notes: "new notes", retained: [])
        #expect(r.map(Compaction.text(of:)) == ["question", "follow-up", Compaction.summaryPrefix + "new notes"])
        #expect(Compaction.notes(in: r) == "new notes")
    }

    @Test func aKeptToolGroupFollowsTheNotes() {
        let group: [APIMessage] = [.assistant("", toolCalls: [ToolCall(id: "c", name: "web_fetch", arguments: "{}")]), .tool(callID: "c", content: "page")]
        let r = Compaction.replacement(history: [.user("q")], notes: "N", retained: group)
        #expect(r.count == 4 && Array(r.suffix(2)) == group)
        #expect(Compaction.text(of: r[1]).hasPrefix(Compaction.summaryPrefix))
    }
}

struct CompactionFitTests {
    private func turn(_ n: Int, size: Int) -> [APIMessage] {
        [.user("question \(n) " + String(repeating: "q ", count: size / 2)),
         .assistant("", toolCalls: [ToolCall(id: "c\(n)", name: "web_fetch", arguments: "{}")]),
         .tool(callID: "c\(n)", content: String(repeating: "r ", count: size / 2)),
         .assistant("answer \(n)")]
    }

    private func request(_ turns: [[APIMessage]]) -> ChatRequest {
        var r = ChatRequest(model: "m", messages: [.system("sys")] + turns.flatMap { $0 })
        r = Compaction.request(from: r)
        return r
    }

    @Test func aRequestThatFitsIsLeftAlone() {
        var r = request([turn(1, size: 400), turn(2, size: 400)])
        let before = r
        let est = Compaction.chars(r.messages) / 4
        let fit = Compaction.fit(&r, window: 100_000, estimate: est, need: Compaction.room)
        #expect(fit.dropped == 0 && fit.kept.isEmpty)
        #expect(r.messages == before.messages)
        #expect(r.maxTokens == nil)
    }

    @Test func theOldestWholeTurnsAreDroppedFirst() {
        var r = request([turn(1, size: 4000), turn(2, size: 4000), turn(3, size: 4000)])
        let est = Compaction.chars(r.messages) / 4 // about 3k tokens
        let fit = Compaction.fit(&r, window: est + Compaction.room - 500, estimate: est, need: Compaction.room)
        #expect(fit.dropped > 0 && fit.dropped % 4 == 0) // whole turns of four messages
        #expect(r.messages.first?.role == "system")
        #expect(Compaction.text(of: r.messages[1]).hasPrefix("question 2") || Compaction.text(of: r.messages[1]).hasPrefix("question 3"))
        #expect(!r.messages.contains { Compaction.text(of: $0).hasPrefix("question 1") })
        #expect(Compaction.text(of: r.messages.last!).contains("handoff notes")) // the instruction is never dropped
        // A tool result never loses its call.
        for (i, m) in r.messages.enumerated() where m.role == "tool" {
            #expect(r.messages[i - 1].toolCalls.contains { $0.id == m.toolCallID })
        }
    }

    @Test func aLatestTurnTooBigAloneKeepsItsToolGroupOutOfTheSummary() {
        // One turn: a question, then a huge tool result. Only its trailing group can be kept out.
        let huge: [APIMessage] = [.user("go"), .assistant("", toolCalls: [ToolCall(id: "c", name: "web_fetch", arguments: "{}")]),
                                  .tool(callID: "c", content: String(repeating: "page ", count: 20_000))]
        var r = request([huge])
        let est = Compaction.chars(r.messages) / 4 // about 25k tokens
        let fit = Compaction.fit(&r, window: 28_000, estimate: est, need: Compaction.room)
        #expect(fit.kept == Array(huge.suffix(2)))
        #expect(r.messages.map(\.role) == ["system", "user", "user"]) // system, the question, the instruction
        #expect(fit.estimate < est)
    }

    @Test func maxTokensIsLoweredOnlyWhenTheRoomIsShort() {
        var r = request([[.user("question " + String(repeating: "q ", count: 200)), .assistant("answer")]])
        let est = Compaction.chars(r.messages) / 4
        let fit = Compaction.fit(&r, window: est + 3000 + Compaction.margin, estimate: est, need: Compaction.room)
        #expect(fit.dropped == 0 && fit.kept.isEmpty) // one turn: nothing to drop
        #expect(r.maxTokens == 3000)
    }
}

// MARK: - Compactor against a scripted model

final class NotesStreamer: ChatStreaming, @unchecked Sendable {
    enum Reply { case notes(String, finish: String), overflow, hang, fail(Error) }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [ChatRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }

    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        let reply: Reply = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? .notes("## Goal\n- done", finish: "stop") : replies.removeFirst()
        }
        return AsyncThrowingStream { c in
            switch reply {
            case .notes(let text, let finish):
                c.yield(ChatDelta(content: text))
                c.yield(ChatDelta(finishReason: finish))
                c.finish()
            case .overflow: c.finish(throwing: APIError.http(status: 400, message: "This model's maximum context length is 1000 tokens"))
            case .fail(let e): c.finish(throwing: e)
            case .hang: break
            }
        }
    }
}

struct CompactorTests {
    private func endpoint() -> Endpoint {
        Endpoint(connectionID: UUID(), connectionName: "t", baseURL: URL(string: "http://localhost/v1")!, apiKey: nil, headers: [:],
                 model: ModelInfo(id: "m", supportsTools: true))
    }

    private func history(turns: Int, size: Int = 400) -> [APIMessage] {
        (1...turns).flatMap { n -> [APIMessage] in
            [.user("question \(n) " + String(repeating: "q ", count: size / 2)),
             .assistant("", toolCalls: [ToolCall(id: "c\(n)", name: "web_fetch", arguments: "{}")]),
             .tool(callID: "c\(n)", content: String(repeating: "r ", count: size / 2)),
             .assistant("answer \(n)")]
        }
    }

    private func base(_ h: [APIMessage]) -> ChatRequest {
        var r = ChatRequest(model: "m", messages: [.system("sys")] + h)
        r.tools = ToolDefinition.standard
        return r
    }

    @Test func writesNotesAndBuildsTheReplacement() async throws {
        let h = history(turns: 3)
        let streamer = NotesStreamer([.notes("## Goal\n- the notes", finish: "stop")])
        let out = try await Compactor(streamer: streamer).compact(endpoint: endpoint(), base: base(h),
                                                                   meter: .estimate([.system("sys")] + h), window: 100_000)
        #expect(out.notes == "## Goal\n- the notes")
        #expect(out.replacement.map(Compaction.text(of:)).suffix(1) == [Compaction.summaryPrefix + "## Goal\n- the notes"])
        #expect(out.replacement.filter { $0.role == "user" }.count == 4) // three questions and the notes
        #expect(out.tokensAfter < out.tokensBefore)
        #expect(out.trimmed == 0 && out.requests == 1)
        let sent = try #require(streamer.requests.first)
        #expect(Array(sent.messages.dropLast()) == base(h).messages) // the request, unchanged, plus the instruction
        #expect(sent.toolChoice == "none")
    }

    @Test func notesThatAreCutOffAreWrittenAgainOnce() async throws {
        let streamer = NotesStreamer([.notes("## Goal\n- half", finish: "length"), .notes("## Goal\n- whole", finish: "stop")])
        let out = try await Compactor(streamer: streamer).compact(endpoint: endpoint(), base: base(history(turns: 2)),
                                                                   meter: ContextMeter(usageTokens: 900), window: 100_000)
        #expect(out.notes == "## Goal\n- whole")
        #expect(streamer.requests.count == 2)
    }

    @Test func notesCutOffTwiceFailAndLeaveTheConversationAlone() async throws {
        let streamer = NotesStreamer([.notes("## Goal\n- half", finish: "length"), .notes("## Goal\n## Next", finish: "stop")])
        await #expect(throws: CompactionError.self) {
            _ = try await Compactor(streamer: streamer).compact(endpoint: self.endpoint(), base: self.base(self.history(turns: 2)),
                                                                meter: ContextMeter(usageTokens: 900), window: 100_000)
        }
        #expect(streamer.requests.count == 2)
    }

    @Test func overflowDropsTheOldestTurnsFromTheRequestOnly() async throws {
        let h = history(turns: 5, size: 4000)
        let streamer = NotesStreamer([.overflow, .notes("## Goal\n- ok", finish: "stop")])
        let est = Compaction.chars([.system("sys")] + h) / 4
        // The first request fits with room for the notes; the server still refuses it, so the retry asks for more room.
        let out = try await Compactor(streamer: streamer).compact(endpoint: endpoint(), base: base(h),
                                                                   meter: ContextMeter(usageTokens: est), window: est + Compaction.room + 800)
        #expect(streamer.requests.count == 2)
        let first = streamer.requests[0].messages, second = streamer.requests[1].messages
        #expect(second.count < first.count) // the retry sent less
        #expect(out.trimmed > 0 && out.trimmed % 4 == 0)
        for sent in streamer.requests {
            for (i, m) in sent.messages.enumerated() where m.role == "tool" {
                #expect(sent.messages[i - 1].toolCalls.contains { $0.id == m.toolCallID }) // never a result without its call
            }
        }
        // The replacement is built from the whole history, so every question survives (within the budget).
        #expect(out.replacement.filter { $0.role == "user" }.count == 6)
    }

    @Test func overflowGivesUpAfterTwoRetries() async {
        let streamer = NotesStreamer([.overflow, .overflow, .overflow, .overflow])
        await #expect(throws: CompactionError.self) {
            _ = try await Compactor(streamer: streamer).compact(endpoint: self.endpoint(), base: self.base(self.history(turns: 6, size: 2000)),
                                                                meter: ContextMeter(usageTokens: 5000), window: 100_000)
        }
        #expect(streamer.requests.count == 3)
    }

    @Test func otherErrorsAreNotRetried() async {
        let streamer = NotesStreamer([.fail(APIError.http(status: 500, message: "boom"))])
        await #expect(throws: CompactionError.self) {
            _ = try await Compactor(streamer: streamer).compact(endpoint: self.endpoint(), base: self.base(self.history(turns: 2)),
                                                                meter: ContextMeter(usageTokens: 900), window: 100_000)
        }
        #expect(streamer.requests.count == 1)
    }

    @Test func nothingToCompactIsAnError() async {
        await #expect(throws: CompactionError.nothingToCompact) {
            _ = try await Compactor(streamer: NotesStreamer([])).compact(endpoint: self.endpoint(), base: self.base([]),
                                                                         meter: ContextMeter(), window: 1000)
        }
    }

    @Test func stoppingEndsItPromptly() async throws {
        let streamer = NotesStreamer([.hang])
        let ep = endpoint()
        let h = history(turns: 2)
        let task = Task { try await Compactor(streamer: streamer).compact(endpoint: ep, base: base(h), meter: ContextMeter(usageTokens: 900), window: 100_000) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }
}

// MARK: - Records and history

@MainActor
struct CompactionRecordTests {
    /// Containers must outlive their contexts, and a destructured tuple would drop them at once.
    nonisolated(unsafe) private static var containers: [ModelContainer] = []

    private func rig() throws -> (ModelContainer, ModelContext, Conversation) {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self, CompactionRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.containers.append(container)
        let context = container.mainContext
        let c = Conversation(connectionID: nil, modelID: "m")
        context.insert(c)
        return (container, context, c)
    }

    @discardableResult
    private func add(_ c: Conversation, _ context: ModelContext, _ role: MessageRole, _ text: String, steps: [ToolStep] = []) -> Message {
        let m = Message(role: role, text: text, sortIndex: (c.messages.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(m)
        c.attach(m, parent: c.leafMessage)
        if !steps.isEmpty { m.steps = steps }
        return m
    }

    private func record(_ c: Conversation, _ context: ModelContext, anchor: Message, steps: Int = -1, notes: String = "N",
                        at: Date = .now) throws -> CompactionRecord {
        let r = try CompactionRecord(anchorMessageID: anchor.id, anchorSteps: steps, notes: notes,
                                     replacement: [.user("kept"), .user(Compaction.summaryPrefix + notes)], tokensBefore: 900, tokensAfter: 100,
                                     isAutomatic: true, createdAt: at)
        context.insert(r)
        r.conversation = c
        try context.save()
        return r
    }

    @Test func aRecordSurvivesAReloadWithEverythingInIt() throws {
        let (container, context, c) = try rig()
        let a = add(c, context, .user, "q"), b = add(c, context, .assistant, "a")
        let r = try record(c, context, anchor: b, notes: "the notes")
        _ = a
        let fresh = ModelContext(container)
        let loaded = try #require(try fresh.fetch(FetchDescriptor<CompactionRecord>()).first)
        #expect(loaded.id == r.id && loaded.anchorMessageID == b.id && loaded.notes == "the notes")
        #expect(loaded.tokensBefore == 900 && loaded.tokensAfter == 100 && loaded.isAutomatic)
        #expect(loaded.coversWholeMessage)
        #expect(loaded.replacement == [.user("kept"), .user(Compaction.summaryPrefix + "the notes")])
        #expect(loaded.conversation?.id == c.id)
    }

    @Test func theTranscriptKeepsEveryOriginal() throws {
        let (_, context, c) = try rig()
        let a = add(c, context, .user, "q"), b = add(c, context, .assistant, "a")
        _ = try record(c, context, anchor: b)
        #expect(c.activePath.map(\.id) == [a.id, b.id]) // nothing removed from the path
        #expect(c.messages.count == 2)
    }

    @Test func historyIsTheReplacementThenWhatFollowsTheAnchor() throws {
        let (_, context, c) = try rig()
        add(c, context, .user, "q1"); let a1 = add(c, context, .assistant, "a1")
        add(c, context, .user, "q2"); add(c, context, .assistant, "a2")
        _ = try record(c, context, anchor: a1)
        let h = try #require(c.compactedHistory(path: c.activePath))
        #expect(h.replacement.count == 2)
        #expect(h.rest.map(\.text) == ["q2", "a2"])
        let api = MessageAssembler.apiMessages(from: h.rest, systemPrompt: "sys", replacing: h.replacement)
        #expect(api.map(Compaction.text(of:)) == ["sys", "kept", Compaction.summaryPrefix + "N", "q2", "a2"])
    }

    @Test func noCompactionMeansNoSplit() throws {
        let (_, context, c) = try rig()
        add(c, context, .user, "q")
        #expect(c.compactedHistory(path: c.activePath) == nil)
    }

    @Test func aCompactionInTheMiddleOfAnAnswerCoversOnlyItsFirstSteps() throws {
        let (_, context, c) = try rig()
        add(c, context, .user, "q")
        func step(_ n: Int) -> ToolStep {
            ToolStep(assistantContent: "", calls: [ToolCallRecord(id: "c\(n)", name: "web_fetch", arguments: "{}", result: "r\(n)", isError: false)])
        }
        let a = add(c, context, .assistant, "final", steps: [step(1), step(2), step(3)])
        _ = try record(c, context, anchor: a, steps: 2)
        let h = try #require(c.compactedHistory(path: c.activePath))
        #expect(h.rest.count == 1)
        #expect(h.rest[0].steps.map { $0.calls[0].id } == ["c3"]) // the steps after the compaction, then the text
        #expect(h.rest[0].text == "final")
        let api = MessageAssembler.apiMessages(from: h.rest, replacing: h.replacement)
        #expect(api.map(\.role) == ["user", "user", "assistant", "tool", "assistant"])
    }

    @Test func anAnswerWhollyCoveredLeavesNothingOfItself() throws {
        let (_, context, c) = try rig()
        add(c, context, .user, "q")
        let step = ToolStep(assistantContent: "", calls: [ToolCallRecord(id: "c1", name: "web_fetch", arguments: "{}", result: "r", isError: false)])
        let a = add(c, context, .assistant, "", steps: [step])
        _ = try record(c, context, anchor: a, steps: 1)
        let h = try #require(c.compactedHistory(path: c.activePath))
        #expect(h.rest.isEmpty)
    }

    @Test func aBranchThatDoesNotPassThroughTheAnchorIsUnaffected() throws {
        let (_, context, c) = try rig()
        let q1 = add(c, context, .user, "q1")
        let a1 = add(c, context, .assistant, "a1")
        _ = try record(c, context, anchor: a1)
        // Edit the first question: a sibling branch from the root.
        let q1b = Message(role: .user, text: "q1 edited", sortIndex: 10)
        context.insert(q1b)
        c.attach(q1b, parent: nil)
        #expect(c.activePath.map(\.id) == [q1b.id])
        #expect(c.compactedHistory(path: c.activePath) == nil)
        // Back on the first branch it applies again.
        c.setLeaf(a1.id)
        #expect(c.activePath.map(\.id) == [q1.id, a1.id])
        #expect(c.compactedHistory(path: c.activePath) != nil)
    }

    @Test func theLatestCompactionOnThePathWins() throws {
        let (_, context, c) = try rig()
        add(c, context, .user, "q1"); let a1 = add(c, context, .assistant, "a1")
        _ = try record(c, context, anchor: a1, notes: "first", at: Date(timeIntervalSince1970: 1))
        add(c, context, .user, "q2"); let a2 = add(c, context, .assistant, "a2")
        _ = try record(c, context, anchor: a2, notes: "second", at: Date(timeIntervalSince1970: 2))
        add(c, context, .user, "q3")
        let h = try #require(c.compactedHistory(path: c.activePath))
        #expect(Compaction.notes(in: h.replacement) == "second")
        #expect(h.rest.map(\.text) == ["q3"])
        let anchored = c.compactions(anchoredIn: c.activePath)
        #expect(anchored[a1.id]?.count == 1 && anchored[a2.id]?.count == 1) // both dividers show
    }

    @Test func deletingAConversationDeletesItsCompactions() throws {
        let (_, context, c) = try rig()
        add(c, context, .user, "q"); let a = add(c, context, .assistant, "a")
        _ = try record(c, context, anchor: a)
        context.delete(c)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<CompactionRecord>()).isEmpty)
    }
}

// MARK: - A turn, end to end

@MainActor
struct CompactionTurnTests {
    private struct Rig {
        let container: ModelContainer
        let controller: ChatController
        let context: ModelContext
        let conversation: Conversation
        let streamer: ProgrammableStreamer
    }

    private func rig(_ plans: [([ChatDelta], ProgrammableStreamer.End)], window: Int = 1000) throws -> Rig {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self, CompactionRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let keys = InMemoryKeyStore()
        let connections = ConnectionStore(defaults: defaults, keys: keys)
        try connections.setAPIKey("k", for: Connection.testID)
        var strata = connections.testGateway()
        strata.models = [ModelInfo(id: "m", contextLength: window, supportsTools: true)]
        connections.upsert(strata)
        let streamer = ProgrammableStreamer(plans)
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults),
                                        streamer: streamer, tools: FakeTools())
        let conversation = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
        conversation.titleIsUserSet = true // no automatic naming request among the scripted ones
        conversation.autoRenameDone = true
        context.insert(conversation)
        return Rig(container: container, controller: controller, context: context, conversation: conversation, streamer: streamer)
    }

    private func toolRound(prompt: Int) -> [ChatDelta] {
        [ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}")]),
         ChatDelta(usage: Usage(promptTokens: prompt, completionTokens: 10)), ChatDelta(finishReason: "tool_calls")]
    }

    private func notes(_ text: String = "## Goal\n- the notes") -> ([ChatDelta], ProgrammableStreamer.End) {
        ([ChatDelta(content: text), ChatDelta(finishReason: "stop")], .finish)
    }

    private func answer(_ text: String, prompt: Int? = nil) -> ([ChatDelta], ProgrammableStreamer.End) {
        var d = [ChatDelta(content: text)]
        if let prompt { d.append(ChatDelta(usage: Usage(promptTokens: prompt, completionTokens: 5))) }
        d.append(ChatDelta(finishReason: "stop"))
        return (d, .finish)
    }

    @Test func compactsBeforeAToolLoopContinuation() async throws {
        let r = try rig([(toolRound(prompt: 950), .finish), notes(), answer("Done")])
        r.controller.send(text: "hi", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()

        let reqs = r.streamer.requests
        #expect(reqs.count == 3)
        // The compaction request is the previous request plus the tool round plus the instruction.
        #expect(Array(reqs[1].messages.dropLast()) == reqs[0].messages + [
            .assistant("", toolCalls: [ToolCall(id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}")]),
            .tool(callID: "c1", content: reqs[1].messages[reqs[1].messages.count - 2].contentText),
        ])
        #expect(reqs[1].toolChoice == "none")
        #expect(reqs[1].tools == reqs[0].tools)
        // Then the turn goes on from the replacement: system, the question, the notes.
        #expect(reqs[2].messages.map(\.role) == ["system", "user", "user"])
        #expect(Compaction.text(of: reqs[2].messages[1]) == "hi")
        #expect(Compaction.text(of: reqs[2].messages[2]) == Compaction.summaryPrefix + "## Goal\n- the notes")
        #expect(reqs[2].toolChoice == nil)

        let answerMessage = try #require(r.conversation.sortedMessages.last { $0.role == .assistant })
        #expect(answerMessage.text == "Done" && answerMessage.errorText == nil)
        let record = try #require(r.conversation.compactions.first)
        #expect(r.conversation.compactions.count == 1)
        #expect(record.anchorMessageID == answerMessage.id && record.anchorSteps == 1)
        #expect(record.notes == "## Goal\n- the notes" && !record.coversWholeMessage)
        // The ring shows the size after compaction until the next report.
        #expect(r.conversation.lastUsage?.promptTokens == record.tokensAfter)
        #expect(record.tokensAfter < record.tokensBefore)
        // The transcript still has the original messages and the steps.
        #expect(answerMessage.steps.count == 1)
    }

    @Test func nextTurnStartsFromTheCompactedHistory() async throws {
        let r = try rig([(toolRound(prompt: 950), .finish), notes(), answer("Done"), answer("Second answer")])
        r.controller.send(text: "hi", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        r.controller.send(text: "again", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        let last = try #require(r.streamer.requests.last)
        // system, the question kept by the compaction, the notes, the rest of the compacted answer, the new question.
        #expect(last.messages.map(\.role) == ["system", "user", "user", "assistant", "user"])
        #expect(Compaction.text(of: last.messages[3]) == "Done")
        #expect(Compaction.text(of: last.messages[4]) == "again")
        #expect(r.streamer.requests.count == 4) // no second compaction: the size is small now
        // And it extends the earlier request's messages: appended only.
        let prior = r.streamer.requests[2].messages
        #expect(Array(last.messages.prefix(prior.count)) == prior)
    }

    @Test func compactsBeforeATurnWhenTheLastReportShowsTheLimitReached() async throws {
        let r = try rig([answer("First answer", prompt: 950), notes(), answer("Second answer")])
        r.controller.send(text: "first", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        r.controller.send(text: "second", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()

        let reqs = r.streamer.requests
        #expect(reqs.count == 3)
        // The compaction covers the history without the new message, which is sent after it.
        #expect(reqs[1].messages.map(\.role) == ["system", "user", "assistant", "user"])
        #expect(Compaction.text(of: reqs[1].messages[1]) == "first")
        #expect(reqs[2].messages.map(\.role) == ["system", "user", "user", "user"])
        #expect(Compaction.text(of: reqs[2].messages[3]) == "second")
        let first = try #require(r.conversation.sortedMessages.first { $0.role == .assistant })
        let record = try #require(r.conversation.compactions.first)
        #expect(record.anchorMessageID == first.id && record.coversWholeMessage)
        // The divider belongs after the first answer, ahead of the second question.
        let anchored = r.conversation.compactions(anchoredIn: r.conversation.activePath)
        #expect(anchored[first.id]?.count == 1)
    }

    @Test func belowTheLimitNothingIsCompacted() async throws {
        let r = try rig([answer("First", prompt: 100), answer("Second")])
        r.controller.send(text: "first", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        r.controller.send(text: "second", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(r.streamer.requests.count == 2)
        #expect(r.conversation.compactions.isEmpty)
    }

    @Test func stopDuringCompactionLeavesTheHistoryAlone() async throws {
        let r = try rig([(toolRound(prompt: 950), .finish), ([], .hang)])
        r.controller.send(text: "hi", images: [], conversation: r.conversation, context: r.context)
        for _ in 0..<100 where r.controller.phase != .compacting { try await Task.sleep(for: .milliseconds(20)) }
        #expect(r.controller.phase == .compacting)
        let start = ContinuousClock.now
        r.controller.stop()
        await r.controller.waitUntilIdle()
        #expect(ContinuousClock.now - start < .milliseconds(1000))
        #expect(!r.controller.isStreaming)
        #expect(r.conversation.compactions.isEmpty)
        let m = try #require(r.conversation.sortedMessages.last { $0.role == .assistant })
        #expect(m.stoppedByUser && m.errorText == nil)
        #expect(m.steps.count == 1) // the tool round that came before is kept
    }

    @Test func aFailedCompactionFailsTheTurnAndKeepsTheHistory() async throws {
        let r = try rig([(toolRound(prompt: 950), .finish), ([], .fail(APIError.http(status: 500, message: "boom")))])
        r.controller.send(text: "hi", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        let m = try #require(r.conversation.sortedMessages.last { $0.role == .assistant })
        #expect(m.errorText?.contains("Couldn't summarize") == true)
        #expect(r.conversation.compactions.isEmpty)
    }

    @Test func summarizeNowCompactsWithoutATurn() async throws {
        let r = try rig([answer("An answer", prompt: 300), notes("## Goal\n- manual")])
        r.controller.send(text: "hi", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        r.controller.compactNow(conversation: r.conversation, context: r.context)
        #expect(r.controller.isStreaming && r.controller.phase == .compacting)
        #expect(r.controller.compactingConversationID == r.conversation.id)
        await r.controller.waitUntilIdle()
        #expect(!r.controller.isStreaming && r.controller.phase == .idle)
        let leaf = try #require(r.conversation.leafMessage)
        let record = try #require(r.conversation.compactions.first)
        #expect(record.anchorMessageID == leaf.id && record.coversWholeMessage && !record.isAutomatic)
        #expect(record.notes == "## Goal\n- manual")
        #expect(r.conversation.lastUsage?.promptTokens == record.tokensAfter)
        #expect(r.conversation.messages.count == 2) // no message was added
        // The request was the conversation as it stands plus the instruction.
        let sent = try #require(r.streamer.requests.last)
        #expect(sent.messages.map(\.role) == ["system", "user", "assistant", "user"])
    }

    @Test func stoppingSummarizeNowChangesNothing() async throws {
        let r = try rig([answer("An answer"), ([], .hang)])
        r.controller.send(text: "hi", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        r.controller.compactNow(conversation: r.conversation, context: r.context)
        try await Task.sleep(for: .milliseconds(100))
        r.controller.stop()
        await r.controller.waitUntilIdle()
        #expect(!r.controller.isStreaming && r.conversation.compactions.isEmpty && r.controller.compactionError == nil)
    }

    @Test func aFailedSummarizeNowSaysWhy() async throws {
        let r = try rig([answer("An answer"), ([], .fail(APIError.http(status: 500, message: "boom")))])
        r.controller.send(text: "hi", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        r.controller.compactNow(conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(r.controller.compactionError?.contains("Couldn't summarize") == true)
        #expect(r.conversation.compactions.isEmpty)
    }
}

private extension APIMessage {
    var contentText: String { Compaction.text(of: self) }
}

struct ModelInfoCompactionTests {
    @Test func maxOutputRoundTripsAndOlderModelsStillDecode() throws {
        var m = ModelInfo(id: "x")
        m.maxOutputTokens = 8192
        let back = try JSONDecoder().decode(ModelInfo.self, from: JSONEncoder().encode(m))
        #expect(back.maxOutputTokens == 8192)
        let old = try JSONDecoder().decode(ModelInfo.self, from: Data(#"{"id":"y"}"#.utf8))
        #expect(old.maxOutputTokens == nil)
    }
}
