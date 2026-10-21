import Foundation
import Observation
import Security

// SSH credentials, servers, known hosts and "always allow" approvals, in the Keychain (like API keys, `KeyStore`), with
// an in-memory vault for tests. Credentials hold secrets; the rest is kept next to them so it all goes together.

/// A secret the model or the user saved by name.
struct SSHCredential: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case password
        case privateKey = "private_key"
        case keyboardInteractive = "keyboard_interactive"

        var title: String {
            switch self {
            case .password: String(localized: "Password")
            case .privateKey: String(localized: "Private key")
            case .keyboardInteractive: String(localized: "Keyboard-interactive answers")
            }
        }
    }

    var id: String { name }
    var name: String
    var kind: Kind
    /// The user name it is for, when it is for one.
    var username: String?
    var password: String?
    var privateKey: String?
    var passphrase: String?
    /// An OpenSSH certificate (`…-cert-v01@openssh.com` line) presented with the private key.
    var certificate: String?
    /// Keyboard-interactive answers, in the order the server asks.
    var answers: [String]?
    /// The key's `authorized_keys` line, when known.
    var publicKey: String?
    var note: String?
    var created = Date()

    /// The authentication methods this credential offers, tried in order.
    var auths: [SSHAuth] {
        switch kind {
        case .password: password.map { [.password($0)] } ?? []
        case .privateKey:
            (privateKey.map { [.privateKey($0, passphrase: passphrase, certificate: certificate)] } ?? [])
                + (password.map { [.password($0)] } ?? [])
        case .keyboardInteractive: [.keyboardInteractive(answers ?? [])] + (password.map { [.password($0)] } ?? [])
        }
    }

    /// What a listing says about it, without secrets.
    var summary: String {
        switch kind {
        case .password: String(localized: "Password")
        case .privateKey: privateKey.flatMap(SSHKeyFormat.inspect)?.summary ?? String(localized: "Private key")
        case .keyboardInteractive: String(localized: "\(answers?.count ?? 0) answers")
        }
    }
}

/// A server saved by name.
struct SSHServer: Codable, Sendable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var host: String
    var port: Int = 22
    var user: String
    /// The saved credential it signs in with.
    var credential: String?
    /// Jump hosts, first to last: saved server names, or `user@host[:port]` (signing in with this server's credential).
    var jump: [String] = []
    var note: String?

    var address: String { port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }
}

/// Storage for the store's records: one item per name.
protocol SSHVault: Sendable {
    func read(_ account: String) -> Data?
    func write(_ data: Data?, account: String) throws
    func accounts() -> [String]
}

struct KeychainSSHVault: SSHVault {
    var service = "cc.coolservices.strata.ssh"

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func write(_ data: Data?, account: String) throws {
        guard let data else {
            let status = SecItemDelete(base(account) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError(status: status) }
            return
        }
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            if added != errSecSuccess { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func accounts() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// For tests and previews.
final class InMemorySSHVault: SSHVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func read(_ account: String) -> Data? { lock.withLock { items[account] } }
    func write(_ data: Data?, account: String) throws { lock.withLock { items[account] = data } }
    func accounts() -> [String] { lock.withLock { Array(items.keys) } }
}

/// Bumped on every change, so settings and approval views redraw.
@MainActor
@Observable
final class SSHStoreVersion {
    static let shared = SSHStoreVersion()
    private(set) var value = 0
    func bump() { value += 1 }
}

enum SSHStoreError: Error, LocalizedError, Equatable {
    case invalidName(String)
    case missing(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name): "\"\(name)\" can't be a name: use letters, digits, dots, dashes and underscores (at most 64)."
        case .missing(let what): what
        case .invalid(let what): what
        }
    }
}

/// Credentials, servers, known hosts and approvals. Thread-safe; reads go to the vault each time (the Keychain caches).
final class SSHStore: Sendable {
    static let shared = SSHStore(vault: KeychainSSHVault())

    let vault: any SSHVault

    init(vault: any SSHVault) { self.vault = vault }

    private static let credentialPrefix = "credential:"
    private static let serverPrefix = "server:"
    private static let hostPrefix = "knownhost:"
    private static let approvalPrefix = "approval:"

    static func validate(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-@"))
        guard !trimmed.isEmpty, trimmed.count <= 64, trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SSHStoreError.invalidName(trimmed)
        }
        return trimmed
    }

    private func decode<T: Decodable>(_ type: T.Type, _ account: String) -> T? {
        vault.read(account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T?, _ account: String) throws {
        try vault.write(value.map { try JSONEncoder().encode($0) }, account: account)
        Task { @MainActor in SSHStoreVersion.shared.bump() }
    }

    private func names(_ prefix: String) -> [String] {
        vault.accounts().filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Credentials

    var credentials: [SSHCredential] { names(Self.credentialPrefix).compactMap(credential(named:)) }

    func credential(named name: String) -> SSHCredential? {
        decode(SSHCredential.self, Self.credentialPrefix + name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func save(_ credential: SSHCredential) throws {
        var c = credential
        c.name = try Self.validate(c.name)
        if c.kind == .privateKey {
            guard let key = c.privateKey, let info = SSHKeyFormat.inspect(key) else {
                throw SSHStoreError.invalid("The private key isn't one OpenChat can read: paste the whole key, from -----BEGIN to -----END.")
            }
            if info.format == .putty {
                throw SSHStoreError.invalid("PuTTY keys aren't supported. Convert it first, for example with puttygen key.ppk -O private-openssh -o key.")
            }
            c.privateKey = key.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            if c.publicKey == nil { c.publicKey = info.publicKey }
        }
        if c.kind == .password, (c.password ?? "").isEmpty { throw SSHStoreError.invalid("A password credential needs the password.") }
        try encode(c, Self.credentialPrefix + c.name)
    }

    func deleteCredential(_ name: String) throws {
        try encode(Optional<SSHCredential>.none, Self.credentialPrefix + name)
    }

    // MARK: Servers

    var servers: [SSHServer] { names(Self.serverPrefix).compactMap(server(named:)) }

    func server(named name: String) -> SSHServer? {
        decode(SSHServer.self, Self.serverPrefix + name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func save(_ server: SSHServer) throws {
        var s = server
        s.name = try Self.validate(s.name)
        s.host = s.host.trimmingCharacters(in: .whitespacesAndNewlines)
        s.user = s.user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.host.isEmpty else { throw SSHStoreError.invalid("A server needs a host.") }
        guard !s.user.isEmpty else { throw SSHStoreError.invalid("A server needs a user name.") }
        guard (1...65535).contains(s.port) else { throw SSHStoreError.invalid("The port must be between 1 and 65535.") }
        s.jump = s.jump.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !s.jump.contains(s.name) else { throw SSHStoreError.invalid("A server can't be its own jump host.") }
        try encode(s, Self.serverPrefix + s.name)
    }

    func deleteServer(_ name: String) throws {
        try encode(Optional<SSHServer>.none, Self.serverPrefix + name)
        try? setAlwaysAllowed(false, target: name)
    }

    // MARK: Known hosts

    struct KnownHost: Codable, Sendable, Equatable, Identifiable {
        var id: String { hostPort }
        var hostPort: String
        var type: String
        var fingerprint: String
        var added = Date()
    }

    var knownHosts: [KnownHost] { names(Self.hostPrefix).compactMap { decode(KnownHost.self, Self.hostPrefix + $0) } }

    func knownHost(_ hostPort: String) -> KnownHost? { decode(KnownHost.self, Self.hostPrefix + hostPort) }

    /// Trust on first use: a new host is saved; a known one must present the same key.
    func check(_ key: SSHHostKey) throws {
        if let known = knownHost(key.hostPort) {
            guard known.fingerprint == key.fingerprint else {
                throw SSHError.hostKeyChanged(hostPort: key.hostPort, type: key.type, expected: known.fingerprint, actual: key.fingerprint)
            }
            return
        }
        try encode(KnownHost(hostPort: key.hostPort, type: key.type, fingerprint: key.fingerprint), Self.hostPrefix + key.hostPort)
    }

    func forgetHost(_ hostPort: String) throws { try encode(Optional<KnownHost>.none, Self.hostPrefix + hostPort) }

    // MARK: Approvals

    /// Targets ("always for this server") whose commands run without asking: a server's name, or `user@host:port`.
    var alwaysAllowed: [String] { names(Self.approvalPrefix) }

    func isAlwaysAllowed(_ target: String) -> Bool { vault.read(Self.approvalPrefix + target) != nil }

    func setAlwaysAllowed(_ allowed: Bool, target: String) throws {
        try vault.write(allowed ? Data("1".utf8) : nil, account: Self.approvalPrefix + target)
        Task { @MainActor in SSHStoreVersion.shared.bump() }
    }
}
