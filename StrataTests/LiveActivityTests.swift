import Foundation
import SwiftData
import Testing
@testable import Strata

/// The Live Activity of running replies: the words for each phase, the rows of several chats, when it shows and how it
/// ends, and the update throttle. ActivityKit itself isn't touched.
@MainActor
struct LiveActivityTests {
    private let id = UUID()

    private func chat(_ phase: ChatController.Phase, wait: ToolWaits.Reason? = nil,
                      approval: ReplyActivityInput.Approval? = nil, browserHost: String? = nil) -> ReplyActivityChat {
        ReplyActivityPhase.chat(ReplyActivityInput(id: id, title: "Cafes", phase: phase, toolWait: wait, approval: approval,
                                                   browserHost: browserHost, steps: 2, started: .now))
    }

    private func row(_ status: ReplyActivityChat.Status, started: TimeInterval = 0, ended: TimeInterval? = nil,
                     id: UUID = UUID()) -> ReplyActivityChat {
        ReplyActivityChat(id: id, title: "\(status)", status: status, label: "", symbol: "sparkle",
                          started: Date(timeIntervalSince1970: started), ended: ended.map { Date(timeIntervalSince1970: $0) })
    }

    // MARK: Phase words

    @Test func toolPhasesReadAsPlainWords() {
        #expect(chat(.tool(name: ToolNames.webSearch, argument: "cafes")).label == "Searching the web")
        #expect(chat(.tool(name: ToolNames.browserOpen, argument: "https://www.naver.com/maps")).label == "Browsing naver.com")
        #expect(chat(.tool(name: ToolNames.webFetch, argument: "https://blog.naver.com/x")).label == "Reading blog.naver.com")
        #expect(chat(.tool(name: ToolNames.runPython, argument: "print(1)")).label == "Running Python")
        #expect(chat(.tool(name: SSHToolNames.exec, argument: "ls")).label == "Working on a server")
        #expect(chat(.tool(name: "something_new", argument: "")).label == "Working")
        #expect(chat(.writing).label == "Writing")
        #expect(chat(.thinking).label == "Thinking")
        #expect(chat(.writing).status == .working)
    }

    @Test func browserActionsNameTheSiteTheBrowserIsOn() {
        #expect(chat(.tool(name: ToolNames.browserClick, argument: "[3]"), browserHost: "map.naver.com").label == "Browsing map.naver.com")
        #expect(chat(.tool(name: ToolNames.browserClick, argument: "[3]")).label == "Browsing")
        #expect(chat(.tool(name: ToolNames.browserOpen, argument: "not a url"), browserHost: "m.place.naver.com").label
                == "Browsing m.place.naver.com")
    }

    @Test func queuedRunsWaitWithoutAClock() {
        let queued = chat(.queued)
        #expect(queued.status == .queued)
        #expect(queued.label == "Waiting for another chat")
        #expect(queued.started == nil)
    }

    @Test func aToolWaitingForAnotherChatSaysSo() {
        let waiting = chat(.tool(name: ToolNames.runPython, argument: ""), wait: .python)
        #expect(waiting.label == "Waiting for Python")
        #expect(waiting.status == .working)
    }

    @Test func approvalsNeedThePerson() {
        let ssh = chat(.tool(name: SSHToolNames.exec, argument: "rm"), approval: .sshCommand(server: "homelab"))
        #expect(ssh.status == .needsYou)
        #expect(ssh.label == "Needs you")
        #expect(ssh.detail == "Approve a command on homelab")
        #expect(chat(.tool(name: ToolNames.webFetch, argument: ""), approval: .robotCheck(host: "blog.naver.com")).detail
                == "blog.naver.com wants a robot check")
        // The tool call itself asks, before its card is in the queue.
        let skill = chat(.tool(name: ToolNames.saveSkill, argument: "naver-map"))
        #expect(skill.status == .needsYou)
        #expect(skill.detail == "Save the skill \u{201C}naver-map\u{201D}?")
        #expect(chat(.tool(name: ToolNames.browserShow, argument: "Sign in")).status == .needsYou)
    }

    @Test func endedRepliesSayHowTheyEnded() {
        let ready = ReplyActivityPhase.ended(id: id, title: "Rates", outcome: .ready(answer: "## Summary\n\nRates **rose** to 0.75.\n\nMore."),
                                             steps: 3, started: .now)
        #expect(ready.status == .ready && ready.label == "Reply ready")
        #expect(ready.detail == "Rates rose to 0.75. More.", "the heading is skipped and the Markdown dropped")
        #expect(ready.ended != nil)
        #expect(ReplyActivityPhase.ended(id: id, title: "", outcome: .stopped, steps: 0, started: nil).label == "Reply stopped")
        let failed = ReplyActivityPhase.ended(id: id, title: "", outcome: .failed(message: "The server is down."), steps: 0, started: nil)
        #expect(failed.status == .failed && failed.detail == "The server is down.")
        #expect(ReplyActivityPhase.ended(id: id, title: "", outcome: .ready(answer: ""), steps: 0, started: nil).detail == nil)
    }

    @Test func longTitlesAndAnswersAreCutForThePayload() {
        let long = String(repeating: "word ", count: 80)
        let row = ReplyActivityPhase.chat(ReplyActivityInput(id: id, title: long, phase: .writing))
        #expect(row.title.count <= ReplyActivityText.titleLimit)
        #expect(row.title.hasSuffix("…"))
        let ended = ReplyActivityPhase.ended(id: id, title: "t", outcome: .ready(answer: long), steps: 0, started: nil)
        #expect((ended.detail?.count ?? 0) <= ReplyActivityText.detailLimit + 1)
    }

    // MARK: Several chats

    @Test func rowsPutWhatNeedsThePersonFirstThenRunningThenQueuedThenEnded() {
        let state = ReplyActivityPhase.state(
            running: [row(.queued), row(.working, started: 20), row(.needsYou, started: 30), row(.working, started: 10)],
            ended: [])
        #expect(state.chats.map(\.status) == [.needsYou, .working, .working])
        #expect(state.chats[1].started == Date(timeIntervalSince1970: 10), "the one that started first")
        #expect(state.hiddenCount == 1, "the queued chat beyond the rows")
        #expect(state.activeCount == 4)
        #expect(state.needsYou)
        #expect(state.lead?.status == .needsYou)
    }

    @Test func endedRowsStayUntilTheLastReplyEnds() {
        let a = UUID(), b = UUID()
        var state = ReplyActivityPhase.state(running: [row(.working, id: a), row(.working, id: b)], ended: [])
        #expect(!state.isFinished)
        state = ReplyActivityPhase.state(running: [row(.working, id: b)], ended: [row(.ready, ended: 5, id: a)])
        #expect(state.chats.map(\.status) == [.working, .ready])
        #expect(!state.isFinished, "one chat still replies")
        state = ReplyActivityPhase.state(running: [], ended: [row(.ready, ended: 5, id: a), row(.failed, ended: 9, id: b)])
        #expect(state.isFinished)
        #expect(state.chats.map(\.status) == [.ready, .failed])
    }

    @Test func aChatThatRunsAgainReplacesItsEndedRow() {
        let a = UUID()
        let state = ReplyActivityPhase.state(running: [row(.working, id: a)], ended: [row(.ready, ended: 1, id: a)])
        #expect(state.chats.count == 1 && state.chats[0].status == .working)
    }

    @Test func endedRowsBeyondTheRowsAreNotCountedAsReplying() {
        let state = ReplyActivityPhase.state(running: [row(.working), row(.working), row(.working)],
                                             ended: [row(.ready, ended: 1)])
        #expect(state.chats.count == 3)
        #expect(state.hiddenCount == 0)
    }

    @Test func theSystemTaskListSaysTheLeadChatsPhase() {
        let one = ReplyActivityPhase.state(running: [chat(.tool(name: ToolNames.webSearch, argument: ""))], ended: [])
        #expect(ReplyActivityPhase.continuedTaskText(one)! == ("Searching the web", "Cafes"))

        let ask = ReplyActivityPhase.state(running: [chat(.writing, approval: .sshCommand(server: "nas"))], ended: [])
        #expect(ReplyActivityPhase.continuedTaskText(ask)! == ("Needs you", "Approve a command on nas"))

        let several = ReplyActivityPhase.state(running: [row(.working, started: 1), row(.working, started: 2), row(.queued)], ended: [])
        #expect(ReplyActivityPhase.continuedTaskText(several)?.subtitle.hasSuffix(" · 2 more chats") == true)

        let done = ReplyActivityPhase.state(running: [], ended: [row(.ready, ended: 1)])
        #expect(ReplyActivityPhase.continuedTaskText(done) == nil)
    }

    // MARK: When it shows, how it ends

    @Test func theActivityShowsOnlyWhereTheSystemShowsNoProgress() {
        #expect(ReplyActivityPolicy.wantsActivity(enabled: true, authorized: true, activeRuns: 1, systemProgressShown: false))
        #expect(!ReplyActivityPolicy.wantsActivity(enabled: true, authorized: true, activeRuns: 1, systemProgressShown: true))
        #expect(!ReplyActivityPolicy.wantsActivity(enabled: false, authorized: true, activeRuns: 2, systemProgressShown: false))
        #expect(!ReplyActivityPolicy.wantsActivity(enabled: true, authorized: false, activeRuns: 2, systemProgressShown: false))
        #expect(!ReplyActivityPolicy.wantsActivity(enabled: true, authorized: true, activeRuns: 0, systemProgressShown: false))
        #expect(ReplyActivityPolicy.canStart(inBackground: false))
        #expect(!ReplyActivityPolicy.canStart(inBackground: true))
    }

    @Test func endingDependsOnWhereThePersonIs() {
        #expect(ReplyActivityPolicy.ending(appActive: true, notifies: true) == .init(dwell: .zero, dismissal: .immediate))
        #expect(ReplyActivityPolicy.ending(appActive: false, notifies: true)
                == .init(dwell: ReplyActivityPolicy.dwell, dismissal: .immediate))
        #expect(ReplyActivityPolicy.ending(appActive: false, notifies: false)
                == .init(dwell: ReplyActivityPolicy.dwell, dismissal: .after(ReplyActivityPolicy.summaryLifetime)))
    }

    // MARK: Throttle

    @Test func updatesGoOutAtMostOnceASecondAndNeverTwiceTheSame() {
        var throttle = ReplyActivityThrottle(interval: .seconds(1))
        let t0 = ContinuousClock.now
        let a = ReplyActivityPhase.state(running: [chat(.thinking)], ended: [])
        let b = ReplyActivityPhase.state(running: [chat(.writing)], ended: [])
        #expect(throttle.delay(for: a, now: t0) == .zero)
        throttle.sent(a, at: t0)
        #expect(throttle.delay(for: a, now: t0 + .seconds(5)) == nil, "nothing new")
        #expect(throttle.delay(for: b, now: t0 + .milliseconds(300)) == .milliseconds(700))
        #expect(throttle.delay(for: b, now: t0 + .milliseconds(1200)) == .zero)
        throttle.reset()
        #expect(throttle.delay(for: a, now: t0) == .zero)
    }

    // MARK: Links

    @Test func linksOpenTheirChat() {
        let url = ReplyActivityLink.url(for: id)
        #expect(url.absoluteString == "openchat://chat/\(id.uuidString)")
        #expect(ReplyActivityLink.conversationID(from: url) == id)
        #expect(ReplyActivityLink.conversationID(from: URL(string: "openchat://add-connection?url=x")!) == nil)
        #expect(ReplyActivityLink.conversationID(from: URL(string: "https://chat/\(id.uuidString)")!) == nil)
    }

    // MARK: Outcome of a finished run

    @Test func aRunsOutcomeComesFromItsMessage() throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let message = Message(role: .assistant, text: "Done.", sortIndex: 1)
        context.insert(message)
        #expect(ReplyLiveActivities.outcome(run: nil, message: message) == .ready(answer: "Done."))
        message.stoppedByUser = true
        #expect(ReplyLiveActivities.outcome(run: nil, message: message) == .stopped)
        message.cutForEarlyAnswer = true
        #expect(ReplyLiveActivities.outcome(run: nil, message: message) == nil, "the early answer's own run follows")
        message.cutForEarlyAnswer = false
        message.stoppedByUser = false
        message.errorText = "Offline"
        #expect(ReplyLiveActivities.outcome(run: nil, message: message) == .failed(message: "Offline"))
        let run = ChatRun(conversationID: UUID(), kind: .turn, messageID: message.id)
        run.discarded = true
        #expect(ReplyLiveActivities.outcome(run: run, message: message) == nil, "a deleted chat leaves no row")
        #expect(ReplyLiveActivities.outcome(run: nil, message: nil) == nil)
    }

    // MARK: Watching a controller

    @Test func watchingRunsFollowsEachChatsPhaseAndTheTaskListTitle() async throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.testID)
        var gateway = connections.testGateway()
        gateway.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(gateway)
        let streamer = ManualStreamer()
        let settings = AppSettings(defaults: defaults)
        let controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
        let chats = ["Alpha", "Beta"].map { title in
            let c = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
            c.title = title
            c.titleIsUserSet = true
            c.autoRenameDone = true
            context.insert(c)
            return c
        }
        let watcher = ReplyLiveActivities()
        watcher.watch(controller: controller, settings: settings)
        func waitFor(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        }

        controller.send(text: "qa", images: [], conversation: chats[0], context: context)
        controller.send(text: "qb", images: [], conversation: chats[1], context: context)
        await waitFor { streamer.started.count == 2 }
        streamer.send("qa", ChatDelta(content: "a1"))
        await waitFor { watcher.currentState.chats.contains { $0.title == "Alpha" && $0.label == "Writing" } }
        #expect(watcher.currentState.activeCount == 2)
        #expect(Set(watcher.currentState.chats.map(\.title)) == ["Alpha", "Beta"])

        streamer.finish("qa")
        await controller.waitUntilIdle(chats[0])
        await waitFor { watcher.currentState.activeCount == 1 }
        #expect(watcher.currentState.chats.map(\.title) == ["Beta"], "no activity was up, so no ended row")

        streamer.finish("qb")
        await controller.waitUntilIdle()
        await waitFor { watcher.currentState.chats.isEmpty }
        #expect(watcher.currentState.isFinished)
    }
}
