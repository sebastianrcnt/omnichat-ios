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

struct KeychainKeyStore: KeyStoring {
    let service: String

    init(service: String = "cc.coolservices.strata.apikey") {
        self.service = service
    }

    private func baseQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    func key(for connectionID: UUID) -> String? {
        var query = baseQuery(connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setKey(_ key: String?, for connectionID: UUID) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            let status = SecItemDelete(baseQuery(connectionID) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError(status: status) }
            return
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(baseQuery(connectionID) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(connectionID)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
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
