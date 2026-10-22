import Testing
import Foundation
import SwiftData
import CryptoKit
@testable import Strata

/// The prompt cache rules for packages (docs/PACKAGES.md 4.3, R1–R7).
@MainActor
struct PackageCacheGoldenTests {
    /// R1: a chat without packages sends the bytes it sent before packages existed, for every combination of tool
    /// groups, with and without image input. The digest was taken from the code before packages were added, and
    /// retaken when run_python's description changed for sockets (the only change in those bytes).
    @Test func chatsWithoutPackagesSendTheSameBytes() async throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        var hasher = SHA256()
        for images in [false, true] {
            let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
            let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
            try connections.setAPIKey("k", for: Connection.testID)
            var gateway = connections.testGateway()
            gateway.models = [ModelInfo(id: "m", supportsImages: images, supportsTools: true)]
            connections.upsert(gateway)
            let settings = AppSettings(defaults: defaults)
            settings.generateTitles = false
            let streamer = ProgrammableStreamer([])
            let controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
            controller.skills = SkillStore(builtIn: [], directory: nil)
            controller.packages = PackageStore(directory: nil, builtIn: [])
            let all = ToolGroup.allCases
            for mask in 0..<(1 << all.count) {
                let groups = Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
                let chat = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
                chat.createdDay = "2026-01-01"
                container.mainContext.insert(chat)
                chat.toolSwitches = groups
                controller.send(text: "hi", images: [], conversation: chat, context: container.mainContext)
                await controller.waitUntilIdle()
            }
            for request in streamer.requests { hasher.update(data: try request.encoded()) }
            #expect(streamer.requests.count == 1 << all.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(digest == "75c3fa460205edcd2c7a5d84a3ddd15786e8a9a1e0506a29c6f13ceee446133d")
    }
}

/// A chat controller with a package store, for the package rules of a running chat.
@MainActor
private struct PackageRig {
    let container: ModelContainer
    let controller: ChatController
    let streamer: ProgrammableStreamer
    let store: PackageStore
    let groups: Set<ToolGroup>

    init(store: PackageStore, plans: [([ChatDelta], ProgrammableStreamer.End)] = [], defaults groups: Set<ToolGroup> = [.web]) throws {
        container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.testID)
        var gateway = connections.testGateway()
        gateway.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(gateway)
        let settings = AppSettings(defaults: defaults)
        settings.generateTitles = false
        streamer = ProgrammableStreamer(plans)
        controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
        controller.skills = SkillStore(builtIn: [], directory: nil)
        controller.packages = store
        self.store = store
        self.groups = groups
    }

    func chat() -> Conversation {
        let chat = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
        chat.createdDay = "2026-01-01"
        chat.toolSwitches = groups // the packages still take their defaults at the first send
        container.mainContext.insert(chat)
        return chat
    }

    func send(_ text: String, in chat: Conversation) async {
        controller.send(text: text, images: [], conversation: chat, context: container.mainContext)
        await controller.waitUntilIdle()
    }

    var last: ChatRequest { streamer.requests.last! }

    static func system(_ r: ChatRequest) -> String {
        guard case .text(let t) = r.messages.first?.content, r.messages.first?.role == "system" else { return "" }
        return t
    }

    static func lastUser(_ r: ChatRequest) -> String {
        guard case .text(let t) = r.messages.last(where: { $0.role == "user" })?.content else { return "" }
        return t
    }

    static func toolNames(_ r: ChatRequest) -> [String] { (r.tools ?? []).map(\.function.name) }

    static func toolBytes(_ r: ChatRequest) throws -> Data { try ChatRequest.encoder.encode(r.tools ?? []) }
}

private func demoPackage(version: String = "1.0.0", description: String = "Search the demo service.", id: String = "com.example.demo",
                         name: String = "Demo", namespace: String = "demo", prompt: String = "Use demo for demo things.") throws -> PackageBundle {
    var tool = TestPackages.getTool()
    tool["description"] = description
    return try TestPackages.bundle(TestPackages.manifest(id: id, name: name, namespace: namespace, version: version, extra: [
        "contents": ["tools": [tool], "prompt": "prompt.md"], "permissions": ["network": ["api.example.com"]]]), ["prompt.md": prompt])
}

/// R2–R7: what a package does to a chat's request, and what it may never do.
@MainActor
struct PackageCacheRuleTests {
    private func store(onInNewChats: Bool = true) throws -> PackageStore {
        let s = PackageStore(directory: nil, builtIn: [], builtInDefault: { _ in false })
        try s.install(try demoPackage(), trust: .unsigned, onInNewChats: onInNewChats)
        return s
    }

    @Test func aPackageOnAtTheFirstSendIsFrozenIntoTheChat() async throws {
        let rig = try PackageRig(store: try store())
        let chat = rig.chat()
        await rig.send("one", in: chat)
        let first = rig.last
        #expect(PackageRig.toolNames(first).last == "demo__search")
        #expect(PackageRig.toolNames(first).prefix(3) == ["web_search", "web_fetch", "run_plugin"], "built-in tools first")
        let system = PackageRig.system(first)
        #expect(system.contains("Package \"Demo\" (tools demo__*):\nUse demo for demo things."))
        #expect(chat.packageSnapshot?.ids == ["com.example.demo"])
        await rig.send("two", in: chat)
        #expect(try PackageRig.toolBytes(rig.last) == PackageRig.toolBytes(first))
        #expect(PackageRig.system(rig.last) == system)
    }

    @Test func userInstalledPackagesStartOffInNewChats() async throws {
        let rig = try PackageRig(store: try store(onInNewChats: false))
        let chat = rig.chat()
        await rig.send("one", in: chat)
        #expect(!PackageRig.toolNames(rig.last).contains("demo__search"))
        #expect(chat.packageSnapshotData == nil, "a chat without packages stores nothing")
        #expect(!PackageRig.system(rig.last).contains("Package \""))
    }

    @Test func anUpdateNeverChangesARunningChat() async throws {
        let rig = try PackageRig(store: try store())
        let chat = rig.chat()
        await rig.send("one", in: chat)
        let before = rig.last
        try rig.store.install(try demoPackage(version: "1.1.0", description: "A new description.", prompt: "New prompt."),
                              trust: .unsigned, onInNewChats: true)
        await rig.send("two", in: chat)
        #expect(try PackageRig.toolBytes(rig.last) == PackageRig.toolBytes(before))
        #expect(PackageRig.system(rig.last) == PackageRig.system(before))
        // A new chat gets the new version.
        let fresh = rig.chat()
        await rig.send("hi", in: fresh)
        #expect(PackageRig.system(rig.last).contains("New prompt."))
        #expect(String(data: try PackageRig.toolBytes(rig.last), encoding: .utf8)!.contains("A new description."))
    }

    @Test func turningAPackageOffKeepsItsToolsAndTellsTheModel() async throws {
        let rig = try PackageRig(store: try store())
        let chat = rig.chat()
        await rig.send("one", in: chat)
        let before = rig.last
        rig.controller.setPackage("com.example.demo", on: false, conversation: chat)
        await rig.send("two", in: chat)
        #expect(try PackageRig.toolBytes(rig.last) == PackageRig.toolBytes(before))
        #expect(PackageRig.system(rig.last) == PackageRig.system(before))
        #expect(PackageRig.lastUser(rig.last) == "two\n\n[Package Demo: off]")
        #expect(ChatToolSwitches(chat).offPackages == ["com.example.demo"])
        // On again: the note says so, on the message that follows.
        rig.controller.setPackage("com.example.demo", on: true, conversation: chat)
        await rig.send("three", in: chat)
        #expect(PackageRig.lastUser(rig.last) == "three\n\n[Package Demo: on]")
        #expect(ChatToolSwitches(chat).offPackages.isEmpty)
    }

    @Test func callsToAPackageTurnedOffAreRefused() async throws {
        let s = try store()
        let rig = try PackageRig(store: s)
        let chat = rig.chat()
        await rig.send("one", in: chat)
        rig.controller.setPackage("com.example.demo", on: false, conversation: chat)
        let offered = OfferedTools(base: FakeTools(), names: ["demo__search"], switches: ChatToolSwitches(chat), packages: chat.packageSnapshot)
        let out = await offered.execute(name: "demo__search", arguments: #"{"q":"x"}"#)
        #expect(out.isError && out.text == ToolSwitch.packageRefusal(name: "Demo"))
    }

    @Test func aPackageTurnedOnMidChatJoinsOnce() async throws {
        let s = try store(onInNewChats: false)
        try s.install(try demoPackage(id: "com.example.second", name: "Second", namespace: "second"), trust: .unsigned, onInNewChats: false)
        let rig = try PackageRig(store: s)
        let chat = rig.chat()
        await rig.send("one", in: chat)
        #expect(chat.packageSnapshot == nil)
        rig.controller.setPackage("com.example.second", on: true, conversation: chat)
        await rig.send("two", in: chat)
        #expect(PackageRig.toolNames(rig.last).last == "second__search")
        #expect(chat.packageSnapshot?.ids == ["com.example.second"])
        let grown = rig.last
        await rig.send("three", in: chat)
        #expect(try PackageRig.toolBytes(rig.last) == PackageRig.toolBytes(grown), "the cache is lost once, then holds")
    }

    @Test func aChatFromBeforePackagesGetsNone() async throws {
        let rig = try PackageRig(store: try store())
        let chat = rig.chat()
        chat.preferencesSnapshot = "" // it sent before, from a build without tool switches
        await rig.send("one", in: chat)
        #expect(!PackageRig.toolNames(rig.last).contains("demo__search"))
        #expect(chat.packageSnapshot == nil)
    }

    @Test func requiredGroupsGateDefaultsAndTurnOnWithThePackage() async throws {
        let b = try TestPackages.bundle(TestPackages.manifest(id: "app.openchat.korea", name: "Korea", namespace: "kr", extra: [
            "requires": ["groups": ["browser"]], "contents": ["skills": ["skills/a.md"]]]),
            ["skills/a.md": "---\nname: places\ndescription: Find places.\n---\n\nBody.\n"])
        let s = PackageStore(directory: nil, builtIn: [b], builtInDefault: { $0.id == "app.openchat.korea" })
        // Browser off: the pack that needs it starts off.
        let off = try PackageRig(store: s, defaults: [.web])
        let a = off.chat()
        await off.send("hi", in: a)
        #expect(a.packageSnapshot == nil)
        // Browser on (a device set to Korea): on, with its skills listed after the app's.
        let on = try PackageRig(store: s, defaults: [.web, .browser])
        let b2 = on.chat()
        await on.send("hi", in: b2)
        #expect(b2.packageSnapshot?.ids == ["app.openchat.korea"])
        #expect(PackageRig.system(on.last).contains("- kr:places: Find places."))
        // Turning the pack on turns on the group it needs.
        let c = off.chat()
        off.controller.setPackage("app.openchat.korea", on: true, conversation: c)
        #expect(c.toolSwitches?.contains(.browser) == true)
        // Turning the group off turns the pack off with it.
        off.controller.setTool(.browser, on: false, conversation: c)
        #expect(c.packageSwitches == [])
    }

    @Test func packageSkillsBringLoadSkillWithoutTheBrowser() throws {
        let b = try TestPackages.bundle(TestPackages.manifest(extra: ["contents": ["skills": ["s.md"]]]),
                                        ["s.md": "---\nname: s\ndescription: S.\n---\n\nBody.\n"])
        let snapshot = PackageSnapshot(packages: [TestPackages.installed(b)])
        #expect(snapshot.requestTools(browserOffered: false).map(\.function.name) == ["load_skill"])
        #expect(snapshot.requestTools(browserOffered: true).isEmpty, "the browser's tools already have it")
    }

    @Test func switchesKeepTheirOrderAndTheDefaultsMarker() {
        #expect(ToolSwitch.encode(groups: [.python, .web], packages: ["b.x", "a.x"]) == "web,python,pkg:a.x,pkg:b.x")
        #expect(ToolSwitch.encode(groups: [.web], packages: nil) == "web,pkg:*")
        #expect(ToolSwitch.packages(in: "web,pkg:*") == nil)
        #expect(ToolSwitch.packages(in: "web") == [])
        #expect(ToolGroup.decode("web,pkg:a.x,pkg:*") == [.web], "older builds skip package entries")
        let chat = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
        chat.toolSwitches = [.web]
        #expect(chat.packageSwitches == nil, "groups set before the first send leave the package defaults to it")
    }
}
