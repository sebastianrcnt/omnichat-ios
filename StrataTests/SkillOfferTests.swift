import Testing
import Foundation
import SwiftData
@testable import Strata

struct SkillOfferPolicyTests {
    private func record(_ name: String, failed: Bool = false) -> ToolCallRecord {
        ToolCallRecord(id: UUID().uuidString, name: name, arguments: "{}", result: failed ? "Error" : "ok", isError: failed)
    }

    private func steps(_ calls: [ToolCallRecord]) -> [ToolStep] { calls.map { ToolStep(assistantContent: "", calls: [$0]) } }

    private func offered(_ calls: [ToolCallRecord], browser: Bool = true, answered: Bool = true) -> Bool {
        SkillOffer.isOffered(steps: steps(calls), browserAvailable: browser, finishedWithAnswer: answered)
    }

    @Test func aFailureThenSuccessInTheWebIsHardWon() {
        #expect(offered([record(ToolNames.browserOpen), record(ToolNames.browserEval, failed: true), record(ToolNames.browserEval)]))
        #expect(offered([record(ToolNames.webFetch, failed: true), record(ToolNames.webSearch), record(ToolNames.webFetch)]))
    }

    @Test func aRecoveryNeedsThreeWebCalls() {
        #expect(!offered([record(ToolNames.webSearch, failed: true), record(ToolNames.webSearch)]))
    }

    @Test func failuresWithNoLaterSuccessDontCount() {
        #expect(!offered([record(ToolNames.browserOpen), record(ToolNames.browserEval), record(ToolNames.browserEval, failed: true)]))
    }

    @Test func manyWebCallsCountOnlyWithTheBrowser() {
        let research = Array(repeating: record(ToolNames.webSearch), count: 4) + Array(repeating: record(ToolNames.webFetch), count: 6)
        #expect(!offered(research))
        #expect(offered(Array(repeating: record(ToolNames.webSearch), count: 3) + [record(ToolNames.browserOpen)]
                        + Array(repeating: record(ToolNames.browserEval), count: 2)))
        #expect(!offered([record(ToolNames.webSearch), record(ToolNames.browserOpen)] + Array(repeating: record(ToolNames.browserEval), count: 3)))
    }

    @Test func otherToolsDontCount() {
        let calls = [record(ToolNames.runPython, failed: true)] + Array(repeating: record(ToolNames.runPython), count: 8)
        #expect(!offered(calls))
        #expect(!offered([record(ToolNames.runPython, failed: true), record(ToolNames.webSearch), record(ToolNames.webFetch)]))
    }

    @Test func notWhenSaveSkillWasAlreadyCalled() {
        #expect(!offered([record(ToolNames.browserEval, failed: true), record(ToolNames.browserEval), record(ToolNames.browserOpen),
                          record(ToolNames.saveSkill, failed: true)]))
    }

    @Test func notWhenALoadedSkillJustWorked() {
        let viaSkill = [record(ToolNames.loadSkill)] + Array(repeating: record(ToolNames.runSkillScript), count: 6)
        #expect(!offered(viaSkill))
        // A loaded skill that needed fixing on the way still offers (to update it).
        #expect(offered([record(ToolNames.loadSkill), record(ToolNames.runSkillScript, failed: true), record(ToolNames.browserOpen),
                         record(ToolNames.browserEval)]))
    }

    @Test func notWithoutTheBrowserToolsOrAnAnswer() {
        let hard = [record(ToolNames.browserEval, failed: true), record(ToolNames.browserEval), record(ToolNames.browserOpen)]
        #expect(!offered(hard, browser: false))
        #expect(!offered(hard, answered: false))
        #expect(!offered([]))
    }

    @Test func webPageToolsAreTheOnesInHiddenViews() {
        for name in [ToolNames.webSearch, ToolNames.webFetch, ToolNames.runPlugin, ToolNames.browserOpen, ToolNames.browserEval,
                     ToolNames.runSkillScript] {
            #expect(ToolNames.usesWebPage(name))
        }
        for name in [ToolNames.browserShow, ToolNames.runPython, ToolNames.loadSkill, ToolNames.saveSkill, ToolNames.showHTML] {
            #expect(!ToolNames.usesWebPage(name))
        }
    }
}

@MainActor
struct SkillOfferTurnTests {
    /// Calls whose arguments contain "fail" fail; the rest work.
    struct FlakyTools: ToolExecuting {
        func execute(name: String, arguments: String) async -> ToolOutput {
            arguments.contains("fail") ? ToolOutput(text: "Error: no such element", isError: true) : ToolOutput(text: "ok \(arguments)")
        }
    }

    nonisolated(unsafe) private static var containers: [ModelContainer] = []

    private struct Rig {
        let controller: ChatController
        let context: ModelContext
        let conversation: Conversation
        let streamer: ProgrammableStreamer
        let settings: AppSettings
    }

    private func rig(_ plans: [([ChatDelta], ProgrammableStreamer.End)]) throws -> Rig {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self, CompactionRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.containers.append(container)
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.strataID)
        var strata = connections.connection(Connection.strataID)!
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let streamer = ProgrammableStreamer(plans)
        let settings = AppSettings(defaults: defaults)
        let controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FlakyTools())
        let conversation = Conversation(connectionID: Connection.strataID, modelID: "m", effort: .medium)
        conversation.titleIsUserSet = true
        conversation.autoRenameDone = true
        context.insert(conversation)
        return Rig(controller: controller, context: context, conversation: conversation, streamer: streamer, settings: settings)
    }

    private func call(_ id: String, _ name: String, _ argument: String) -> ChatDelta {
        ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: id, name: name, arguments: "{\"js\":\"\(argument)\",\"url\":\"https://a.b\"}")])
    }

    /// A browser script fails, the next one works, then the answer.
    private var hardWonTurn: [([ChatDelta], ProgrammableStreamer.End)] {
        [([call("c1", ToolNames.browserOpen, "open")], .finish),
         ([call("c2", ToolNames.browserEval, "fail")], .finish),
         ([call("c3", ToolNames.browserEval, "fixed")], .finish),
         ([ChatDelta(content: "Found it.")], .finish)]
    }

    @Test func aHardWonTurnOffersTheChipOnItsAnswer() async throws {
        let r = try rig(hardWonTurn)
        r.controller.send(text: "find it", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        let answer = try #require(r.conversation.leafMessage)
        #expect(answer.text == "Found it.")
        #expect(r.controller.skillOfferMessageID == answer.id)
    }

    @Test func anEasyTurnDoesNot() async throws {
        let r = try rig([([call("c1", ToolNames.browserOpen, "open")], .finish), ([ChatDelta(content: "Done.")], .finish)])
        r.controller.send(text: "find it", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(r.controller.skillOfferMessageID == nil)
    }

    @Test func tappingSendsTheHiddenInstructionWithToolsStillOn() async throws {
        let r = try rig(hardWonTurn + [([ChatDelta(content: "Saved the skill.")], .finish)])
        r.controller.send(text: "find it", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        let offered = try #require(r.controller.skillOfferMessageID)
        r.controller.saveAsSkill(conversation: r.conversation, context: r.context)
        #expect(r.controller.skillOfferMessageID == nil) // gone as soon as it is used
        await r.controller.waitUntilIdle()
        let path = r.conversation.activePath
        #expect(path.map(\.role) == [.user, .assistant, .user, .assistant])
        let instruction = path[2], reply = path[3]
        #expect(path[1].id == offered)
        #expect(instruction.hiddenInstruction && instruction.skillRequest && instruction.isHiddenInTranscript)
        #expect(instruction.text == SkillOffer.instruction)
        #expect(!reply.answeredEarly && reply.text == "Saved the skill.")
        let request = try #require(r.streamer.requests.last)
        #expect(request.messages.last == .user(SkillOffer.instruction))
        #expect(request.toolChoice == nil && !(request.tools ?? []).isEmpty)
        #expect(r.controller.skillOfferMessageID == nil)
        #expect(!r.conversation.transcript.contains("save_skill"))
    }

    @Test func closingItOrSendingAgainRemovesIt() async throws {
        let r = try rig(hardWonTurn + hardWonTurn + [([ChatDelta(content: "Sure.")], .finish)])
        r.controller.send(text: "find it", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(r.controller.skillOfferMessageID != nil)
        r.controller.dismissSkillOffer()
        #expect(r.controller.skillOfferMessageID == nil)
        r.controller.saveAsSkill(conversation: r.conversation, context: r.context) // nothing to save once closed
        #expect(!r.controller.isStreaming)

        r.controller.send(text: "again", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(r.controller.skillOfferMessageID == r.conversation.leafMessage?.id)
        r.controller.send(text: "thanks", images: [], conversation: r.conversation, context: r.context)
        #expect(r.controller.skillOfferMessageID == nil) // cleared when the next turn starts
        await r.controller.waitUntilIdle()
        #expect(r.controller.skillOfferMessageID == nil)
    }

    @Test func notWhenTheBrowserIsOff() async throws {
        let r = try rig(hardWonTurn)
        r.settings.browserEnabled = false
        r.controller.send(text: "find it", images: [], conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(r.controller.skillOfferMessageID == nil)
    }
}
