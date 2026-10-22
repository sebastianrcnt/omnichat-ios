import Foundation

/// Package secrets (API tokens a package declares) and the tools the user allowed "Always", in the Keychain: service
/// `cc.coolservices.strata.package`, account `<id>/<secret>` for a secret and `always:<id>/<tool>` for an approval.
/// Values are only read where a request is built (`HTTPToolRunner`); the model, the feed and the logs never see them,
/// and every result is scrubbed of them (`scrub`).
final class PackageSecretStore: @unchecked Sendable {
    static let shared = PackageSecretStore()

    private let vault: any SSHVault

    init(vault: any SSHVault = KeychainSSHVault(items: KeychainItems(service: "cc.coolservices.strata.package"))) {
        self.vault = vault
    }

    private static func account(_ packageID: String, _ name: String) -> String { "\(packageID)/\(name)" }

    func value(_ name: String, package packageID: String) -> String? {
        vault.read(Self.account(packageID, name)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func hasValue(_ name: String, package packageID: String) -> Bool { value(name, package: packageID)?.isEmpty == false }

    /// Saves a value (trimmed); nil or empty clears it.
    func setValue(_ value: String?, name: String, package packageID: String) throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try vault.write(trimmed.isEmpty ? nil : Data(trimmed.utf8), account: Self.account(packageID, name))
        if !trimmed.isEmpty { DebugRedaction.registerExact([trimmed]) }
        Task { @MainActor in PackagesVersion.shared.bump() }
    }

    /// Every secret value of a package that is set (for scrubbing).
    func values(package packageID: String) -> [String] {
        vault.accounts().filter { $0.hasPrefix(packageID + "/") }.compactMap { vault.read($0) }
            .compactMap { String(data: $0, encoding: .utf8) }.filter { !$0.isEmpty }
    }

    // MARK: "Always" approvals

    private static func approvalAccount(_ packageID: String, _ tool: String) -> String { "always:\(packageID)/\(tool)" }

    func isAlwaysAllowed(package packageID: String, tool: String) -> Bool {
        vault.read(Self.approvalAccount(packageID, tool)) != nil
    }

    func setAlwaysAllowed(_ allowed: Bool, package packageID: String, tool: String) throws {
        try vault.write(allowed ? Data("1".utf8) : nil, account: Self.approvalAccount(packageID, tool))
        Task { @MainActor in PackagesVersion.shared.bump() }
    }

    /// The tools of a package allowed "Always".
    func alwaysAllowedTools(package packageID: String) -> [String] {
        let prefix = "always:\(packageID)/"
        return vault.accounts().filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
    }

    /// Uninstall: every secret and approval of the package goes.
    func removeAll(package packageID: String) {
        for account in vault.accounts() where account.hasPrefix(packageID + "/") || account.hasPrefix("always:\(packageID)/") {
            try? vault.write(nil, account: account)
        }
        Task { @MainActor in PackagesVersion.shared.bump() }
    }

    /// Feeds every stored secret to the debug redaction at launch, so a debug bundle can't carry one.
    func registerForRedaction() {
        DebugRedaction.registerExact(vault.accounts().filter { !$0.hasPrefix("always:") }.compactMap { vault.read($0) }
            .compactMap { String(data: $0, encoding: .utf8) })
    }

    /// Replaces every occurrence of a secret value, and its base64, base64url and percent-encoded forms, with
    /// `[secret]`: some APIs echo the token back.
    static func scrub(_ text: String, secrets: [String]) -> String {
        var out = text
        for secret in secrets where secret.count >= 4 {
            for form in forms(of: secret) where !form.isEmpty { out = out.replacingOccurrences(of: form, with: "[secret]") }
        }
        return out
    }

    static func forms(of secret: String) -> [String] {
        let data = Data(secret.utf8)
        let b64 = data.base64EncodedString()
        let trimmed = b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let url = trimmed.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let percent = secret.addingPercentEncoding(withAllowedCharacters: URLTemplate.unreserved) ?? secret
        // Longest first, so a form that contains another is replaced whole.
        return Array(Set([secret, b64, trimmed, url, percent])).sorted { $0.count > $1.count }
    }
}
