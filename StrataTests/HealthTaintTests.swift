import Testing
import Foundation
import SwiftData
@testable import Strata

/// Chats that hold health data (`HealthTaint`): "Only send health data to on-device or local models" holds for every
/// request they make, and chat sync can't upload them.
@MainActor
struct HealthTaintTests {
    private struct Rig {
        let container: ModelContainer // must outlive the context
        let controller: ChatController
        let context: ModelContext
        let conversation: Conversation
        let streamer: ProgrammableStreamer
        let connections: ConnectionStore
    }

    private func rig(_ plans: [([ChatDelta], ProgrammableStreamer.End)] = [], baseURL: String = Connection.testBaseURL,
                     localOnly: Bool = true) throws -> Rig {
        let container = try ModelContainer(for: StrataStore.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.testID)
        var gateway = connections.testGateway()
        gateway.baseURL = baseURL
        gateway.supportsResumable = false
        gateway.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(gateway)
        let streamer = ProgrammableStreamer(plans)
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults),
                                        streamer: streamer, tools: FakeTools())
        controller.healthLocalOnly = { localOnly }
        let conversation = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
        context.insert(conversation)
        return Rig(container: container, controller: controller, context: context, conversation: conversation,
                   streamer: streamer, connections: connections)
    }

    private func healthCall(isError: Bool = false) -> ToolCallRecord {
        ToolCallRecord(id: "h", name: ToolNames.healthQuery, arguments: "{\"metric\":\"resting_heart_rate\"}",
                       result: isError ? "Error: the user didn't allow reading Apple Health now." : "date | bpm\n2026-10-20 | 58",
                       isError: isError)
    }

    private func assistant(_ r: Rig) -> Message? { r.conversation.sortedMessages.last { $0.role == .assistant } }

    /// A model switched to a remote one gets nothing from a chat that read Health: not the turn, not "Summarize now",
    /// not the title.
    @Test func aChatWithHealthDataNeverGoesToARemoteModelWhileLocalOnlyIsOn() async throws {
        let r = try rig()
        r.conversation.healthTainted = true
        r.controller.send(text: "And last week?", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        let blocked = APIError.healthLocalOnly(connection: "Strata").errorDescription
        #expect(assistant(r)?.errorText == blocked)
        #expect(r.streamer.requests.isEmpty)

        r.controller.compactNow(conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(r.controller.compactionError(for: r.conversation) == blocked)

        r.controller.autoRename(conversation: r.conversation, context: r.context, force: true)
        #expect(r.controller.titleFailedConversationID == r.conversation.id)
        #expect(!r.controller.isTitling(r.conversation.id))

        // Retrying sends nothing either.
        r.controller.regenerate(conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(r.streamer.requests.isEmpty)
    }

    @Test func aLocalModelOrTheSwitchOffLetsItGo() async throws {
        let local = try rig(baseURL: "http://192.168.1.20:8080/v1")
        local.conversation.healthTainted = true
        local.controller.send(text: "hi", images: [], conversation: local.conversation, context: local.context)
        await local.controller.waitUntilIdle()
        #expect(local.streamer.requests.count == 1)
        #expect(assistant(local)?.errorText == nil)

        let off = try rig(localOnly: false)
        off.conversation.healthTainted = true
        off.controller.send(text: "hi", images: [], conversation: off.conversation, context: off.context)
        await off.controller.waitUntilIdle()
        #expect(off.streamer.requests.count == 1)

        // A chat that never read Health goes anywhere.
        let clean = try rig()
        clean.controller.send(text: "hi", images: [], conversation: clean.conversation, context: clean.context)
        await clean.controller.waitUntilIdle()
        #expect(clean.streamer.requests.count == 1)
    }

    /// Chats from before the flag existed are found by what their messages hold. An error result never carried data.
    @Test func olderChatsAreFoundByTheirSteps() throws {
        let r = try rig()
        let read = Message(role: .assistant, text: "Your resting heart rate averaged 58.", sortIndex: 0)
        read.steps = [ToolStep(assistantContent: "", calls: [healthCall()])]
        r.context.insert(read)
        r.conversation.attach(read, parent: nil)

        let declined = Conversation(connectionID: Connection.testID, modelID: "m")
        r.context.insert(declined)
        let refused = Message(role: .assistant, text: "I couldn't read it.", sortIndex: 0)
        refused.steps = [ToolStep(assistantContent: "", calls: [healthCall(isError: true)])]
        r.context.insert(refused)
        declined.attach(refused, parent: nil)

        // Redacted when chat sync went on (older versions): the reply after it still repeats the data.
        let redacted = Conversation(connectionID: Connection.testID, modelID: "m")
        r.context.insert(redacted)
        let kept = Message(role: .assistant, text: "Your resting heart rate averaged 58.", sortIndex: 0)
        var call = healthCall()
        call.result = HealthSettings.removedResult
        kept.steps = [ToolStep(assistantContent: "", calls: [call])]
        r.context.insert(kept)
        redacted.attach(kept, parent: nil)
        try r.context.save()

        #expect(!r.conversation.healthTainted)
        let found = Set(try HealthTaint.conversations(in: r.context).map(\.id))
        #expect(found == [r.conversation.id, redacted.id])
        #expect(r.conversation.healthTainted && redacted.healthTainted && !declined.healthTainted)
        #expect(HealthPrivacy.blockedRequest(declined, to: ToolDestination(name: "Remote", baseURL: URL(string: "https://api.example.com"), kind: .openAICompatible),
                                             localOnly: true) == nil)
        #expect(HealthPrivacy.blockedRequest(r.conversation, to: ToolDestination(name: "Remote", baseURL: URL(string: "https://api.example.com"), kind: .openAICompatible),
                                             localOnly: true) == .healthLocalOnly(connection: "Remote"))
    }

    /// A read during a turn marks the chat, so the next request to a remote model is refused even after a model switch.
    @Test func aHealthReadMarksTheChat() async throws {
        let r = try rig([([ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "h", name: ToolNames.healthQuery, arguments: "{\"metric\":\"steps\"}")])], .finish),
                         ([ChatDelta(content: "You walked 8,000 steps a day.")], .finish)],
                        baseURL: "http://localhost:11434/v1")
        r.conversation.setSwitches(groups: [.health], packages: [])
        r.controller.send(text: "How much did I walk?", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(assistant(r)?.errorText == nil)
        #expect(r.conversation.healthTainted)
        #expect(r.streamer.requests.count == 2)
    }

    /// Chat sync went on while Health was being read: the result is never sent on, and the chat isn't marked (nothing
    /// was kept).
    @Test func aReadThatLandsAfterSyncWentOnEndsTheTurnUnused() async throws {
        let r = try rig([([ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "h", name: ToolNames.healthQuery, arguments: "{\"metric\":\"steps\"}")])], .finish)],
                        baseURL: "http://localhost:11434/v1")
        r.conversation.setSwitches(groups: [.health], packages: [])
        await HealthRedaction.$forcedActive.withValue(true) {
            r.controller.send(text: "How much did I walk?", images: [], conversation: r.conversation, context: r.context)
            await r.controller.waitUntilIdle()
        }
        #expect(assistant(r)?.errorText != nil)
        #expect(assistant(r)?.steps.isEmpty == true)
        #expect(r.streamer.requests.count == 1)
        #expect(!r.conversation.healthTainted)
    }
}
