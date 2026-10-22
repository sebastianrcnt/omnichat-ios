import Testing
import Foundation
@testable import Strata

/// Installing, updating, reverting and removing packages, and the built-in ones (docs/PACKAGES.md 5).
struct PackageInstallTests {
    private func store(builtIn: [PackageBundle] = []) -> PackageStore {
        PackageStore(directory: nil, builtIn: builtIn, builtInDefault: { _ in false })
    }

    private func installer(_ store: PackageStore) -> PackageInstaller {
        PackageInstaller(store: store, secrets: PackageSecretStore(vault: InMemorySSHVault()))
    }

    private let network = ["permissions": ["network": ["api.example.com"]]] as [String: Any]

    @Test func newPackagesStartOffAndKeepTheirNamespace() throws {
        let s = store()
        let i = installer(s)
        let c = i.candidate(try TestPackages.bundle(TestPackages.manifest(extra: network)), source: .file("demo.ocpkg"))
        #expect(c.change == .new && c.trust == .unsigned && c.blocker == nil)
        #expect(!c.onInNewChatsByDefault, "only company packages are on in new chats by default")
        try i.install(c, onInNewChats: c.onInNewChatsByDefault)
        let p = try #require(s.package(id: "com.example.demo"))
        #expect(p.namespace == "demo" && !p.record.onInNewChats && p.trust == .unsigned)
        #expect(s.defaultOn.isEmpty)
    }

    @Test func aTakenNamespaceGetsAnAlias() throws {
        let s = store()
        try s.install(try TestPackages.bundle(TestPackages.manifest()), trust: .unsigned, onInNewChats: false)
        let other = installer(s).candidate(try TestPackages.bundle(TestPackages.manifest(id: "com.other.demo")), source: .file("x"))
        #expect(other.namespace == "demo2")
    }

    @Test func updatesShowWiderPermissionsAndKeepTheOldVersionForRevert() throws {
        let s = store()
        let i = installer(s)
        try i.install(i.candidate(try TestPackages.bundle(TestPackages.manifest(extra: network)), source: .file("a")), onInNewChats: true)
        let wider = TestPackages.manifest(version: "1.1.0", extra: ["permissions": ["network": ["api.example.com", "files.example.com"],
                                                                                     "secrets": [["name": "token", "label": "Token", "inject": "bearer"]]]])
        let c = i.candidate(try TestPackages.bundle(wider), source: .file("b"))
        #expect(c.change == .update(from: "1.0.0"))
        #expect(c.newHosts == ["files.example.com"] && c.newSecrets == ["token"] && c.widensPermissions)
        #expect(c.changedFiles == ["manifest.json"])
        #expect(c.onInNewChatsByDefault, "the update sheet starts from the installed setting")
        try i.install(c, onInNewChats: c.onInNewChatsByDefault)
        let p = try #require(s.package(id: "com.example.demo"))
        #expect(p.version == "1.1.0" && p.record.previousVersion == "1.0.0")
        #expect(p.record.onInNewChats, "an update keeps the user's choice")
        #expect(p.record.consents.map(\.version) == ["1.0.0", "1.1.0"])
        // Memory-only stores can't reload the old files; the folder store test covers revert.
    }

    @Test func revertAndRemoveOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pkgs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = PackageStore(directory: dir, builtIn: [], builtInDefault: { _ in false })
        let secrets = PackageSecretStore(vault: InMemorySSHVault())
        let i = PackageInstaller(store: s, secrets: secrets)
        try i.install(i.candidate(try TestPackages.bundle(TestPackages.manifest()), source: .file("a")), onInNewChats: false)
        try i.install(i.candidate(try TestPackages.bundle(TestPackages.manifest(version: "2.0.0")), source: .file("b")), onInNewChats: false)
        try secrets.setValue("tok-123456", name: "token", package: "com.example.demo")
        // A fresh store reads the registry and the files back.
        let reopened = PackageStore(directory: dir, builtIn: [], builtInDefault: { _ in false })
        #expect(reopened.package(id: "com.example.demo")?.version == "2.0.0")
        try reopened.revert(id: "com.example.demo")
        #expect(reopened.package(id: "com.example.demo")?.version == "1.0.0")
        try PackageInstaller(store: reopened, secrets: secrets).remove(id: "com.example.demo")
        #expect(reopened.package(id: "com.example.demo") == nil)
        #expect(secrets.value("token", package: "com.example.demo") == nil, "uninstall deletes its secrets")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("com.example.demo").path))
    }

    /// A reinstall that can't be written, or a registry that can't be saved, leaves the working installation.
    @Test func aFailedInstallKeepsTheInstalledVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pkgs-\(UUID().uuidString)")
        let packageDir = dir.appendingPathComponent("com.example.demo")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packageDir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let s = PackageStore(directory: dir, builtIn: [], builtInDefault: { _ in false })
        let i = installer(s)
        try i.install(i.candidate(try TestPackages.bundle(TestPackages.manifest()), source: .file("a")), onInNewChats: false)
        try i.install(i.candidate(try TestPackages.bundle(TestPackages.manifest()), source: .file("a")), onInNewChats: false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: packageDir.path) == ["1.0.0"], "no staging left behind")

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: packageDir.path)
        #expect(throws: (any Error).self) {
            try i.install(i.candidate(try TestPackages.bundle(TestPackages.manifest()), source: .file("a")), onInNewChats: false)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packageDir.path)
        #expect(PackageStore(directory: dir, builtIn: [], builtInDefault: { _ in false }).package(id: "com.example.demo")?.version == "1.0.0")

        // The registry can't be written: the update fails and the store still has the installed version.
        let registry = dir.appendingPathComponent("registry.json")
        try FileManager.default.removeItem(at: registry)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try i.install(i.candidate(try TestPackages.bundle(TestPackages.manifest(version: "2.0.0")), source: .file("b")), onInNewChats: false)
        }
        #expect(s.package(id: "com.example.demo")?.version == "1.0.0")
        #expect(!FileManager.default.fileExists(atPath: packageDir.appendingPathComponent("2.0.0").path))
    }

    /// The audit's example: build metadata used to be dropped unchecked, so this version passed validation and named
    /// a folder outside the package's, which `install` deleted before writing.
    @Test func versionsCantLeaveThePackageFolder() throws {
        let evil = "1.0.0+seed/../../../Artifacts"
        #expect(SemVer(evil) == nil)
        #expect(SemVer("1.0.0+build.5") != nil && SemVer("2.0.0-beta.1+exp.sha.5114f85") != nil)
        for bad in ["1.0.0+", "1.0.0+a..b", "1.0.0+a\\b", "1.0.0-é", "1.0.0+ü", "1.0.0-a/b"] { #expect(SemVer(bad) == nil, "\(bad)") }
        #expect { try TestPackages.bundle(TestPackages.manifest(version: evil)) } throws: {
            ($0 as? LocalizedError)?.errorDescription?.contains("SemVer") == true
        }
        #expect(throws: PackageError.self) { try TestPackages.bundle(TestPackages.manifest(version: " 1.0.0")) }

        // The store checks the folder on its own too.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pkgs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("com.example.demo")
        #expect(throws: PackageStore.Failure.unsafePath(evil)) { try PackageStore.contained(evil, in: package) }
        for bad in ["..", ".", "", "a/b", "a\\b"] { #expect(throws: PackageStore.Failure.self) { try PackageStore.contained(bad, in: package) } }
        #expect(try PackageStore.contained("1.0.0+seed", in: package).path == package.appendingPathComponent("1.0.0+seed").path)
    }

    @Test func theSameKeyRuleGuardsUpdates() throws {
        let s = store()
        let i = installer(s)
        let key = PackageKeys.generate()
        let first = i.candidate(try TestPackages.signed(TestPackages.manifest(), key: key), source: .file("a"))
        #expect(first.trust == .trustedKey && first.asksToTrustKey)
        try i.install(first, onInNewChats: false)
        #expect(s.isTrustedKey(key.publicKey))
        // Same key: fine, and the key isn't asked about again.
        let same = i.candidate(try TestPackages.signed(TestPackages.manifest(version: "1.1.0"), key: key), source: .file("b"))
        #expect(same.blocker == nil && !same.asksToTrustKey)
        // Another key, or no signature: refused.
        let other = i.candidate(try TestPackages.signed(TestPackages.manifest(version: "1.2.0"), key: PackageKeys.generate()), source: .file("c"))
        #expect(other.blocker != nil)
        #expect(throws: PackageError.self) { try i.install(other, onInNewChats: false) }
        let unsigned = i.candidate(try TestPackages.bundle(TestPackages.manifest(version: "1.3.0")), source: .file("d"))
        #expect(unsigned.blocker != nil)
        // A rotation chain from the installed key is accepted.
        let next = PackageKeys.generate()
        let link = try PackageSignature.rotate(from: try PackageKeys.privateKey(key.privateKey), to: next.publicKey)
        let rotated = i.candidate(try TestPackages.signed(TestPackages.manifest(version: "2.0.0"), key: next, chain: [link], original: key.publicKey),
                                  source: .file("e"))
        #expect(rotated.blocker == nil)
    }

    @Test func theUpdateSheetsSwitchDecidesOnInNewChats() throws {
        let s = store()
        let i = installer(s)
        try i.install(i.candidate(try TestPackages.bundle(TestPackages.manifest()), source: .file("a")), onInNewChats: true)
        let update = i.candidate(try TestPackages.bundle(TestPackages.manifest(version: "1.1.0")), source: .file("b"))
        #expect(update.onInNewChatsByDefault)
        try i.install(update, onInNewChats: false)
        #expect(s.package(id: "com.example.demo")?.record.onInNewChats == false)
    }

    @Test func aDeclinedKeyStaysUntrustedThroughUpdates() throws {
        let s = store()
        let i = installer(s)
        let key = PackageKeys.generate()
        let first = i.candidate(try TestPackages.signed(TestPackages.manifest(), key: key), source: .file("a"))
        try i.install(first, onInNewChats: false, trustKey: false)
        #expect(s.package(id: "com.example.demo")?.trust == .unsigned && !s.isTrustedKey(key.publicKey))
        // The same key signs the update: the question comes back, starting off, and saying no keeps it unsigned.
        let update = i.candidate(try TestPackages.signed(TestPackages.manifest(version: "1.1.0"), key: key), source: .file("b"))
        #expect(update.blocker == nil && update.asksToTrustKey && update.keyDeclined)
        try i.install(update, onInNewChats: false, trustKey: false)
        #expect(s.package(id: "com.example.demo")?.trust == .unsigned)
        // Saying yes now trusts it.
        let later = i.candidate(try TestPackages.signed(TestPackages.manifest(version: "1.2.0"), key: key), source: .file("c"))
        try i.install(later, onInNewChats: false, trustKey: true)
        #expect(s.package(id: "com.example.demo")?.trust == .trustedKey && s.isTrustedKey(key.publicKey))
    }

    @Test func revertToAnUnsignedVersionDropsTrust() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pkgs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = PackageStore(directory: dir, builtIn: [], builtInDefault: { _ in false })
        let i = installer(s)
        try i.install(i.candidate(try TestPackages.bundle(TestPackages.manifest()), source: .file("a")), onInNewChats: false)
        let signed = i.candidate(try TestPackages.signed(TestPackages.manifest(version: "2.0.0"), key: PackageKeys.generate()), source: .file("b"))
        try i.install(signed, onInNewChats: false)
        #expect(s.package(id: "com.example.demo")?.trust == .trustedKey)
        try s.revert(id: "com.example.demo")
        let p = try #require(s.package(id: "com.example.demo"))
        #expect(p.version == "1.0.0" && p.trust == .unsigned && p.record.keys.isEmpty)
    }

    @Test func pageToolsAndBuiltInIDsAreRefused() throws {
        let i = installer(store(builtIn: [try TestPackages.bundle(TestPackages.manifest(id: "app.omnichat.wikipedia", namespace: "wiki"))]))
        let impostor = i.candidate(try TestPackages.bundle(TestPackages.manifest(id: "app.omnichat.wikipedia", namespace: "wikix")), source: .file("x"))
        #expect(impostor.blocker != nil)
        let tool: [String: Any] = ["name": "read", "kind": "page", "description": "Read.", "page": ["url": "https://a.example/x"], "script": "a.js"]
        let page = try TestPackages.bundle(TestPackages.manifest(extra: ["contents": ["tools": [tool]], "permissions": ["network": ["a.example"]]]),
                                           ["a.js": "window.strataPlugin = 1"])
        #expect(i.candidate(page, source: .file("p")).blocker != nil)
    }

    @Test func addPackageLinks() {
        let link = AddPackageLink(URL(string: "omnichat://add-package?url=https%3A%2F%2Fexample.com%2Fa.ocpkg&sha256=" + String(repeating: "ab", count: 32))!)
        #expect(link?.url.absoluteString == "https://example.com/a.ocpkg" && link?.sha256?.count == 64)
        #expect(AddPackageLink(URL(string: "omnichat://add-package?url=http%3A%2F%2Fexample.com%2Fa.ocpkg")!) == nil, "https only")
        #expect(AddPackageLink(URL(string: "omnichat://add-package?url=https%3A%2F%2Fu%3Ap%40example.com%2Fa")!) == nil, "no user info")
        #expect(AddPackageLink(URL(string: "omnichat://add-package?url=https%3A%2F%2Fexample.com%2Fa&sha256=xyz")!) == nil)
        #expect(AddPackageLink(URL(string: "omnichat://add-connection?url=https%3A%2F%2Fexample.com")!) == nil)
        let round = AddPackageLink(url: URL(string: "https://example.com/p.ocpkg")!, sha256: nil)
        #expect(AddPackageLink(round.link) == round)
    }

    @Test func linkDownloadsAreCheckedAgainstTheirDigest() async throws {
        let zip = PackageArchive.write(try PackageBundle.packed(try TestPackages.files(TestPackages.manifest())))
        PackageHTTPStub.reset(["dl.example.com/p.ocpkg": .init(status: 200, body: String(decoding: zip, as: UTF8.self))])
        var i = installer(store())
        i.configuration = { PackageHTTPStub.configuration() }
        i.resolver = PackageTestResolver()
        // Zip bytes don't survive a String round trip, so the digest check is what's tested here.
        let wrong = AddPackageLink(url: URL(string: "https://dl.example.com/p.ocpkg")!, sha256: String(repeating: "0", count: 64))
        await #expect(throws: PackageInstaller.Failure.digestMismatch) { _ = try await i.candidate(link: wrong) }
        i.resolver = PackageTestResolver(address: "192.168.1.2")
        await #expect(throws: PackageInstaller.Failure.self) { _ = try await i.candidate(link: wrong) }
    }
}

struct BuiltInPackageTests {
    private var bundled: [PackageBundle] { PackageStore.bundled() }

    @Test func theBuiltInPackagesShipAndValidate() throws {
        let ids = bundled.map(\.manifest.id)
        #expect(ids.contains(BuiltInPackages.wikipedia) && ids.contains(BuiltInPackages.korea) && ids.contains(BuiltInPackages.connections))
        for b in bundled { #expect(b.warnings.isEmpty, "\(b.manifest.id): \(b.warnings)") }
    }

    @Test func wikipediaIsAPageToolOverTheOldPluginScript() throws {
        let wiki = try #require(bundled.first { $0.manifest.id == BuiltInPackages.wikipedia })
        #expect(wiki.manifest.namespace == "wiki" && wiki.usableTools.map(\.name) == ["summary"])
        let tool = wiki.usableTools[0]
        #expect(tool.kind == "page" && tool.page?.url == "https://{lang}.wikipedia.org/wiki/{title}")
        let plugin = try #require(PluginRegistry.bundled.plugin(named: "wikipedia_summary"))
        #expect(wiki.files[tool.script ?? ""].map { String(decoding: $0, as: UTF8.self) } == plugin.script, "the same script as run_plugin's")
        #expect(wiki.manifest.requiredGroups == ["web"])
    }

    @Test func theKoreaPackHoldsNaverPlaces() throws {
        let korea = try #require(bundled.first { $0.manifest.id == BuiltInPackages.korea })
        #expect(korea.manifest.namespace == "kr" && korea.skills.map(\.name) == ["naver-places"])
        let p = TestPackages.installed(korea, trust: .builtIn)
        #expect(p.skills.map(\.name) == ["kr:naver-places"])
        #expect(p.promptSection.contains("- kr:naver-places: Find places in Korea"))
        #expect(!SkillStore.bundled().contains { $0.name == "naver-places" }, "it moved out of the app's skills")
    }

    @Test func builtInDefaults() throws {
        let korea = try #require(bundled.first { $0.manifest.id == BuiltInPackages.korea }).manifest
        let connections = try #require(bundled.first { $0.manifest.id == BuiltInPackages.connections }).manifest
        #expect(PackageStore.builtInDefault(korea, region: "KR", enabledPlugins: []))
        #expect(!PackageStore.builtInDefault(korea, region: "US", enabledPlugins: []))
        #expect(!PackageStore.builtInDefault(connections, region: "KR", enabledPlugins: []))
        let wiki = try #require(bundled.first { $0.manifest.id == BuiltInPackages.wikipedia }).manifest
        #expect(PackageStore.builtInDefault(wiki, region: nil, enabledPlugins: ["wikipedia_summary"]), "it follows the old plugin switch")
        #expect(!PackageStore.builtInDefault(wiki, region: nil, enabledPlugins: []))
        #expect(!PackageStore.builtInDefault(korea), "off under unit tests")
        // A store on a Korean device turns the pack on in new chats; elsewhere it stays off.
        let kr = PackageStore(directory: nil, builtIn: bundled, builtInDefault: { $0.id == BuiltInPackages.korea })
        #expect(kr.defaultOn == [BuiltInPackages.korea])
        #expect(PackageStore(directory: nil, builtIn: bundled, builtInDefault: { _ in false }).defaultOn.isEmpty)
        // The connections package adds nothing to chats, so it never has a switch.
        #expect(kr.package(id: BuiltInPackages.connections)?.addsToChats == false)
        #expect(kr.replacedPlugins(by: [BuiltInPackages.wikipedia]) == ["wikipedia_summary"])
        #expect(kr.replacedPlugins(by: [BuiltInPackages.korea]).isEmpty)
    }
}
