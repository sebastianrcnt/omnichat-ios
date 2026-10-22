import CloudKit
import CoreData
import Foundation
import SwiftData

/// iCloud sync at run time: starts the parts at launch, tidies the store after each import from another device, and
/// keeps what Settings > iCloud shows (the account, the last sync, the switches).
///
/// What syncs: chats with their messages, images, compactions, figures and artifact pages, and saved skills (CloudKit,
/// `StrataStore`); preferences and the connection list (key-value storage, `SettingsSync`, `ConnectionSync`); API keys,
/// sign-ins, SSH credentials and custom headers (iCloud Keychain, `KeychainItems`).
@MainActor
@Observable
final class CloudSync {
    static let shared = CloudSync()

    enum Account: Equatable {
        case checking, available, noAccount, restricted, temporarilyUnavailable, unknown
    }

    /// The store was opened with CloudKit (the switch was on at launch, and this isn't a test run).
    private(set) var chatsSyncing = false
    private(set) var account: Account = .checking
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var controller: ChatController?
    @ObservationIgnored private var skills: SkillSync?
    @ObservationIgnored private var files: FileSync?
    @ObservationIgnored private var settingsSync: SettingsSync?
    @ObservationIgnored private var connectionSync: ConnectionSync?
    @ObservationIgnored private var settings: AppSettings?
    @ObservationIgnored private var connections: ConnectionStore?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var tidyTask: Task<Void, Never>?
    @ObservationIgnored private var defaults: UserDefaults = .standard

    /// Called once at launch, after the container opened.
    func start(container: ModelContainer, settings: AppSettings, connections: ConnectionStore, controller: ChatController,
               defaults: UserDefaults = .standard) {
        guard self.container == nil, !StrataStore.isRunningTests else { return }
        self.container = container
        self.controller = controller
        self.settings = settings
        self.connections = connections
        self.defaults = defaults
        chatsSyncing = StrataStore.syncEnabled(defaults)

        tidyStore()
        let skills = SkillSync(container: container, defaults: defaults)
        skills.start()
        self.skills = skills
        let files = FileSync(container: container)
        FileMirror.handler = files
        files.migrateExisting(defaults: defaults)
        files.materialize()
        self.files = files

        Task.detached(priority: .utility) { KeychainSync.applyIfNeeded() }
        if SettingsSync.isEnabled(defaults) { startSettingsSync(localWins: false) }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event
            let summary = event.map { EventSummary($0) }
            MainActor.assumeIsolated { if let summary { self?.record(summary) } }
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccount() }
        })
        refreshAccount()
    }

    // MARK: Status

    /// What the app keeps of a CloudKit event (the event itself is not Sendable).
    struct EventSummary: Sendable {
        var isImport: Bool
        var finished: Date?
        var succeeded: Bool
        var error: String?

        init(_ event: NSPersistentCloudKitContainer.Event) {
            isImport = event.type == .import
            finished = event.endDate
            succeeded = event.succeeded
            error = event.error?.localizedDescription
        }
    }

    private func record(_ event: EventSummary) {
        guard let finished = event.finished else {
            isSyncing = true
            return
        }
        isSyncing = false
        if event.succeeded {
            lastSync = finished
            lastError = nil
        } else {
            lastError = event.error
        }
        if event.isImport && event.succeeded { scheduleTidy() }
    }

    func refreshAccount() {
        guard !StrataStore.isRunningTests else { return }
        Task { @MainActor in
            let status = try? await CKContainer(identifier: StrataStore.cloudKitContainer).accountStatus()
            account = switch status {
            case .available: .available
            case .noAccount: .noAccount
            case .restricted: .restricted
            case .temporarilyUnavailable: .temporarilyUnavailable
            default: .unknown
            }
        }
    }

    // MARK: After imports

    /// Imports come in bursts: tidy once they settle.
    private func scheduleTidy() {
        tidyTask?.cancel()
        tidyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.tidyStore()
            self.skills?.apply()
            self.files?.materialize()
        }
    }

    /// Removes duplicate records. A conversation that is on screen or replying is left for the next time.
    private func tidyStore() {
        guard let context = container?.mainContext else { return }
        var busy = controller?.runningConversationIDs ?? []
        if let visible = controller?.visibleConversationID { busy.insert(visible) }
        _ = try? SyncDedupe.conversations(context, skipping: busy)
        _ = try? SyncDedupe.files(context)
    }

    // MARK: Switches

    /// "Sync chats and skills": the store opens with or without CloudKit, so it applies at the next launch. Turning it
    /// on turns Apple Health off on this device and removes what Health tools read from the stored chats first
    /// (`HealthSettings.blockedBySync`, `HealthRedaction`).
    var chatSyncSwitch: Bool {
        get { _ = switchVersion; return StrataStore.syncEnabled(defaults) }
        set {
            if newValue && !StrataStore.syncEnabled(defaults) {
                settings?.healthEnabled = false
                HealthRequests.shared.declineAll()
                if let container { try? HealthRedaction.redact(container.mainContext) }
            }
            defaults.set(newValue, forKey: StrataStore.syncEnabledKey)
            switchVersion += 1
        }
    }

    /// Whether the chat switch differs from how the store was opened.
    var needsRelaunch: Bool {
        _ = switchVersion
        return !StrataStore.isRunningTests && container != nil && StrataStore.syncEnabled(defaults) != chatsSyncing
    }

    var settingsSyncSwitch: Bool {
        get { _ = switchVersion; return SettingsSync.isEnabled(defaults) }
        set {
            defaults.set(newValue, forKey: SettingsSync.enabledKey)
            switchVersion += 1
            if newValue { startSettingsSync(localWins: true) } else { stopSettingsSync() }
        }
    }

    var secretSyncSwitch: Bool {
        get { _ = switchVersion; return KeychainSync.isEnabled(defaults) }
        set {
            defaults.set(newValue, forKey: KeychainSync.enabledKey)
            switchVersion += 1
            Task.detached(priority: .userInitiated) { KeychainSync.applyIfNeeded() }
        }
    }

    private var switchVersion = 0

    private func startSettingsSync(localWins: Bool) {
        guard container != nil, let settings, let connections, settingsSync == nil else { return }
        let settingsSync = SettingsSync(defaults: defaults, settings: settings)
        settingsSync.start(localWins: localWins)
        self.settingsSync = settingsSync
        let connectionSync = ConnectionSync(store: connections, defaults: defaults)
        connectionSync.start()
        self.connectionSync = connectionSync
    }

    private func stopSettingsSync() {
        settingsSync?.stop()
        settingsSync = nil
        connectionSync?.stop()
        connectionSync = nil
    }
}
