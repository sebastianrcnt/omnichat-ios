import Foundation
import Observation

/// How far a package is trusted, which decides what it may do without asking (docs/PACKAGES.md 5.5).
enum PackageTrust: String, Codable, Sendable {
    /// Shipped in the app bundle: the OmniChat-known publisher.
    case builtIn
    /// Signed by a company key from MDM or policy (phase 3; nothing installs at this level yet).
    case company
    /// Signed by a key the user accepted at its first install.
    case trustedKey
    /// No signature: made by the user, their assistant, or someone they trust.
    case unsigned

    var title: String {
        switch self {
        case .builtIn: String(localized: "Built in")
        case .company: String(localized: "Managed")
        case .trustedKey: String(localized: "Signed")
        case .unsigned: String(localized: "Not signed")
        }
    }

    /// Unsigned packages can't run a tool that writes without asking first.
    var mayWriteWithoutAsking: Bool { self != .unsigned }

    /// Only company packages are on in new chats unless the user turns them on (the product decision of 2026-10-22).
    var onInNewChatsByDefault: Bool { self == .company }
}

/// The registry's entry for an installed package.
struct PackageRecord: Codable, Sendable, Equatable {
    var id: String
    var version: String
    /// Kept for "Revert", until a later install replaces it.
    var previousVersion: String?
    var trust: PackageTrust
    /// The signature's keys, oldest first; empty when unsigned. An update must be signed by one of them.
    var keys: [String]
    /// The manifest's namespace, or a local alias when another package had it first.
    var namespace: String
    var onInNewChats: Bool
    var installedAt: Date
    /// What the user agreed to, per version.
    var consents: [Consent]

    struct Consent: Codable, Sendable, Equatable {
        var version: String
        var date: Date
        var network: [String]
        var secrets: [String]
        var privateNetwork: Bool
    }
}

/// A package that can be used: its registry entry and its verified files.
struct InstalledPackage: Sendable, Identifiable {
    var record: PackageRecord
    var bundle: PackageBundle

    var id: String { record.id }
    var manifest: PackageManifest { bundle.manifest }
    var name: String { manifest.name }
    var version: String { record.version }
    var namespace: String { record.namespace }
    var trust: PackageTrust { record.trust }
    var isBuiltIn: Bool { record.trust == .builtIn }

    var tools: [PackageTool] { bundle.usableTools }

    func tool(named name: String) -> PackageTool? { tools.first { $0.name == name } }

    /// `<namespace>__<tool>` for each tool, in manifest order.
    var toolNames: [String] { tools.map { PackageRender.toolName(namespace: namespace, tool: $0.name) } }

    var promptSection: String { bundle.promptSection(namespace: namespace) }

    /// The tool definitions as frozen into a chat's snapshot.
    var toolDefinitions: [PackageJSON] { tools.map { PackageRender.toolDefinition(namespace: namespace, tool: $0) } }

    /// The package's skills, named `<namespace>:<name>`.
    var skills: [Skill] {
        bundle.skills.map { Skill(name: "\(namespace):\($0.name)", description: $0.description, body: $0.body, isBuiltIn: true) }
    }

    /// The built-in tool groups it turns on, and the ones it can't share a chat with.
    var requiredGroups: Set<ToolGroup> { Set(manifest.requiredGroups.compactMap(ToolGroup.init(rawValue:))) }
    var exclusiveGroups: Set<ToolGroup> { Set(manifest.exclusiveGroups.compactMap(ToolGroup.init(rawValue:))) }

    var icon: Data? { bundle.files["icon.png"] }

    /// Whether it adds anything to a chat (tools, skills or a prompt): only those have a switch in the "+" menu. A
    /// package of connection presets or commands doesn't.
    var addsToChats: Bool { !tools.isEmpty || !bundle.skills.isEmpty || !(bundle.promptText ?? "").isEmpty }
}

/// The packages on this device: the built-in ones (`Resources/Packages`), then those the user installed
/// (`Application Support/Packages/<id>/<version>/` plus `registry.json`). Thread-safe in the way of `SkillStore`;
/// Settings observes `PackagesVersion`.
final class PackageStore: @unchecked Sendable {
    static let shared = PackageStore()

    private struct Registry: Codable {
        var packages: [PackageRecord] = []
        /// Publisher keys the user accepted (TOFU).
        var trustedKeys: [String] = []
        /// "On in new chats" for built-in packages the user changed.
        var builtInDefaults: [String: Bool] = [:]
    }

    private let lock = NSLock()
    /// Nil keeps everything in memory (tests).
    private let directory: URL?
    private let builtIn: [PackageBundle]
    private let builtInDefault: @Sendable (PackageManifest) -> Bool
    private var registry = Registry()
    private var bundles: [String: PackageBundle] = [:]
    private var loaded = false

    /// - Parameter builtInDefault: whether a built-in package is on in new chats until the user says otherwise.
    init(directory: URL? = PackageStore.defaultDirectory, builtIn: [PackageBundle] = PackageStore.bundled(),
         builtInDefault: @escaping @Sendable (PackageManifest) -> Bool = PackageStore.builtInDefault) {
        self.directory = directory
        self.builtIn = builtIn.sorted { $0.manifest.id < $1.manifest.id }
        self.builtInDefault = builtInDefault
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Packages", isDirectory: true)
    }

    /// The folders in the bundle's `Packages` folder, each one package.
    static func bundled(_ bundle: Bundle = .main) -> [PackageBundle] {
        guard let root = bundle.url(forResource: "Packages", withExtension: nil),
              let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { try? PackageBundle.load(folder: $0) }
    }

    /// Whether a built-in package is on in new chats until the user says otherwise in Settings › Packages: Wikipedia
    /// when its old site plugin is on (`AppSettings.enabledPlugins`), the Korea pack on a device set to Korea (its
    /// skills are about Korean sites). Read when a new chat takes its defaults, so a chat that has sent never changes
    /// with it. Off under unit tests, so a test's requests don't depend on the simulator's region.
    @Sendable static func builtInDefault(_ manifest: PackageManifest) -> Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        return builtInDefault(manifest, region: Locale.current.region?.identifier, enabledPlugins: AppSettings.currentEnabledPlugins)
    }

    static func builtInDefault(_ manifest: PackageManifest, region: String?, enabledPlugins: Set<String>) -> Bool {
        switch manifest.id {
        case BuiltInPackages.wikipedia: enabledPlugins.contains("wikipedia_summary")
        case BuiltInPackages.korea: region == "KR"
        default: false
        }
    }

    // MARK: Loading

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("registry.json")),
              let saved = try? Self.decoder.decode(Registry.self, from: data) else { return }
        registry = saved
        // Built-in defaults saved under a legacy id (before the rename to OmniChat) carry over to the current id.
        for (id, on) in saved.builtInDefaults where BuiltInPackages.canonicalID(id) != id {
            registry.builtInDefaults[id] = nil
            registry.builtInDefaults[BuiltInPackages.canonicalID(id)] = registry.builtInDefaults[BuiltInPackages.canonicalID(id)] ?? on
        }
        for record in saved.packages {
            if let bundle = try? PackageBundle.load(folder: folder(record.id, record.version)) { bundles[record.id] = bundle }
        }
        // A package whose files went missing or no longer verify is dropped from the registry.
        registry.packages.removeAll { bundles[$0.id] == nil }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func folder(_ id: String, _ version: String) -> URL {
        (directory ?? FileManager.default.temporaryDirectory).appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    private func save() {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(registry) { try? data.write(to: directory.appendingPathComponent("registry.json"), options: .atomic) }
    }

    // MARK: Reading

    /// Every package, built-in first, each group by name.
    var all: [InstalledPackage] {
        lock.withLock {
            loadIfNeeded()
            let builtIns = builtIn.map { bundle in
                InstalledPackage(record: PackageRecord(id: bundle.manifest.id, version: bundle.manifest.version, trust: .builtIn, keys: [],
                                                       namespace: bundle.manifest.namespace,
                                                       onInNewChats: registry.builtInDefaults[bundle.manifest.id] ?? builtInDefault(bundle.manifest),
                                                       installedAt: .distantPast, consents: []),
                                 bundle: bundle)
            }
            let installed = registry.packages.compactMap { record in bundles[record.id].map { InstalledPackage(record: record, bundle: $0) } }
            return builtIns.sorted { $0.name < $1.name } + installed.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    func package(id: String) -> InstalledPackage? {
        let id = BuiltInPackages.canonicalID(id)
        return all.first { $0.id == id }
    }

    func package(namespace: String) -> InstalledPackage? { all.first { $0.namespace == namespace } }

    /// The packages a new chat turns on.
    var defaultOn: Set<String> { Set(all.filter { $0.record.onInNewChats && $0.addsToChats }.map(\.id)) }

    /// The site plugins a chat with `packages` on leaves out of its plugin list: the built-in package that replaced
    /// each offers it instead.
    func replacedPlugins(by packages: Set<String>) -> Set<String> {
        Set(BuiltInPackages.replacedPlugins.filter { packages.contains($0.value) && isBuiltIn($0.value) }.keys)
    }

    func isBuiltIn(_ id: String) -> Bool {
        let id = BuiltInPackages.canonicalID(id)
        return builtIn.contains { $0.manifest.id == id }
    }

    func isTrustedKey(_ key: String) -> Bool { lock.withLock { loadIfNeeded(); return registry.trustedKeys.contains(key) } }

    /// Whether another package uses the namespace.
    func namespaceTaken(_ namespace: String, except id: String) -> Bool {
        all.contains { $0.namespace == namespace && $0.id != id }
    }

    /// A free alias for a namespace another package has: `jira2`, `jira3`, …
    func alias(for namespace: String, id: String) -> String {
        guard namespaceTaken(namespace, except: id) else { return namespace }
        var n = 2
        while namespaceTaken("\(namespace.prefix(15 - String(n).count))\(n)", except: id) { n += 1 }
        return "\(namespace.prefix(15 - String(n).count))\(n)"
    }

    // MARK: Changing

    enum Failure: Error, LocalizedError, Equatable {
        case builtIn(String)
        case notInstalled(String)
        case nothingToRevert(String)

        var errorDescription: String? {
            switch self {
            case .builtIn(let id): String(localized: "\(id) is built into OmniChat and can't be replaced or removed.")
            case .notInstalled(let id): String(localized: "\(id) isn't installed.")
            case .nothingToRevert(let id): String(localized: "\(id) has no earlier version to go back to.")
            }
        }
    }

    /// Installs (or updates to) a reviewed package. The version it replaces is kept for "Revert".
    func install(_ bundle: PackageBundle, trust: PackageTrust, onInNewChats: Bool, namespace: String? = nil) throws {
        let m = bundle.manifest
        guard !isBuiltIn(m.id) else { throw Failure.builtIn(m.id) }
        let ns = namespace ?? alias(for: m.namespace, id: m.id)
        try lock.withLock {
            loadIfNeeded()
            if directory != nil {
                let target = folder(m.id, m.version)
                try? FileManager.default.removeItem(at: target)
                try bundle.write(to: target)
            }
            let old = registry.packages.first { $0.id == m.id }
            if let old, old.version != m.version, let older = old.previousVersion, older != m.version, directory != nil {
                try? FileManager.default.removeItem(at: folder(m.id, older))
            }
            let consent = PackageRecord.Consent(version: m.version, date: .now, network: m.network, secrets: m.secrets.map(\.name),
                                                privateNetwork: m.privateNetwork)
            var record = PackageRecord(id: m.id, version: m.version,
                                       previousVersion: old.flatMap { $0.version == m.version ? $0.previousVersion : $0.version },
                                       trust: trust, keys: bundle.verification.keys.map(\.string), namespace: old?.namespace ?? ns,
                                       onInNewChats: old?.onInNewChats ?? onInNewChats, installedAt: .now,
                                       consents: Array(((old?.consents ?? []) + [consent]).suffix(10)))
            if old == nil { record.onInNewChats = onInNewChats }
            registry.packages.removeAll { $0.id == m.id }
            registry.packages.append(record)
            bundles[m.id] = bundle
            if trust == .trustedKey, let key = bundle.verification.signingKey?.string, !registry.trustedKeys.contains(key) {
                registry.trustedKeys.append(key)
            }
            save()
        }
        PackagesVersion.bump()
    }

    /// Goes back to the version an update replaced.
    func revert(id: String) throws {
        try lock.withLock {
            loadIfNeeded()
            guard let i = registry.packages.firstIndex(where: { $0.id == id }) else { throw Failure.notInstalled(id) }
            guard let previous = registry.packages[i].previousVersion,
                  let bundle = try? PackageBundle.load(folder: folder(id, previous)) else { throw Failure.nothingToRevert(id) }
            let current = registry.packages[i].version
            registry.packages[i].version = previous
            registry.packages[i].previousVersion = current
            registry.packages[i].keys = bundle.verification.keys.map(\.string)
            bundles[id] = bundle
            save()
        }
        PackagesVersion.bump()
    }

    /// Removes the files and the registry entry. Secrets and approvals are the caller's (`PackageInstaller.remove`).
    func remove(id: String) throws {
        guard !isBuiltIn(id) else { throw Failure.builtIn(id) }
        lock.withLock {
            loadIfNeeded()
            registry.packages.removeAll { $0.id == id }
            bundles[id] = nil
            if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true)) }
            save()
        }
        PackagesVersion.bump()
    }

    func setOnInNewChats(_ on: Bool, id: String) {
        let id = BuiltInPackages.canonicalID(id)
        lock.withLock {
            loadIfNeeded()
            if builtIn.contains(where: { $0.manifest.id == id }) {
                registry.builtInDefaults[id] = on
            } else if let i = registry.packages.firstIndex(where: { $0.id == id }) {
                registry.packages[i].onInNewChats = on
            }
            save()
        }
        PackagesVersion.bump()
    }
}

/// Changes when a package is installed, changed or removed, so Settings and the composer redraw.
@MainActor
@Observable
final class PackagesVersion {
    static let shared = PackagesVersion()
    private(set) var value = 0

    nonisolated static func bump() { Task { @MainActor in shared.value += 1 } }
    func bump() { value += 1 }
}

/// The ids of the packages that ship in the app.
enum BuiltInPackages {
    static let wikipedia = "app.omnichat.wikipedia"
    static let korea = "app.omnichat.korea"
    static let connections = "app.omnichat.connections"

    /// The ids they had before the rename to OmniChat. Chats (their switches and snapshots, synced through iCloud) and
    /// the registry may still hold them, so every id read back goes through `canonicalID`.
    static let legacyIDs = [
        "app.openchat.wikipedia": wikipedia,
        "app.openchat.korea": korea,
        "app.openchat.connections": connections,
    ]

    /// The current id of a package: a legacy built-in id maps to its new one, any other id is returned unchanged.
    static func canonicalID(_ id: String) -> String { legacyIDs[id] ?? id }

    /// Site plugins a built-in package took over: new chats list the package instead (chats that froze the plugin
    /// list keep it, and `run_plugin` still runs it).
    static let replacedPlugins = ["wikipedia_summary": wikipedia]
}
