import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Strata

/// The rename from OpenChat to OmniChat: what earlier builds wrote (links, built-in package ids in chats and the
/// registry, package files, key rotation links) keeps working, and only the new forms are written.
@MainActor
struct RenameCompatibilityTests {
    // MARK: URL scheme

    @Test func bothSchemesAreRegistered() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = Set(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
        #expect(schemes.isSuperset(of: ["omnichat", "openchat"]))
    }

    @Test func oldLinksStillOpenAndNewLinksUseTheNewScheme() throws {
        let add = try AddConnectionLink.parse(URL(string: "openchat://add-connection?url=https://x.example/v1&name=Old")!).get()
        #expect(add.name == "Old" && add.baseURL.absoluteString == "https://x.example/v1")
        #expect((try? AddConnectionLink.parse(URL(string: "omnichat://add-connection?url=https://x.example/v1")!).get()) != nil)
        #expect(AddConnectionLink.parse(URL(string: "otherchat://add-connection?url=https://x.example/v1")!) == .failure(.notAnAddLink))

        let package = try #require(AddPackageLink(URL(string: "openchat://add-package?url=https%3A%2F%2Fexample.com%2Fa.ocpkg")!))
        #expect(package.url.absoluteString == "https://example.com/a.ocpkg")
        #expect(package.link.scheme == "omnichat")

        let id = UUID()
        #expect(ShareURL.isShareURL(URL(string: "openchat://share?id=\(id.uuidString)")!))
        #expect(ShareURL.id(in: URL(string: "openchat://share?id=\(id.uuidString)")!) == id)
        #expect(ShareURL.url(for: id).scheme == "omnichat")

        #expect(ReplyActivityLink.conversationID(from: URL(string: "openchat://chat/\(id.uuidString)")!) == id)
        #expect(ReplyActivityLink.url(for: id).scheme == "omnichat")
    }

    @Test func anOldAddPackageLinkReachesTheReview() {
        let links = PackageLinks()
        // http isn't allowed, so the link is refused in the review sheet without a download, but it is taken.
        #expect(links.receive(URL(string: "openchat://add-package?url=http%3A%2F%2Fexample.com%2Fa.ocpkg")!))
        #expect(links.pending != nil)
        #expect(!links.receive(URL(string: "openchat://somewhere-else")!))
    }

    // MARK: Package files

    @Test func theOldPackageTypeIsStillAPackage() {
        #expect(ShareItemLoader.kind(UTType(importedAs: "cc.coolservices.openchat.package", conformingTo: .zip)) == .package)
        #expect(ShareItemLoader.kind(UTType(exportedAs: PackageFileType.identifier, conformingTo: .zip)) == .package)
        #expect(UTType.legacyPackages.map(\.identifier) == ["cc.coolservices.openchat.package"])
        #expect(UTType(filenameExtension: "ocpkg").map(ShareItemLoader.kind) == .package)
    }

    // MARK: Built-in package ids

    @Test func theBuiltInPackagesHaveTheNewIDs() {
        let ids = Set(PackageStore.bundled().map(\.manifest.id))
        #expect(ids == [BuiltInPackages.wikipedia, BuiltInPackages.korea, BuiltInPackages.connections])
        #expect(ids.allSatisfy { $0.hasPrefix("app.omnichat.") })
        #expect(BuiltInPackages.canonicalID("app.openchat.korea") == BuiltInPackages.korea)
        #expect(BuiltInPackages.canonicalID("app.openchat.example.xposts") == "app.openchat.example.xposts", "only built-ins map")
    }

    @Test func aChatsOldSwitchesAndSnapshotReadAsTheNewIDs() throws {
        #expect(ToolSwitch.packages(in: "web,pkg:app.openchat.korea,pkg:com.example.demo") == [BuiltInPackages.korea, "com.example.demo"])
        #expect(ToolSwitch.packages(in: "web,pkg:*") == nil)

        func entry(_ id: String, _ namespace: String) -> PackageSnapshot.Entry {
            PackageSnapshot.Entry(id: id, name: namespace, version: "1.0.0", digest: "d", namespace: namespace, tools: [],
                                  promptSection: "Package \(namespace)", skillNames: [])
        }
        // As an earlier build froze it: sorted by the old ids.
        let old = PackageSnapshot(entries: [entry("app.openchat.korea", "kr"), entry("app.openchat.wikipedia", "wiki"), entry("app.oz.x", "x")])
        let decoded = try #require(PackageSnapshot.decode(old.encoded))
        #expect(decoded.ids == [BuiltInPackages.korea, BuiltInPackages.wikipedia, "app.oz.x"])
        #expect(decoded.entries.map(\.namespace) == old.entries.map(\.namespace), "the frozen order, and so the bytes, stay")
        #expect(decoded.promptSections == old.promptSections)
    }

    @Test func theRegistrysOldBuiltInDefaultsCarryOver() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = #"{"packages": [], "trustedKeys": [], "builtInDefaults": {"app.openchat.korea": true}}"#
        try Data(registry.utf8).write(to: directory.appendingPathComponent("registry.json"))
        let korea = try TestPackages.bundle(TestPackages.manifest(id: BuiltInPackages.korea, name: "Korea", namespace: "kr",
                                                                  extra: ["contents": ["prompt": "prompt.md"]]), ["prompt.md": "Korea."])
        let store = PackageStore(directory: directory, builtIn: [korea], builtInDefault: { _ in false })
        #expect(store.package(id: BuiltInPackages.korea)?.record.onInNewChats == true)
        #expect(store.package(id: "app.openchat.korea")?.id == BuiltInPackages.korea)
        #expect(store.isBuiltIn("app.openchat.korea"))
        #expect(store.defaultOn == [BuiltInPackages.korea])
    }

    // MARK: Signatures

    @Test func aRotationLinkSignedWithTheOldPrefixStillVerifies() throws {
        let old = PackageKeys.generate(), new = PackageKeys.generate()
        let oldKey = try PackageKeys.privateKey(old.privateKey)
        let legacy = PackageSignature.Link(key: new.publicKey,
                                           sig: Base64URL.encode(try oldKey.signature(for: Data(("openchat-key-rotation:v1\n" + new.publicKey).utf8))))
        let b = try TestPackages.signed(TestPackages.manifest(), key: new, chain: [legacy], original: old.publicKey)
        #expect(b.verification.keys.map(\.string) == [old.publicKey, new.publicKey])

        // New links use the new prefix, and nothing else verifies.
        let link = try PackageSignature.rotate(from: oldKey, to: new.publicKey)
        let sig = try #require(Base64URL.decode(link.sig))
        #expect(oldKey.publicKey.isValidSignature(sig, for: Data(("omnichat-key-rotation:v1\n" + new.publicKey).utf8)))
        let forged = PackageSignature.Link(key: new.publicKey,
                                           sig: Base64URL.encode(try oldKey.signature(for: Data(("otherchat-key-rotation:v1\n" + new.publicKey).utf8))))
        #expect(throws: PackageError.self) { try TestPackages.signed(TestPackages.manifest(), key: new, chain: [forged], original: old.publicKey) }
    }

    @Test func bothNamesAreReservedNamespaces() {
        #expect(PackageLimits.reservedNamespaces.isSuperset(of: ["omnichat", "openchat"]))
    }
}
