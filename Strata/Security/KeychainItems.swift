import Foundation
import Security

// The app's Keychain items: generic passwords, one service per kind of secret (API keys, ChatGPT and OpenCode sign-ins,
// SSH), one account per record. With "Sync secrets with iCloud Keychain" on (the default) they are synchronizable and
// readable after first unlock; off, this device keeps its own copies, readable on this device only. Values are never
// logged.

/// The switch and the services it covers.
enum KeychainSync {
    /// The Settings switch "Sync secrets with iCloud Keychain" (this device only, on by default).
    static let enabledKey = "sync.secrets"
    /// The mode the items were last moved to (`moveAll`), so launch only moves them when the switch changed.
    static let appliedKey = "sync.secretsApplied"

    static let services = [
        "cc.coolservices.strata.apikey",
        "cc.coolservices.strata.chatgpt.registration",
        "cc.coolservices.strata.chatgpt.tokens",
        "cc.coolservices.strata.opencode.session",
        "cc.coolservices.strata.opencode.apikey",
        "cc.coolservices.strata.ssh",
        headersService,
    ]

    /// Custom headers of synced connections, which may hold credentials (`ConnectionSync`).
    static let headersService = "cc.coolservices.strata.headers"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Moves every item of every service to the switch's mode, when it differs from the last move. Returns how many
    /// items moved.
    @discardableResult
    static func applyIfNeeded(defaults: UserDefaults = .standard, backend: any KeychainBackend = SystemKeychain()) -> Int {
        let enabled = isEnabled(defaults)
        if let applied = defaults.object(forKey: appliedKey) as? Bool, applied == enabled { return 0 }
        var moved = 0
        var complete = true
        for service in services {
            let result = KeychainItems(service: service, backend: backend, synchronizable: { enabled }).moveAll(synchronizable: enabled)
            moved += result.moved
            complete = complete && result.failed == 0
        }
        if complete { defaults.set(enabled, forKey: appliedKey) }
        return moved
    }
}

/// The calls the items make, so tests can run them against a fake (`InMemoryKeychain`).
protocol KeychainBackend: Sendable {
    func copy(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychain: KeychainBackend {
    func copy(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        return (status, out)
    }

    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// The generic-password items of one service.
///
/// On a Mac, items live in the data protection keychain (the one iCloud Keychain syncs). Items saved before sync are in
/// the older file keychain: they are still read from there, and `moveAll` moves them over.
struct KeychainItems: Sendable {
    let service: String
    var backend: any KeychainBackend = SystemKeychain()
    /// Whether new and moved items sync (`KeychainSync.isEnabled`), read at each write.
    var synchronizable: @Sendable () -> Bool = { KeychainSync.isEnabled() }
    /// The Mac's file keychain holds items from before sync.
    var hasFileKeychain: Bool = Self.isMac

    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    // MARK: Queries

    /// Matches the service's items (or one account's) in `mode`: synchronizable, device-only, or either (nil).
    func match(_ account: String?, synchronizable mode: Bool?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        query[kSecAttrSynchronizable as String] = mode.map { $0 as CFBoolean } ?? kSecAttrSynchronizableAny
        if hasFileKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    /// The attributes of a new item. A synchronizable item can't be "this device only", so it is "after first unlock".
    func attributes(_ account: String, data: Data, synchronizable sync: Bool) -> [String: Any] {
        var item = match(account, synchronizable: sync)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = sync ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return item
    }

    /// The Mac's file keychain, where items from before sync are (no synchronizable or accessibility attributes there).
    func fileKeychainMatch(_ account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    // MARK: Reading and writing

    func read(_ account: String) -> Data? {
        // The switch's own mode first: while items move, an account can briefly have both.
        let preferred = synchronizable()
        for mode in [preferred, !preferred] {
            if let data = data(match(account, synchronizable: mode)) { return data }
        }
        return hasFileKeychain ? data(fileKeychainMatch(account)) : nil
    }

    /// Saves (nil deletes) the account's item in the switch's mode. Deleting removes every copy, the one in iCloud too.
    /// Saving with sync off leaves the copy in iCloud Keychain to the other devices that still use it.
    func write(_ data: Data?, account: String) throws {
        guard let data else {
            for query in [match(account, synchronizable: nil)] + (hasFileKeychain ? [fileKeychainMatch(account)] : []) {
                let status = backend.delete(query)
                if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError(status: status) }
            }
            return
        }
        let sync = synchronizable()
        let status = backend.update(match(account, synchronizable: sync), [kSecValueData as String: data])
        var inFileKeychain = false
        if status == errSecItemNotFound || (hasFileKeychain && status == errSecMissingEntitlement) {
            inFileKeychain = try add(account, data: data, synchronizable: sync)
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
        guard !inFileKeychain else { return }
        // The device-only copy of an item that now syncs is replaced by it; a synced copy stays for other devices.
        if sync { _ = backend.delete(match(account, synchronizable: false)) }
        if hasFileKeychain { _ = backend.delete(fileKeychainMatch(account)) }
    }

    func accounts() -> [String] {
        var queries = [match(nil, synchronizable: nil)]
        if hasFileKeychain { queries.append(fileKeychainMatch(nil)) }
        var seen = Set<String>()
        var out: [String] = []
        for var query in queries {
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            let (status, result) = backend.copy(query)
            guard status == errSecSuccess, let items = result as? [[String: Any]] else { continue }
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String, seen.insert(account).inserted else { continue }
                out.append(account)
            }
        }
        return out
    }

    // MARK: Moving

    /// Moves every item of the service to `sync`: device-only items (and the Mac's file keychain items) become
    /// synchronizable, or synchronizable ones get a device-only copy. Turning sync off never deletes the iCloud copy,
    /// which other devices may still use. An item that can't be moved stays where it is and counts as failed.
    func moveAll(synchronizable sync: Bool) -> (moved: Int, failed: Int) {
        var moved = 0, failed = 0
        var listing = match(nil, synchronizable: !sync)
        listing[kSecReturnAttributes as String] = true
        listing[kSecMatchLimit as String] = kSecMatchLimitAll
        var sources: [(account: String, query: [String: Any], deleteAfter: Bool)] = []
        if case (errSecSuccess, let result) = backend.copy(listing), let items = result as? [[String: Any]] {
            for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) {
                sources.append((account, match(account, synchronizable: !sync), sync))
            }
        }
        if hasFileKeychain {
            var legacy = fileKeychainMatch(nil)
            legacy[kSecReturnAttributes as String] = true
            legacy[kSecMatchLimit as String] = kSecMatchLimitAll
            if case (errSecSuccess, let result) = backend.copy(legacy), let items = result as? [[String: Any]] {
                for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) {
                    sources.append((account, fileKeychainMatch(account), true))
                }
            }
        }
        for source in sources {
            guard let data = data(source.query) else { failed += 1; continue }
            let target = match(source.account, synchronizable: sync)
            var status = backend.add(attributes(source.account, data: data, synchronizable: sync))
            // Already there in the new mode (another device synced it, or a move stopped halfway): this device's copy wins.
            if status == errSecDuplicateItem { status = backend.update(target, [kSecValueData as String: data]) }
            guard status == errSecSuccess else { failed += 1; continue }
            if source.deleteAfter { _ = backend.delete(source.query) }
            moved += 1
        }
        return (moved, failed)
    }

    // MARK: Private

    private func data(_ query: [String: Any]) -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = backend.copy(query)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Returns true when the item went to the Mac's file keychain instead.
    private func add(_ account: String, data: Data, synchronizable sync: Bool) throws -> Bool {
        let status = backend.add(attributes(account, data: data, synchronizable: sync))
        if status == errSecSuccess { return false }
        // A Mac build signed without a provisioning profile can't reach the data protection keychain: the file keychain
        // keeps the secret working, on this Mac only.
        guard hasFileKeychain && status == errSecMissingEntitlement else { throw KeychainError(status: status) }
        var legacy = fileKeychainMatch(account)
        legacy[kSecValueData as String] = data
        var added = backend.add(legacy)
        if added == errSecDuplicateItem { added = backend.update(fileKeychainMatch(account), [kSecValueData as String: data]) }
        guard added == errSecSuccess else { throw KeychainError(status: added) }
        return true
    }
}
