import Foundation

/// A data-driven web search engine: URL template plus XPath selectors (SearXNG style).
struct SearchEngine: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    /// `{query}` is replaced with the percent-encoded query.
    var urlTemplate: String
    var resultsXPath: String
    var titleXPath: String
    var urlXPath: String
    var snippetXPath: String
    /// If this XPath matches, the page is a bot challenge.
    var challengeXPath: String?
    /// Named post-processing of the extracted href ("ddg_redirect").
    var urlTransform: String?
    var maxResults: Int = 8

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        urlTemplate = try c.decode(String.self, forKey: .urlTemplate)
        resultsXPath = try c.decode(String.self, forKey: .resultsXPath)
        titleXPath = try c.decode(String.self, forKey: .titleXPath)
        urlXPath = try c.decode(String.self, forKey: .urlXPath)
        snippetXPath = try c.decode(String.self, forKey: .snippetXPath)
        challengeXPath = try c.decodeIfPresent(String.self, forKey: .challengeXPath)
        urlTransform = try c.decodeIfPresent(String.self, forKey: .urlTransform)
        maxResults = try c.decodeIfPresent(Int.self, forKey: .maxResults) ?? 8
    }

    func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: urlTemplate.replacingOccurrences(of: "{query}", with: encoded))
    }

    func transformURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch urlTransform {
        case "ddg_redirect": return SearchEngine.decodeDDGRedirect(trimmed)
        default: return trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        }
    }

    /// DDG wraps result links as `//duckduckgo.com/l/?uddg=<encoded>&rut=...`.
    static func decodeDDGRedirect(_ href: String) -> String? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard let comps = URLComponents(string: absolute) else { return nil }
        if let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value, !uddg.isEmpty {
            return uddg
        }
        // Not a redirect link: keep direct http(s) links, drop DDG-internal ones.
        if let host = comps.host, host.hasSuffix("duckduckgo.com") { return nil }
        return comps.scheme?.hasPrefix("http") == true ? absolute : nil
    }
}

struct SearchResult: Equatable, Sendable {
    var title: String
    var url: String
    var snippet: String
}

enum SearchEngines {
    static func load(from data: Data) throws -> [SearchEngine] {
        try JSONDecoder().decode([SearchEngine].self, from: data)
    }

    /// Engines bundled in the app (`engines.json`).
    static func bundled() -> [SearchEngine] {
        for bundle in [Bundle.main, Bundle(for: BundleToken.self)] {
            if let url = bundle.url(forResource: "engines", withExtension: "json"),
               let data = try? Data(contentsOf: url), let engines = try? load(from: data), !engines.isEmpty {
                return engines
            }
        }
        return []
    }

    static var `default`: SearchEngine? { bundled().first }
}

private final class BundleToken {}

enum SearchFormatter {
    /// Compact text for the model: numbered title / url / snippet.
    static func format(query: String, results: [SearchResult]) -> String {
        guard !results.isEmpty else { return "No results found for \"\(query)\"." }
        var lines = ["Search results for \"\(query)\":"]
        for (i, r) in results.enumerated() {
            lines.append("\(i + 1). \(r.title)")
            lines.append("   \(r.url)")
            if !r.snippet.isEmpty { lines.append("   \(r.snippet)") }
        }
        return lines.joined(separator: "\n")
    }
}
