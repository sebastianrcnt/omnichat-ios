import Foundation

// MARK: - Search

enum SearchExtractorError: Error, LocalizedError, Equatable {
    case challenge
    case badPayload

    var errorDescription: String? {
        switch self {
        case .challenge:
            String(localized: "The search engine showed a bot challenge (CAPTCHA), so no results could be read. Try again later or answer without searching.")
        case .badPayload: String(localized: "Could not read the search results page.")
        }
    }
}

enum SearchExtractor {
    /// JavaScript that evaluates the engine's XPaths with `document.evaluate` and returns JSON.
    static func script(for engine: SearchEngine) -> String {
        struct Config: Encodable {
            var results: String, title: String, url: String, snippet: String, challenge: String?, max: Int
        }
        let cfg = Config(results: engine.resultsXPath, title: engine.titleXPath, url: engine.urlXPath,
                         snippet: engine.snippetXPath, challenge: engine.challengeXPath, max: engine.maxResults * 3)
        let json = (try? String(data: JSONEncoder().encode(cfg), encoding: .utf8)) ?? "{}"
        return """
        (function() {
          var cfg = \(json);
          function snap(xp, ctx) {
            return document.evaluate(xp, ctx || document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
          }
          function text(xp, ctx) {
            var s = snap(xp, ctx);
            if (s.snapshotLength === 0) return "";
            var n = s.snapshotItem(0);
            var t = (n.nodeType === 2) ? n.value : n.textContent;
            return (t || "").replace(/\\s+/g, " ").trim();
          }
          if (cfg.challenge && snap(cfg.challenge).snapshotLength > 0) {
            return JSON.stringify({ challenge: true, results: [] });
          }
          var nodes = snap(cfg.results), out = [];
          for (var i = 0; i < nodes.snapshotLength && out.length < cfg.max; i++) {
            var n = nodes.snapshotItem(i);
            out.push({ title: text(cfg.title, n), url: text(cfg.url, n), snippet: text(cfg.snippet, n) });
          }
          return JSON.stringify({ challenge: false, results: out });
        })()
        """
    }

    private struct Payload: Decodable {
        struct Item: Decodable { var title: String; var url: String; var snippet: String }
        var challenge: Bool
        var results: [Item]
    }

    /// Parse the script's JSON and apply the engine's URL transform, dropping unusable rows.
    static func parse(json: String, engine: SearchEngine) throws -> [SearchResult] {
        guard let data = json.data(using: .utf8), let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw SearchExtractorError.badPayload
        }
        if payload.challenge { throw SearchExtractorError.challenge }
        var seen = Set<String>()
        var results: [SearchResult] = []
        for item in payload.results {
            guard !item.title.isEmpty, let url = engine.transformURL(item.url), seen.insert(url).inserted else { continue }
            results.append(SearchResult(title: item.title, url: url, snippet: item.snippet))
            if results.count >= engine.maxResults { break }
        }
        return results
    }

    @MainActor
    static func extract(engine: SearchEngine, from page: HiddenWebView) async throws -> [SearchResult] {
        let json = try await page.evaluateString(script(for: engine))
        return try parse(json: json, engine: engine)
    }
}

struct WebSearchTool {
    var engine: SearchEngine

    @MainActor
    func run(query: String) async -> ToolOutput {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let url = engine.searchURL(for: q) else {
            return ToolOutput(text: "Error: the search query is empty.", isError: true)
        }
        let page = HiddenWebView()
        defer { page.dispose() }
        do {
            try await page.load(url)
            let results = try await SearchExtractor.extract(engine: engine, from: page)
            return ToolOutput(text: SearchFormatter.format(query: q, results: results),
                              sources: results.map { SourceCandidate(title: $0.title, url: $0.url, content: $0.snippet.isEmpty ? $0.title : $0.snippet) })
        } catch {
            return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Fetch

enum PageTextFormatter {
    static let maxCharacters = 24_000

    /// Collapse whitespace runs and truncate to the character budget.
    static func normalize(_ text: String, limit: Int = maxCharacters) -> String {
        let joined = normalizeFull(text)
        guard joined.count > limit else { return joined }
        return String(joined.prefix(limit)) + "\n\n[Truncated: page text exceeded \(limit) characters.]"
    }

    /// Collapse whitespace runs, keeping the whole text (slicing happens later, per `web_fetch` call).
    static func normalizeFull(_ text: String) -> String {
        var lines: [String] = []
        var blank = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }).joined(separator: " ")
            if line.isEmpty {
                blank += 1
                if blank == 1 { lines.append("") }
            } else {
                blank = 0
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Slices extracted page text for `web_fetch(url, offset)`.
enum PageSlicer {
    enum Result: Equatable {
        case slice(text: String, footer: String)
        case offsetPastEnd(offset: Int, total: Int)
    }

    /// Returns `[offset, offset+limit)` of `text` plus a footer telling the model how to continue.
    static func slice(_ text: String, offset: Int, limit: Int) -> Result {
        let total = text.count
        let start = max(0, offset)
        if start > 0 && start >= total { return .offsetPastEnd(offset: start, total: total) }
        let end = min(total, start + max(1, limit))
        let from = text.index(text.startIndex, offsetBy: start)
        let to = text.index(from, offsetBy: end - start)
        let body = String(text[from..<to])
        let footer = end >= total
            ? "[End of page, \(total) characters total.]"
            : "[Showing characters \(start)\u{2013}\(end) of \(total). Call web_fetch with the same url and offset=\(end) to read more.]"
        return .slice(text: body, footer: footer)
    }
}

/// A page's extracted text, kept so continuation calls do not reload it.
struct FetchedPage: Sendable, Equatable {
    var title: String
    var url: String
    var text: String
}

/// In-memory cache of extracted pages (about 10 minutes).
final class PageCache: @unchecked Sendable {
    static let shared = PageCache()
    var timeToLive: TimeInterval = 600
    var capacity = 16

    private let lock = NSLock()
    private var entries: [String: (page: FetchedPage, stored: Date)] = [:]

    func page(for url: URL, now: Date = .now) -> FetchedPage? {
        let key = SourceStore.key(for: url.absoluteString)
        return lock.withLock {
            guard let e = entries[key], now.timeIntervalSince(e.stored) < timeToLive else { return nil }
            return e.page
        }
    }

    func store(_ page: FetchedPage, for url: URL, now: Date = .now) {
        let key = SourceStore.key(for: url.absoluteString)
        lock.withLock {
            entries[key] = (page, now)
            if entries.count > capacity, let oldest = entries.min(by: { $0.value.stored < $1.value.stored })?.key { entries[oldest] = nil }
        }
    }

    func removeAll() { lock.withLock { entries.removeAll() } }
}

typealias PageLoader = @MainActor @Sendable (URL) async throws -> FetchedPage

struct WebFetchTool {
    var resolver: any HostResolving = SystemHostResolver()
    var cache: PageCache = .shared
    /// Characters returned per call (Settings > Fetch length).
    var limit: Int = AppSettings.currentFetchLength
    /// Test seam; `nil` loads with the hidden web view.
    var loader: PageLoader?

    private static var readabilitySource: String? {
        for bundle in [Bundle.main] {
            if let url = bundle.url(forResource: "Readability", withExtension: "js"),
               let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        }
        return nil
    }

    static let extractionScript = """
    (function() {
      function fallback() { return document.body ? document.body.innerText : ""; }
      try {
        var article = new Readability(document.cloneNode(true)).parse();
        if (article && article.textContent && article.textContent.trim().length > 0) {
          return JSON.stringify({ title: article.title || document.title || "", text: article.textContent, readable: true });
        }
      } catch (e) {}
      return JSON.stringify({ title: document.title || "", text: fallback(), readable: false });
    })()
    """

    /// Validates and rewrites the URL as `web_fetch` does before loading.
    static func prepare(_ raw: String, resolver: any HostResolving) async throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { throw URLGuardError.invalidURL }
        let rewritten = URLRewriter.rewrite(url)
        try await URLGuard.validate(rewritten, resolver: resolver)
        return rewritten
    }

    @MainActor
    func run(urlString: String, offset: Int = 0) async -> ToolOutput {
        let url: URL
        do { url = try await Self.prepare(urlString, resolver: resolver) }
        catch { return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true) }
        if offset < 0 {
            return ToolOutput(text: "Error: offset must be zero or a positive character offset.", isError: true)
        }

        let page: FetchedPage
        if let cached = cache.page(for: url) {
            page = cached
        } else {
            do {
                page = try await (loader ?? Self.loadWithWebView(resolver: resolver))(url)
            } catch {
                return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
            }
            cache.store(page, for: url)
        }

        switch PageSlicer.slice(page.text, offset: offset, limit: limit) {
        case .offsetPastEnd(let off, let total):
            return ToolOutput(text: "Error: offset \(off) is past the end of the page (\(total) characters). Use an offset below \(total).", isError: true)
        case .slice(let body, let footer):
            let content = body + "\n\n" + footer
            let header = offset == 0 ? "Title: \(page.title)\nURL: \(page.url)\n\n" : "URL: \(page.url)\n\n"
            return ToolOutput(text: header + content,
                              sources: [SourceCandidate(title: page.title.isEmpty ? page.url : page.title, url: page.url, content: content)])
        }
    }

    /// The real loader: hidden web view plus Readability.
    @MainActor
    static func loadWithWebView(resolver: any HostResolving) -> PageLoader {
        { url in
            guard let readability = Self.readabilitySource else { throw WebToolError.script("the page reader is missing from the app bundle.") }
            let page = HiddenWebView(resolver: resolver)
            defer { page.dispose() }
            try await page.load(url, timeout: .seconds(15))
            try? await Task.sleep(for: .milliseconds(600)) // let client-side rendering settle
            _ = try await page.evaluateString(readability + "\n;'ok'")
            let json = try await page.evaluateString(Self.extractionScript)
            struct Extracted: Decodable { var title: String; var text: String }
            guard let data = json.data(using: .utf8), let e = try? JSONDecoder().decode(Extracted.self, from: data) else {
                throw WebToolError.script("could not read the page.")
            }
            let body = PageTextFormatter.normalizeFull(e.text)
            if body.isEmpty { throw WebToolError.script("the page has no readable text.") }
            let finalURL = page.webView.url?.absoluteString ?? url.absoluteString
            return FetchedPage(title: e.title.trimmingCharacters(in: .whitespacesAndNewlines), url: finalURL, text: body)
        }
    }
}

// MARK: - Router

/// Dispatches model tool calls to the on-device tools.
struct ToolRouter: ToolExecuting {
    var usesWebKit: Bool { true }
    func execute(name: String, arguments: String) async -> ToolOutput {
        let args = (arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        switch name {
        case ToolNames.webSearch:
            guard let query = args["query"] as? String else {
                return ToolOutput(text: "Error: missing required argument \"query\".", isError: true)
            }
            guard let engine = SearchEngines.default else {
                return ToolOutput(text: "Error: no search engine is configured.", isError: true)
            }
            return await WebSearchTool(engine: engine).run(query: query)
        case ToolNames.webFetch:
            guard let url = args["url"] as? String else {
                return ToolOutput(text: "Error: missing required argument \"url\".", isError: true)
            }
            let offset = (args["offset"] as? Int) ?? (args["offset"] as? Double).map(Int.init) ?? Int((args["offset"] as? String) ?? "") ?? 0
            return await WebFetchTool().run(urlString: url, offset: offset)
        default:
            return ToolOutput(text: "Error: unknown tool \"\(name)\".", isError: true)
        }
    }
}
