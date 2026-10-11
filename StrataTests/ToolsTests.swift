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
