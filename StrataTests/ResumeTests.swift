import Foundation
import SwiftData
import Testing
@testable import Strata

private final class RecoveryStreamer: ResumableChatStreaming, @unchecked Sendable {
    private let lock = NSLock()
    var deltas: [ChatDelta]
    var waits: Bool
    var lookupID: String?
    private var seen: [TurnCheckpoint] = []
    private var cancelledIDs: [String] = []
    private var plainCount = 0

    init(deltas: [ChatDelta] = [], waits: Bool = false, lookupID: String? = nil) {
        self.deltas = deltas
        self.waits = waits
        self.lookupID = lookupID
    }
    var checkpoints: [TurnCheckpoint] { lock.withLock { seen } }
    var cancels: [String] { lock.withLock { cancelledIDs } }
    var plainRequests: Int { lock.withLock { plainCount } }

    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        lock.withLock { plainCount += 1 }
        return AsyncThrowingStream { c in c.yield(ChatDelta(content: "plain")); c.finish() }
    }
    func stream(_ request: ChatRequest, endpoint: Endpoint, checkpoint: TurnCheckpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        lock.withLock { seen.append(checkpoint) }
        return AsyncThrowingStream { c in
            let task = Task {
                for delta in deltas { c.yield(delta) }
                if waits {
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { c.finish(throwing: CancellationError()); return }
                }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    func requestID(forIdempotencyKey key: String, endpoint: Endpoint) async throws -> String? { lookupID }
    func cancel(requestID: String, endpoint: Endpoint) async throws {
        lock.withLock { cancelledIDs.append(requestID) }
    }
}

private final class IdempotentRecoveryStreamer: ResumableChatStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var registry: [String: String] = [:]
    private var attempts = 0
    var generationCount: Int { lock.withLock { registry.count } }
    var postCount: Int { lock.withLock { attempts } }

    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { $0.finish(throwing: APIError.server("wrong protocol path")) }
    }
    func stream(_ request: ChatRequest, endpoint: Endpoint, checkpoint: TurnCheckpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        let key = checkpoint.idempotencyKey!
        let (created, rid) = lock.withLock {
            attempts += 1
            let created = registry[key] == nil
            if created { registry[key] = "req_0123456789abcdef01234567" }
            return (created, registry[key]!)
        }
        return AsyncThrowingStream { c in
            if created {
                // Server accepted generation, but app crashed before receiving response headers.
                c.finish(throwing: URLError(.networkConnectionLost))
            } else {
                c.yield(ChatDelta(requestID: rid))
                c.yield(ChatDelta(content: "recovered reply", sequence: 1))
                c.yield(ChatDelta(isDone: true, sequence: 2))
                c.finish()
            }
        }
    }
    func cancel(requestID: String, endpoint: Endpoint) async throws {}
}

/// Records which tools ran.
private final class CountingTools: ToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var ran: [String] = []
    var names: [String] { lock.withLock { ran } }
    func execute(name: String, arguments: String) async -> ToolOutput {
        lock.withLock { ran.append(name) }
        return ToolOutput(text: "ran \(name)")
    }
}

@MainActor
struct ResumeTests {
    private let rid = "req_0123456789abcdef01234567"
    private func endpoint(resumable: Bool = true) -> Endpoint {
        Endpoint(connectionID: Connection.testID, connectionName: "Test", baseURL: URL(string: "http://localhost/v1")!,
                 apiKey: nil, headers: [:], model: ModelInfo(id: "m", supportsTools: false), supportsResumable: resumable)
    }

    @Test func dropResumeIgnoresDuplicatesAndKeepsAllText() async throws {
        var snapshot = try TurnCheckpoint(messages: [.user("hi")])
        #expect(try snapshot.apply(ChatDelta(content: "A", requestID: rid, sequence: 1)))
        // Represents relaunch/network recovery from the last applied cursor.
        let persisted = try JSONEncoder().encode(snapshot)
        snapshot = try JSONDecoder().decode(TurnCheckpoint.self, from: persisted)
        let streamer = RecoveryStreamer(deltas: [ChatDelta(content: "A", sequence: 1),
                                                ChatDelta(content: "B", sequence: 2),
                                                ChatDelta(content: "C", sequence: 3),
                                                ChatDelta(isDone: true, sequence: 4)])
        var text = ""
        let outcome = try await TurnRunner(streamer: streamer, tools: FakeTools()).run(
            endpoint: endpoint(), messages: [], effort: nil, checkpoint: snapshot) { event in
                if case .content(let value) = event { text += value }
            }
        #expect(text == "ABC")
        #expect(outcome.finalContent == "ABC")
        #expect(streamer.checkpoints.first?.requestID == rid)
        #expect(streamer.checkpoints.first?.lastSequence == 1)
    }

    @Test func resumeFromAStalePersistedPairLosesAndDuplicatesNothing() async throws {
        // The app was killed after "ABC" streamed but only the seq 1 / "A" pair had been written.
        var live = try TurnCheckpoint(messages: [.user("hi")])
        live.requestData = try ChatRequest(model: "m", messages: [.user("hi")]).encoded()
        live.submissionStarted = true
        var snapshots: [CheckpointPersister.Snapshot] = []
        let persister = CheckpointPersister(minInterval: 1, now: { 0 }, center: NotificationCenter(), autoTrailing: false) { snapshots.append($0) }
        for (i, piece) in ["A", "B", "C"].enumerated() {
            _ = try live.apply(ChatDelta(content: piece, requestID: rid, sequence: i + 1))
            try persister.update(live)
        }
        #expect(snapshots.count == 1) // only the first pair was written
        let staticData = try #require(snapshots[0].staticData)
        let restored = try TurnCheckpoint.restore(staticData: staticData, dynamicData: snapshots[0].dynamicData)
        #expect(restored.lastSequence == 1 && restored.accumulator.content == "A")
        let streamer = RecoveryStreamer(deltas: [ChatDelta(content: "A", sequence: 1), ChatDelta(content: "B", sequence: 2),
                                                ChatDelta(content: "C", sequence: 3), ChatDelta(isDone: true, sequence: 4)])
        var text = ""
        let outcome = try await TurnRunner(streamer: streamer, tools: FakeTools()).run(
            endpoint: endpoint(), messages: [], effort: nil, checkpoint: restored) { event in
                if case .content(let value) = event { text += value }
            }
        #expect(text == "ABC" && outcome.finalContent == "ABC")
    }

    @Test func cursorIncludesCommentsAndRejectsMissingEvents() throws {
        var parser = SSEParser(includeIDOnlyEvents: true)
        let events = parser.feed("id: 1\n: keepalive\n\nid: 2\ndata: [DONE]\n\n")
        #expect(events.map(\.id) == ["1", "2"])
        var snapshot = try TurnCheckpoint(messages: [])
        for event in events {
            var delta = try ChatChunkDecoder.decode(event.data)
            delta.sequence = Int(event.id!)
            #expect(try snapshot.apply(delta))
        }
        #expect(snapshot.lastSequence == 2 && snapshot.streamDone)
        #expect(throws: APIError.self) { try snapshot.apply(ChatDelta(content: "missing", sequence: 4)) }
        #expect(snapshot.lastSequence == 2)
    }

    @Test func checkpointPersistsIDSequencePartialAndToolArgumentsInSwiftData() throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let message = Message(role: .assistant, text: "partial", sortIndex: 0)
        var snapshot = try TurnCheckpoint(messages: [.user(parts: [.imageURL("data:image/jpeg;base64,AA=="), .text("hi")])])
        _ = try snapshot.apply(ChatDelta(content: "partial", toolCalls: [ToolCallDelta(index: 0, id: "call", name: "web_search", arguments: "{\"que")], requestID: rid, sequence: 1))
        message.resumeData = try JSONEncoder().encode(snapshot)
        context.insert(message)
        try context.save()
        let freshContext = ModelContext(container)
        let fetched = try #require(freshContext.fetch(FetchDescriptor<Message>()).first)
        let recovered = try JSONDecoder().decode(TurnCheckpoint.self, from: #require(fetched.resumeData))
        #expect(fetched.text == "partial")
        #expect(recovered.requestID == rid && recovered.lastSequence == 1)
        #expect(recovered.idempotencyKey == snapshot.idempotencyKey)
        #expect(recovered.accumulator.toolCalls.first?.arguments == "{\"que")
        #expect(try recovered.messages == snapshot.messages)
    }

    @Test func completedStreamRunsSuspendedToolsWithoutRegeneratingIt() async throws {
        var snapshot = try TurnCheckpoint(messages: [.user("hi")])
        _ = try snapshot.apply(ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "call", name: "web_search", arguments: "{}")], requestID: rid, sequence: 1))
        _ = try snapshot.apply(ChatDelta(isDone: true, sequence: 2))
        let streamer = RecoveryStreamer(deltas: [ChatDelta(content: "answer", requestID: rid, sequence: 1), ChatDelta(isDone: true, sequence: 2)])
        var ep = endpoint(); ep.model.supportsTools = true
        let outcome = try await TurnRunner(streamer: streamer, tools: FakeTools()).run(
            endpoint: ep, messages: [], effort: nil, checkpoint: snapshot) { _ in }
        #expect(outcome.finalContent == "answer")
        #expect(outcome.steps.count == 1)
        #expect(outcome.steps[0].calls[0].result == "result of web_search {}")
        // Only the next round was sent; the stored done stream was not sent again.
        #expect(streamer.checkpoints.count == 1)
        #expect(streamer.checkpoints[0].requestID == nil)
        #expect(streamer.checkpoints[0].idempotencyKey != snapshot.idempotencyKey)
        #expect(try streamer.checkpoints[0].messages.last?.role == "tool")
    }

    @Test func crashBeforeHeaderRepostsPersistedKeyWithoutDuplicateGeneration() async throws {
        let streamer = IdempotentRecoveryStreamer()
        let runner = TurnRunner(streamer: streamer, tools: FakeTools())
        var persisted: Data?
        do {
            _ = try await runner.run(endpoint: endpoint(), messages: [.user("hi")], effort: nil) { event in
                if case .checkpoint(let snapshot) = event { persisted = try JSONEncoder().encode(snapshot) }
            }
            Issue.record("The first simulated app process should lose the connection")
        } catch is URLError {}
        let recovered = try JSONDecoder().decode(TurnCheckpoint.self, from: #require(persisted))
        #expect(recovered.submissionStarted && recovered.requestID == nil)
        #expect(recovered.idempotencyKey != nil && recovered.requestData != nil)
        #expect(UUID(uuidString: recovered.idempotencyKey!) != nil)
        var replayedKey: String?
        let outcome = try await runner.run(endpoint: endpoint(), messages: [], effort: nil, checkpoint: recovered) { event in
            if case .checkpoint(let snapshot) = event { replayedKey = snapshot.idempotencyKey }
        }
        #expect(outcome.finalContent == "recovered reply")
        #expect(replayedKey == recovered.idempotencyKey)
        #expect(streamer.postCount == 2 && streamer.generationCount == 1)
    }

    @Test func checkpointFailurePreventsSendingThePOST() async throws {
        let streamer = RecoveryStreamer()
        do {
            _ = try await TurnRunner(streamer: streamer, tools: FakeTools()).run(
                endpoint: endpoint(), messages: [.user("hi")], effort: nil) { event in
                    if case .checkpoint = event { throw CocoaError(.fileWriteOutOfSpace) }
                }
            Issue.record("Sending must fail when the key cannot be persisted")
        } catch is CocoaError {}
        #expect(streamer.checkpoints.isEmpty && streamer.plainRequests == 0)
    }

    /// From the audit: turning resumable replies off for the connection made a restored, already-submitted round go
    /// out again as a plain request, its answer appended to the saved partial one.
    @Test func aSubmittedRoundIsNotResentPlainOnceRecoveryIsOff() async throws {
        var snapshot = try TurnCheckpoint(messages: [.user("hi")])
        snapshot.requestData = try ChatRequest(model: "m", messages: [.user("hi")]).encoded()
        snapshot.submissionStarted = true
        _ = try snapshot.apply(ChatDelta(content: "partial", requestID: rid, sequence: 1))
        let streamer = RecoveryStreamer()
        await #expect(throws: APIError.self) {
            _ = try await TurnRunner(streamer: streamer, tools: FakeTools()).run(
                endpoint: endpoint(resumable: false), messages: [], effort: nil, checkpoint: snapshot) { _ in }
        }
        #expect(streamer.plainRequests == 0 && streamer.checkpoints.isEmpty)
    }

    @Test func originalBodyAndKeySurviveSettingsChanges() async throws {
        var snapshot = try TurnCheckpoint(messages: [.user("hi")])
        let original = try ChatRequest(model: "original-model", messages: [.user("hi")]).encoded()
        snapshot.requestData = original
        snapshot.submissionStarted = true
        let key = snapshot.idempotencyKey
        let streamer = RecoveryStreamer(deltas: [ChatDelta(content: "answer", sequence: 1), ChatDelta(isDone: true, sequence: 2)])
        _ = try await TurnRunner(streamer: streamer, tools: FakeTools()).run(
            endpoint: endpoint(), messages: [], effort: .high, checkpoint: snapshot) { _ in }
        #expect(streamer.checkpoints[0].requestData == original)
        #expect(streamer.checkpoints[0].idempotencyKey == key)
    }

    @Test func alreadyCompletedToolResultsAreNotExecutedAgain() async throws {
        var snapshot = try TurnCheckpoint(messages: [.user("hi")])
        _ = try snapshot.apply(ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "call", name: "web_search", arguments: "{}")], requestID: rid, sequence: 1))
        _ = try snapshot.apply(ChatDelta(isDone: true, sequence: 2))
        snapshot.records = [ToolCallRecord(id: "call", name: "web_search", arguments: "{}", result: "persisted result", isError: false)]
        let streamer = RecoveryStreamer(deltas: [ChatDelta(content: "answer", sequence: 1), ChatDelta(isDone: true, sequence: 2)])
        var ep = endpoint(); ep.model.supportsTools = true
        let outcome = try await TurnRunner(streamer: streamer, tools: FakeTools()).run(
            endpoint: ep, messages: [], effort: nil, checkpoint: snapshot) { _ in }
        #expect(outcome.steps[0].calls[0].result == "persisted result")
        #expect(try streamer.checkpoints[0].messages.last == .tool(callID: "call", content: "persisted result"))
    }

    /// From the audit: recovery re-ran every call without a saved result, so a POST that went through just before the
    /// app was killed went out twice. A started call that can act outside the app is not run again.
    @Test func aStartedCallThatActsOutsideIsNotRunAgainOnRecovery() async throws {
        var snapshot = try TurnCheckpoint(messages: [.user("hi")])
        snapshot.requestData = try ChatRequest(model: "m", messages: [.user("hi")]).encoded()
        snapshot.submissionStarted = true
        _ = try snapshot.apply(ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "c1", name: "run_python", arguments: "{\"code\":\"post()\"}"),
                                                     ToolCallDelta(index: 1, id: "c2", name: "web_search", arguments: "{}")],
                                         requestID: rid, sequence: 1))
        _ = try snapshot.apply(ChatDelta(isDone: true, sequence: 2))
        snapshot.startedCalls = ["c1"]
        // The marker survives the static/dynamic split.
        let restored = try TurnCheckpoint.restore(staticData: TurnCheckpoint.encodeStatic(snapshot),
                                                  dynamicData: JSONEncoder().encode(snapshot.dynamicPart))
        #expect(restored.startedCalls == ["c1"])
        let tools = CountingTools()
        var runner = TurnRunner(streamer: RecoveryStreamer(deltas: [ChatDelta(content: "ok", sequence: 1), ChatDelta(isDone: true, sequence: 2)]),
                                tools: tools)
        runner.python = true
        var ep = endpoint(); ep.model.supportsTools = true
        let outcome = try await runner.run(endpoint: ep, messages: [], effort: nil, checkpoint: restored) { _ in }
        #expect(tools.names == ["web_search"], "only the call that only reads runs again")
        #expect(outcome.steps[0].calls[0].result == TurnRunner.interruptedCallNote && outcome.steps[0].calls[0].isError)
    }

    /// The marker is on disk before such a call runs; a failed write stops the round before the call.
    @Test func callsThatActOutsideAreMarkedBeforeTheyRun() async throws {
        let tools = CountingTools()
        let streamer = RecoveryStreamer(deltas: [ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "c1", name: "run_python", arguments: "{}")], sequence: 1),
                                                 ChatDelta(isDone: true, sequence: 2)])
        var runner = TurnRunner(streamer: streamer, tools: tools)
        runner.python = true
        var ep = endpoint(); ep.model.supportsTools = true
        var markedBeforeRun = false
        await #expect(throws: CheckpointWriteError.self) {
            _ = try await runner.run(endpoint: ep, messages: [.user("hi")], effort: nil) { event in
                if case .checkpoint(let cp) = event, cp.startedCalls == ["c1"] {
                    markedBeforeRun = tools.names.isEmpty
                    throw CheckpointWriteError()
                }
            }
        }
        #expect(markedBeforeRun && tools.names.isEmpty)
        #expect(ToolNames.mayActOutside("ssh_exec") && ToolNames.mayActOutside("browser_click") && !ToolNames.mayActOutside("web_fetch"))
    }

    @Test func oldConnectionSettingsGetSafeCapabilityDefaults() throws {
        let other = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Other\",\"baseURL\":\"https://localhost/v1\"}".utf8)
        #expect(try !JSONDecoder().decode(Connection.self, from: other).supportsResumable)
        var disabled = Connection.testGateway()
        disabled.supportsResumable = false
        #expect(try !JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(disabled)).supportsResumable)
    }

    @Test func plainProviderUsesUnchangedProtocolPath() async throws {
        let streamer = RecoveryStreamer()
        let outcome = try await TurnRunner(streamer: streamer, tools: FakeTools()).run(
            endpoint: endpoint(resumable: false), messages: [.user("hi")], effort: nil) { _ in }
        #expect(outcome.finalContent == "plain")
        #expect(streamer.plainRequests == 1)
        #expect(streamer.checkpoints.isEmpty)
        #expect(!Connection(name: "Other", baseURL: "http://localhost/v1").supportsResumable)
    }

    @Test(arguments: [false, true]) func stopDuringResumeCancelsServerAndLocalTask(beforeHeaders: Bool) async throws {
        let defaults = UserDefaults(suiteName: "resume-tests-\(UUID())")!
        let keys = InMemoryKeyStore()
        try keys.setKey("test-only-key", for: Connection.testID)
        let connections = ConnectionStore(defaults: defaults, keys: keys)
        var strata = Connection.testGateway()
        strata.models = [ModelInfo(id: "m", supportsTools: false)]
        connections.upsert(strata)
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let conversation = Conversation(connectionID: Connection.testID, modelID: "m")
        let prefix = beforeHeaders ? "" : "partial"
        let message = Message(role: .assistant, text: prefix, sortIndex: 0)
        message.conversation = conversation
        var snapshot = try TurnCheckpoint(messages: [.user("hi")])
        if beforeHeaders { snapshot.submissionStarted = true }
        else { _ = try snapshot.apply(ChatDelta(content: "partial", requestID: rid, sequence: 1)) }
        message.resumeData = try JSONEncoder().encode(snapshot)
        message.hasResume = true
        context.insert(conversation); context.insert(message); try context.save()
        let streamer = RecoveryStreamer(waits: true, lookupID: beforeHeaders ? rid : nil)
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults), streamer: streamer, tools: FakeTools())
        controller.restorePending(context: context)
        for _ in 0..<100 where streamer.checkpoints.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.isStreaming)
        controller.stop()
        // Repeated foreground notifications while cancellation is pending must be harmless.
        controller.restorePending(context: context)
        for _ in 0..<100 where controller.isStreaming || message.cancelPending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isStreaming)
        #expect(message.stoppedByUser && !message.cancelPending)
        #expect(message.resumeData == nil)
        #expect(streamer.cancels == [rid])
        #expect(message.text == prefix)
    }
}
