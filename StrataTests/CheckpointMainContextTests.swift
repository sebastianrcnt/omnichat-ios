import Foundation
import SwiftData
import Testing
@testable import Strata

/// Keeps a real controller turn open so the assertions happen before Stop/finalization can repair its checkpoint.
private final class CheckpointHoldingStreamer: ResumableChatStreaming, @unchecked Sendable {
    private let pair = AsyncThrowingStream<ChatDelta, Error>.makeStream()

    func yield(_ delta: ChatDelta) { pair.continuation.yield(delta) }
    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> { pair.stream }
    func stream(_ request: ChatRequest, endpoint: Endpoint, checkpoint: TurnCheckpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        pair.stream
    }
    func requestID(forIdempotencyKey key: String, endpoint: Endpoint) async throws -> String? { nil }
    func cancel(requestID: String, endpoint: Endpoint) async throws {}
}

@MainActor
struct CheckpointMainContextTests {
    @Test func checkpointSurvivesALaterMainContextSaveDuringTheTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-main-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(for: StrataStore.schema, configurations:
            ModelConfiguration(url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none))
        let main = container.mainContext
        main.autosaveEnabled = false
        let suite = "strata.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("test-only-key", for: Connection.testID)
        var connection = Connection.testGateway()
        connection.supportsResumable = true
        connection.models = [ModelInfo(id: "m", supportsTools: false)]
        connections.upsert(connection)
        let streamer = CheckpointHoldingStreamer()
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults),
                                        streamer: streamer, tools: FakeTools())
        defer { controller.stop() }
        let conversation = Conversation(connectionID: Connection.testID, modelID: "m")
        conversation.titleIsUserSet = true
        conversation.autoRenameDone = true
        main.insert(conversation)
        controller.send(text: "hi", images: [], conversation: conversation, context: main)
        let run = try #require(controller.run(for: conversation))
        for _ in 0..<300 where (run.persister?.writeCount ?? 0) < 1 { try await Task.sleep(for: .milliseconds(10)) }
        let persister = try #require(run.persister)
        #expect(persister.writeCount == 1, "submission is durable before the stream begins")
        let message = try #require(run.message)
        // Like streaming, main has already loaded and changed the message when the next checkpoint arrives.
        message.text = "partial"
        let source = try #require(run.sourceStore).assign(SourceCandidate(title: "t", url: "https://example.com", content: "snippet"))
        persister.minInterval = 0
        streamer.yield(ChatDelta(content: "durable partial", requestID: "req_0123456789abcdef01234567", sequence: 1))
        for _ in 0..<300 where persister.writeCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(persister.writeCount == 2)
        #expect(persister.staticEncodeCount == 1, "dynamic-only writes reuse the static half")
        #expect(message.hasResume, "main must see the checkpoint during the turn")
        #expect(message.resumeCheckpoint?.lastSequence == 1)
        #expect(conversation.sources == [source])
        let staticData = try #require(message.resumeData)
        let dynamicData = try #require(message.resumeDynamicData)

        message.text = "partial and more"
        try main.save() // used to silently overwrite the background writer's checkpoint with stale nil/false
        let fresh = ModelContext(container)
        let id = message.persistentModelID
        let saved = try #require(try fresh.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.persistentModelID == id })).first)
        #expect(controller.isStreaming, "verify mid-turn, not after a terminal save")
        #expect(saved.text == "partial and more")
        #expect(saved.hasResume && saved.resumeData == staticData && saved.resumeDynamicData == dynamicData)
        #expect(saved.resumeDeviceID == DeviceIdentity.current)
        #expect(saved.resumeCheckpoint?.lastSequence == 1)
        #expect(saved.resumeCheckpoint?.accumulator.content == "durable partial")
        #expect(saved.conversation?.sources == [source])
        controller.stop()
        await controller.waitUntilIdle()
    }
}
