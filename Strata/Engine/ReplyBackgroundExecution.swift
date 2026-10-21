import Foundation
import UserNotifications
#if os(iOS)
import UIKit
import BackgroundTasks
#endif

/// Which runs hold the background lease, and how the ones that ended went. Pure, so the counting is tested without
/// the system's task scheduler.
struct BackgroundLeaseLedger: Equatable {
    struct Outcome: Equatable {
        var success: Bool
        /// What the system's task list shows for the finished task; nil keeps what it showed.
        var title: String?
        var subtitle: String?
    }

    private(set) var holders: Set<UUID> = []
    /// The runs that ended since the lease was taken.
    private(set) var ended: [Outcome] = []

    var isHeld: Bool { !holders.isEmpty }

    /// True when this run takes the lease (no other run holds it).
    mutating func begin(_ run: UUID) -> Bool {
        let first = holders.isEmpty
        guard holders.insert(run).inserted else { return false }
        if first { ended = [] }
        return first
    }

    /// What the lease ends with when this was the last run holding it; nil while others still hold it (or the run
    /// held nothing).
    mutating func end(_ run: UUID, _ outcome: Outcome) -> Outcome? {
        guard holders.remove(run) != nil else { return nil }
        ended.append(outcome)
        guard holders.isEmpty else { return nil }
        defer { ended = [] }
        return Self.summary(ended)
    }

    /// One run: as it ended. Several: "Replies ready" with the chats' titles when none failed.
    static func summary(_ outcomes: [Outcome]) -> Outcome {
        guard outcomes.count > 1 else { return outcomes.first ?? Outcome(success: true) }
        let success = outcomes.allSatisfy(\.success)
        let titles = outcomes.compactMap(\.subtitle).filter { !$0.isEmpty }
        return Outcome(success: success, title: success ? String(localized: "Replies ready") : nil,
                       subtitle: titles.joined(separator: ", "))
    }
}

/// Keeps replies going while the app is in the background. One lease for all the chats that run at once: taken when
/// the first run starts, given back when the last one ends, its progress the sum of theirs.
///
/// Why one and not one per run: each `BGContinuedProcessingTask` is its own entry in the system's task list (three chats
/// would show three "Preparing reply" items), each needs its own identifier registered and submitted, and with the
/// `.fail` strategy a submission the system can't start at once is refused, so later runs could end up with no
/// continued task anyway. A single task covers the process, which is what keeps every run alive; its title says when
/// several chats are replying.
@MainActor
final class ReplyBackgroundExecution {
    private(set) static var hasContinuedLease = false
    private(set) var ledger = BackgroundLeaseLedger()
    /// Runs holding the lease now.
    var holderCount: Int { ledger.holders.count }
    #if os(iOS)
    private var fallback: UIBackgroundTaskIdentifier = .invalid
    private var continued: BGContinuedProcessingTask?
    private var identifier: String?
    private var units: Int64 = 0
    /// Every delta advances the count, but the system's progress object is written about once a second.
    private var progressLimiter = RateLimiter(interval: .seconds(1))
    private var active: Bool { ledger.isHeld }

    /// A run starts: the first one takes the lease, a later one joins it.
    func begin(_ run: UUID) {
        guard ledger.begin(run) else {
            updateRunningTitle()
            return
        }
        progressLimiter.reset()
        fallback = UIApplication.shared.beginBackgroundTask(withName: "Strata reply") { [weak self] in
            Task { @MainActor in self?.endFallback() }
        }
        if #available(iOS 26.0, *) {
            let id = "cc.coolservices.strata.reply.\(UUID().uuidString)"
            identifier = id
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
                // The scheduler invokes this handler on the explicitly supplied main queue.
                MainActor.assumeIsolated {
                    guard let self, self.active, let task = task as? BGContinuedProcessingTask else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    self.continued = task
                    Self.hasContinuedLease = true
                    task.progress.totalUnitCount = max(1000, self.units + 1000)
                    task.progress.completedUnitCount = self.units
                    task.expirationHandler = { [weak self] in
                        Task { @MainActor in
                            // Expiration also covers system resource limits, not just user cancellation.
                            // Keep the server stream/checkpoint alive; app Stop is the explicit cancel.
                            self?.continued?.setTaskCompleted(success: false)
                            self?.continued = nil
                            Self.hasContinuedLease = false
                        }
                    }
                    if self.holderCount > 1 { self.updateRunningTitle() } // more chats started before the task did
                    self.endFallback()
                }
            }
            if registered {
                DiagnosticCounters.shared.backgroundIdentifierRegistered()
                let request = BGContinuedProcessingTaskRequest(identifier: id,
                    title: String(localized: "Preparing reply"), subtitle: String(localized: "OpenChat is replying"))
                request.strategy = .fail // no stale queued work after the turn has already finished
                do { try BGTaskScheduler.shared.submit(request) }
                catch { identifier = nil } // finite beginBackgroundTask fallback remains active
            }
        }
    }

    /// For the diagnostics panel.
    var stateDescription: String {
        let runs = holderCount > 1 ? " (\(holderCount) replies)" : ""
        if continued != nil { return "continued task running" + runs }
        if active { return (fallback != .invalid ? "background task only" : "active, no lease") + runs }
        return "idle"
    }

    /// The task list says how many chats are replying.
    private func updateRunningTitle() {
        guard let continued else { return }
        if holderCount > 1 {
            continued.updateTitle(String(localized: "Preparing replies"), subtitle: String(localized: "OpenChat is replying in \(holderCount) chats"))
        } else {
            continued.updateTitle(String(localized: "Preparing reply"), subtitle: String(localized: "OpenChat is replying"))
        }
    }

    func advance(by count: Int = 1) {
        units += Int64(max(1, count))
        if let continued, progressLimiter.allow() {
            continued.progress.totalUnitCount = units + 1000 // generation length is unknown
            continued.progress.completedUnitCount = units
        }
    }

    /// - Parameters:
    ///   - title, subtitle: what the system's task list shows for the finished task ("Reply ready" / "Reply stopped" and
    ///     the chat's title), instead of the "Preparing reply" it started with.
    ///   The lease ends with the last run; with several, it says "Replies ready" and the chats' titles.
    func end(_ run: UUID, success: Bool, title: String? = nil, subtitle: String? = nil) {
        guard let summary = ledger.end(run, .init(success: success, title: title, subtitle: subtitle)) else {
            if ledger.isHeld { updateRunningTitle() }
            return
        }
        if let continued {
            if let title = summary.title { continued.updateTitle(title, subtitle: summary.subtitle ?? "") }
            if summary.success { continued.progress.completedUnitCount = continued.progress.totalUnitCount }
            continued.setTaskCompleted(success: summary.success)
        }
        continued = nil
        Self.hasContinuedLease = false
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        identifier = nil
        endFallback()
    }

    private func endFallback() {
        if fallback != .invalid { UIApplication.shared.endBackgroundTask(fallback); fallback = .invalid }
    }
    #else
    // A Mac app keeps running while another app is in front: there is no lease to hold.
    // The ledger still counts, so the rules are the same on both.
    func begin(_ run: UUID) { _ = ledger.begin(run) }
    var stateDescription: String { "not needed on macOS" }
    func advance(by count: Int = 1) {}
    func end(_ run: UUID, success: Bool, title: String? = nil, subtitle: String? = nil) {
        _ = ledger.end(run, .init(success: success, title: title, subtitle: subtitle))
    }
    #endif

    /// Off in Settings > Notifications.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "notifyReplies") as? Bool ?? true }
    private static let router = ReplyNotificationRouter()

    static func prepareNotifications() {
        UNUserNotificationCenter.current().delegate = router
    }

    /// Asks for permission while the app is in front, at the first send: a reply that finishes in the background can't
    /// show the permission sheet, so asking then would lose that first notification.
    static func requestPermissionIfNeeded() {
        #if DEBUG
        if DebugHooks.value("StrataNoNotifications") != nil { return } // keeps the permission prompt out of screenshots
        #endif
        // Unit tests send through the controller in a host app: no permission sheet there.
        guard enabled, AppLifecycle.isActive, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Tells the person their reply is ready: the chat's title, then the start of the answer. Tapping it opens the chat.
    static func notifyCompletion(title: String, body: String, conversationID: UUID) {
        post(title: title.isEmpty ? String(localized: "Reply ready") : title,
             body: body.isEmpty ? String(localized: "Your OpenChat reply is ready.") : body,
             conversationID: conversationID)
    }

    /// A tool stopped at a robot check while the app is not in front. Tapping it opens the chat and the page.
    static func notifyRobotCheck(host: String, conversationID: UUID?, requestID: UUID) {
        post(title: "OpenChat", body: String(localized: "\(host) wants a robot check. Tap to open the page."),
             conversationID: conversationID, extra: [ReplyNotificationRouter.robotCheckKey: requestID.uuidString])
    }

    /// Posts when the setting is on, the app is not in front and the person allowed notifications.
    private static func post(title: String, body: String, conversationID: UUID?, extra: [String: String] = [:]) {
        #if DEBUG
        if DebugHooks.value("StrataNoNotifications") != nil { return }
        #endif
        guard enabled, !AppLifecycle.isActive else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            #if os(iOS)
            guard status == .authorized || status == .provisional || status == .ephemeral else { return }
            #else
            guard status == .authorized || status == .provisional else { return }
            #endif
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            var info = extra
            if let conversationID {
                content.threadIdentifier = conversationID.uuidString
                info[ReplyNotificationRouter.conversationKey] = conversationID.uuidString
            }
            content.userInfo = info
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Opens the chat a tapped notification is about. The tap can arrive before the window is up (a cold launch), so the
/// chat waits in `pending` until `ChatLifecycle` takes it.
@MainActor
@Observable
final class ReplyNotificationRouter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    nonisolated static let conversationKey = "conversation"
    /// A robot-check notification's request (`RobotCheckRequests`): tapping it opens the page as Open page would.
    nonisolated static let robotCheckKey = "robotCheck"
    static var shared: ReplyNotificationRouter?
    var pending: UUID?

    override init() {
        super.init()
        Self.shared = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let raw = info[Self.robotCheckKey] as? String, let request = UUID(uuidString: raw) {
            RobotCheckRequests.shared.answer(request, .open)
        }
        guard let raw = info[Self.conversationKey] as? String, let id = UUID(uuidString: raw) else { return }
        pending = id
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [] // the person is already looking at the app
    }
}
