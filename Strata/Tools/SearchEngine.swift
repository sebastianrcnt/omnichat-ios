import Foundation

/// A data-driven web search engine: URL template plus XPath selectors (SearXNG style).
struct SearchEngine: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    /// `{query}` is replaced with the percent-encoded query, `{lang}` with "ko" for a Hangul query and "en" otherwise.
    var urlTemplate: String
    var resultsXPath: String
    var titleXPath: String
    var urlXPath: String
    var snippetXPath: String
    /// If this XPath matches, the page is a bot challenge.
    var challengeXPath: String?
    /// Named post-processing of the extracted href ("ddg_redirect", "bing_redirect").
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
        let lang = SearchEngines.containsHangul(query) ? "ko" : "en"
        return URL(string: urlTemplate.replacingOccurrences(of: "{query}", with: encoded)
            .replacingOccurrences(of: "{lang}", with: lang))
    }

    func transformURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch urlTransform {
        case "ddg_redirect": return SearchEngine.decodeDDGRedirect(trimmed)
        case "bing_redirect": return SearchEngine.decodeBingRedirect(trimmed)
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

extension SearchEngine {
    /// Bing wraps result links as `https://www.bing.com/ck/a?...&u=a1<base64url of the real URL>&ntb=1`.
    /// Direct links pass through; Bing's own pages and relative links are dropped.
    static func decodeBingRedirect(_ href: String) -> String? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard let comps = URLComponents(string: absolute), let host = comps.host?.lowercased() else { return nil }
        guard host == "bing.com" || host.hasSuffix(".bing.com") else {
            return comps.scheme?.hasPrefix("http") == true ? absolute : nil
        }
        guard comps.path == "/ck/a", let u = comps.queryItems?.first(where: { $0.name == "u" })?.value,
              u.hasPrefix("a1") else { return nil }
        var b64 = String(u.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let decoded = String(data: data, encoding: .utf8),
              decoded.hasPrefix("http://") || decoded.hasPrefix("https://") else { return nil }
        return decoded
    }
}

/// The user's choice in Settings > Search engine. Purely internal: the tool definitions never mention it.
enum SearchEnginePreference: String, CaseIterable, Identifiable, Sendable {
    case auto, duckduckgo, bing, naver

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        case .naver: "Naver"
        }
    }

    /// Engine ids to try for `query`, in order. The first that answers wins; the others are fallbacks.
    /// Auto: Naver for a Hangul query, Bing otherwise.
    func order(for query: String) -> [String] {
        switch self {
        case .auto: SearchEngines.containsHangul(query) ? ["naver", "bing", "duckduckgo"] : ["bing", "duckduckgo"]
        case .naver: ["naver", "bing", "duckduckgo"]
        case .bing: ["bing", "duckduckgo"]
        case .duckduckgo: ["duckduckgo", "bing"]
        }
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

    static var `default`: SearchEngine? { bundled().first { $0.id == "duckduckgo" } ?? bundled().first }

    /// The engines to try for `query`, best first (engines missing from `available` are skipped).
    static func chain(for query: String, preference: SearchEnginePreference, available: [SearchEngine] = bundled()) -> [SearchEngine] {
        preference.order(for: query).compactMap { id in available.first { $0.id == id } }
    }

    /// True if `text` has any Hangul (syllables, jamo, compatibility jamo).
    static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            switch s.value {
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xD7B0...0xD7FF: true
            default: false
            }
        }
    }
}

private final class BundleToken {}

enum SearchFormatter {
    /// Compact text for the model: numbered title / url / snippet.
    /// `engine` (the one that answered) is named in the header when given: `Search results for "q" (Bing):`.
    static func format(query: String, results: [SearchResult], engine: String? = nil) -> String {
        guard !results.isEmpty else { return "No results found for \"\(query)\"." }
        var lines = ["Search results for \"\(query)\"\(engine.map { " (\($0))" } ?? ""):"]
        for (i, r) in results.enumerated() {
            lines.append("\(i + 1). \(r.title)")
            lines.append("   \(r.url)")
            if !r.snippet.isEmpty { lines.append("   \(r.snippet)") }
        }
        return lines.joined(separator: "\n")
    }
}
