import Foundation
import UserNotifications
#if os(iOS)
import UIKit
import BackgroundTasks
#endif

/// One user-started turn, including all of its tool rounds.
@MainActor
final class ReplyBackgroundExecution {
    private(set) static var hasContinuedLease = false
    #if os(iOS)
    private var fallback: UIBackgroundTaskIdentifier = .invalid
    private var continued: BGContinuedProcessingTask?
    private var identifier: String?
    private var active = false
    private var units: Int64 = 0
    /// Every delta advances the count, but the system's progress object is written about once a second.
    private var progressLimiter = RateLimiter(interval: .seconds(1))

    func begin() {
        guard !active else { return }
        active = true
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
                    self.endFallback()
                }
            }
            if registered {
                DiagnosticCounters.shared.backgroundIdentifierRegistered()
                let request = BGContinuedProcessingTaskRequest(identifier: id,
                    title: String(localized: "Preparing reply"), subtitle: String(localized: "Strata is replying"))
                request.strategy = .fail // no stale queued work after the turn has already finished
                do { try BGTaskScheduler.shared.submit(request) }
                catch { identifier = nil } // finite beginBackgroundTask fallback remains active
            }
        }
    }

    /// For the diagnostics panel.
    var stateDescription: String {
        if continued != nil { return "continued task running" }
        if active { return fallback != .invalid ? "background task only" : "active, no lease" }
        return "idle"
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
    func end(success: Bool, title: String? = nil, subtitle: String? = nil) {
        active = false
        if let continued {
            if let title { continued.updateTitle(title, subtitle: subtitle ?? "") }
            if success { continued.progress.completedUnitCount = continued.progress.totalUnitCount }
            continued.setTaskCompleted(success: success)
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
    func begin() {}
    var stateDescription: String { "not needed on macOS" }
    func advance(by count: Int = 1) {}
    func end(success: Bool, title: String? = nil, subtitle: String? = nil) {}
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
             body: body.isEmpty ? String(localized: "Your Strata reply is ready.") : body,
             conversationID: conversationID)
    }

    /// A tool stopped at a robot check while the app is not in front. Tapping it opens the chat and the page.
    static func notifyRobotCheck(host: String, conversationID: UUID?, requestID: UUID) {
        post(title: "Strata", body: String(localized: "\(host) wants a robot check. Tap to open the page."),
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
