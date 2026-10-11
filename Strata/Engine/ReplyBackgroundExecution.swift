import UIKit
import BackgroundTasks
import UserNotifications

/// One user-started turn, including all of its tool rounds.
@MainActor
final class ReplyBackgroundExecution {
    private(set) static var hasContinuedLease = false
    private var fallback: UIBackgroundTaskIdentifier = .invalid
    private var continued: BGContinuedProcessingTask?
    private var identifier: String?
    private var active = false
    private var units: Int64 = 0

    func begin() {
        guard !active else { return }
        active = true
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
        if let continued {
            continued.progress.totalUnitCount = units + 1000 // generation length is unknown
            continued.progress.completedUnitCount = units
        }
    }

    func end(success: Bool) {
        active = false
        if let continued {
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

    private static var notificationObserver: NSObjectProtocol?
    private static var deliveringNotification = false
    private static let notificationPendingKey = "strata.replyNotificationPending"

    static func prepareNotifications() {
        guard notificationObserver == nil else { return }
        notificationObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                      object: nil, queue: .main) { _ in
            Task { @MainActor in deliverPendingNotification() }
        }
    }

    static func notifyCompletion() {
        guard UIApplication.shared.applicationState != .active else { return }
        UserDefaults.standard.set(true, forKey: notificationPendingKey)
        deliverPendingNotification()
    }

    private static func deliverPendingNotification() {
        #if DEBUG
        if DebugHooks.value("StrataNoNotifications") != nil { return } // keeps the permission prompt out of screenshots
        #endif
        guard UserDefaults.standard.bool(forKey: notificationPendingKey), !deliveringNotification else { return }
        deliveringNotification = true
        Task { @MainActor in
            defer { deliveringNotification = false }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                // iOS cannot show a permission sheet while suspended/backgrounded.
                // First background completion queues the lazy request for the next active scene.
                guard UIApplication.shared.applicationState == .active else { return }
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                    UserDefaults.standard.set(false, forKey: notificationPendingKey)
                    return
                }
            }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Reply ready")
            content.body = String(localized: "Your Strata reply is ready.")
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                UserDefaults.standard.set(false, forKey: notificationPendingKey)
            } catch { /* retry the queued notification at the next active scene */ }
        }
    }
}
