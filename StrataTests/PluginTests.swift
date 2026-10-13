import Foundation
import Testing
@testable import Strata

private func manifest(name: String = "demo", url: String = "https://{lang}.example.com/wiki/{title}",
                      args: [PluginArgument]? = nil, hosts: [String]? = ["example.com"], settle: Double? = nil,
                      waitFor: String? = nil) -> PluginManifest {
    PluginManifest(name: name, description: "A demo plugin.",
                   args: args ?? [PluginArgument(name: "title", description: "The title", required: true),
                                  PluginArgument(name: "lang", description: "Language", default: "en")],
                   url: url, hosts: hosts, settle: settle, waitFor: waitFor)
}

private func plugin(_ m: PluginManifest = manifest()) -> WebPlugin {
    WebPlugin(manifest: m, script: "window.strataPlugin = async function (args) { return args; };")
}

private func invalid(_ m: PluginManifest) -> Bool {
    do { try m.validate(); return false } catch { return error is PluginError }
}

// MARK: - Manifests

struct PluginManifestTests {
    @Test func aValidManifestDecodesAndValidates() throws {
        let json = #"""
        {"name":"demo","description":"A demo plugin.","url":"https://{lang}.example.com/wiki/{title}","hosts":["example.com"],
         "settle":0.5,"waitFor":"#content",
         "args":[{"name":"title","description":"The title","required":true},{"name":"lang","description":"Language","default":"en"}]}
        """#
        let p = try PluginRegistry.load(manifest: Data(json.utf8), script: "window.strataPlugin = function () {}")
        #expect(p.name == "demo")
        #expect(p.manifest.settle == 0.5)
        #expect(p.manifest.waitFor == "#content")
        #expect(p.manifest.args.map(\.name) == ["title", "lang"])
    }

    @Test func badManifestsAreRejected() {
        #expect(invalid(manifest(name: "Demo")), "uppercase name")
        #expect(invalid(manifest(name: "1demo")))
        #expect(invalid(manifest(name: "de-mo")))
        #expect(invalid(manifest(name: String(repeating: "a", count: 41))))
        #expect(invalid(manifest(url: "ftp://example.com/{title}")))
        #expect(invalid(manifest(url: "{lang}://example.com/{title}")))
        #expect(invalid(manifest(url: "https://example.com/{nope}")), "a placeholder that is not an argument")
        #expect(invalid(manifest(args: [PluginArgument(name: "title", description: "T")])), "optional placeholder with no default")
        #expect(invalid(manifest(args: [PluginArgument(name: "title", description: "T", required: true),
                                        PluginArgument(name: "title", description: "Again", required: true)])))
        #expect(invalid(manifest(args: [PluginArgument(name: "title", description: "", required: true)])))
        #expect(invalid(manifest(args: [PluginArgument(name: "title", description: "T", required: true, default: "x")])))
        #expect(invalid(manifest(hosts: [])))
        #expect(invalid(manifest(settle: -1)))
        #expect(invalid(manifest(settle: 11)))
        #expect(invalid(manifest(waitFor: "  ")))
        var multiline = manifest()
        multiline.description = "Two\nlines"
        #expect(invalid(multiline))
        #expect(!invalid(manifest()))
        #expect(!invalid(manifest(hosts: nil)))
    }

    @Test func malformedJSONAndAMissingScriptAreRejected() {
        #expect(throws: PluginError.self) { try PluginRegistry.load(manifest: Data("{".utf8), script: "window.strataPlugin = 1") }
        let json = try! JSONEncoder().encode(manifest())
        #expect(throws: PluginError.self) { try PluginRegistry.load(manifest: json, script: "") }
    }

    @Test func theLoaderSkipsBrokenPluginsAndKeepsTheRest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ file: String, _ text: String) throws { try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        let good = String(decoding: try JSONEncoder().encode(manifest(name: "good")), as: UTF8.self)
        try write("good.plugin.json", good)
        try write("good.plugin.js", "window.strataPlugin = function () { return 1; };")
        try write("noscript.plugin.json", String(decoding: try JSONEncoder().encode(manifest(name: "noscript")), as: UTF8.self))
        try write("broken.plugin.json", "{ not json")
        try write("renamed.plugin.json", good) // its name says "good"
        try write("renamed.plugin.js", "window.strataPlugin = function () {};")
        try write("notes.json", "{}") // not a plugin

        let registry = PluginRegistry.load(directory: dir)
        #expect(registry.plugins.map(\.name) == ["good"])
        #expect(registry.problems.count == 3)
        #expect(registry.problems.contains { $0.hasPrefix("broken.plugin.json") })
        #expect(registry.problems.contains { $0.hasPrefix("noscript.plugin.json") })
        #expect(registry.problems.contains { $0.hasPrefix("renamed.plugin.json") })
    }

    @Test func theSamplePluginIsBundledAndValid() throws {
        let p = try #require(PluginRegistry.bundled.plugin(named: "wikipedia_summary"))
        #expect(PluginRegistry.bundled.problems.isEmpty)
        #expect(p.script.contains("window.strataPlugin"))
        #expect(p.manifest.hosts == ["wikipedia.org"])
        let url = try p.manifest.pageURL(arguments: try p.manifest.resolveArguments(#"{"title":"Alan Turing"}"#))
        #expect(url.absoluteString == "https://en.wikipedia.org/wiki/Alan%20Turing")
    }
}

// MARK: - Arguments and URLs

struct PluginURLTests {
    private let m = manifest()

    @Test func placeholdersArePercentEncoded() throws {
        let url = try m.pageURL(arguments: ["title": "AC/DC? #1 & more@x", "lang": "en"])
        #expect(url.absoluteString == "https://en.example.com/wiki/AC%2FDC%3F%20%231%20%26%20more%40x")
        #expect(url.host() == "en.example.com")
        let korean = try m.pageURL(arguments: ["title": "서울", "lang": "ko"])
        #expect(korean.absoluteString == "https://ko.example.com/wiki/%EC%84%9C%EC%9A%B8")
    }

    @Test func aValueCannotChangeTheHost() throws {
        let url = try m.pageURL(arguments: ["title": "x", "lang": "evil.com/"])
        #expect(url.host(percentEncoded: false)?.hasSuffix(".example.com") == true)
        #expect(url.path() == "/wiki/x")
        let userinfo = try m.pageURL(arguments: ["title": "x", "lang": "a:b@evil.com:80"])
        #expect(userinfo.host(percentEncoded: false)?.hasSuffix(".example.com") == true)
        #expect(userinfo.user() == nil && userinfo.port == nil)
    }

    @Test func defaultsAreFilledAndNumbersAccepted() throws {
        let args = try m.resolveArguments(#"{"title": 42}"#)
        #expect(args["lang"] as? String == "en")
        #expect(try m.pageURL(arguments: args).absoluteString == "https://en.example.com/wiki/42")
        #expect(PluginManifest.json(args) == #"{"lang":"en","title":42}"#)
    }

    @Test func argumentsComeAsAStringOrAnObject() throws {
        #expect(try m.resolveArguments(["title": "A"])["title"] as? String == "A")
        #expect(try m.resolveArguments(#" {"title":"A"} "#)["title"] as? String == "A")
        let noArgs = manifest(url: "https://example.com/", args: [])
        #expect(try noArgs.resolveArguments(nil).isEmpty)
        #expect(try noArgs.resolveArguments("").isEmpty)
    }

    @Test func badArgumentsSayWhatIsWrong() {
        func message(_ raw: Any?) -> String {
            do { _ = try m.pageURL(arguments: try m.resolveArguments(raw)); return "" } catch { return error.localizedDescription }
        }
        #expect(message(nil).contains("missing required argument \"title\""))
        #expect(message(#"{"titel":"x"}"#).contains("has no argument \"titel\" (it takes: title, lang)"))
        #expect(message("not json").contains("must be a JSON object"))
        #expect(message(#"{"title":"  "}"#).contains("\"title\" is empty"))
        #expect(message(#"{"title":["a"]}"#).contains("must be a string or a number"))
    }

    @Test func placeholdersAreFoundInOrder() {
        #expect(PluginManifest.placeholders(in: "https://{a}.x.com/{b}?q={c}") == ["a", "b", "c"])
        #expect(PluginManifest.placeholders(in: "https://x.com/") == [])
    }
}

struct PluginHostTests {
    @Test func aHostOrItsSubdomainsAreAllowed() {
        let hosts = ["wikipedia.org", "*.example.com"]
        #expect(PluginManifest.hostAllowed("wikipedia.org", hosts: hosts))
        #expect(PluginManifest.hostAllowed("en.wikipedia.org", hosts: hosts))
        #expect(PluginManifest.hostAllowed("EN.M.Wikipedia.org.", hosts: hosts))
        #expect(PluginManifest.hostAllowed("a.example.com", hosts: hosts))
        #expect(PluginManifest.hostAllowed("example.com", hosts: hosts))
    }

    @Test func lookalikesAreNot() {
        let hosts = ["wikipedia.org"]
        #expect(!PluginManifest.hostAllowed("evilwikipedia.org", hosts: hosts))
        #expect(!PluginManifest.hostAllowed("wikipedia.org.evil.com", hosts: hosts))
        #expect(!PluginManifest.hostAllowed("", hosts: hosts))
        #expect(PluginManifest.hostAllowed("anything.net", hosts: nil), "no list allows any host (the URL guard still applies)")
    }
}

// MARK: - System prompt

struct PluginPromptTests {
    private let registry = PluginRegistry(plugins: [plugin(manifest(name: "zeta")), plugin(manifest(name: "alpha")),
                                                    plugin(manifest(name: "noargs", url: "https://example.com/", args: []))])

    @Test func theListIsSortedAndOnlyHasEnabledPlugins() {
        let text = registry.promptSection(enabled: ["zeta", "alpha", "missing"])
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains("run_plugin"))
        #expect(lines[1] == #"- alpha: A demo plugin. Args: title (required): The title; lang (default "en"): Language."#)
        #expect(lines[2].hasPrefix("- zeta: "))
        #expect(registry.promptSection(enabled: ["noargs"]).hasSuffix("- noargs: A demo plugin. No args."))
    }

    @Test func itIsEmptyWhenNothingIsEnabled() {
        #expect(registry.promptSection(enabled: []) == "")
        #expect(registry.promptSection(enabled: ["missing"]) == "")
        #expect(ConversationDate.systemPrompt(base: "Be brief.", day: "2026-10-13", plugins: "")
                == ConversationDate.systemPrompt(base: "Be brief.", day: "2026-10-13"))
    }

    @Test func itIsByteStable() {
        let a = registry.promptSection(enabled: ["zeta", "alpha"])
        for _ in 0..<20 {
            #expect(registry.promptSection(enabled: Set(["alpha", "zeta"].shuffled())) == a)
        }
        let reloaded = PluginRegistry(plugins: registry.plugins.reversed())
        #expect(reloaded.promptSection(enabled: ["alpha", "zeta"]) == a)
    }

    @Test func itSitsBetweenThePromptAndTheDate() {
        let list = registry.promptSection(enabled: ["alpha"])
        let system = ConversationDate.systemPrompt(base: "Be brief.", day: "2026-10-13", plugins: list)
        #expect(system == "Be brief.\n\n" + list + "\n\nCurrent date: 2026-10-13 (Tuesday).")
        #expect(ConversationDate.systemPrompt(base: "", day: "2026-10-13", plugins: list) == list + "\n\nCurrent date: 2026-10-13 (Tuesday).")
    }
}

// MARK: - Tool definition and routing

struct PluginRouterTests {
    @Test func runPluginIsAFixedToolThatNamesNoPlugin() throws {
        #expect(ToolDefinition.standard.map(\.function.name) == ["web_search", "web_fetch", "run_plugin"])
        let json = String(decoding: try ChatRequest.encoder.encode(ToolDefinition.runPlugin), as: UTF8.self)
        #expect(!json.contains("wikipedia"))
        #expect(ToolDefinition.runPlugin.function.parameters.required == ["name"])
        #expect(Set(ToolDefinition.runPlugin.function.parameters.properties.keys) == ["name", "args"])
    }

    @Test func theRouterPassesTheNameAndArgs() async {
        let seen = Seen()
        let router = ToolRouter(pluginRunner: { name, args in
            await seen.add(name, args)
            return ToolOutput(text: "ran \(name)")
        })
        let a = await router.execute(name: "run_plugin", arguments: #"{"name":"demo","args":"{\"title\":\"A\"}"}"#)
        #expect(a.text == "ran demo")
        // An object instead of the string the schema asks for, and no args at all.
        _ = await router.execute(name: "run_plugin", arguments: #"{"name":"demo","args":{"title":"B"}}"#)
        _ = await router.execute(name: "run_plugin", arguments: #"{"name":"demo"}"#)
        let calls = await seen.calls
        #expect(calls.map(\.0) == ["demo", "demo", "demo"])
        #expect(calls.map(\.1) == [#"{"title":"A"}"#, #"{"title":"B"}"#, ""])
    }

    @Test func aCallWithoutANameIsAnError() async {
        let router = ToolRouter(pluginRunner: { _, _ in ToolOutput(text: "should not run") })
        let out = await router.execute(name: "run_plugin", arguments: #"{"args":"{}"}"#)
        #expect(out.isError)
        #expect(out.text.contains("missing required argument \"name\""))
    }

    private actor Seen {
        var calls: [(String, String)] = []
        func add(_ name: String, _ args: String) { calls.append((name, args)) }
    }
}

// MARK: - The tool

@MainActor
struct RunPluginToolTests {
    private struct PublicResolver: HostResolving {
        func resolve(_ host: String) async -> [String] { ["93.184.216.34"] }
    }
    private struct PrivateResolver: HostResolving {
        func resolve(_ host: String) async -> [String] { ["10.0.0.5"] }
    }

    private func tool(enabled: Set<String> = ["demo"], resolver: any HostResolving = PublicResolver(),
                      timeouts: FetchTimeouts = .standard, executor: @escaping PluginExecutor) -> RunPluginTool {
        RunPluginTool(registry: PluginRegistry(plugins: [plugin(), plugin(manifest(name: "other"))]), enabled: enabled,
                      resolver: resolver, limit: 1000, timeouts: timeouts, executor: executor)
    }

    private static let okJSON = #"{"kind":"json","body":"{\n  \"answer\": 42\n}","total":18,"title":"Demo page","url":"https://en.example.com/wiki/A"}"#

    @Test func aSuccessfulRunReturnsTheResultAsASource() async {
        let t = tool { p, url, args in
            #expect(p.name == "demo")
            #expect(url.absoluteString == "https://en.example.com/wiki/A")
            #expect(args == #"{"lang":"en","title":"A"}"#)
            return Self.okJSON
        }
        let out = await t.run(name: "demo", arguments: #"{"title":"A"}"#)
        #expect(!out.isError)
        #expect(out.text == "Plugin: demo\nTitle: Demo page\nURL: https://en.example.com/wiki/A\n\n{\n  \"answer\": 42\n}")
        #expect(out.sources == [SourceCandidate(title: "Demo page", url: "https://en.example.com/wiki/A", content: "{\n  \"answer\": 42\n}")])
    }

    @Test func aLongResultIsCutWithANote() throws {
        let body = String(repeating: "x", count: 1500)
        let json = String(decoding: try JSONEncoder().encode(["kind": "text", "body": body, "url": "https://e.com/"]), as: UTF8.self)
        let out = try PluginScript.format(json: json, plugin: plugin(), limit: 1000)
        #expect(out.content.hasPrefix(String(repeating: "x", count: 1000) + "\n\n[Truncated: the plugin result exceeded 1000 characters.]"))
    }

    @Test func unknownAndDisabledPluginsListWhatIsAvailable() async {
        let t = tool { _, _, _ in Issue.record("must not run"); return "" }
        let unknown = await t.run(name: "nope", arguments: "")
        #expect(unknown.isError && unknown.text.contains("Available plugins: demo."))
        let disabled = await t.run(name: "other", arguments: "")
        #expect(disabled.isError && disabled.text.contains("no plugin named \"other\""))
        let none = await tool(enabled: []) { _, _, _ in "" }.run(name: "demo", arguments: "")
        #expect(none.text.contains("no plugins are enabled"))
        #expect(FetchFailure(errorText: none.text) == .failed)
    }

    @Test func aHostOutsideTheAllowlistIsBlocked() async {
        var m = manifest()
        m.hosts = ["example.org"]
        var t = tool { _, _, _ in Issue.record("must not run"); return "" }
        t.registry = PluginRegistry(plugins: [plugin(m)])
        let out = await t.run(name: "demo", arguments: #"{"title":"A"}"#)
        #expect(out.isError)
        #expect(out.text.contains("en.example.com is not a site the demo plugin may open"))
        #expect(FetchFailure(errorText: out.text) == .blocked)
    }

    @Test func thePrivateHostGuardStillApplies() async {
        let t = tool(resolver: PrivateResolver()) { _, _, _ in Issue.record("must not run"); return "" }
        let out = await t.run(name: "demo", arguments: #"{"title":"A"}"#)
        #expect(out.isError && out.text.contains("private"))
        #expect(FetchFailure(errorText: out.text) == .blocked)
    }

    @Test func errorsReadLikeFetchFailures() async {
        let script = await tool { _, _, _ in #"{"error":"no article"}"# }.run(name: "demo", arguments: #"{"title":"A"}"#)
        #expect(script.isError && script.text == "Error: Plugin script failed: no article")
        #expect(FetchFailure(errorText: script.text) == .failed)

        let slow = await tool { _, _, _ in throw PluginTimeout(what: "loading the plugin's page", limit: .seconds(15)) }
            .run(name: "demo", arguments: #"{"title":"A"}"#)
        #expect(slow.text.hasPrefix("Error: Timed out after"))
        #expect(slow.text.contains("loading the plugin's page has a 15 s limit"))
        #expect(FetchFailure(errorText: slow.text) == .timedOut)

        let insecure = await tool { _, _, _ in throw WebToolError.insecure }.run(name: "demo", arguments: #"{"title":"A"}"#)
        #expect(FetchFailure(errorText: insecure.text) == .certificate)
    }

    @Test func theOverallDeadlineEndsARunThatNeverReturns() async {
        var timeouts = FetchTimeouts.standard
        timeouts.overall = .milliseconds(300)
        let t = tool(timeouts: timeouts) { _, _, _ in
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } // ignores cancellation
            return ""
        }
        let start = ContinuousClock.now
        let out = await t.run(name: "demo", arguments: #"{"title":"A"}"#)
        #expect(out.isError)
        #expect(out.text.contains("Timed out after") && out.text.contains("the whole plugin run"))
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}

// MARK: - Feed

struct PluginFeedTests {
    @Test func aPluginCallIsARowForItsPageTitledWithThePlugin() {
        let args = #"{"name":"wikipedia_summary","args":"{\"title\":\"Alan Turing\"}"}"#
        let failed = ToolCallRecord(id: "p1", name: ToolNames.runPlugin, arguments: args,
                                    result: "Error: Blocked: x is not a site the wikipedia_summary plugin may open.", isError: true)
        #expect(failed.primaryArgument == "https://en.wikipedia.org/wiki/Alan%20Turing")
        let call = FeedCall(record: failed)
        #expect(call.plugin == "wikipedia_summary")
        let cards = ActivityFeed.cards(calls: [call], sources: [:])
        let row = cards.first?.extras.first
        #expect(row?.title == "wikipedia_summary")
        #expect(row?.host == "en.wikipedia.org")
        #expect(row?.read == .failed)
        #expect(row?.failure == .blocked)

        let done = ToolCallRecord(id: "p2", name: ToolNames.runPlugin, arguments: args, result: "ok", isError: false, sourceIDs: [7])
        let page = SourceInfo(id: 7, title: "Alan Turing", url: "https://en.wikipedia.org/wiki/Alan_Turing", snippet: "")
        let read = ActivityFeed.cards(calls: [FeedCall(record: done)], sources: [7: page]).first?.extras.first
        #expect(read?.title == "wikipedia_summary · Alan Turing")
        #expect(read?.read == .read)
        #expect(ProcessSegment.toolTitle(calls: [done]) == "Read 1 page")
    }

    @Test func anUnknownPluginFallsBackToItsName() {
        let record = ToolCallRecord(id: "p", name: ToolNames.runPlugin, arguments: #"{"name":"nope"}"#, result: "", isError: false)
        #expect(record.primaryArgument == "nope")
    }
}

// MARK: - Pipeline

@MainActor
private final class FakePluginPage: PluginPage {
    enum Load { case finish, timeout, hang, fail }
    var currentURL: URL?
    var onProgress: (@MainActor (Double) -> Void)?
    var loadBehavior: Load = .hang
    /// What the probe reports, in turn (the last one repeats).
    var probes: [String] = [#"{"href":"https://e.com/","ready":"complete","found":true}"#]
    var result = #"{"kind":"json","body":"1","total":1,"title":"","url":"https://e.com/"}"#
    var scriptError: Error?
    private(set) var probeCount = 0
    private(set) var ranScript = false
    private(set) var abandoned = false

    func load(_ url: URL, timeout: Duration) async throws {
        switch loadBehavior {
        case .finish: return
        case .timeout: try await Task.sleep(for: timeout); throw WebToolError.timeout
        case .hang: try await Task.sleep(for: .seconds(60))
        case .fail: throw WebToolError.navigation("offline")
        }
    }

    func evaluate(_ js: String, timeout: Duration) async throws -> String {
        let p = probes[min(probeCount, probes.count - 1)]
        probeCount += 1
        return p
    }

    func callAsync(_ body: String, timeout: Duration) async throws -> String {
        ranScript = true
        if let scriptError { throw scriptError }
        return result
    }

    func abandonLoad() { abandoned = true }
    func stop() {}
}

@MainActor
struct PluginPipelineTests {
    private let url = URL(string: "https://e.com/")!
    private let fast = FetchTimeouts(load: .milliseconds(600), script: .seconds(1), probe: .milliseconds(200), settle: .milliseconds(10), overall: .seconds(5))
    private static let loading = #"{"href":"https://e.com/","ready":"loading","found":false}"#
    private static let parsedNoMatch = #"{"href":"https://e.com/","ready":"interactive","found":false}"#
    private static let blank = #"{"href":"about:blank","ready":"complete","found":false}"#

    private func run(_ page: FakePluginPage, waitFor: String? = nil) async throws -> String {
        try await PluginPipeline.run(plugin(manifest(waitFor: waitFor)), url: url, arguments: "{}", page: page, timeouts: fast, maxCharacters: 100)
    }

    @Test func aReadyPageRunsWithoutWaitingForTheLoadToFinish() async throws {
        let page = FakePluginPage() // the load never finishes
        page.probes = [Self.blank, Self.loading, #"{"href":"https://e.com/","ready":"interactive","found":true}"#]
        let start = ContinuousClock.now
        _ = try await run(page, waitFor: "#content")
        #expect(ContinuousClock.now - start < fast.load)
        #expect(page.ranScript)
        #expect(page.abandoned, "the pending load is let go, not stopped")
    }

    @Test func waitForHoldsTheRunUntilItMatches() async throws {
        let page = FakePluginPage()
        page.probes = [Self.parsedNoMatch, Self.parsedNoMatch, #"{"href":"https://e.com/","ready":"complete","found":true}"#]
        _ = try await run(page, waitFor: "#content")
        #expect(page.probeCount == 3)
    }

    @Test func atTheLoadLimitThePluginRunsOnWhatArrived() async throws {
        for behavior in [FakePluginPage.Load.hang, .timeout] {
            let page = FakePluginPage()
            page.loadBehavior = behavior
            page.probes = [Self.parsedNoMatch] // waitFor never matches
            let start = ContinuousClock.now
            _ = try await run(page, waitFor: "#never")
            #expect(ContinuousClock.now - start >= fast.load)
            #expect(page.ranScript, "\(behavior)")
        }
    }

    @Test func aPageThatNeverShowedUpTimesOut() async {
        let page = FakePluginPage()
        page.probes = [Self.blank]
        await #expect(throws: PluginTimeout(what: "loading the plugin's page", limit: fast.load)) { _ = try await run(page) }
        #expect(!page.ranScript)
    }

    @Test func aFailedNavigationFails() async {
        let page = FakePluginPage()
        page.loadBehavior = .fail
        page.probes = [Self.blank]
        await #expect(throws: WebToolError.navigation("offline")) { _ = try await run(page) }
    }

    @Test func aScriptTimeoutNamesTheScript() async {
        let page = FakePluginPage()
        page.scriptError = WebToolError.timeout
        await #expect(throws: PluginTimeout(what: "the plugin script", limit: fast.script)) { _ = try await run(page) }
    }

    @Test func theProbeAndReadiness() {
        let ready = PluginScript.Probe(href: "https://e.com/", ready: "interactive", found: false)
        #expect(ready.isReady(waitFor: nil))
        #expect(!ready.isReady(waitFor: "#x"))
        #expect(!PluginScript.Probe(href: "https://e.com/", ready: "loading", found: true).isReady(waitFor: "#x"))
        #expect(!PluginScript.Probe(href: "about:blank", ready: "complete", found: true).isReady(waitFor: nil))
        #expect(PluginScript.probe(waitFor: #"a[href="x"]"#).contains(#""a[href=\"x\"]""#))
    }
}

// MARK: - Real web view

@MainActor
@Suite(.serialized)
struct PluginWebViewTests {
    private func html(_ body: String) -> String { "<!doctype html><html><head><title>Fixture</title></head><body>\(body)</body></html>" }

    @Test func aPageThatNeverFinishesLoadingStillRunsThePlugin() async throws {
        let view = HiddenWebView(guardNavigations: false)
        defer { view.dispose() }
        let timeouts = FetchTimeouts(load: .seconds(8), script: .seconds(3), probe: .seconds(1), settle: .milliseconds(10), overall: .seconds(20))
        // The image never loads, so didFinish never comes; the content is there at once.
        let page = html("<div id='content'><p>Hello plugin</p></div><img src='http://10.255.255.1/never.png'>")
        var m = manifest()
        m.waitFor = "#content"
        let p = WebPlugin(manifest: m, script: """
            window.strataPlugin = async function (args) {
              await new Promise(function (r) { setTimeout(r, 20); });
              return { text: document.querySelector("#content p").textContent, title: args.title };
            };
            """)
        let start = ContinuousClock.now
        let json = try await PluginPipeline.run(p, url: URL(string: "https://example.com/")!, arguments: #"{"title":"T"}"#,
                                                page: view, timeouts: timeouts, maxCharacters: 1000,
                                                navigate: { try await view.load(html: page, baseURL: URL(string: "https://example.com/"), timeout: timeouts.load) })
        #expect(ContinuousClock.now - start < .seconds(4), "ran before the load limit")
        let out = try PluginScript.format(json: json, plugin: p, limit: 1000)
        #expect(out.title == "T")
        #expect(out.content.contains(#""text": "Hello plugin""#))
        #expect(out.url == "https://example.com/")
    }

    @Test func aThrowingPluginReportsItsMessage() async throws {
        let view = HiddenWebView(guardNavigations: false)
        defer { view.dispose() }
        try await view.load(html: html("<p>x</p>"), baseURL: URL(string: "https://example.com/"))
        let p = WebPlugin(manifest: manifest(), script: "window.strataPlugin = function () { throw new Error('no article'); };")
        let json = try await view.callAsync(PluginScript.invocation(p, arguments: "{}", maxCharacters: 100), timeout: .seconds(3))
        #expect(throws: PluginError.script("no article")) { _ = try PluginScript.format(json: json, plugin: p, limit: 100) }
    }
}
