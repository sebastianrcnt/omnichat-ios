import Foundation
import Testing
import WebKit
@testable import Strata

@MainActor
private final class FakeBrowserPage: BrowserPage {
    var currentURL: URL?
    var onProgress: (@MainActor (Double) -> Void)?
    /// What the settle probe reports, in turn (the last one repeats).
    var probes: [String] = [settled]
    var extracted = #"{"title":"A page","url":"https://e.com/final","text":"Hello   world\n\n\n\nBye"}"#
    var scriptResult = #"{"body":"42","total":2,"url":"https://e.com/final"}"#
    private(set) var probeCount = 0
    private(set) var scripts: [String] = []

    nonisolated static let settled = #"{"href":"https://e.com/final","ready":"complete","domQuiet":900,"netQuiet":900,"text":20}"#

    func load(_ url: URL, timeout: Duration) async throws { currentURL = url }

    func evaluate(_ js: String, timeout: Duration) async throws -> String {
        if js.contains("__strataSettle") {
            let p = probes[min(probeCount, probes.count - 1)]
            probeCount += 1
            return p
        }
        return extracted
    }

    func callAsync(_ body: String, timeout: Duration) async throws -> String {
        scripts.append(body)
        return scriptResult
    }

    func abandonLoad() {}
    func stop() {}
}

/// Resolves every host to a public address.
private struct PublicResolver: HostResolving {
    func resolve(_ host: String) async -> [String] { ["93.184.216.34"] }
}

/// A DNS server that stops answering: replies after 5 s, whatever happens meanwhile (like a blocked getaddrinfo).
private struct StuckResolver: HostResolving {
    func resolve(_ host: String) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { cont.resume(returning: ["93.184.216.34"]) }
        }
    }
}

struct BrowserTextTests {
    @Test func shortTextIsKeptWhole() {
        let out = BrowserText.capped("  one \n\n\n\n two  ", limit: 100)
        #expect(out.text == "one\n\ntwo")
        #expect(out.total == 8)
    }

    @Test func longTextIsCutWithANote() {
        let raw = String(repeating: "a", count: 250)
        let out = BrowserText.capped(raw, limit: 100)
        #expect(out.text.hasPrefix(String(repeating: "a", count: 100) + "\n\n[Truncated:"))
        #expect(out.text.contains("first 100 of 250 characters"))
        #expect(out.text.contains("browser_eval"))
        #expect(out.total == 250)
    }

    @Test func evalResultsAreCappedToo() {
        #expect(BrowserText.cappedResult("short", total: 5, limit: 10) == "short")
        let body = String(repeating: "x", count: 50)
        let cut = BrowserText.cappedResult(body, total: 5_000, limit: 20)
        #expect(cut.hasPrefix(String(repeating: "x", count: 20) + "\n\n[Truncated: the result has 5000 characters"))
    }

    @Test func scriptResultsAreFormatted() {
        let ok = BrowserScript.format(json: #"{"body":"[1,2]","total":5,"url":"https://e.com/"}"#, limit: 100)
        #expect(ok.text == "URL: https://e.com/\n\n[1,2]")
        #expect(!ok.isError)
        #expect(BrowserScript.url(inResult: ok.text) == "https://e.com/")
        let thrown = BrowserScript.format(json: #"{"error":"ReferenceError: x is not defined","url":"https://e.com/"}"#, limit: 100)
        #expect(thrown.isError && thrown.text.contains("ReferenceError"))
        #expect(BrowserScript.format(json: "nope", limit: 100).isError)
    }

    @Test func theInvocationWrapsTheModelsCodeInAnAsyncFunction() {
        let js = BrowserScript.invocation("return document.title;", maxCharacters: 99)
        #expect(js.contains("await (async () => {\nreturn document.title;\n  })()"))
        #expect(js.contains("const __strataCap = 99;"))
    }

    @Test func aPageSettlesWhenQuiet() throws {
        let busy = try #require(BrowserSettle.Probe.decode(#"{"href":"https://e.com/","ready":"complete","domQuiet":100,"netQuiet":900,"text":10}"#))
        #expect(!busy.isSettled)
        let blank = try #require(BrowserSettle.Probe.decode(#"{"href":"about:blank","ready":"complete","domQuiet":900,"netQuiet":900,"text":10}"#))
        #expect(!blank.isSettled && !blank.committed)
        #expect(BrowserSettle.Probe.decode(FakeBrowserPage.settled)?.isSettled == true)
        #expect(BrowserSettle.Probe.decode(FakeBrowserPage.settled)?.settledBy == .quiet)
    }

    @Test func aPageWhoseNetworkNeverRestsIsReadAMomentAfterLoad() throws {
        func probe(ready: String = "complete", net: Double = 50, load: Double?) throws -> BrowserSettle.Probe {
            let loadField = load.map { #","loadQuiet":\#($0)"# } ?? ""
            return try #require(BrowserSettle.Probe.decode(
                #"{"href":"https://e.com/","ready":"\#(ready)","domQuiet":100,"netQuiet":\#(net)\#(loadField),"text":10}"#))
        }
        #expect(try probe(load: 3000).settledBy == .afterLoad, "busy network and DOM, but the load event is 3 s behind")
        #expect(try !probe(load: 1000).isSettled, "too soon after load")
        #expect(try !probe(load: -1).isSettled, "no load event yet")
        #expect(try !probe(load: nil).isSettled, "an older probe without the field")
        #expect(try !probe(ready: "interactive", load: 3000).isSettled, "still loading subresources")
    }

    @MainActor
    @Test func timingSummaryNamesTheSlowPhases() {
        var t = BrowserOpenTiming(host: "sec.gov")
        t.total = 3100
        t.load = 2600
        t.state = 200
        t.resolve = 40
        t.settle = .afterLoad
        #expect(t.summary == "sec.gov 3.1 s · load 2.6 s (after load) · state 0.2 s")
    }
}

/// From the audit: pages and artifacts reached `http://nas/…` and other LAN names, which the rules didn't list, and
/// artifact iframes skipped the address check.
@MainActor
struct LocalNetworkRuleTests {
    /// Whether any pattern matches, read the way WebKit's content blockers read them (case-insensitive).
    private func blocked(_ url: String, by patterns: [String]) -> Bool {
        patterns.contains { url.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    @Test func localNamesAndAddressesAreBlocked() {
        let local = ["http://nas/admin", "http://nas./", "https://user@nas:8443/", "http://router.lan/", "https://db.internal/",
                     "http://printer.home.arpa/", "http://wiki.corp/", "http://x.intranet:8080/", "http://tv.local./",
                     "http://192.0.0.8/", "http://198.18.0.1/", "http://239.255.255.250/", "http://127.0.0.1:8765/",
                     "ws://10.0.0.2/", "http://[::1]/"]
        for url in local { #expect(blocked(url, by: LocalNetworkRules.patterns), "\(url)") }
        let web = ["https://cdn.jsdelivr.net/npm/chart.js@4.4.0", "https://example.com:8443/a", "https://user@example.com/",
                   "https://localhost.example.com/", "https://8.8.8.8/", "https://lan.example.org/"]
        for url in web { #expect(!blocked(url, by: LocalNetworkRules.patterns), "\(url)") }
        // Artifacts get no plain HTTP or WebSocket at all.
        #expect(blocked("http://example.com/logo.png", by: LocalNetworkRules.artifactPatterns))
        #expect(blocked("ws://example.com/feed", by: LocalNetworkRules.artifactPatterns))
        #expect(!blocked("https://cdn.jsdelivr.net/npm/d3@7", by: LocalNetworkRules.artifactPatterns))
    }

    @Test func theRulesCompile() async {
        #expect(await LocalNetworkRules.rules() != nil)
        #expect(await LocalNetworkRules.artifactRules() != nil)
    }

    @Test func artifactSubframesNeedAPublicAddress() async {
        let url = URL(string: "https://nas.example.com/")!
        #expect(await ArtifactNavigation.subframePolicy(url, resolver: PackageTestResolver(address: "192.168.1.5")) == .cancel)
        #expect(await ArtifactNavigation.subframePolicy(url, resolver: PackageTestResolver()) == .allow)
        #expect(await ArtifactNavigation.subframePolicy(URL(string: "file:///etc/hosts")!, resolver: PackageTestResolver()) == .cancel)
    }

    @Test func artifactsOpenOnlyTappedPublicLinksOutside() async {
        let web = URL(string: "https://example.com/")!
        #expect(await ArtifactNavigation.mayOpenOutside(web, type: .linkActivated, resolver: PackageTestResolver()))
        // A script assigning location.href (or calling window.open) is not a tap.
        #expect(!(await ArtifactNavigation.mayOpenOutside(web, type: .other, resolver: PackageTestResolver())))
        // The other browser has no local-network rules, so a LAN destination stays blocked even when tapped.
        #expect(!(await ArtifactNavigation.mayOpenOutside(URL(string: "http://router.local/admin")!, type: .linkActivated,
                                                          resolver: PackageTestResolver())))
        #expect(!(await ArtifactNavigation.mayOpenOutside(web, type: .linkActivated,
                                                          resolver: PackageTestResolver(address: "10.0.0.1"))))
        #expect(await ArtifactNavigation.mayOpenOutside(URL(string: "mailto:a@example.com")!, type: .linkActivated))
        #expect(!(await ArtifactNavigation.mayOpenOutside(URL(string: "file:///etc/hosts")!, type: .linkActivated)))
    }
}

@MainActor
struct BrowserToolTests {
    private func sessions(_ page: FakeBrowserPage) -> BrowserSessions {
        let s = BrowserSessions()
        s.makePage = { page }
        return s
    }

    @Test func openReturnsTheTextTitleAndFinalURL() async {
        let page = FakeBrowserPage()
        page.probes = [#"{"href":"https://e.com/final","ready":"loading","domQuiet":0,"netQuiet":0,"text":0}"#, FakeBrowserPage.settled]
        let tool = BrowserOpenTool(resolver: PublicResolver(), limit: 1000, sessions: sessions(page))
        let out = await tool.run(urlString: "https://e.com/", conversation: UUID())
        #expect(!out.isError)
        #expect(out.text == "Title: A page\nURL: https://e.com/final\n\nHello world\n\nBye")
        #expect(out.sources.first?.url == "https://e.com/final")
        #expect(page.probeCount == 2)
    }

    @Test func openRefusesLocalPagesAndOtherSchemes() async {
        let tool = BrowserOpenTool(resolver: PublicResolver(), sessions: sessions(FakeBrowserPage()))
        for url in ["http://localhost:8080/", "file:///etc/hosts", "http://printer.local/"] {
            let out = await tool.run(urlString: url, conversation: nil)
            #expect(out.isError, "\(url)")
        }
    }

    @Test func openGivesUpOnAResolverThatStopsAnswering() async {
        // From the audit: the address check ran before the overall deadline and couldn't be cancelled.
        let page = FakeBrowserPage()
        var timeouts = FetchTimeouts.standard
        timeouts.overall = .milliseconds(300)
        let tool = BrowserOpenTool(resolver: StuckResolver(), timeouts: timeouts, sessions: sessions(page))
        let start = ContinuousClock.now
        let out = await tool.run(urlString: "https://slow.example.com/", conversation: UUID())
        #expect(out.isError && out.text.contains("looking up the address"))
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(page.currentURL == nil, "nothing was opened")

        let stopped = Task { @MainActor in
            await BrowserOpenTool(resolver: StuckResolver(), sessions: sessions(page)).run(urlString: "https://slow.example.com/", conversation: UUID())
        }
        try? await Task.sleep(for: .milliseconds(100))
        stopped.cancel()
        let cancelled = await stopped.value
        #expect(cancelled.isError && cancelled.text.contains("cancelled"))
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(page.currentURL == nil)
    }

    @Test func evalNeedsAnOpenPage() async {
        let page = FakeBrowserPage()
        let s = sessions(page)
        let id = UUID()
        let before = await BrowserEvalTool(sessions: s).run(code: "return 1", conversation: id)
        #expect(before.isError && before.text.contains("browser_open"))
        _ = await BrowserOpenTool(resolver: PublicResolver(), sessions: s).run(urlString: "https://e.com/", conversation: id)
        let after = await BrowserEvalTool(sessions: s).run(code: "return 42", conversation: id)
        #expect(after.text == "URL: https://e.com/final\n\n42")
        #expect(page.scripts.first?.contains("return 42") == true)
    }

    @Test func eachConversationHasItsOwnPage() async {
        let s = BrowserSessions()
        var made = 0
        s.makePage = { made += 1; return FakeBrowserPage() }
        let a = UUID(), b = UUID()
        _ = s.session(for: a)
        _ = s.session(for: a)
        _ = s.session(for: b)
        #expect(made == 2 && s.count == 2)
        s.close(a)
        #expect(s.count == 1)
    }

    @Test func theToolsAreOfferedOnlyWhenOn() {
        #expect(!ToolDefinition.available(python: false, images: false).map(\.function.name).contains("browser_open"))
        let names = ToolDefinition.available(python: true, images: true, browser: true).map(\.function.name)
        #expect(Array(names.prefix(6)) == ToolDefinition.available(python: true, images: true).map(\.function.name),
                "the browser tools come after the others, so turning them on keeps the rest of the prefix")
        #expect(names.contains("browser_open") && names.contains("browser_eval") && names.contains("load_skill"))
    }
}
