import Testing
import Foundation
import Security
@testable import Strata

/// A header store that refuses every write (a Keychain that can't be written).
private final class ReadOnlyKeyStore: KeyStoring, @unchecked Sendable {
    func key(for connectionID: UUID) -> String? { nil }
    func setKey(_ key: String?, for connectionID: UUID) throws { throw KeychainError(status: errSecNotAvailable) }
}

/// Custom headers may hold credentials: they live in the header store (the Keychain), not in the UserDefaults list.
@MainActor
struct ConnectionHeadersTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")! }

    private func listed(_ defaults: UserDefaults) -> String {
        String(decoding: defaults.data(forKey: "connections.v1") ?? Data(), as: UTF8.self)
    }

    @Test func headersGoToTheHeaderStoreNotTheList() throws {
        let d = defaults(), headers = InMemoryKeyStore()
        let store = ConnectionStore(defaults: d, keys: InMemoryKeyStore(), headers: headers)
        var c = Connection(name: "Org", baseURL: "https://org.example/v1", customHeaders: "Authorization: Bearer secret")
        store.upsert(c)
        #expect(headers.key(for: c.id) == "Authorization: Bearer secret")
        #expect(!listed(d).contains("secret"))
        #expect(store.endpoint(connectionID: c.id, modelID: "m")?.headers["Authorization"] == "Bearer secret")
        // Read back at launch.
        let reloaded = ConnectionStore(defaults: d, keys: InMemoryKeyStore(), headers: headers)
        #expect(reloaded.connection(c.id)?.customHeaders == "Authorization: Bearer secret")
        // Cleared, then deleted.
        c.customHeaders = ""
        reloaded.upsert(c)
        #expect(headers.key(for: c.id) == nil)
        c.customHeaders = "X-Org: acme"
        reloaded.upsert(c)
        reloaded.delete(c.id)
        #expect(headers.key(for: c.id) == nil)
    }

    @Test func headersSavedInTheListMoveToTheHeaderStore() throws {
        let d = defaults(), headers = InMemoryKeyStore()
        let c = Connection(name: "Org", baseURL: "https://org.example/v1", customHeaders: "Authorization: Bearer old-version")
        d.set(try JSONEncoder().encode([c]), forKey: "connections.v1") // as an older version saved it
        let store = ConnectionStore(defaults: d, keys: InMemoryKeyStore(), headers: headers)
        #expect(store.connection(c.id)?.customHeaders == "Authorization: Bearer old-version")
        #expect(headers.key(for: c.id) == "Authorization: Bearer old-version")
        #expect(!listed(d).contains("old-version"))
    }

    @Test func headersStayInTheListWhenTheHeaderStoreCantTakeThem() throws {
        let d = defaults()
        let c = Connection(name: "Org", baseURL: "https://org.example/v1", customHeaders: "Authorization: Bearer kept")
        d.set(try JSONEncoder().encode([c]), forKey: "connections.v1")
        let store = ConnectionStore(defaults: d, keys: InMemoryKeyStore(), headers: ReadOnlyKeyStore())
        #expect(store.connection(c.id)?.customHeaders == "Authorization: Bearer kept")
        store.upsert(Connection(name: "Other", baseURL: "https://other.example/v1", customHeaders: "X-New: also-kept"))
        #expect(listed(d).contains("kept") && listed(d).contains("also-kept"))
        let reloaded = ConnectionStore(defaults: d, keys: InMemoryKeyStore(), headers: ReadOnlyKeyStore())
        #expect(reloaded.connection(c.id)?.customHeaders == "Authorization: Bearer kept")
    }

    /// The header store already holds other headers for the connection (another device's, through iCloud Keychain):
    /// this device keeps its own, and neither copy is overwritten.
    @Test func differingHeadersAreNeitherOverwrittenNorLost() throws {
        let d = defaults(), headers = InMemoryKeyStore()
        let c = Connection(name: "Org", baseURL: "https://org.example/v1", customHeaders: "Authorization: Bearer here")
        d.set(try JSONEncoder().encode([c]), forKey: "connections.v1")
        try headers.setKey("Authorization: Bearer there", for: c.id)
        let store = ConnectionStore(defaults: d, keys: InMemoryKeyStore(), headers: headers)
        store.upsert(Connection(name: "Other", baseURL: "https://other.example/v1"))
        #expect(store.connection(c.id)?.customHeaders == "Authorization: Bearer here")
        #expect(headers.key(for: c.id) == "Authorization: Bearer there")
        #expect(listed(d).contains("Bearer here"))
    }
}
