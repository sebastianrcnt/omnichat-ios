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
            return ToolOutput(text: SearchFormatter.format(query: q, results: results))
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
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count > limit else { return joined }
        return String(joined.prefix(limit)) + "\n\n[Truncated: page text exceeded \(limit) characters.]"
    }
}

struct WebFetchTool {
    var resolver: any HostResolving = SystemHostResolver()

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
    func run(urlString: String) async -> ToolOutput {
        let url: URL
        do { url = try await Self.prepare(urlString, resolver: resolver) }
        catch { return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true) }
        guard let readability = Self.readabilitySource else {
            return ToolOutput(text: "Error: the page reader is missing from the app bundle.", isError: true)
        }
        let page = HiddenWebView(resolver: resolver)
        defer { page.dispose() }
        do {
            try await page.load(url, timeout: .seconds(15))
            try? await Task.sleep(for: .milliseconds(600)) // let client-side rendering settle
            _ = try await page.evaluateString(readability + "\n;'ok'")
            let json = try await page.evaluateString(Self.extractionScript)
            struct Extracted: Decodable { var title: String; var text: String }
            guard let data = json.data(using: .utf8), let e = try? JSONDecoder().decode(Extracted.self, from: data) else {
                return ToolOutput(text: "Error: could not read the page.", isError: true)
            }
            let body = PageTextFormatter.normalize(e.text)
            if body.isEmpty { return ToolOutput(text: "Error: the page has no readable text.", isError: true) }
            let finalURL = page.webView.url?.absoluteString ?? url.absoluteString
            let title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolOutput(text: "Title: \(title)\nURL: \(finalURL)\n\n\(body)")
        } catch {
            return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Router

/// Dispatches model tool calls to the on-device tools.
struct ToolRouter: ToolExecuting {
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
            return await WebFetchTool().run(urlString: url)
        default:
            return ToolOutput(text: "Error: unknown tool \"\(name)\".", isError: true)
        }
    }
}
