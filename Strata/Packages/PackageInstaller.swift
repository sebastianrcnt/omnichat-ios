import Foundation

/// A package read from a file or a link, waiting in the review sheet: nothing is written before the user taps Install.
struct PackageCandidate: Identifiable, Sendable {
    enum Source: Sendable, Equatable {
        case file(String)
        case link(URL)
    }

    enum Change: Sendable, Equatable {
        case new
        case update(from: String)
        case reinstall
        case downgrade(from: String)
    }

    var bundle: PackageBundle
    var source: Source
    /// The trust it gets if installed.
    var trust: PackageTrust
    var change: Change
    /// The namespace it would use: its own, or a local alias when another package has it.
    var namespace: String
    /// The first install of its signing key: the sheet asks "Trust this publisher's key?".
    var asksToTrustKey: Bool
    /// Hosts, secrets and private network access the installed version didn't have (empty for a new install).
    var newHosts: [String]
    var newSecrets: [String]
    var newPrivateNetwork: Bool
    /// Files added, changed or removed against the installed version.
    var changedFiles: [String]
    /// Why it can't be installed, if it can't.
    var blocker: String?

    var id: String { bundle.manifest.id }
    var manifest: PackageManifest { bundle.manifest }
    var widensPermissions: Bool { !newHosts.isEmpty || !newSecrets.isEmpty || newPrivateNetwork }
    /// "On in new chats" starts on only for company trust (decision of 2026-10-22).
    var onInNewChatsByDefault: Bool { trust.onInNewChatsByDefault }
}

/// Reads packages for review and installs the ones the user accepts (docs/PACKAGES.md 5.1–5.4): the same-key rule for
/// updates, page tools only from built-in packages, aliases for a namespace already taken. Downloads for links are
/// capped at 5 MB, checked against the link's sha256, and come from an ephemeral session.
struct PackageInstaller: Sendable {
    var store: PackageStore = .shared
    var secrets: PackageSecretStore = .shared
    var configuration: @Sendable () -> URLSessionConfiguration = { HTTPToolRunner.ephemeral() }
    var resolver: any HostResolving = SystemHostResolver()

    static let downloadLimit = 5 * 1_048_576

    enum Failure: Error, LocalizedError, Equatable {
        case download(String)
        case digestMismatch

        var errorDescription: String? {
            switch self {
            case .download(let reason): String(localized: "Couldn't download the package: \(reason)")
            case .digestMismatch: String(localized: "The downloaded package isn't the one the link names (its SHA-256 differs).")
            }
        }
    }

    /// A zip (`.ocpkg`) or a folder.
    func candidate(file url: URL) throws -> PackageCandidate {
        var isFolder: ObjCBool = false
        let bundle: PackageBundle
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            bundle = try PackageBundle.load(folder: url)
        } else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= PackageArchive.Limits().zipped else { throw PackageError.archive("the package is larger than 5 MB.") }
            bundle = try PackageBundle.load(zip: try Data(contentsOf: url))
        }
        return candidate(bundle, source: .file(url.lastPathComponent))
    }

    /// Downloads a link's package (`openchat://add-package?url=…&sha256=…`).
    func candidate(link: AddPackageLink) async throws -> PackageCandidate {
        do { try await URLGuard.validate(link.url, resolver: resolver) } catch {
            throw Failure.download((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        var request = URLRequest(url: link.url, timeoutInterval: 60)
        request.setValue("OpenChat", forHTTPHeaderField: "User-Agent")
        let resolver = resolver
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await LimitedDownload.data(for: request, configuration: configuration(), limit: Self.downloadLimit) { url in
                guard url.scheme?.lowercased() == "https" else { return false }
                return (try? await URLGuard.validate(url, resolver: resolver)) != nil
            }
        } catch {
            throw Failure.download((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.download("HTTP \(http.statusCode).")
        }
        if let expected = link.sha256, PackageChecksums.sha256Hex(data) != expected.lowercased() { throw Failure.digestMismatch }
        return candidate(try PackageBundle.load(zip: data), source: .link(link.url))
    }

    /// The review of a loaded package against what is installed.
    func candidate(_ bundle: PackageBundle, source: PackageCandidate.Source) -> PackageCandidate {
        let m = bundle.manifest
        let installed = store.package(id: m.id)
        let signingKey = bundle.verification.signingKey?.string
        let trust: PackageTrust = signingKey == nil ? .unsigned : .trustedKey
        var candidate = PackageCandidate(bundle: bundle, source: source, trust: trust, change: .new,
                                         namespace: installed?.namespace ?? store.alias(for: m.namespace, id: m.id),
                                         asksToTrustKey: signingKey.map { !store.isTrustedKey($0) } ?? false,
                                         newHosts: m.network, newSecrets: m.secrets.map(\.name), newPrivateNetwork: m.privateNetwork,
                                         changedFiles: [], blocker: nil)
        if store.isBuiltIn(m.id) {
            candidate.blocker = String(localized: "\(m.id) is built into OpenChat and can't be replaced.")
            return candidate
        }
        if let page = m.tools.first(where: { $0.kind == "page" }) {
            candidate.blocker = String(localized: "\(page.name) is a page tool, which only packages built into OpenChat may have for now.")
            return candidate
        }
        guard let installed else { return candidate }

        let old = installed.manifest
        candidate.newHosts = m.network.filter { !old.network.contains($0) }
        candidate.newSecrets = m.secrets.map(\.name).filter { old.secret(named: $0) == nil }
        candidate.newPrivateNetwork = m.privateNetwork && !old.privateNetwork
        candidate.changedFiles = Set(bundle.files.keys).union(installed.bundle.files.keys).sorted()
            .filter { bundle.files[$0] != installed.bundle.files[$0] }
        if let new = SemVer(m.version), let current = SemVer(installed.version) {
            candidate.change = new > current ? .update(from: installed.version) : new == current ? .reinstall : .downgrade(from: installed.version)
        }
        // Same-key rule: a signed package only updates to a version signed by one of its keys (directly or through the
        // signature's rotation chain).
        if !installed.record.keys.isEmpty {
            let keys = Set(bundle.verification.keys.map(\.string))
            if keys.isEmpty {
                candidate.blocker = String(localized: "The installed \(installed.name) is signed, and this version isn't. Only its publisher can update it.")
            } else if keys.isDisjoint(with: installed.record.keys) {
                candidate.blocker = String(localized: "This version of \(installed.name) is signed by a different key than the installed one. Remove the installed package first if you trust the new publisher.")
            } else {
                candidate.asksToTrustKey = false
            }
        }
        return candidate
    }

    /// Installs a reviewed candidate. `trustKey` is the answer to "Trust this publisher's key?" (signed packages
    /// install as unsigned without it).
    func install(_ candidate: PackageCandidate, onInNewChats: Bool, trustKey: Bool = true) throws {
        if let blocker = candidate.blocker { throw PackageError.invalid(blocker) }
        let trust: PackageTrust = candidate.trust == .trustedKey && (trustKey || !candidate.asksToTrustKey) ? .trustedKey : .unsigned
        try store.install(candidate.bundle, trust: trust, onInNewChats: onInNewChats, namespace: candidate.namespace)
    }

    /// Uninstall: the files, secrets and approvals go; chats that offered it refuse its calls; the audit log stays.
    func remove(id: String) throws {
        try store.remove(id: id)
        secrets.removeAll(package: id)
    }
}

/// `openchat://add-package?url=<https URL>&sha256=<hex>`: a package to download and review.
struct AddPackageLink: Equatable, Sendable {
    var url: URL
    var sha256: String?

    static let host = "add-package"

    init(url: URL, sha256: String? = nil) {
        self.url = url
        self.sha256 = sha256
    }

    /// Nil unless the link is ours and its url is https without user info, at most 2 KB.
    init?(_ link: URL) {
        guard link.scheme?.lowercased() == "openchat", link.host()?.lowercased() == Self.host,
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "url" })?.value, raw.utf8.count <= 2048,
              let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host() != nil, url.user == nil, url.password == nil
        else { return nil }
        let digest = items.first(where: { $0.name == "sha256" })?.value?.lowercased()
        if let digest, digest.count != 64 || !digest.allSatisfy(\.isHexDigit) { return nil }
        self.init(url: url, sha256: digest)
    }

    var link: URL {
        var c = URLComponents()
        c.scheme = "openchat"
        c.host = Self.host
        c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)] + (sha256.map { [URLQueryItem(name: "sha256", value: $0)] } ?? [])
        return c.url!
    }
}
