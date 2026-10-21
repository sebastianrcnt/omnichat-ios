import Foundation
import SwiftData
import Testing
@testable import Strata

extension ChatController {
    /// The one chat that runs (tests that drive a single chat).
    var soleRun: ChatRun? { runs.count == 1 ? runs.values.first : nil }
}

/// A server the test speaks for: each request opens a stream keyed by the chat's question (the last user message),
/// and the test sends its deltas and ends it, in whatever order it likes.
final class ManualStreamer: ChatStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var feeds: [String: AsyncThrowingStream<ChatDelta, Error>.Continuation] = [:]
    private var _started: [String] = []

    /// The questions whose requests went out, in order.
    var started: [String] { lock.withLock { _started } }

    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        let key = Self.question(request)
        return AsyncThrowingStream { c in
            lock.withLock {
                feeds[key] = c
                _started.append(key)
            }
        }
    }

    func send(_ key: String, _ delta: ChatDelta) {
        _ = lock.withLock { feeds[key] }?.yield(delta)
    }

    func finish(_ key: String) {
        lock.withLock { feeds.removeValue(forKey: key) }?.finish()
    }

    private static func question(_ request: ChatRequest) -> String {
        guard let user = request.messages.last(where: { $0.role == "user" }), case .text(let text) = user.content else { return "" }
        return text
    }
}

@MainActor
struct MultiChatTests {
    private struct Rig {
        let container: ModelContainer // must outlive the context
        let controller: ChatController
        let context: ModelContext
        let streamer: ManualStreamer
        let chats: [Conversation]
    }

    private func rig(chats: Int = 2) throws -> Rig {
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
        let conversations = (0..<chats).map { _ in
            let c = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
            c.titleIsUserSet = true // no naming requests among the streams
            c.autoRenameDone = true
            context.insert(c)
            return c
        }
        return Rig(container: container, controller: controller, context: context, streamer: streamer, chats: conversations)
    }

    private func answer(_ c: Conversation) -> Message? { c.sortedMessages.last { $0.role == .assistant } }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func send(_ r: Rig, _ i: Int, _ text: String) {
        r.controller.send(text: text, images: [], conversation: r.chats[i], context: r.context)
    }

    // MARK: Runs side by side

    @Test func twoChatsStreamAtOnceAndEachDeltaLandsInItsOwnAnswer() async throws {
        let r = try rig()
        let (a, b) = (r.chats[0], r.chats[1])
        send(r, 0, "qa")
        send(r, 1, "qb")
        await waitFor { r.streamer.started.count == 2 }
        #expect(r.controller.isStreaming(a) && r.controller.isStreaming(b))
        #expect(r.controller.run(for: a) !== r.controller.run(for: b))

        r.streamer.send("qa", ChatDelta(reasoning: "thinking about a"))
        r.streamer.send("qb", ChatDelta(content: "b1 "))
        r.streamer.send("qa", ChatDelta(content: "a1 "))
        r.streamer.send("qb", ChatDelta(content: "b2"))
        await waitFor { r.controller.run(for: a)?.phase == .writing && r.controller.run(for: b)?.phase == .writing }
        r.streamer.send("qa", ChatDelta(content: "a2"))
        r.streamer.finish("qb")
        await r.controller.waitUntilIdle(b)
        #expect(r.controller.isStreaming(a), "the other chat goes on")
        #expect(answer(b)?.text == "b1 b2" && answer(b)?.reasoning.isEmpty == true)

        r.streamer.finish("qa")
        await r.controller.waitUntilIdle()
        #expect(answer(a)?.text == "a1 a2")
        #expect(answer(a)?.reasoning == "thinking about a")
        #expect(r.controller.runs.isEmpty)
    }

    @Test func stoppingOneChatLeavesTheOtherRunning() async throws {
        let r = try rig()
        let (a, b) = (r.chats[0], r.chats[1])
        send(r, 0, "qa")
        send(r, 1, "qb")
        await waitFor { r.streamer.started.count == 2 }
        r.streamer.send("qa", ChatDelta(content: "partial a"))
        r.streamer.send("qb", ChatDelta(content: "partial b"))
        await waitFor { r.controller.run(for: a)?.phase == .writing && r.controller.run(for: b)?.phase == .writing }

        r.controller.stop(a)
        await r.controller.waitUntilIdle(a)
        #expect(answer(a)?.stoppedByUser == true && answer(a)?.text == "partial a")
        #expect(r.controller.isStreaming(b) && r.controller.run(for: b)?.phase == .writing)

        r.streamer.send("qb", ChatDelta(content: ", rest of b"))
        r.streamer.finish("qb")
        await r.controller.waitUntilIdle()
        #expect(answer(b)?.stoppedByUser == false && answer(b)?.text == "partial b, rest of b")
    }

    @Test func aFourthChatWaitsForASlotAndStartsWhenOneFrees() async throws {
        let r = try rig(chats: 4)
        #expect(ChatController.maxConcurrentRuns == 3)
        for (i, q) in ["q0", "q1", "q2", "q3"].enumerated() { send(r, i, q) }
        await waitFor { r.streamer.started.count == 3 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(Set(r.streamer.started) == ["q0", "q1", "q2"], "only three requests at once")
        let queued = try #require(r.controller.run(for: r.chats[3]))
        #expect(queued.isQueued && queued.phase == .queued && !queued.canAnswerNow)
        #expect(queued.turnStart == nil, "waiting doesn't count as working time")
        #expect(answer(r.chats[3]) != nil, "its answer is there, waiting")

        r.streamer.send("q1", ChatDelta(content: "one"))
        r.streamer.finish("q1")
        await waitFor { r.streamer.started.contains("q3") }
        #expect(r.streamer.started.last == "q3")
        #expect(r.controller.run(for: r.chats[3])?.isQueued == false)

        for q in ["q0", "q2", "q3"] { r.streamer.send(q, ChatDelta(content: "done \(q)")); r.streamer.finish(q) }
        await r.controller.waitUntilIdle()
        #expect(answer(r.chats[3])?.text == "done q3")
        #expect(answer(r.chats[1])?.text == "one")
    }

    @Test func queuedRunsStartOldestFirstAndAStoppedOneNeverStarts() async throws {
        let r = try rig(chats: 4)
        r.controller.maxConcurrentRuns = 1
        for (i, q) in ["q0", "q1", "q2", "q3"].enumerated() { send(r, i, q) }
        await waitFor { r.streamer.started == ["q0"] }
        r.controller.stop(r.chats[2]) // queued: dropped before it starts
        #expect(!r.controller.isStreaming(r.chats[2]))
        #expect(answer(r.chats[2])?.stoppedByUser == true)

        r.streamer.finish("q0")
        await waitFor { r.streamer.started.count == 2 }
        #expect(r.streamer.started == ["q0", "q1"])
        r.streamer.finish("q1")
        await waitFor { r.streamer.started.count == 3 }
        #expect(r.streamer.started == ["q0", "q1", "q3"], "the stopped chat was skipped")
        r.streamer.finish("q3")
        await r.controller.waitUntilIdle()
        #expect(!r.streamer.started.contains("q2"))
    }

    // MARK: Deleting

    @Test func deletingARunningChatStopsItsRunAndNotTheOthers() async throws {
        let r = try rig(chats: 3)
        r.controller.maxConcurrentRuns = 2
        let (a, b, c) = (r.chats[0], r.chats[1], r.chats[2])
        send(r, 0, "qa")
        send(r, 1, "qb")
        send(r, 2, "qc")
        await waitFor { r.streamer.started.count == 2 }
        r.streamer.send("qa", ChatDelta(content: "partial"))
        await waitFor { r.controller.run(for: a)?.phase == .writing }
        #expect(r.controller.run(for: c)?.isQueued == true)

        ConversationDeletion.delete(a, context: r.context, controller: r.controller)
        #expect(!r.controller.runningConversationIDs.contains(a.id), "gone at once")
        await waitFor { r.streamer.started.contains("qc") }
        #expect(r.streamer.started.contains("qc"), "its slot went to the queued chat")
        r.streamer.send("qa", ChatDelta(content: " more")) // nothing listens any more

        for q in ["qb", "qc"] { r.streamer.send(q, ChatDelta(content: q)); r.streamer.finish(q) }
        await r.controller.waitUntilIdle()
        #expect(answer(b)?.text == "qb" && answer(c)?.text == "qc")
        #expect(r.controller.backgroundHolderCount == 0)
        #expect(try r.context.fetch(FetchDescriptor<Conversation>()).map(\.id).contains(a.id) == false)
    }

    @Test func deletingAQueuedChatDropsItFromTheQueue() async throws {
        let r = try rig(chats: 2)
        r.controller.maxConcurrentRuns = 1
        send(r, 0, "qa")
        send(r, 1, "qb")
        await waitFor { r.streamer.started == ["qa"] }
        ConversationDeletion.delete(r.chats[1], context: r.context, controller: r.controller)
        r.streamer.finish("qa")
        await r.controller.waitUntilIdle()
        #expect(r.streamer.started == ["qa"])
        #expect(r.controller.runs.isEmpty)
    }

    // MARK: Background lease

    @Test func oneBackgroundLeaseIsHeldWhileAnyChatRuns() async throws {
        let r = try rig(chats: 3)
        r.controller.maxConcurrentRuns = 2
        send(r, 0, "qa")
        send(r, 1, "qb")
        send(r, 2, "qc")
        await waitFor { r.streamer.started.count == 2 }
        #expect(r.controller.backgroundHolderCount == 2, "a queued run holds nothing")
        r.streamer.finish("qa")
        await waitFor { r.streamer.started.count == 3 }
        #expect(r.controller.backgroundHolderCount == 2)
        r.streamer.finish("qb")
        await r.controller.waitUntilIdle(r.chats[1])
        #expect(r.controller.backgroundHolderCount == 1)
        r.streamer.finish("qc")
        await r.controller.waitUntilIdle()
        #expect(r.controller.backgroundHolderCount == 0)
    }

    @Test func theLeaseLedgerCountsRunsAndSumsUpTheirEnd() {
        var ledger = BackgroundLeaseLedger()
        let (a, b) = (UUID(), UUID())
        let first = ledger.begin(a), joined = ledger.begin(b), twice = ledger.begin(b)
        #expect(first, "the first run takes the lease")
        #expect(!joined, "a later one joins it")
        #expect(!twice, "twice is once")
        let early = ledger.end(a, .init(success: true, title: "Reply ready", subtitle: "Chat A"))
        #expect(early == nil, "b still holds it")
        #expect(ledger.isHeld)
        let summary = ledger.end(b, .init(success: true, title: "Reply ready", subtitle: "Chat B"))
        #expect(summary == .init(success: true, title: String(localized: "Replies ready"), subtitle: "Chat A, Chat B"))
        #expect(!ledger.isHeld)
        let unheld = ledger.end(b, .init(success: true))
        #expect(unheld == nil, "not held")

        _ = ledger.begin(a)
        let single = ledger.end(a, .init(success: false, title: nil, subtitle: "Chat A"))
        #expect(single == .init(success: false, title: nil, subtitle: "Chat A"), "one run: as it ended")
        _ = ledger.begin(a)
        _ = ledger.begin(b)
        _ = ledger.end(a, .init(success: false, subtitle: "A"))
        let mixed = ledger.end(b, .init(success: true, title: "Reply ready", subtitle: "B"))
        #expect(mixed?.success == false && mixed?.title == nil, "one failed: not a success")
    }

    // MARK: Sidebar marks

    @Test func aReplyThatEndsInAnotherChatIsUnreadUntilOpened() async throws {
        let r = try rig()
        let (a, b) = (r.chats[0], r.chats[1])
        r.controller.visibleConversationID = a.id
        send(r, 0, "qa")
        send(r, 1, "qb")
        await waitFor { r.streamer.started.count == 2 }
        #expect(r.controller.status(of: a.id) == .running && r.controller.status(of: b.id) == .running)

        r.streamer.send("qb", ChatDelta(content: "b"))
        r.streamer.finish("qb")
        await r.controller.waitUntilIdle(b)
        #expect(r.controller.status(of: b.id) == .unread)
        #expect(r.controller.readyNotice?.conversationID == b.id)

        r.streamer.send("qa", ChatDelta(content: "a"))
        r.streamer.finish("qa")
        await r.controller.waitUntilIdle(a)
        #expect(r.controller.status(of: a.id) == .none, "the chat on screen is read")
        #expect(r.controller.readyNotice?.conversationID == b.id)

        r.controller.visibleConversationID = b.id
        #expect(r.controller.status(of: b.id) == .none)
        #expect(r.controller.readyNotice == nil, "opening the chat answers the banner")
    }

    @Test func aStoppedReplyIsNotNews() async throws {
        let r = try rig()
        r.controller.visibleConversationID = r.chats[0].id
        send(r, 1, "qb")
        await waitFor { r.streamer.started.count == 1 }
        r.controller.stop(r.chats[1])
        await r.controller.waitUntilIdle()
        #expect(r.controller.status(of: r.chats[1].id) == .none)
        #expect(r.controller.readyNotice == nil)
    }

    @Test func theIndicatorRules() {
        var marks = ChatIndicators()
        let (a, b) = (UUID(), UUID())
        #expect(marks.status(a, running: true) == .running)
        let onScreen = marks.runEnded(a, visible: a)
        #expect(!onScreen, "on screen: read")
        #expect(marks.status(a, running: false) == .none)
        let elsewhere = marks.runEnded(b, visible: a)
        #expect(elsewhere)
        #expect(marks.status(b, running: false) == .unread)
        #expect(marks.status(b, running: true) == .running, "a new run shows over the mark")
        let newChat = marks.runEnded(b, visible: nil)
        #expect(newChat, "a new chat on screen: still elsewhere")
        marks.opened(b)
        #expect(marks.status(b, running: false) == .none)
    }

    // MARK: Requests per chat

    @Test func robotChecksShowOnlyInTheirChat() async {
        let requests = RobotCheckRequests()
        requests.notify = { _ in }
        let view = HiddenWebView(guardNavigations: false)
        defer { view.dispose() }
        let (a, b) = (UUID(), UUID())
        let ra = RobotCheckRequests.Request(host: "a.com", kind: .cloudflare, page: view, conversationID: a, callID: "ca")
        let rb = RobotCheckRequests.Request(host: "b.com", kind: .cloudflare, page: view, conversationID: b, callID: "cb")
        let ta = Task { await requests.ask(ra) }
        let tb = Task { await requests.ask(rb) }
        while requests.pending.count < 2 { await Task.yield() }
        #expect(requests.pending(for: a).map(\.id) == [ra.id])
        #expect(requests.pending(for: b).map(\.id) == [rb.id])
        #expect(requests.pending(for: UUID()).isEmpty)
        requests.answer(ra.id, .skip)
        requests.answer(rb.id, .skip)
        let (outA, outB) = (await ta.value, await tb.value)
        #expect(outA == .skipped && outB == .skipped)
    }

    @Test func skillApprovalsAndBrowserSheetsShowOnlyInTheirChat() async {
        let approvals = SkillApprovals()
        let (a, b) = (UUID(), UUID())
        let skill = Skill(name: "one", description: "Does a thing.", body: "Step one.")
        let fromB = SkillApprovals.Request(skill: skill, replaces: nil, conversationID: b)
        let fromA = SkillApprovals.Request(skill: skill, replaces: nil, conversationID: a)
        let tb = Task { await approvals.ask(fromB) }
        let ta = Task { await approvals.ask(fromA) }
        while approvals.pending(for: a) == nil || approvals.pending(for: b) == nil { await Task.yield() }
        #expect(approvals.pending(for: a)?.id == fromA.id, "b asked first, but a's chat shows its own")
        #expect(approvals.pending(for: b)?.id == fromB.id)
        approvals.answer(fromA.id, approved: true)
        approvals.answer(fromB.id, approved: false)
        let (approvedA, approvedB) = (await ta.value, await tb.value)
        #expect(approvedA && !approvedB)

        // The tool's request carries the chat its turn runs in.
        let made = ToolContext.$conversationID.withValue(a) { SkillApprovals.Request(skill: skill, replaces: nil) }
        #expect(made.conversationID == a)

        let shows = BrowserShowRequests()
        let view = HiddenWebView(guardNavigations: false)
        defer { view.dispose() }
        shows.present(.init(reason: "", page: view, mode: .watch(conversation: b)))
        #expect(shows.pending(for: a) == nil && shows.pending(for: b) != nil)
        let handover = BrowserShowRequests.Request(reason: "Sign in", page: view, conversationID: a)
        #expect(handover.owner == a)
    }

    // MARK: Browser slots

    @Test func atMostTwoChatsBrowseAtOnceAndTheThirdWaitsItsTurn() async throws {
        let sessions = BrowserSessions()
        sessions.makePage = { SlotPage() }
        #expect(sessions.maxActiveConversations == BrowserSessions.maxActiveConversations)
        let (a, b, c) = (UUID(), UUID(), UUID())
        let gates = [a: Gate(), b: Gate(), c: Gate()]
        let order = Box<[UUID]>([])
        func call(_ chat: UUID) -> Task<Void, Error> {
            Task { @MainActor in
                try await ToolContext.$callID.withValue("call-\(chat)") {
                    try await sessions.run(conversation: chat) { _ in
                        order.value.append(chat)
                        await gates[chat]!.wait()
                    }
                }
            }
        }
        let ta = call(a), tb = call(b)
        await waitFor { order.value.count == 2 }
        let tc = call(c)
        await waitFor { sessions.waitingConversations == [c] }
        #expect(sessions.activeConversations == [a, b])
        #expect(ToolWaits.shared.reason(for: "call-\(c)", conversation: c) == .browser, "its live line says what it waits for")
        #expect(order.value.count == 2)

        gates[b]!.open()
        try await tb.value
        await waitFor { order.value.count == 3 }
        #expect(order.value.last == c)
        #expect(ToolWaits.shared.reason(for: "call-\(c)", conversation: c) == nil)
        #expect(sessions.activeConversations == [a, c])

        // A chat that already holds a slot gets in at once (its next call), others still wait.
        let again = call(a)
        gates[a]!.open()
        try await ta.value
        try await again.value
        gates[c]!.open()
        try await tc.value
        #expect(sessions.activeConversations.isEmpty && sessions.waitingConversations.isEmpty)
    }

    @Test func stopBrowsingLetsAWaitingCallGoWithoutASlot() async throws {
        let sessions = BrowserSessions()
        sessions.makePage = { SlotPage() }
        sessions.maxActiveConversations = 1
        let (a, b) = (UUID(), UUID())
        let gate = Gate()
        let ta = Task { @MainActor in try await sessions.run(conversation: a) { _ in await gate.wait() } }
        await waitFor { sessions.activeConversations == [a] }
        let tb = Task { @MainActor in try await sessions.run(conversation: b) { _ in } }
        await waitFor { sessions.waitingConversations == [b] }
        sessions.stopBrowsing(b)
        await #expect(throws: BrowserStoppedError.self) { try await tb.value }
        #expect(sessions.waitingConversations.isEmpty)
        gate.open()
        try await ta.value
    }

    @Test func theSameCallIDInTwoChatsFindsEachChatsOwnPageAndProgress() async throws {
        // Servers that send no ids get `call_0`, `call_1`... in every chat.
        let sessions = BrowserSessions()
        sessions.makePage = { SlotPage() }
        let (a, b) = (UUID(), UUID())
        for chat in [a, b] {
            try await ToolContext.$callID.withValue("call_0") {
                try await sessions.run(conversation: chat) { _ in }
            }
        }
        let pageA = try #require(sessions.existingSession(a)?.page as? SlotPage)
        let pageB = try #require(sessions.existingSession(b)?.page as? SlotPage)
        #expect(pageA !== pageB)
        #expect(sessions.conversation(forCall: "call_0", conversation: a) == a)
        #expect(sessions.conversation(forCall: "call_0", conversation: b) == b)
        #expect(sessions.conversation(lastCallIn: ["call_0"], of: b) == b)
        #expect(sessions.conversation(lastCallIn: ["call_9"], of: b) == nil, "never another chat's")

        let progress = ToolProgress()
        progress.report("call_0", 0.3, conversation: a)
        progress.report("call_0", 0.8, conversation: b)
        #expect(progress.value(for: "call_0", conversation: a) == 0.3)
        #expect(progress.value(for: "call_0", conversation: b) == 0.8)
        let waits = ToolWaits()
        waits.begin("call_0", .browser, conversation: a)
        #expect(waits.reason(among: ["call_0"], conversation: a) == .browser)
        #expect(waits.reason(among: ["call_0"], conversation: b) == nil)
    }

    // MARK: Python

    @Test func pythonRunsFromEveryChatGoOneAtATimeInOrder() async throws {
        let python = PythonRuntime()
        let gates = (0..<3).map { _ in Gate() }
        let order = Box<[Int]>([])
        func run(_ i: Int) -> Task<Int?, Never> {
            Task { @MainActor in
                await ToolContext.$callID.withValue("py\(i)") {
                    await python.serialized { order.value.append(i); await gates[i].wait(); return i }
                }
            }
        }
        let first = run(0)
        await waitFor { order.value == [0] }
        let second = run(1)
        await waitFor { ToolWaits.shared.reason(for: "py1") == .python }
        let third = run(2)
        await waitFor { ToolWaits.shared.reason(for: "py2") == .python }
        #expect(python.isRunning)
        gates[0].open()
        #expect(await first.value == 0)
        await waitFor { order.value.count == 2 }
        #expect(order.value == [0, 1])
        #expect(ToolWaits.shared.reason(for: "py1") == nil && ToolWaits.shared.reason(for: "py2") == .python)
        gates[1].open()
        gates[2].open()
        #expect(await second.value == 1)
        #expect(await third.value == 2)
        #expect(order.value == [0, 1, 2])
        #expect(!python.isRunning)
    }

    @Test func aStoppedChatStopsWaitingForPython() async {
        let python = PythonRuntime()
        let gate = Gate()
        let first = Task { @MainActor in await python.serialized { await gate.wait(); return 1 } }
        await waitFor { python.isRunning }
        let waiting = Task { @MainActor in await ToolContext.$callID.withValue("pyw") { await python.serialized { 2 } } }
        await waitFor { ToolWaits.shared.reason(for: "pyw") == .python }
        waiting.cancel()
        #expect(await waiting.value == nil, "cancelled while waiting: it never ran")
        #expect(ToolWaits.shared.reason(for: "pyw") == nil)
        gate.open()
        #expect(await first.value == 1)
    }

    // MARK: Slots

    @Test func slotsAdmitInOrderOfArrival() async {
        let slots = FairSlots(capacity: 1)
        let (a, b, c) = (UUID(), UUID(), UUID())
        #expect(await slots.acquire(a))
        #expect(slots.admitsNow(a) && !slots.admitsNow(b))
        let got = Box<[UUID]>([])
        let tb = Task { @MainActor in if await slots.acquire(b) { got.value.append(b) } }
        await waitFor { slots.waitingKeys == [b] }
        let tc = Task { @MainActor in if await slots.acquire(c) { got.value.append(c) } }
        await waitFor { slots.waitingKeys == [b, c] }
        slots.release(a)
        await tb.value
        #expect(got.value == [b] && slots.holderKeys == [b])
        slots.capacity = 2
        await tc.value
        #expect(got.value == [b, c])
    }
}

/// A browser page that does nothing.
@MainActor
private final class SlotPage: BrowserPage {
    var currentURL: URL?
    var onProgress: (@MainActor (Double) -> Void)?
    func load(_ url: URL, timeout: Duration) async throws { currentURL = url }
    func evaluate(_ js: String, timeout: Duration) async throws -> String { "" }
    func callAsync(_ body: String, timeout: Duration) async throws -> String { "" }
    func abandonLoad() {}
    func stop() {}
}

/// A value the test's tasks share.
@MainActor
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Holds a test's work until it is opened.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let all = waiters
        waiters = []
        for w in all { w.resume() }
    }
}
