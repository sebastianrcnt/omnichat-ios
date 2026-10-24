import Testing
import Foundation
import Security
@testable import Strata

/// A Keychain with the semantics `KeychainItems` relies on: items match on service, account and synchronizable state (no
/// synchronizable key in a query matches device-only items only; `kSecAttrSynchronizableAny` matches both), a
/// synchronizable item can't be "this device only", and with `mac` set a query without `kSecUseDataProtectionKeychain`
/// reaches the separate file keychain.
final class InMemoryKeychain: KeychainBackend, @unchecked Sendable {
    struct Item: Equatable {
        var service: String
        var account: String
        var sync: Bool
        var fileKeychain: Bool
        var accessible: String?
        var data: Data
    }

    private let lock = NSLock()
    private(set) var items: [Item] = []
    let mac: Bool
    /// A Mac build without a provisioning profile: the data protection keychain refuses every call.
    var dataProtectionMissing = false

    init(mac: Bool = false) { self.mac = mac }

    func seed(_ item: Item) { lock.withLock { items.append(item) } }
    var snapshot: [Item] { lock.withLock { items } }

    private func usesFileKeychain(_ q: [String: Any]) -> Bool {
        mac && (q[kSecUseDataProtectionKeychain as String] as? Bool) != true
    }

    private func matches(_ item: Item, _ q: [String: Any]) -> Bool {
        guard item.service == q[kSecAttrService as String] as? String, item.fileKeychain == usesFileKeychain(q) else { return false }
        if let account = q[kSecAttrAccount as String] as? String, item.account != account { return false }
        if item.fileKeychain { return true }
        let mode = q[kSecAttrSynchronizable as String]
        if let any = mode as? String, any == kSecAttrSynchronizableAny as String { return true }
        return item.sync == ((mode as? Bool) ?? false)
    }

    private func refused(_ q: [String: Any]) -> Bool { dataProtectionMissing && !usesFileKeychain(q) }

    func copy(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        lock.withLock {
            if refused(query) { return (errSecMissingEntitlement, nil) }
            let found = items.filter { matches($0, query) }
            guard !found.isEmpty else { return (errSecItemNotFound, nil) }
            if query[kSecReturnData as String] as? Bool == true { return (errSecSuccess, found[0].data as CFData) }
            let attributes: [[String: Any]] = found.map {
                [kSecAttrAccount as String: $0.account, kSecAttrSynchronizable as String: $0.sync]
            }
            return (errSecSuccess, attributes as CFArray)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            if refused(attributes) { return errSecMissingEntitlement }
            let file = usesFileKeychain(attributes)
            let sync = !file && (attributes[kSecAttrSynchronizable as String] as? Bool ?? false)
            let accessible = attributes[kSecAttrAccessible as String] as? String
            if sync && accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String { return errSecParam }
            guard let service = attributes[kSecAttrService as String] as? String, let account = attributes[kSecAttrAccount as String] as? String,
                  let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            if items.contains(where: { $0.service == service && $0.account == account && $0.fileKeychain == file && $0.sync == sync }) {
                return errSecDuplicateItem
            }
            items.append(Item(service: service, account: account, sync: sync, fileKeychain: file, accessible: accessible, data: data))
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            if refused(query) { return errSecMissingEntitlement }
            var found = false
            for i in items.indices where matches(items[i], query) {
                if let data = attributes[kSecValueData as String] as? Data { items[i].data = data }
                found = true
            }
            return found ? errSecSuccess : errSecItemNotFound
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            if refused(query) { return errSecMissingEntitlement }
            let before = items.count
            items.removeAll { matches($0, query) }
            return items.count < before ? errSecSuccess : errSecItemNotFound
        }
    }
}

/// Holds the first delete of synchronizable items until released.
final class GatedKeychain: KeychainBackend, @unchecked Sendable {
    let inner: InMemoryKeychain
    let reachedDelete = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var gated = false
    init(_ inner: InMemoryKeychain) { self.inner = inner }
    func waitForDelete() { reachedDelete.wait() }

    func copy(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?) { inner.copy(query) }
    func add(_ attributes: [String: Any]) -> OSStatus { inner.add(attributes) }
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus { inner.update(query, attributes) }
    func delete(_ query: [String: Any]) -> OSStatus {
        let first = (query[kSecAttrSynchronizable as String] as? Bool) == true && lock.withLock { () -> Bool in
            defer { gated = true }
            return !gated
        }
        if first { reachedDelete.signal(); release.wait() }
        return inner.delete(query)
    }
}

/// A switch the tests can flip.
final class SyncSwitch: @unchecked Sendable {
    var on: Bool
    init(_ on: Bool) { self.on = on }
}

struct KeychainSyncTests {
    let service = "cc.coolservices.strata.tests"

    private func items(_ keychain: InMemoryKeychain, _ sync: SyncSwitch) -> KeychainItems {
        KeychainItems(service: service, backend: keychain, synchronizable: { sync.on }, hasFileKeychain: keychain.mac)
    }

    @Test func newItemsSyncAfterFirstUnlockOrStayOnTheDevice() {
        let items = KeychainItems(service: service, backend: InMemoryKeychain(), hasFileKeychain: false)
        let on = items.attributes("a", data: Data("v".utf8), synchronizable: true)
        #expect(on[kSecAttrSynchronizable as String] as? Bool == true)
        #expect(on[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(on[kSecAttrService as String] as? String == service)
        #expect(on[kSecAttrAccount as String] as? String == "a")
        let off = items.attributes("a", data: Data("v".utf8), synchronizable: false)
        #expect(off[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(off[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        // Reads, updates and deletes find an item in either state.
        #expect(items.match("a", synchronizable: nil)[kSecAttrSynchronizable as String] as? String == kSecAttrSynchronizableAny as String)
        #expect(items.match("a", synchronizable: nil)[kSecUseDataProtectionKeychain as String] == nil) // iPhone: one keychain
        let mac = KeychainItems(service: service, backend: InMemoryKeychain(mac: true), hasFileKeychain: true)
        #expect(mac.match("a", synchronizable: true)[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(mac.fileKeychainMatch("a")[kSecUseDataProtectionKeychain as String] == nil)
        #expect(mac.fileKeychainMatch("a")[kSecAttrSynchronizable as String] == nil)
    }

    @Test func writesFollowTheSwitch() throws {
        let keychain = InMemoryKeychain(), sync = SyncSwitch(true)
        let store = items(keychain, sync)
        try store.write(Data("one".utf8), account: "a")
        #expect(keychain.snapshot.map(\.sync) == [true])
        #expect(keychain.snapshot.first?.accessible == kSecAttrAccessibleAfterFirstUnlock as String)
        try store.write(Data("two".utf8), account: "a")
        #expect(keychain.snapshot.count == 1)
        #expect(store.read("a") == Data("two".utf8))

        // Off: this device writes its own copy; the iCloud copy stays for other devices.
        sync.on = false
        try store.write(Data("three".utf8), account: "a")
        #expect(keychain.snapshot.count == 2)
        #expect(store.read("a") == Data("three".utf8))
        #expect(keychain.snapshot.first { $0.sync }?.data == Data("two".utf8))
        #expect(keychain.snapshot.first { !$0.sync }?.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(store.accounts() == ["a"])

        // Back on: the device-only copy gives way to the synced one.
        sync.on = true
        try store.write(Data("four".utf8), account: "a")
        #expect(keychain.snapshot.map(\.sync) == [true])
        #expect(store.read("a") == Data("four".utf8))

        // Deleting removes every copy.
        sync.on = false
        try store.write(Data("five".utf8), account: "a")
        try store.write(nil, account: "a")
        #expect(keychain.snapshot.isEmpty)
        #expect(store.read("a") == nil)
    }

    @Test func itemsFromBeforeSyncMoveToICloudKeychain() {
        let keychain = InMemoryKeychain()
        for (account, value) in [("a", "key-a"), ("b", "key-b")] {
            keychain.seed(.init(service: service, account: account, sync: false, fileKeychain: false,
                                accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, data: Data(value.utf8)))
        }
        keychain.seed(.init(service: "other.service", account: "c", sync: false, fileKeychain: false, accessible: nil, data: Data()))
        let store = items(keychain, SyncSwitch(true))
        let result = store.moveAll(synchronizable: true)
        #expect(result.moved == 2 && result.failed == 0)
        let mine = keychain.snapshot.filter { $0.service == service }
        #expect(mine.allSatisfy { $0.sync && $0.accessible == kSecAttrAccessibleAfterFirstUnlock as String })
        #expect(Set(mine.map(\.account)) == ["a", "b"])
        #expect(store.read("a") == Data("key-a".utf8))
        #expect(store.read("b") == Data("key-b".utf8))
        #expect(keychain.snapshot.contains { $0.service == "other.service" && !$0.sync }) // other services untouched
        #expect(store.moveAll(synchronizable: true).moved == 0) // nothing left to move
    }

    @Test func removingFromICloudKeepsThisDevicesCopy() {
        let keychain = InMemoryKeychain()
        let api = KeychainSync.services[0], ssh = "cc.coolservices.strata.ssh"
        keychain.seed(.init(service: api, account: "a", sync: true, fileKeychain: false,
                            accessible: kSecAttrAccessibleAfterFirstUnlock as String, data: Data("key".utf8)))
        keychain.seed(.init(service: ssh, account: "b", sync: true, fileKeychain: false,
                            accessible: kSecAttrAccessibleAfterFirstUnlock as String, data: Data("old".utf8)))
        keychain.seed(.init(service: ssh, account: "b", sync: false, fileKeychain: false,
                            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, data: Data("mine".utf8)))
        keychain.seed(.init(service: "other.service", account: "c", sync: true, fileKeychain: false, accessible: nil, data: Data()))
        let off = secretsOff()
        let result = KeychainSync.removeFromICloud(backend: keychain, defaults: off)
        #expect(result.removed == 2 && result.kept == 0)
        let ours = keychain.snapshot.filter { $0.service != "other.service" }
        #expect(ours.allSatisfy { !$0.sync })
        #expect(ours.first { $0.service == api }?.data == Data("key".utf8))
        #expect(ours.first { $0.service == ssh }?.data == Data("mine".utf8)) // this device's copy wins
        #expect(keychain.snapshot.contains { $0.service == "other.service" && $0.sync }) // other apps' items untouched
        #expect(KeychainSync.removeFromICloud(backend: keychain, defaults: off).removed == 0)
    }

    @Test func turningSyncOffKeepsADeviceOnlyCopyOfEach() {
        let keychain = InMemoryKeychain()
        keychain.seed(.init(service: service, account: "a", sync: true, fileKeychain: false,
                            accessible: kSecAttrAccessibleAfterFirstUnlock as String, data: Data("key".utf8)))
        let sync = SyncSwitch(false)
        let store = items(keychain, sync)
        #expect(store.moveAll(synchronizable: false).moved == 1)
        let local = keychain.snapshot.filter { !$0.sync }
        #expect(local.map(\.data) == [Data("key".utf8)])
        #expect(local.first?.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(keychain.snapshot.contains { $0.sync }) // still there for the other devices
        #expect(store.read("a") == Data("key".utf8))
        // Turning it on again moves the device-only copy back (it wins over the synced one).
        try? store.write(Data("changed".utf8), account: "a")
        sync.on = true
        #expect(store.moveAll(synchronizable: true).moved == 1)
        #expect(keychain.snapshot.count == 1)
        #expect(keychain.snapshot.first?.sync == true)
        #expect(store.read("a") == Data("changed".utf8))
    }

    @Test func aMacsFileKeychainItemsAreReadAndMoved() throws {
        let keychain = InMemoryKeychain(mac: true)
        keychain.seed(.init(service: service, account: "a", sync: false, fileKeychain: true, accessible: nil, data: Data("old".utf8)))
        let store = items(keychain, SyncSwitch(true))
        #expect(store.read("a") == Data("old".utf8))
        #expect(store.accounts() == ["a"])
        #expect(store.moveAll(synchronizable: true).moved == 1)
        #expect(keychain.snapshot == [.init(service: service, account: "a", sync: true, fileKeychain: false,
                                            accessible: kSecAttrAccessibleAfterFirstUnlock as String, data: Data("old".utf8))])
        // A write replaces a file keychain copy left behind.
        keychain.seed(.init(service: service, account: "b", sync: false, fileKeychain: true, accessible: nil, data: Data("x".utf8)))
        try store.write(Data("y".utf8), account: "b")
        #expect(!keychain.snapshot.contains { $0.fileKeychain })
        #expect(store.read("b") == Data("y".utf8))
    }

    @Test func aMacWithoutTheEntitlementKeepsUsingItsFileKeychain() throws {
        let keychain = InMemoryKeychain(mac: true)
        keychain.dataProtectionMissing = true
        keychain.seed(.init(service: service, account: "a", sync: false, fileKeychain: true, accessible: nil, data: Data("old".utf8)))
        let store = items(keychain, SyncSwitch(true))
        let result = store.moveAll(synchronizable: true)
        #expect(result.moved == 0 && result.failed == 1)
        #expect(store.read("a") == Data("old".utf8)) // not lost
        try store.write(Data("new".utf8), account: "b")
        #expect(store.read("b") == Data("new".utf8))
        #expect(keychain.snapshot.allSatisfy { $0.fileKeychain })
    }

    @Test func launchMovesItemsOnlyWhenTheSwitchChanged() {
        let keychain = InMemoryKeychain()
        keychain.seed(.init(service: KeychainSync.services[0], account: UUID().uuidString, sync: false, fileKeychain: false,
                            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, data: Data("k".utf8)))
        keychain.seed(.init(service: "cc.coolservices.strata.ssh", account: "credential:pi", sync: false, fileKeychain: false,
                            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, data: Data("{}".utf8)))
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        #expect(KeychainSync.isEnabled(defaults)) // on by default
        #expect(KeychainSync.applyIfNeeded(defaults: defaults, backend: keychain) == 2)
        #expect(keychain.snapshot.allSatisfy { $0.sync })
        #expect(defaults.object(forKey: KeychainSync.appliedKey) as? Bool == true)
        #expect(KeychainSync.applyIfNeeded(defaults: defaults, backend: keychain) == 0)
        defaults.set(false, forKey: KeychainSync.enabledKey)
        #expect(KeychainSync.applyIfNeeded(defaults: defaults, backend: keychain) == 2)
        #expect(keychain.snapshot.filter { !$0.sync }.count == 2)
        #expect(defaults.object(forKey: KeychainSync.appliedKey) as? Bool == false)
    }

    @Test func everySecretServiceIsCovered() {
        let stores: [any KeyStoring] = [
            KeychainKeyStore(), ChatGPTCredentialStore.keychain.tokenStore, ChatGPTCredentialStore.keychain.registrations,
            OpenCodeCredentialStore.keychain.sessions, OpenCodeCredentialStore.keychain.apiKeys,
        ]
        let services = stores.compactMap { ($0 as? KeychainKeyStore)?.service }
        #expect(services.count == stores.count)
        #expect(Set(KeychainSync.services + KeychainSync.deviceOnlyServices)
            .isSuperset(of: services + [KeychainSSHVault().items.service, KeychainSync.headersService]))
        // The rotating sign-ins are device-only; the registration and API keys follow the switch.
        let deviceOnly = stores.compactMap { ($0 as? KeychainKeyStore).map { $0.items.deviceOnly ? $0.service : nil } ?? nil }
        #expect(Set(deviceOnly) == Set(KeychainSync.deviceOnlyServices))
        #expect(Set(KeychainSync.services).isDisjoint(with: KeychainSync.deviceOnlyServices))
    }

    /// ChatGPT tokens and OpenCode sessions spend their refresh token on each refresh: they never sync, whatever the
    /// switch says, and a refresh, a refused refresh or a sign-out here never touches a copy another device still uses.
    @Test func rotatingSignInsStayOnTheDevice() throws {
        let keychain = InMemoryKeychain()
        let service = "cc.coolservices.strata.tests.\(UUID().uuidString)"
        // A session saved before sign-ins stopped syncing, which another device may use too.
        keychain.seed(.init(service: service, account: "a", sync: true, fileKeychain: false,
                            accessible: kSecAttrAccessibleAfterFirstUnlock as String, data: Data("old".utf8)))
        let store = KeychainItems(service: service, backend: keychain, synchronizable: { true }, hasFileKeychain: false, deviceOnly: true)
        // From the audit: taking that copy put one single-use refresh token on every device. This device signs in again.
        #expect(store.read("a") == nil)
        #expect(!keychain.snapshot.contains { !$0.sync })
        try store.write(Data("rotated".utf8), account: "a")
        #expect(keychain.snapshot.first { $0.sync }?.data == Data("old".utf8))
        #expect(keychain.snapshot.first { !$0.sync }?.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(store.accounts() == ["a"])

        try store.write(nil, account: "a") // signed out, or the refresh was refused
        #expect(store.read("a") == nil) // the old iCloud copy isn't taken again
        #expect(keychain.snapshot.contains { $0.sync && $0.account == "a" }) // still there for the other device

        try store.write(Data("new".utf8), account: "b")
        #expect(keychain.snapshot.first { $0.account == "b" }?.sync == false)
    }

    @Test func removingFromICloudDeletesTheOldSyncedSignIns() {
        let keychain = InMemoryKeychain()
        let session = KeychainSync.deviceOnlyServices[1]
        keychain.seed(.init(service: session, account: "s", sync: true, fileKeychain: false,
                            accessible: kSecAttrAccessibleAfterFirstUnlock as String, data: Data("session".utf8)))
        keychain.seed(.init(service: session, account: "s", sync: false, fileKeychain: false,
                            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, data: Data("mine".utf8)))
        let result = KeychainSync.removeFromICloud(backend: keychain, defaults: secretsOff())
        #expect(result.removed == 1 && result.kept == 0)
        #expect(keychain.snapshot.map(\.sync) == [false])
        #expect(keychain.snapshot.first?.data == Data("mine".utf8)) // this device's own sign-in stays
    }

    @Test func removalDoesNothingOnceTheSwitchIsOnAgain() {
        let keychain = InMemoryKeychain()
        keychain.seed(.init(service: KeychainSync.services[0], account: "a", sync: true, fileKeychain: false,
                            accessible: kSecAttrAccessibleAfterFirstUnlock as String, data: Data("key".utf8)))
        let on = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        on.set(true, forKey: KeychainSync.enabledKey)
        let result = KeychainSync.removeFromICloud(backend: keychain, defaults: on)
        #expect(result.removed == 0 && result.kept == 0)
        #expect(keychain.snapshot.map(\.sync) == [true])
    }

    /// From the audit: removal checked this device's copy, then turning sync back on moved that copy to iCloud and
    /// deleted it, and removal deleted the iCloud copy: the secret was gone from both. The two now take turns.
    @Test func turningSyncOnDuringRemovalLosesNothing() async throws {
        let inner = InMemoryKeychain()
        let api = KeychainSync.services[0]
        inner.seed(.init(service: api, account: "a", sync: true, fileKeychain: false,
                         accessible: kSecAttrAccessibleAfterFirstUnlock as String, data: Data("key".utf8)))
        let keychain = GatedKeychain(inner)
        nonisolated(unsafe) let defaults = secretsOff()
        defaults.set(false, forKey: KeychainSync.appliedKey)
        let removal = Task.detached { KeychainSync.removeFromICloud(backend: keychain, defaults: defaults) }
        await Task.detached { keychain.waitForDelete() }.value // removal has its local copy, and is about to delete the iCloud one
        defaults.set(true, forKey: KeychainSync.enabledKey)
        let apply = Task.detached { KeychainSync.applyIfNeeded(defaults: defaults, backend: keychain) }
        try await Task.sleep(for: .milliseconds(100))
        keychain.release.signal()
        _ = await removal.value
        _ = await apply.value
        let left = inner.snapshot.filter { $0.service == api }
        #expect(left.map(\.data) == [Data("key".utf8)])
        #expect(left.first?.sync == true) // moved back to iCloud after the removal
    }

    private func secretsOff() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        defaults.set(false, forKey: KeychainSync.enabledKey)
        return defaults
    }

    @Test func apiKeysAreTrimmedAndBlankDeletes() throws {
        let keychain = InMemoryKeychain()
        let store = KeychainKeyStore(items: items(keychain, SyncSwitch(true)))
        let id = UUID()
        try store.setKey("  sk-123 \n", for: id)
        #expect(store.key(for: id) == "sk-123")
        #expect(keychain.snapshot.first?.account == id.uuidString)
        try store.setKey("   ", for: id)
        #expect(store.key(for: id) == nil)
        #expect(keychain.snapshot.isEmpty)
    }
}
