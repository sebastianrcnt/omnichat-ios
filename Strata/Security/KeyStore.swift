import Foundation
import Security

/// Per-connection API key storage. Keys are never logged.
protocol KeyStoring: Sendable {
    func key(for connectionID: UUID) -> String?
    func setKey(_ key: String?, for connectionID: UUID) throws
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        String(localized: "Keychain error \(Int(status))")
    }
}

/// API keys and other per-connection secrets, one item per connection id (`KeychainItems`: synced with iCloud Keychain
/// while the switch is on).
struct KeychainKeyStore: KeyStoring {
    let items: KeychainItems

    var service: String { items.service }

    init(service: String = "cc.coolservices.strata.apikey") {
        items = KeychainItems(service: service)
    }

    init(items: KeychainItems) {
        self.items = items
    }

    func key(for connectionID: UUID) -> String? {
        items.read(connectionID.uuidString).flatMap { String(data: $0, encoding: .utf8) }
    }

    func setKey(_ key: String?, for connectionID: UUID) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        try items.write(trimmed.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, account: connectionID.uuidString)
    }
}

/// In-memory store for tests and previews.
final class InMemoryKeyStore: KeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: String] = [:]

    func key(for connectionID: UUID) -> String? {
        lock.withLock { storage[connectionID] }
    }

    func setKey(_ key: String?, for connectionID: UUID) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            if let trimmed, !trimmed.isEmpty { storage[connectionID] = trimmed } else { storage[connectionID] = nil }
        }
    }
}
