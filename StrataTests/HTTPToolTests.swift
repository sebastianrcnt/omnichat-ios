import Testing
import Foundation
import SwiftData
@testable import Strata

/// Package HTTP tools end to end against a URLProtocol stub: requests, hosts, redirects, errors, secrets, approvals and
/// the audit log (docs/PACKAGES.md 3.4, 4.4–4.7).
@Suite(.serialized)
struct HTTPToolTests {
    private let secrets = PackageSecretStore(vault: InMemorySSHVault())
    private let audit = PackageAudit(directory: nil)

    private var runner: HTTPToolRunner {
        var r = HTTPToolRunner()
        r.configuration = { PackageHTTPStub.configuration() }
        r.resolver = PackageTestResolver()
        return r
    }

    private func package(tools: [[String: Any]], network: [String] = ["api.example.com"], secrets declared: [[String: Any]] = [],
                         trust: PackageTrust = .unsigned, extra: [String: Any] = [:]) throws -> (PackageStore, InstalledPackage) {
        var permissions: [String: Any] = ["network": network]
        if !declared.isEmpty { permissions["secrets"] = declared }
        var m = TestPackages.manifest(extra: ["contents": ["tools": tools], "permissions": permissions])
        for (k, v) in extra { m[k] = v }
        let store = PackageStore(directory: nil, builtIn: [], builtInDefault: { _ in false })
        try store.install(try TestPackages.bundle(m), trust: trust, onInNewChats: false)
        return (store, try #require(store.package(id: "com.example.demo")))
    }

    private func router(_ store: PackageStore, _ p: InstalledPackage,
                        approve: (@Sendable (PackageApproval, UUID?, String?) async -> PackageApprovalAnswer)? = nil) -> PackageToolRouter {
        var r = PackageToolRouter(base: FakeTools(), snapshot: PackageSnapshot(packages: [p]), store: store, secrets: secrets, audit: audit)
        r.http = runner
        r.approve = approve ?? { _, _, _ in Issue.record("no approval expected"); return .deny }
        return r
    }

    @Test func aReadOnlyToolRunsAndItsResultIsProjected() async throws {
        let tool = TestPackages.getTool(extra: ["response": ["each": "/items", "fields": ["name": "/n"],
                                                             "sources": ["title": "{name}", "url": "https://example.com/{name}"]]])
        let (store, p) = try package(tools: [tool])
        PackageHTTPStub.reset(["api.example.com/search": .init(status: 200, body: #"{"items":[{"n":"a","x":1},{"n":"b"}]}"#)])
        let out = await router(store, p).execute(name: "demo__search", arguments: #"{"q":"hello world"}"#)
        #expect(!out.isError, "\(out.text)")
        #expect(out.text == #"[{"name":"a"},{"name":"b"}]"#)
        #expect(out.sources.map(\.url) == ["https://example.com/a", "https://example.com/b"])
        let sent = try #require(PackageHTTPStub.requests.first)
        #expect(sent.url?.absoluteString == "https://api.example.com/search?q=hello%20world")
        #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
        let event = try #require(audit.events().first)
        #expect(event.package == "com.example.demo" && event.tool == "search" && event.outcome == .ok && event.host == "api.example.com")
        #expect(event.argsSha256 == PackageAudit.hash(#"{"q":"hello world"}"#), "a hash, never the arguments")
    }

    @Test func theXPostsSampleCapturesTheIDFromALink() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/Examples/xposts")
        let bundle = try PackageBundle.load(folder: folder)
        let store = PackageStore(directory: nil, builtIn: [], builtInDefault: { _ in false })
        try store.install(bundle, trust: .unsigned, onInNewChats: false)
        let p = try #require(store.package(id: bundle.manifest.id))
        PackageHTTPStub.reset(["cdn.syndication.twimg.com/tweet-result": .init(status: 200, body: """
            {"id_str":"20","text":"just setting up my twttr","created_at":"2006-03-21T20:50:14.000Z","favorite_count":250000,
             "conversation_count":17000,"user":{"name":"jack","screen_name":"jack"}}
            """)])
        let out = await router(store, p).execute(name: "xposts__read", arguments: #"{"post":"https://x.com/jack/status/20?s=46"}"#)
        #expect(!out.isError, "\(out.text)")
        #expect(out.text.contains("just setting up my twttr"))
        let sent = try #require(PackageHTTPStub.requests.first?.url)
        #expect(URLComponents(url: sent, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value == "20")
        let bad = await router(store, p).execute(name: "xposts__read", arguments: #"{"post":"not a link"}"#)
        #expect(bad.isError && bad.text.contains("Bad arguments for xposts__read"))
    }

    @Test func redirectsOffTheDeclaredHostsAreBlocked() async throws {
        let (store, p) = try package(tools: [TestPackages.getTool()])
        PackageHTTPStub.reset(["api.example.com/search": .init(status: 302, body: "", location: "https://evil.example.net/steal")])
        let out = await router(store, p).execute(name: "demo__search", arguments: #"{"q":"x"}"#)
        #expect(out.isError && out.text.contains("Blocked: evil.example.net is not a host the Demo package may reach."), "\(out.text)")
        #expect(!PackageHTTPStub.requests.contains { $0.url?.host() == "evil.example.net" })
    }

    @Test func privateAddressesAreBlockedUnlessDeclared() async throws {
        let (store, p) = try package(tools: [TestPackages.getTool()])
        var r = router(store, p)
        r.http.resolver = PackageTestResolver(address: "10.0.0.5")
        PackageHTTPStub.reset(["api.example.com/search": .init(status: 200, body: "{}")])
        let out = await r.execute(name: "demo__search", arguments: #"{"q":"x"}"#)
        #expect(out.isError && out.text.contains("private"), "\(out.text)")
        #expect(PackageHTTPStub.requests.isEmpty)
    }

    @Test func httpErrorsSayWhatToDo() async throws {
        let (store, p) = try package(tools: [TestPackages.getTool()])
        for (status, phrase) in [(401, "Settings › Packages › Demo"), (404, "not found"), (429, "rate limited"), (503, "the server failed")] {
            PackageHTTPStub.reset(["api.example.com/search": .init(status: status, body: #"{"message":"nope"}"#)])
            let out = await router(store, p).execute(name: "demo__search", arguments: #"{"q":"x"}"#)
            #expect(out.isError && out.text.hasPrefix("HTTP \(status)") && out.text.contains(phrase) && out.text.contains("nope"), "\(out.text)")
        }
    }

    @Test func secretsAreInjectedAndScrubbedFromResults() async throws {
        let tool = TestPackages.getTool(extra: ["request": ["url": "https://api.example.com/search", "query": ["q": "{q}"], "auth": ["secret": "token"]]])
        let (store, p) = try package(tools: [tool], secrets: [["name": "token", "label": "API token", "inject": "bearer"]])
        let missing = await router(store, p).execute(name: "demo__search", arguments: #"{"q":"x"}"#)
        #expect(missing.isError && missing.text == "The Demo package has no API token yet. Ask the user to add it in Settings › Packages › Demo.")
        try secrets.setValue("tok_ABCDEF123456", name: "token", package: p.id)
        let echoed = Data("tok_ABCDEF123456".utf8).base64EncodedString()
        PackageHTTPStub.reset(["api.example.com/search": .init(status: 200, body: #"{"echo":"tok_ABCDEF123456","b64":"\#(echoed)"}"#)])
        let out = await router(store, p).execute(name: "demo__search", arguments: #"{"q":"x"}"#)
        #expect(!out.isError && !out.text.contains("tok_ABCDEF") && !out.text.contains(echoed) && out.text.contains("[secret]"), "\(out.text)")
        #expect(PackageHTTPStub.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok_ABCDEF123456")
        #expect(DebugRedaction.redact("token tok_ABCDEF123456 here").contains("<redacted>"))
    }

    @Test func writesAskFirstAndADenialIsRefused() async throws {
        let post = TestPackages.getTool("create", path: "/items", query: [:], extra: [
            "request": ["method": "POST", "url": "https://api.example.com/items", "body": ["json": ["title": "{q}"]]], "title": "Create item"])
        let (store, p) = try package(tools: [post])
        PackageHTTPStub.reset(["api.example.com/items": .init(status: 201, body: #"{"id":7}"#)])
        let asked = LockedValue<[PackageApproval]>([])
        let denying = router(store, p) { approval, _, _ in asked.set(asked.get() + [approval]); return .deny }
        let denied = await denying.execute(name: "demo__create", arguments: #"{"q":"Hello"}"#)
        #expect(denied.isError && denied.text.contains("declined"))
        #expect(PackageHTTPStub.requests.isEmpty, "nothing is sent before the user approves")
        let card = try #require(asked.get().first)
        #expect(card.level == .always && card.toolTitle == "Create item" && card.request.hasPrefix("POST https://api.example.com/items"))
        #expect(card.request.contains(#""title":"Hello""#))
        #expect(audit.events().first?.outcome == .denied)

        let running = router(store, p) { _, _, _ in .run }
        let ran = await running.execute(name: "demo__create", arguments: #"{"q":"Hello"}"#)
        #expect(!ran.isError && ran.text.contains("7"))
        // "Always" is remembered in the Keychain, so the next call doesn't ask.
        _ = await router(store, p) { _, _, _ in .always }.execute(name: "demo__create", arguments: #"{"q":"Again"}"#)
        #expect(secrets.isAlwaysAllowed(package: p.id, tool: "create"))
        _ = await router(store, p).execute(name: "demo__create", arguments: #"{"q":"Third"}"#)
        #expect(PackageHTTPStub.requests.count == 3)
    }

    @Test func unsignedWritesAskEvenWhenTheManifestSaysNever() async throws {
        let post = TestPackages.getTool("create", extra: ["request": ["method": "POST", "url": "https://api.example.com/items"], "confirm": "never"])
        let (store, p) = try package(tools: [post])
        let level = await router(store, p).approvalLevel(tool: p.tools[0], package: p, conversation: UUID())
        #expect(level == .first)
        let signed = TestPackages.installed(p.bundle, trust: .trustedKey)
        #expect(await router(store, p).approvalLevel(tool: p.tools[0], package: signed, conversation: UUID()) == nil)
    }

    @Test func removedOrChangedToolsAreRefused() async throws {
        let (store, p) = try package(tools: [TestPackages.getTool()])
        var frozen = PackageSnapshot(packages: [p])
        frozen.entries[0].tools[0].schemaVersion = 0
        var r = router(store, p)
        r.snapshot = frozen
        let changed = await r.execute(name: "demo__search", arguments: #"{"q":"x"}"#)
        #expect(changed.isError && changed.text.contains("This tool changed since the chat started"))
        try store.remove(id: p.id)
        let removed = await router(store, p).execute(name: "demo__search", arguments: #"{"q":"x"}"#)
        #expect(removed.isError && removed.text.contains("The Demo package was removed"))
        let unknown = await router(store, p).execute(name: "other__tool", arguments: "{}")
        #expect(unknown.isError)
    }

    @Test func otherToolsPassThrough() async throws {
        let (store, p) = try package(tools: [TestPackages.getTool()])
        let out = await router(store, p).execute(name: "web_search", arguments: #"{"query":"x"}"#)
        #expect(out.text == #"result of web_search {"query":"x"}"#)
    }
}

/// Package skills through `load_skill` and `run_skill_script`, and the old bare name of a skill that moved into a
/// built-in package.
struct PackageSkillTests {
    private func store() throws -> PackageStore {
        let skill = "---\nname: triage\ndescription: Sort issues.\n---\n\nSort them by priority.\n"
        let b = try TestPackages.bundle(TestPackages.manifest(id: "app.openchat.korea", name: "Korea", namespace: "kr",
                                                              extra: ["contents": ["skills": ["skills/triage.md"]]]),
                                        ["skills/triage.md": skill])
        return PackageStore(directory: nil, builtIn: [b], builtInDefault: { _ in false })
    }

    @Test func packageSkillsLoadByTheirFullName() async throws {
        let s = try store()
        let p = try #require(s.package(id: "app.openchat.korea"))
        let router = PackageToolRouter(base: FakeTools(), snapshot: PackageSnapshot(packages: [p]), store: s)
        let out = await router.execute(name: ToolNames.loadSkill, arguments: #"{"name":"kr:triage"}"#)
        #expect(!out.isError && out.text == "Skill: kr:triage\n\nSort them by priority.")
    }

    @Test func aMovedSkillStillLoadsByItsOldName() async throws {
        let s = try store()
        // A chat from before the move has no packages, and its frozen skill list names the skill without a namespace.
        let router = PackageToolRouter(base: FakeTools(), snapshot: nil, store: s)
        let out = await router.execute(name: ToolNames.loadSkill, arguments: #"{"name":"triage"}"#)
        #expect(!out.isError && out.text.hasPrefix("Skill: kr:triage"))
        #expect(router.resolveSkill("kr:triage")?.name == "kr:triage")
        #expect(router.resolveSkill("nothing") == nil)
    }
}

/// The built-in Wikipedia package's page tool runs the old plugin script, and a chat with it lists it instead of the
/// plugin.
@MainActor
struct WikipediaPackageTests {
    private func store() throws -> PackageStore {
        PackageStore(directory: nil, builtIn: PackageStore.bundled().filter { $0.manifest.id == BuiltInPackages.wikipedia },
                     builtInDefault: { _ in true })
    }

    @Test func thePageToolRunsLikeThePlugin() async throws {
        let s = try store()
        let p = try #require(s.package(id: BuiltInPackages.wikipedia))
        let seen = LockedValue<(String, String)?>(nil)
        var router = PackageToolRouter(base: FakeTools(), snapshot: PackageSnapshot(packages: [p]), store: s, audit: PackageAudit(directory: nil))
        router.pageExecutor = { plugin, url, args in
            seen.set((url.absoluteString, args))
            #expect(plugin.script.contains("strataPlugin") && plugin.manifest.hosts == ["wikipedia.org"])
            return #"{"kind":"json","body":"{\n  \"title\": \"Alan Turing\"\n}","total":24,"title":"Alan Turing","url":"https://en.wikipedia.org/wiki/Alan_Turing"}"#
        }
        let out = await router.execute(name: "wiki__summary", arguments: #"{"title":"Alan Turing","lang":"ko"}"#)
        #expect(!out.isError, "\(out.text)")
        #expect(seen.get()?.0 == "https://ko.wikipedia.org/wiki/Alan%20Turing")
        #expect(seen.get()?.1.contains(#""paragraphs":"3""#) == true, "defaults fill in, as plugin args")
        #expect(out.sources.first?.url == "https://en.wikipedia.org/wiki/Alan_Turing")
        // The host stays within the package's network.
        let off = await router.execute(name: "wiki__summary", arguments: #"{"title":"x","lang":"evil.example/"}"#)
        #expect(off.isError)
    }

    @Test func aChatWithWikipediaListsItInsteadOfThePlugin() async throws {
        let key = AppSettings.enabledPluginsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(["wikipedia_summary"], forKey: key)
        let rig = try PackageRigForWiki(store: try store())
        let chat = rig.chat()
        await rig.send("hi", in: chat)
        let request = try #require(rig.streamer.requests.last)
        #expect((request.tools ?? []).map(\.function.name).contains("wiki__summary"))
        guard case .text(let system) = request.messages.first?.content else { Issue.record("no system prompt"); return }
        #expect(!system.contains("- wikipedia_summary:"))
        // With the package off in the chat, the plugin is listed as before.
        let other = rig.chat()
        rig.controller.setPackage(BuiltInPackages.wikipedia, on: false, conversation: other)
        await rig.send("hi", in: other)
        guard case .text(let plain) = rig.streamer.requests.last?.messages.first?.content else { Issue.record("no system prompt"); return }
        #expect(plain.contains("- wikipedia_summary:"))
    }
}

@MainActor
private struct PackageRigForWiki {
    let container: ModelContainer
    let controller: ChatController
    let streamer = ProgrammableStreamer([])

    init(store: PackageStore) throws {
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
        controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
        controller.skills = SkillStore(builtIn: [], directory: nil)
        controller.packages = store
    }

    func chat() -> Conversation {
        let chat = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
        chat.toolSwitches = [.web]
        container.mainContext.insert(chat)
        return chat
    }

    func send(_ text: String, in chat: Conversation) async {
        controller.send(text: text, images: [], conversation: chat, context: container.mainContext)
        await controller.waitUntilIdle()
    }
}

/// Approvals share one queue: SSH cards go through `SSHRequests`, a view of `ToolApprovals`.
@MainActor
struct ToolApprovalQueueTests {
    @Test func sshAndPackageCardsShareTheQueue() async throws {
        let approvals = ToolApprovals()
        let ssh = SSHRequests(approvals: approvals)
        let chat = UUID()
        let approval = PackageApproval(packageID: "p", packageName: "P", trust: .unsigned, toolTitle: "Create", toolName: "p__create",
                                       host: "api.example.com", request: "POST https://api.example.com", arguments: "{}", level: .first)
        async let packageAnswer = approvals.askPackage(approval, conversation: chat, callID: "call_1")
        async let sshAnswer = ssh.askApproval(SSHApproval(target: "nas", server: "nas", action: .exec(command: "ls")), conversation: chat, callID: "call_2")
        while approvals.all.count < 2 { await Task.yield() }
        #expect(ssh.all.count == 1 && ssh.request(forCall: "call_2", conversation: chat) != nil)
        #expect(approvals.request(forCall: "call_1", conversation: UUID()) == nil, "call ids repeat across chats")
        let packageCard = try #require(approvals.request(forCall: "call_1", conversation: chat))
        approvals.answer(packageCard.id, .package(.allowInChat))
        ssh.answer(try #require(ssh.request(forCall: "call_2", conversation: chat)).id, .approval(.run))
        #expect(await packageAnswer == .allowInChat)
        #expect(await sshAnswer == .run)
        #expect(approvals.all.isEmpty)
    }

    @Test func aCancelledTurnDenies() async {
        let approvals = ToolApprovals()
        let approval = PackageApproval(packageID: "p", packageName: "P", trust: .unsigned, toolTitle: "Create", toolName: "p__create",
                                       host: "h", request: "", arguments: "{}", level: .always)
        let task = Task { await approvals.askPackage(approval, conversation: UUID(), callID: "c") }
        while approvals.all.isEmpty { await Task.yield() }
        task.cancel()
        #expect(await task.value == .deny)
    }
}

/// Package tools on the on-device model: only those that opted in, at most two.
struct OnDevicePackageToolTests {
    @Test func optedInToolsAreOfferedOnDevice() throws {
        var tools: [[String: Any]] = (0..<3).map { i in
            TestPackages.getTool("t\(i)", extra: ["onDevice": ["description": "Search \(i).", "parameters": ["q"]]])
        }
        tools.append(TestPackages.getTool("plain"))
        let b = try TestPackages.bundle(TestPackages.manifest(extra: ["contents": ["tools": tools], "permissions": ["network": ["api.example.com"]]]))
        let store = PackageStore(directory: nil, builtIn: [], builtInDefault: { _ in false })
        try store.install(b, trust: .unsigned, onInNewChats: false)
        let names = ["web_search", "demo__plain", "demo__t0", "demo__t1", "demo__t2"]
        let specs = OnDevicePromptBuilder.packageTools(names, packages: store)
        #expect(specs.map(\.name) == ["demo__t0", "demo__t1"])
        #expect(specs[0].description == "Search 0." && specs[0].parameters.map(\.name) == ["q"] && !specs[0].parameters[0].optional)
    }
}
