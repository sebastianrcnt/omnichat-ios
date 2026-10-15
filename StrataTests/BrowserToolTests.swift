import Foundation
import Testing
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
