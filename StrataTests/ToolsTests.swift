import Testing
import Foundation
import WebKit
@testable import Strata

struct URLGuardTests {
    @Test(arguments: [
        "127.0.0.1", "127.255.0.3", "10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.255",
        "192.168.1.1", "169.254.169.254", "0.0.0.0", "100.64.0.1", "224.0.0.1", "255.255.255.255",
        "::1", "::", "fe80::1", "fe80::abcd%en0", "fc00::1", "fd12:3456::1", "ff02::1",
        "::ffff:127.0.0.1", "::ffff:10.1.2.3", "::ffff:192.168.0.9", "64:ff9b::7f00:1",
    ])
    func blocksPrivateAddresses(address: String) {
        #expect(URLGuard.isBlocked(address: address))
    }

    @Test(arguments: ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "100.63.0.1", "100.128.0.1", "193.0.0.1",
                      "2606:4700:4700::1111", "2001:4860:4860::8888", "::ffff:8.8.8.8"])
    func allowsPublicAddresses(address: String) {
        #expect(!URLGuard.isBlocked(address: address))
    }

    @Test func blocksLocalHostnames() {
        for h in ["localhost", "LOCALHOST", "foo.localhost", "printer.local", "db.internal", "router.lan", "x.home.arpa", ""] {
            #expect(URLGuard.isBlockedHostname(h), "\(h)")
        }
        #expect(!URLGuard.isBlockedHostname("example.com"))
    }

    struct FakeResolver: HostResolving {
        var table: [String: [String]]
        func resolve(_ host: String) async -> [String] { table[host] ?? [] }
    }

    @Test func validateChecksSchemeAndResolvedAddresses() async throws {
        let resolver = FakeResolver(table: [
            "example.com": ["93.184.216.34"],
            "evil.example": ["93.184.216.34", "10.0.0.5"],
            "rebind.example": ["127.0.0.1"],
            "127.1": ["127.0.0.1"],
        ])
        try await URLGuard.validate(URL(string: "https://example.com/a")!, resolver: resolver)
        await #expect(throws: URLGuardError.unsupportedScheme("file")) { try await URLGuard.validate(URL(string: "file:///etc/passwd")!, resolver: resolver) }
        await #expect(throws: URLGuardError.unsupportedScheme("ftp")) { try await URLGuard.validate(URL(string: "ftp://example.com/")!, resolver: resolver) }
        await #expect(throws: URLGuardError.blockedHost("evil.example")) { try await URLGuard.validate(URL(string: "http://evil.example/")!, resolver: resolver) }
        await #expect(throws: URLGuardError.blockedHost("rebind.example")) { try await URLGuard.validate(URL(string: "https://rebind.example/")!, resolver: resolver) }
        await #expect(throws: URLGuardError.blockedHost("127.1")) { try await URLGuard.validate(URL(string: "http://127.1/")!, resolver: resolver) }
        await #expect(throws: URLGuardError.blockedHost("localhost")) { try await URLGuard.validate(URL(string: "http://localhost:8080/")!, resolver: resolver) }
        await #expect(throws: URLGuardError.unresolvable("nope.example")) { try await URLGuard.validate(URL(string: "https://nope.example/")!, resolver: resolver) }
    }

    @Test func systemResolverNormalizesLiteralForms() async {
        let r = SystemHostResolver()
        let loopback = await r.resolve("127.1")
        #expect(loopback.contains("127.0.0.1"))
        let v6 = await r.resolve("::1")
        #expect(v6.contains("::1"))
    }
}

struct URLRewriterTests {
    @Test func naverBlogRewrittenToMobile() {
        let u = URL(string: "https://blog.naver.com/someone/223344?x=1#frag")!
        #expect(URLRewriter.rewrite(u).absoluteString == "https://m.blog.naver.com/someone/223344?x=1#frag")
    }

    @Test func otherHostsUntouched() {
        for s in ["https://m.blog.naver.com/a", "https://example.com/", "https://blog.naver.com.evil.test/x", "https://naver.com/"] {
            #expect(URLRewriter.rewrite(URL(string: s)!).absoluteString == s)
        }
    }

    @MainActor
    @Test func fetchPrepareRewritesAndGuards() async throws {
        struct R: HostResolving { func resolve(_ host: String) async -> [String] { ["211.1.1.1"] } }
        let u = try await WebFetchTool.prepare("https://blog.naver.com/a/1", resolver: R())
        #expect(u.host == "m.blog.naver.com")
        await #expect(throws: URLGuardError.self) { try await WebFetchTool.prepare("http://192.168.0.1/admin", resolver: SystemHostResolver()) }
    }
}

struct SearchEngineTests {
    @Test func bundledEngineIsDuckDuckGo() throws {
        let engine = try #require(SearchEngines.default)
        #expect(engine.id == "duckduckgo")
        #expect(engine.resultsXPath == "//div[@id=\"links\"]/div[contains(@class,\"web-result\")]")
        #expect(engine.challengeXPath == "//form[@id='challenge-form']")
    }

    @Test func urlTemplateEncodesQuery() throws {
        let engine = try #require(SearchEngines.default)
        #expect(engine.searchURL(for: "swift & ui?")?.absoluteString == "https://html.duckduckgo.com/html/?q=swift%20%26%20ui%3F")
    }

    @Test func decodesDDGRedirect() {
        #expect(SearchEngine.decodeDDGRedirect("//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.com%2Fp%3Fx%3D1%26y%3D2&rut=zz") == "https://a.com/p?x=1&y=2")
        #expect(SearchEngine.decodeDDGRedirect("https://example.org/direct") == "https://example.org/direct")
        #expect(SearchEngine.decodeDDGRedirect("//duckduckgo.com/y.js?ad_domain=x") == nil)
    }

    @Test func enginesAreDataDrivenJSON() throws {
        let json = """
        [{"id":"x","name":"X","urlTemplate":"https://x.test/?q={query}","resultsXPath":"//r","titleXPath":".//a","urlXPath":".//a/@href","snippetXPath":".//p"}]
        """
        let engines = try SearchEngines.load(from: Data(json.utf8))
        #expect(engines.first?.maxResults == 8)
        #expect(engines.first?.challengeXPath == nil)
    }

    @Test func formatterIsCompact() {
        let text = SearchFormatter.format(query: "q", results: [SearchResult(title: "T", url: "https://u", snippet: "S")])
        #expect(text == "Search results for \"q\":\n1. T\n   https://u\n   S")
        #expect(SearchFormatter.format(query: "q", results: []).contains("No results"))
    }

    @Test func pageTextNormalizationAndTruncation() {
        #expect(PageTextFormatter.normalize("a   b\n\n\n\n c\t d ") == "a b\n\nc d")
        let long = String(repeating: "x", count: 30_000)
        let out = PageTextFormatter.normalize(long)
        #expect(out.count < 24_200 && out.contains("[Truncated"))
    }
}

/// Runs the real extraction script (document.evaluate) against saved DDG HTML in a WKWebView.
@MainActor
struct DDGExtractionTests {
    private func fixture(_ name: String) throws -> String {
        let bundle = Bundle(for: FixtureToken.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func load(_ name: String) async throws -> HiddenWebView {
        let page = HiddenWebView(guardNavigations: false)
        try await page.load(html: try fixture(name), baseURL: URL(string: "https://html.duckduckgo.com/html/"))
        return page
    }

    @Test func extractsOrganicResultsOnly() async throws {
        let engine = try #require(SearchEngines.default)
        let page = try await load("ddg-results")
        defer { page.dispose() }
        let results = try await SearchExtractor.extract(engine: engine, from: page)
        #expect(results.count == 3) // ad skipped, duplicate URL dropped
        #expect(results[0].title == "Applying Liquid Glass to custom views | Apple Developer Documentation")
        #expect(results[0].url == "https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views")
        #expect(results[0].snippet == "Configure, combine, and morph views using Liquid Glass effects in SwiftUI.")
        #expect(results[1].title == "Hacking with Swift: SwiftUI quick start")
        #expect(results[1].url == "https://www.hackingwithswift.com/quick-start/swiftui?a=1&b=2")
        #expect(results[1].snippet == "Learn SwiftUI & build apps. Includes glass effects.")
        #expect(results[2].url == "https://example.org/direct-link")
        #expect(results[2].snippet == "")
    }

    @Test func detectsBotChallenge() async throws {
        let engine = try #require(SearchEngines.default)
        let page = try await load("ddg-challenge")
        defer { page.dispose() }
        await #expect(throws: SearchExtractorError.challenge) {
            try await SearchExtractor.extract(engine: engine, from: page)
        }
    }

    @Test func readabilityExtractsArticle() async throws {
        let page = try await load("article")
        defer { page.dispose() }
        let readability = try #require(Bundle.main.url(forResource: "Readability", withExtension: "js"))
        _ = try await page.evaluateString(try String(contentsOf: readability, encoding: .utf8) + "\n;'ok'")
        let json = try await page.evaluateString(WebFetchTool.extractionScript)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let text = try #require(obj["text"] as? String)
        #expect(text.contains("The tide rose slowly"))
        #expect(text.contains("all well"))
        #expect(!text.contains("Subscribe to our newsletter"))
    }
}

private final class FixtureToken {}

// MARK: - web_fetch continuation

struct PageSlicerTests {
    private let text = String(repeating: "a", count: 100)

    @Test func firstSliceHasAContinuationFooter() {
        guard case .slice(let body, let footer) = PageSlicer.slice(text, offset: 0, limit: 40) else { Issue.record("expected slice"); return }
        #expect(body.count == 40)
        #expect(footer == "[Showing characters 0\u{2013}40 of 100. Call web_fetch with the same url and offset=40 to read more.]")
    }

    @Test func middleSliceContinuesFromTheOffset() {
        let numbered = (0..<100).map { String($0 % 10) }.joined()
        guard case .slice(let body, let footer) = PageSlicer.slice(numbered, offset: 40, limit: 40) else { Issue.record("expected slice"); return }
        #expect(body == String(numbered.dropFirst(40).prefix(40)))
        #expect(footer.contains("40\u{2013}80 of 100") && footer.contains("offset=80"))
    }

    @Test func lastSliceSaysEndOfPage() {
        guard case .slice(let body, let footer) = PageSlicer.slice(text, offset: 80, limit: 40) else { Issue.record("expected slice"); return }
        #expect(body.count == 20)
        #expect(footer == "[End of page, 100 characters total.]")
        // A page that fits in one call never offers a continuation.
        guard case .slice(_, let whole) = PageSlicer.slice(text, offset: 0, limit: 500) else { Issue.record("expected slice"); return }
        #expect(whole == "[End of page, 100 characters total.]")
    }

    @Test func offsetPastTheEndIsReported() {
        #expect(PageSlicer.slice(text, offset: 100, limit: 40) == .offsetPastEnd(offset: 100, total: 100))
        #expect(PageSlicer.slice(text, offset: 250, limit: 40) == .offsetPastEnd(offset: 250, total: 100))
        // Offset 0 on an empty page is not an error.
        #expect(PageSlicer.slice("", offset: 0, limit: 10) == .slice(text: "", footer: "[End of page, 0 characters total.]"))
    }

    @Test func slicesCountCharactersNotBytes() {
        let korean = String(repeating: "한", count: 30)
        guard case .slice(let body, _) = PageSlicer.slice(korean, offset: 10, limit: 10) else { Issue.record("expected slice"); return }
        #expect(body == String(repeating: "한", count: 10))
    }
}

private struct PublicResolver: HostResolving {
    func resolve(_ host: String) async -> [String] { ["93.184.216.34"] }
}

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func hit() { lock.withLock { count += 1 } }
}

@MainActor
struct WebFetchContinuationTests {
    private func tool(counter: LoadCounter, cache: PageCache, limit: Int = 40) -> WebFetchTool {
        let page = FetchedPage(title: "Long page", url: "https://example.com/long", text: String(repeating: "x", count: 100))
        return WebFetchTool(resolver: PublicResolver(), cache: cache, limit: limit, loader: { _ in counter.hit(); return page })
    }

    @Test func continuationReusesTheCachedPage() async {
        let counter = LoadCounter()
        let cache = PageCache()
        let t = tool(counter: counter, cache: cache)
        let first = await t.run(urlString: "https://example.com/long")
        let second = await t.run(urlString: "https://example.com/long", offset: 40)
        let third = await t.run(urlString: "https://example.com/long", offset: 80)
        #expect(counter.count == 1, "pages load once; continuation calls come from the cache")
        #expect(first.text.hasPrefix("Title: Long page\nURL: https://example.com/long\n\n"))
        #expect(first.text.contains("offset=40"))
        #expect(second.text.hasPrefix("URL: https://example.com/long\n\n") && second.text.contains("offset=80"))
        #expect(third.text.contains("[End of page, 100 characters total.]"))
        // The candidate content carries the footer, so numbered source blocks keep it.
        #expect(first.sources.first?.content.contains("offset=40") == true)
        #expect(second.sources.first?.url == first.sources.first?.url)
    }

    @Test func offsetPastTheEndIsAClearError() async {
        let t = tool(counter: LoadCounter(), cache: PageCache())
        let out = await t.run(urlString: "https://example.com/long", offset: 500)
        #expect(out.isError)
        #expect(out.text.contains("offset 500 is past the end of the page (100 characters)"))
        #expect(out.sources.isEmpty)
    }

    @Test func negativeOffsetIsRejected() async {
        let out = await tool(counter: LoadCounter(), cache: PageCache()).run(urlString: "https://example.com/long", offset: -1)
        #expect(out.isError)
    }

    @Test func expiredCacheEntriesReload() async {
        let counter = LoadCounter()
        let cache = PageCache()
        cache.timeToLive = 0
        let t = tool(counter: counter, cache: cache)
        _ = await t.run(urlString: "https://example.com/long")
        _ = await t.run(urlString: "https://example.com/long")
        #expect(counter.count == 2)
    }

    @Test func cacheKeyIgnoresFragmentsAndTrailingSlash() {
        let cache = PageCache()
        let page = FetchedPage(title: "t", url: "u", text: "body")
        cache.store(page, for: URL(string: "https://Example.com/a/#top")!)
        #expect(cache.page(for: URL(string: "https://example.com/a")!) == page)
        #expect(cache.page(for: URL(string: "https://example.com/b")!) == nil)
    }

    @Test func toolDefinitionCarriesTheOptionalOffset() throws {
        let json = try String(decoding: ChatRequest.encoder.encode(ToolDefinition.webFetch), as: UTF8.self)
        #expect(json.contains("\"offset\"") && json.contains("\"integer\""))
        #expect(json.contains("\"required\":[\"url\"]"))
        // Byte-identical across encodes (prefix cache).
        #expect(json == (try String(decoding: ChatRequest.encoder.encode(ToolDefinition.webFetch), as: UTF8.self)))
    }

    @Test func continuationIsLabelledAsReadMore() {
        let record = ToolCallRecord(id: "1", name: "web_fetch", arguments: "{\"url\":\"https://a.com\",\"offset\":24000}", result: "", isError: false)
        #expect(record.fetchOffset == 24000)
        #expect(ActivityEntry(call: record, sources: [:]).isContinuation)
        let first = ToolCallRecord(id: "2", name: "web_fetch", arguments: "{\"url\":\"https://a.com\"}", result: "", isError: false)
        #expect(!ActivityEntry(call: first, sources: [:]).isContinuation)
    }
}
