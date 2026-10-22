#if os(iOS)
import Foundation
import SwiftUI
import UIKit
import UserNotifications
@preconcurrency import ActivityKit

/// The Live Activity of running replies (`ReplyActivityAttributes`, drawn by the widget extension).
///
/// One activity for all the chats that reply at once, not one per chat. Apple's guidance is to track several events
/// with a single activity whose layout adapts; the Dynamic Island shows only one activity in full (the rest shrink to
/// minimal bubbles), so three chats would read as three anonymous dots; and the background lease that keeps the
/// replies going is one task for all of them too (`ReplyBackgroundExecution`). The activity lists up to three chats,
/// the one that needs the person first, and each row opens its chat.
///
/// When it shows: iOS draws its own progress for the continued task (`BGContinuedProcessingTask`) on the Lock Screen and
/// in the Dynamic Island while that task holds the app, and an app can neither hide nor restyle it. So while it is
/// there, the reply's words go into that task's title ("Searching the web" · the chat) and no activity is started; the
/// activity shows when the app leaves the screen without it (the system refused or ended the task). See
/// `ReplyActivityPolicy`.
///
/// Updates are local, from this process while it runs: at most one a second (`ReplyActivityThrottle`), and only when the
/// words change. The elapsed time counts on its own in the views. A heartbeat moves the stale date on, so an activity
/// whose app was suspended mid-reply says so instead of showing the last phase for hours.
@MainActor
final class ReplyLiveActivities {
    static let shared = ReplyLiveActivities()

    private weak var controller: ChatController?
    private var settings: AppSettings?
    private var activity: Activity<ReplyActivityAttributes>?
    private var throttle = ReplyActivityThrottle()
    private var pendingPush: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var latest = ReplyActivityAttributes.ContentState(chats: [])
    /// The runs seen working, to tell how each ended once it leaves `ChatController.runs`.
    private var tracked: [UUID: Tracked] = [:]
    /// Rows of replies that ended while the activity was up.
    private var ended: [UUID: ReplyActivityChat] = [:]
    /// The site each chat's browser is on.
    private var browserHosts: [UUID: String] = [:]
    private var notificationsAllowed = false
    private var observers: [NSObjectProtocol] = []

    private struct Tracked {
        weak var run: ChatRun?
        weak var message: Message?
        var title: String
        var steps: Int
        var started: Date?
    }

    /// How long an activity stays fresh without an update; the heartbeat renews it well before.
    static let staleAfter: Duration = .seconds(90)
    static let heartbeatInterval: Duration = .seconds(45)

    /// From the app's `init`: watches the controller from now on.
    static func install(controller: ChatController, settings: AppSettings) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return } // unit tests
        shared.watch(controller: controller, settings: settings)
    }

    /// The words the activity shows now (also when no activity is up). Tests read it.
    var currentState: ReplyActivityAttributes.ContentState { latest }

    /// Watches `controller` from now on. Internal for tests, which watch a controller of their own.
    func watch(controller: ChatController, settings: AppSettings) {
        guard self.controller == nil else { return }
        self.controller = controller
        self.settings = settings
        // An activity left by an earlier process can't be updated by this one: its rows say nothing true any more.
        for old in Activity<ReplyActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillResignActive() }
        })
        observe()
    }

    // MARK: Watching the runs

    /// Reads the state with observation tracking, so the next change of anything it read (a phase, a tool call, an
    /// approval card, the setting) reads it again.
    private func observe() {
        let state = withObservationTracking {
            _ = settings?.liveActivities
            return snapshot()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        latest = state
        apply(state)
    }

    private func snapshot() -> ReplyActivityAttributes.ContentState {
        guard let controller else { return .init(chats: []) }
        collectEnded(controller)
        var running: [ReplyActivityChat] = []
        for run in controller.runs.values where run.kind == .turn && !run.discarded {
            let id = run.conversationID
            if case .tool(let name, let argument) = run.phase, name == ToolNames.browserOpen,
               let host = ReplyActivityPhase.host(of: argument) {
                browserHosts[id] = host
            }
            let message = run.message ?? tracked[id]?.message
            let title = message.flatMap { m in m.conversation.map { ChatController.notificationTitle($0, assistant: m) } }
                ?? tracked[id]?.title ?? ""
            tracked[id] = Tracked(run: run, message: message, title: title, steps: run.completedToolRounds,
                                  started: run.turnStart ?? tracked[id]?.started)
            running.append(ReplyActivityPhase.chat(ReplyActivityInput(
                id: id, title: title, phase: run.phase,
                toolWait: ToolWaits.shared.reason(among: run.pendingCalls.map(\.id), conversation: id),
                approval: approval(for: id), browserHost: browserHosts[id], steps: run.completedToolRounds,
                started: run.turnStart)))
        }
        return ReplyActivityPhase.state(running: running, ended: Array(ended.values))
    }

    /// Runs that left `runs` (or were replaced by another run of the same chat): their last row, while an activity is up.
    private func collectEnded(_ controller: ChatController) {
        for (id, seen) in tracked where controller.runs[id] == nil || controller.runs[id] !== seen.run {
            tracked[id] = nil
            browserHosts[id] = nil
            guard activity != nil, let outcome = Self.outcome(run: seen.run, message: seen.message) else { continue }
            ended[id] = ReplyActivityPhase.ended(id: id, title: seen.title, outcome: outcome, steps: seen.steps,
                                                 started: seen.started)
        }
    }

    /// How a run ended, from its message; nil for one that leaves no row: a deleted chat, or a run cut short for an
    /// early answer (the answer's own run follows).
    static func outcome(run: ChatRun?, message: Message?) -> ReplyActivityOutcome? {
        guard run?.discarded != true, let message, message.modelContext != nil, !message.isDeleted,
              !message.cutForEarlyAnswer else { return nil }
        if let error = message.errorText { return .failed(message: error) }
        if message.stoppedByUser { return .stopped }
        return .ready(answer: message.text)
    }

    /// The card waiting for the person in this chat, if any.
    private func approval(for id: UUID) -> ReplyActivityInput.Approval? {
        if let request = SSHRequests.shared.pending(conversation: id).first {
            switch request.kind {
            case .approval(let approval): return .sshCommand(server: approval.server)
            case .prompt(let prompt): return .sshPrompt(hop: prompt.hop)
            }
        }
        if let request = ToolApprovals.shared.pending(conversation: id).first {
            switch request.kind {
            case .package(let p): return .packageTool(package: p.packageName, tool: p.toolTitle)
            case .network(let n): return .network(host: n.host)
            case .ssh: break
            }
        }
        if let request = SkillApprovals.shared.pending(for: id), request.conversationID == id {
            return .skill(name: request.skill.name)
        }
        if let request = RobotCheckRequests.shared.pending(for: id).first(where: { $0.conversationID == id }) {
            return .robotCheck(host: request.host)
        }
        if let request = BrowserShowRequests.shared.pending(for: id), request.conversationID == id, request.mode == .handover {
            return .browser
        }
        return nil
    }

    // MARK: Showing

    private var authorized: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private var systemProgressShown: Bool {
        #if DEBUG
        // `-StrataLiveActivityAlways 1`: the activity also next to the continued task, for simulator checks.
        if DebugHooks.value("StrataLiveActivityAlways") != nil { return false }
        #endif
        return ReplyBackgroundExecution.hasContinuedLease
    }

    private var wantsActivity: Bool {
        ReplyActivityPolicy.wantsActivity(enabled: settings?.liveActivities ?? true, authorized: authorized,
                                          activeRuns: latest.activeCount, systemProgressShown: systemProgressShown)
    }

    private func apply(_ state: ReplyActivityAttributes.ContentState) {
        if let activity {
            if state.isFinished {
                finish(activity, with: state)
                return
            }
            if !wantsActivity { // turned off, or the system's own progress took over
                self.activity = nil
                stopUpdates()
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                return
            }
        } else {
            ended = [:]
        }
        schedulePush()
    }

    /// The app is about to leave the screen: the last moment ActivityKit lets it start an activity.
    private func appWillResignActive() {
        refreshNotificationPermission()
        guard activity == nil, wantsActivity, ReplyActivityPolicy.canStart(inBackground: AppLifecycle.isBackground) else { return }
        let attributes = ReplyActivityAttributes(accentHex: settings?.accentHex ?? AccentPreset.defaultHex)
        do {
            activity = try Activity.request(attributes: attributes, content: content(latest), pushType: nil)
            throttle.sent(latest)
            startHeartbeat()
        } catch {
            activity = nil // not allowed now (Settings, a system limit): the notifications still say when it's done
        }
    }

    private func content(_ state: ReplyActivityAttributes.ContentState) -> ActivityContent<ReplyActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: state.isFinished ? nil : .now + Self.staleAfter.timeInterval,
                        relevanceScore: state.needsYou ? 100 : 50)
    }

    /// The next update within the throttle. The continued task's title follows the same words.
    private func schedulePush() {
        guard pendingPush == nil, let delay = throttle.delay(for: latest) else { return }
        pendingPush = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled else { return }
            self.pendingPush = nil
            self.push(self.latest)
        }
    }

    private func push(_ state: ReplyActivityAttributes.ContentState) {
        throttle.sent(state)
        controller?.backgroundStatus = ReplyActivityPhase.continuedTaskText(state)
        guard let activity, !state.isFinished else { return }
        // No alert when a chat starts needing the person: the SSH and robot-check cards already post a notification
        // then, and one buzz is enough. The activity turns to "Needs you" and moves that chat to the top.
        let content = content(state)
        Task { await activity.update(content) }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let self, let activity = self.activity, !Task.isCancelled else { return }
                let content = self.content(self.latest)
                await activity.update(content)
            }
        }
    }

    private func stopUpdates() {
        pendingPush?.cancel()
        pendingPush = nil
        heartbeat?.cancel()
        heartbeat = nil
        throttle.reset()
        ended = [:]
    }

    /// Every reply ended: the result shows for a moment, then the activity goes (`ReplyActivityPolicy.ending`).
    private func finish(_ activity: Activity<ReplyActivityAttributes>, with state: ReplyActivityAttributes.ContentState) {
        self.activity = nil
        stopUpdates()
        controller?.backgroundStatus = nil
        guard !state.chats.isEmpty else { // nothing to show (the chats were deleted)
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let plan = ReplyActivityPolicy.ending(appActive: AppLifecycle.isActive, notifies: notifies)
        let content = content(state)
        let dismissal: ActivityUIDismissalPolicy = switch plan.dismissal {
        case .immediate: .immediate
        case .after(let duration): .after(.now + duration.timeInterval)
        }
        // The dwell outlives the background lease, which ended with the last reply: a few seconds of our own.
        let lease = plan.dwell > .zero ? BackgroundMoment(name: "OpenChat Live Activity") : nil
        Task {
            if plan.dwell > .zero {
                await activity.update(content)
                try? await Task.sleep(for: plan.dwell)
            }
            await activity.end(content, dismissalPolicy: dismissal)
            lease?.end()
        }
    }

    /// A notification brings the answer: the setting is on and the person allowed them.
    private var notifies: Bool {
        #if DEBUG
        if DebugHooks.value("StrataNoNotifications") != nil { return false }
        #endif
        return ReplyBackgroundExecution.enabled && notificationsAllowed
    }

    private func refreshNotificationPermission() {
        Task { @MainActor in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            notificationsAllowed = status == .authorized || status == .provisional || status == .ephemeral
        }
    }
}

/// A few seconds of background time for the activity's last words.
@MainActor
private final class BackgroundMoment {
    private var task: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

extension View {
    /// Opens the chat of a tapped Live Activity (`openchat://chat/<id>`), the way a tapped notification does.
    func replyActivityLinks() -> some View {
        onOpenURL { url in
            guard let id = ReplyActivityLink.conversationID(from: url) else { return }
            ReplyNotificationRouter.shared?.pending = id
        }
    }
}
#endif
