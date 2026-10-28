import Foundation

/// iCloud key-value storage, or a fake in tests. Both apps name the same store (`ubiquity-kvstore-identifier`).
protocol CloudKeyValueStoring: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    var dictionaryRepresentation: [String: Any] { get }
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStoring {}

/// For tests and previews.
final class InMemoryKeyValueStore: CloudKeyValueStoring {
    private(set) var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    var dictionaryRepresentation: [String: Any] { values }
    func synchronize() -> Bool { true }
}

/// Plist values compared as Foundation compares them (an `Int` 3 and an `NSNumber` 3 are equal).
private func same(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case let (a?, b?): (a as AnyObject).isEqual(b as AnyObject)
    default: false
    }
}

// MARK: - Settings

/// The preferences that follow the user to their other devices, in iCloud key-value storage under `prefix`. What
/// belongs to one device stays out: text size, notifications and Live Activities, the background sound, dictation,
/// Apple Health, developer mode, the model last picked, and the sync switches themselves.
@MainActor
final class SettingsSync {
    /// The Settings switch "Sync settings and connections" (this device only, on by default).
    static let enabledKey = "sync.settings"
    nonisolated static let prefix = "settings."

    /// The synced `AppSettings.fields`, plus the keys other settings keep (SSH approvals). Listed here because sync
    /// runs off the main actor; a test keeps it equal to the fields marked `.synced`.
    nonisolated static let keys: [String] = [
        "accentHex", "defaultContextLength", "fetchLength", FetchPatience.defaultsKey, "searchEngine", "smoothStreaming",
        "continueOnEmptyAnswer", "generateTitles", "nameChatsOnDevice", "thinkingLines", "translateThinking", "recentModels",
        AppSettings.userPreferencesKey, AppSettings.enabledPluginsKey, AppSettings.webSearchEnabledKey,
        PythonSettings.enabledKey, PythonSettings.timeLimitKey, AppSettings.browserEnabledKey, AppSettings.locationEnabledKey,
        AppSettings.sshEnabledKey, AppSettings.videoTranscriptsEnabledKey, AppSettings.interactiveViewsEnabledKey,
        RobotCheck.askKey, SSHApprovalPolicy.askKey,
    ]

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Writes the cloud's values of the synced keys into `defaults`. Returns the keys that changed.
    @discardableResult
    nonisolated static func pull(_ keys: [String] = keys, from cloud: any CloudKeyValueStoring, to defaults: UserDefaults) -> [String] {
        var changed: [String] = []
        for key in keys where Self.keys.contains(key) {
            guard let value = cloud.object(forKey: prefix + key), !same(value, defaults.object(forKey: key)) else { continue }
            defaults.set(value, forKey: key)
            changed.append(key)
        }
        return changed
    }

    /// Writes this device's values of the synced keys to the cloud, where they differ. A key never set here is not
    /// written (and a value removed here is not removed elsewhere). Returns the keys written.
    @discardableResult
    nonisolated static func push(from defaults: UserDefaults, to cloud: any CloudKeyValueStoring) -> [String] {
        var written: [String] = []
        for key in keys {
            guard let value = defaults.object(forKey: key), !same(value, cloud.object(forKey: prefix + key)) else { continue }
            cloud.set(value, forKey: prefix + key)
            written.append(key)
        }
        return written
    }

    let defaults: UserDefaults
    let cloud: any CloudKeyValueStoring
    let settings: AppSettings
    private var applying = false
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, cloud: any CloudKeyValueStoring = NSUbiquitousKeyValueStore.default, settings: AppSettings) {
        self.defaults = defaults
        self.cloud = cloud
        self.settings = settings
    }

    /// Starts following both sides. `localWins`: when the switch was just turned on, this device's values go up first;
    /// at launch the cloud's (which hold this device's earlier changes too) come down first.
    func start(localWins: Bool = false) {
        guard observers.isEmpty else { return }
        cloud.synchronize()
        if localWins { Self.push(from: defaults, to: cloud) }
        apply(Self.pull(from: cloud, to: defaults))
        Self.push(from: defaults, to: cloud)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localChanged() }
        })
        if let ubiquitous = cloud as? NSUbiquitousKeyValueStore {
            observers.append(center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: ubiquitous,
                                                queue: .main) { [weak self] note in
                let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
                MainActor.assumeIsolated { self?.remoteChanged(keys) }
            })
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    func localChanged() {
        guard !applying else { return }
        Self.push(from: defaults, to: cloud)
    }

    /// Keys another device changed (nil: all of them, as after an account change).
    func remoteChanged(_ keys: [String]?) {
        let synced = keys?.filter { $0.hasPrefix(Self.prefix) }.map { String($0.dropFirst(Self.prefix.count)) } ?? Self.keys
        apply(Self.pull(synced, from: cloud, to: defaults))
    }

    private func apply(_ changed: [String]) {
        guard !changed.isEmpty else { return }
        applying = true
        settings.reload(from: defaults)
        applying = false
    }
}

// MARK: - Connections

/// The connection list in iCloud key-value storage: one key per connection (`connection.<id>`) plus the order, so two
/// devices adding connections at once both keep theirs. What stays on the device: the on-device connection (each
/// device has its own model), and custom headers, which may hold credentials and travel in the Keychain instead
/// (`KeychainSync.headersService`, synced or not with the other secrets). API keys and sign-ins are in the Keychain already.
@MainActor
final class ConnectionSync {
    nonisolated static let keyPrefix = "connection."
    static let orderKey = "connections.order"
    /// The ids this device has seen in the cloud (this device only): one of them missing there was deleted elsewhere.
    static let seenKey = "sync.connectionsSeen"
    /// The iCloud account `seenKey` was recorded under (`account`). Under another one, a connection missing from the
    /// cloud was never deleted there.
    static let seenAccountKey = "sync.connectionsSeenAccount"
    /// Each synced connection as this device last sent or received it, kept when sync is turned off (`stop`): turning it
    /// on again sends up what changed here meanwhile instead of taking the cloud's older copy.
    static let snapshotKey = "sync.connectionsAtStop"

    /// The iCloud account, as an opaque archive of `FileManager.ubiquityIdentityToken`: empty when signed out, nil when
    /// it can't be told.
    nonisolated static func currentAccount() -> Data? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return Data() }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
    }

    /// Two archives of `currentAccount` name the same account (tokens compare as objects, not bytes).
    nonisolated static func sameAccount(_ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        func token(_ data: Data) -> NSObject? {
            guard !data.isEmpty, let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
            unarchiver.requiresSecureCoding = false
            return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
        }
        guard let x = token(a), let y = token(b) else { return false }
        return x.isEqual(y)
    }

    /// The on-device connection stays, and so does one still being set up (no address yet, or an Anthropic connection
    /// without models: Settings removes those, and another device must not remove one being set up here).
    nonisolated static func syncs(_ connection: Connection) -> Bool {
        guard connection.kind != .appleOnDevice else { return false }
        if connection.kind == .anthropic { return !connection.models.isEmpty }
        let url = connection.baseURL.trimmingCharacters(in: .whitespaces).lowercased()
        return connection.kind != .openAICompatible || !connection.models.isEmpty || !(url.isEmpty || url == "https://" || url == "http://")
    }

    /// A connection as the cloud keeps it: no custom headers, and no credentials in its base URL (the app refuses such a
    /// URL, `BaseURLCredentials`; one saved before that never leaves the device with them).
    nonisolated static func encode(_ connection: Connection) -> Data? {
        var c = connection
        c.customHeaders = ""
        c.baseURL = BaseURLCredentials.stripped(c.baseURL)
        return try? JSONEncoder().encode(c)
    }

    /// A connection as another device decodes it (decoding fills in some flags), for comparing what was sent. Values,
    /// not bytes: JSON of the same connection can come out in a different key order.
    nonisolated static func trimmed(_ headers: String) -> String { headers.trimmingCharacters(in: .whitespacesAndNewlines) }

    nonisolated static func normalized(_ connection: Connection) -> Connection? {
        encode(connection).flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
    }

    /// The cloud's connections, by id.
    nonisolated static func cloudConnections(_ cloud: any CloudKeyValueStoring) -> [UUID: Connection] {
        var out: [UUID: Connection] = [:]
        for (key, value) in cloud.dictionaryRepresentation where key.hasPrefix(keyPrefix) {
            guard let id = UUID(uuidString: String(key.dropFirst(keyPrefix.count))), let data = value as? Data,
                  let connection = try? JSONDecoder().decode(Connection.self, from: data), connection.id == id else { continue }
            out[id] = connection
        }
        return out
    }

    /// The list after another device's changes: the cloud's version of each connection it has, this device's
    /// connections it never had (new here, or from before sync), minus those it had and no longer has (deleted
    /// elsewhere). In the cloud's order, then this device's. `headers` gives a synced connection its custom headers.
    nonisolated static func merge(local: [Connection], cloud: [UUID: Connection], order: [UUID], seen: Set<UUID>,
                                  headers: (UUID) -> String?) -> [Connection] {
        var out: [Connection] = []
        var placed = Set<UUID>()
        for id in order + cloud.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !placed.contains(id) {
            guard var connection = cloud[id] else { continue }
            connection.customHeaders = headers(id) ?? ""
            out.append(connection)
            placed.insert(id)
        }
        for connection in local where !placed.contains(connection.id) {
            if syncs(connection) && seen.contains(connection.id) { continue }
            out.append(connection)
            placed.insert(connection.id)
        }
        // Keep this device's order for the connections it already had, with arrivals after them.
        let position = Dictionary(uniqueKeysWithValues: local.enumerated().map { ($1.id, $0) })
        return out.enumerated().sorted { a, b in
            (position[a.element.id] ?? Int.max, a.offset) < (position[b.element.id] ?? Int.max, b.offset)
        }.map(\.element)
    }

    let store: ConnectionStore
    let cloud: any CloudKeyValueStoring
    let defaults: UserDefaults
    let headers: any KeyStoring
    let account: () -> Data?
    private var applying = false
    private var observer: NSObjectProtocol?
    /// Each connection as this device last sent or received it: only one changed here since goes up, so a save here
    /// never sends back an older copy of one another device just changed.
    private var lastSynced: [UUID: Connection] = [:]
    /// Each connection's headers as this device last read or wrote them. Only a change made here goes to the Keychain:
    /// iCloud Keychain may have brought a newer value meanwhile, which a stale copy in memory must not overwrite.
    private var lastHeaders: [UUID: String] = [:]

    init(store: ConnectionStore, cloud: any CloudKeyValueStoring = NSUbiquitousKeyValueStore.default,
         defaults: UserDefaults = .standard, headers: any KeyStoring = KeychainKeyStore(service: KeychainSync.headersService),
         account: @escaping () -> Data? = ConnectionSync.currentAccount) {
        self.store = store
        self.cloud = cloud
        self.defaults = defaults
        self.headers = headers
        self.account = account
    }

    var seen: Set<UUID> {
        get { Set((defaults.stringArray(forKey: Self.seenKey) ?? []).compactMap(UUID.init(uuidString:))) }
        set { defaults.set(newValue.map(\.uuidString).sorted(), forKey: Self.seenKey) }
    }

    /// The deletions `seen` stands for belong to the account it was recorded under. After a change of Apple Account (or
    /// a sign-out) the cloud's list is another one: what is missing there wasn't deleted, so the record starts over and
    /// this device's connections stay (and go up to the new account). Called before each use of `seen`.
    private func checkAccount() {
        guard let current = account() else { return }
        guard let recorded = defaults.data(forKey: Self.seenAccountKey) else {
            defaults.set(current, forKey: Self.seenAccountKey) // recorded from now on
            return
        }
        guard !Self.sameAccount(recorded, current) else { return }
        seen = []
        lastSynced = [:]
        lastHeaders = [:]
        defaults.removeObject(forKey: Self.snapshotKey)
        defaults.set(current, forKey: Self.seenAccountKey)
    }

    /// `localWins`: the switch was just turned on. Connections changed or deleted here while it was off go up before the
    /// cloud's list comes down (the cloud's copy of the others, and connections new there, still come down). At launch
    /// the cloud's list comes down first.
    func start(localWins: Bool = false) {
        guard observer == nil else { return }
        cloud.synchronize()
        // Headers from before sync go to the Keychain first, so the merge finds them there.
        for c in store.connections where Self.syncs(c) && !c.customHeaders.isEmpty && headers.key(for: c.id) == nil {
            try? headers.setKey(c.customHeaders, for: c.id)
        }
        checkAccount()
        if localWins {
            // What this device last synced, so only what changed since goes up (without it, all of this device's list).
            for (id, data) in defaults.dictionary(forKey: Self.snapshotKey) as? [String: Data] ?? [:] {
                if let id = UUID(uuidString: id), let c = try? JSONDecoder().decode(Connection.self, from: data) { lastSynced[id] = c }
            }
            push(store.connections)
        }
        defaults.removeObject(forKey: Self.snapshotKey)
        pull()
        push(store.connections)
        store.onSave = { [weak self] connections in self?.push(connections) }
        store.changedHeaders = { [weak self] id in self?.changedHeaders(id) }
        if let ubiquitous = cloud as? NSUbiquitousKeyValueStore {
            observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                              object: ubiquitous, queue: .main) { [weak self] note in
                let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
                let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if reason == NSUbiquitousKeyValueStoreAccountChange {
                        // Another account's list: `pull` starts the deletion record over, and this device's list goes up.
                        self.pull()
                        self.push(self.store.connections)
                        return
                    }
                    guard keys.isEmpty || keys.contains(where: { $0.hasPrefix(Self.keyPrefix) || $0 == Self.orderKey }) else { return }
                    self.pull()
                }
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        store.onSave = nil
        store.changedHeaders = nil
        // Encoded as they go up: no headers, no credentials in a URL (`encode`).
        let snapshot = lastSynced.reduce(into: [String: Data]()) { out, pair in out[pair.key.uuidString] = Self.encode(pair.value) }
        defaults.set(snapshot, forKey: Self.snapshotKey)
    }

    /// Headers another device changed: iCloud Keychain brings them with no key-value change, so this device's copy in
    /// memory stays as it was until the next pull. Requests read them here (`ConnectionStore.changedHeaders`), and
    /// nothing is written back: the stale copy matches what this device last saw, so `push` leaves the Keychain alone.
    /// Nil when nothing changed elsewhere since this device last read or wrote them.
    func changedHeaders(_ id: UUID) -> String? {
        guard let seen = lastHeaders[id] else { return nil }
        let now = headers.key(for: id) ?? ""
        return Self.trimmed(now) == seen ? nil : now
    }

    /// Takes the cloud's list.
    func pull() {
        checkAccount()
        let remote = Self.cloudConnections(cloud)
        let order = (cloud.object(forKey: Self.orderKey) as? [String] ?? []).compactMap(UUID.init(uuidString:))
        let merged = Self.merge(local: store.connections, cloud: remote, order: order, seen: seen, headers: { headers.key(for: $0) })
        seen.formUnion(remote.keys)
        for (id, connection) in remote { lastSynced[id] = Self.normalized(connection) }
        for c in merged where remote[c.id] != nil { lastHeaders[c.id] = Self.trimmed(c.customHeaders) }
        guard merged != store.connections else { return }
        applying = true
        store.replaceAll(merged)
        applying = false
        // The store merged duplicate ChatGPT accounts (`ConnectionStore.collapseDuplicateAccounts`): the losers' removal
        // goes up now, or the next pull would bring them back from the cloud.
        if store.connections != merged { push(store.connections) }
    }

    /// Writes this device's list where it differs from the cloud's: changed connections, new ones, the order, and the
    /// removal of those deleted here.
    func push(_ connections: [Connection]) {
        guard !applying else { return }
        checkAccount()
        let remote = Self.cloudConnections(cloud)
        var known = seen
        // One this device has seen in the cloud and that is gone from it was deleted elsewhere: the next pull drops it
        // here, and it must not go back up before that.
        let synced = connections.filter { Self.syncs($0) && (remote[$0.id] != nil || !known.contains($0.id)) }
        for c in synced {
            let sent = Self.normalized(c)
            // A copy an older version uploaded with credentials in its URL is replaced even when nothing changed here.
            let leaked = remote[c.id].map { BaseURLCredentials.contains($0.baseURL) } ?? false
            if let data = Self.encode(c), lastSynced[c.id] != sent || leaked {
                cloud.set(data, forKey: Self.keyPrefix + c.id.uuidString)
                lastSynced[c.id] = sent
            }
            let local = Self.trimmed(c.customHeaders)
            if local != lastHeaders[c.id] ?? Self.trimmed(headers.key(for: c.id) ?? "") { try? headers.setKey(c.customHeaders, for: c.id) }
            lastHeaders[c.id] = local
        }
        let ids = Set(synced.map(\.id))
        // Only what this device had and no longer has is removed: a connection another device just added is not.
        for id in remote.keys where !ids.contains(id) && known.contains(id) {
            cloud.removeObject(forKey: Self.keyPrefix + id.uuidString)
            try? headers.setKey(nil, for: id)
            lastHeaders[id] = nil
            known.remove(id)
            lastSynced[id] = nil
        }
        known.formUnion(ids)
        seen = known
        let order = synced.map(\.id.uuidString)
        if cloud.object(forKey: Self.orderKey) as? [String] != order { cloud.set(order, forKey: Self.orderKey) }
    }
}
