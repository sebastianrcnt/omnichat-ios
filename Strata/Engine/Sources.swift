import Foundation

/// A numbered web source. Ids are stable for the whole conversation.
struct SourceInfo: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var title: String
    var url: String
    var snippet: String

    var host: String {
        guard let h = URL(string: url)?.host(percentEncoded: false) else { return url }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Registrable domain for chips (`wikipedia.org`), middle-truncated when long.
    var shortHost: String { DomainFormatter.short(host) }
}

/// The sources an answer used: the pages it read, then the results it cited, each id once.
enum SourceUsage {
    static func ids(calls: [ToolCallRecord], text: String, known: Set<Int>) -> [Int] {
        var ids: [Int] = []
        for id in calls.filter({ ToolNames.readsPage($0.name) }).flatMap(\.sourceIDs) where !ids.contains(id) { ids.append(id) }
        for id in CitationParser.citedIDs(in: text, known: known) where !ids.contains(id) { ids.append(id) }
        return ids
    }
}

/// Assigns conversation-wide source ids. The same URL (ignoring fragment, a trailing slash and case of
/// the host) always keeps its first id, including across turns.
@MainActor
final class SourceStore {
    private(set) var items: [SourceInfo]
    private var byKey: [String: Int] = [:]

    init(items: [SourceInfo] = []) {
        self.items = items
        for item in items { byKey[Self.key(for: item.url)] = item.id }
    }

    var byID: [Int: SourceInfo] { Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }) }

    @discardableResult
    func assign(_ candidate: SourceCandidate) -> SourceInfo {
        let key = Self.key(for: candidate.url)
        let snippet = String(candidate.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        if let id = byKey[key], let index = items.firstIndex(where: { $0.id == id }) {
            // Same URL: keep the id; fill in missing details.
            if items[index].snippet.isEmpty { items[index].snippet = snippet }
            if items[index].title.isEmpty { items[index].title = candidate.title }
            return items[index]
        }
        let info = SourceInfo(id: (items.map(\.id).max() ?? 0) + 1, title: candidate.title, url: candidate.url, snippet: snippet)
        items.append(info)
        byKey[key] = info.id
        return info
    }

    nonisolated static func key(for url: String) -> String {
        guard var comps = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return url }
        comps.fragment = nil
        comps.host = comps.host?.lowercased()
        comps.scheme = comps.scheme?.lowercased()
        var s = comps.string ?? url
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

enum SourceFormatter {
    static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// `<source id="N" title="..." url="...">content</source>`
    static func block(_ info: SourceInfo, content: String) -> String {
        // Keep the content from closing the tag early.
        let safe = content.replacingOccurrences(of: "</source", with: "<\\/source")
        return "<source id=\"\(info.id)\" title=\"\(escapeAttribute(info.title))\" url=\"\(escapeAttribute(info.url))\">\(safe)</source>"
    }
}

/// The app's half of the system message: how replies render, how to cite and when to use tools. Personality, tone
/// and names are the user's (`preferences`). Fixed text, so the cached prefix holds across chats.
enum AppPrompt {
    static let base = """
    You are an AI assistant in Strata, a chat app.

    - Replies are rendered as Markdown. Math is not rendered: write formulas in plain text or Unicode, not LaTeX.
    - Respond in the same language as the user's message unless asked otherwise.
    - If you do not know the answer, say so. If the request is ambiguous, ask for clarification.
    """

    static let tools = """
    Tool results contain sources, each wrapped like <source id="1" title="..." url="...">content</source>.

    - Cite sources inline with the source id in square brackets, for example [1] or [1][2], directly after the statement they support.
    - Only cite a source that has an explicit id attribute, and only ids that appear in the tool results. Never invent ids or citations.
    - Do not output the <source> XML tags or their attributes. Do not add a separate list of sources.
    - If the sources are missing, unreadable or do not answer the question, say so, then answer from your own knowledge and make clear that it is not from the sources.
    """

    static let python = """
    - For anything beyond simple arithmetic, calculate with run_python instead of in your head.
    - To show a figure run_python saved, put ![short caption](figure-N) on its own line where it belongs in your reply.
    """

    /// The app prompt for a model with (or without) tools, and with `run_python` offered or not.
    static func text(tools: Bool, python: Bool) -> String {
        guard tools else { return base }
        return base + "\n\n" + Self.tools + (python ? "\n" + Self.python : "")
    }

    /// The user's preferences as a system-prompt section, or "" when they are blank. Followed in every reply, so
    /// they are given as instructions rather than background.
    static func preferences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """
        The user has set these instructions for how you behave and respond. Follow them in every reply; they take precedence over the defaults above.
        <userPreferences>
        \(trimmed)
        </userPreferences>
        """
    }

    /// The system prompt connections carried before the app prompt existed, to tell it apart from one the user wrote.
    static let legacyCitation = """
    You are a helpful assistant. You can use the web_search and web_fetch tools when current or external information would help.

    Tool results contain sources, each wrapped like <source id="1" title="..." url="...">content</source>.

    Guidelines:
    - Cite sources inline with the source id in square brackets, for example [1] or [1][2], directly after the statement they support.
    - Only cite a source that has an explicit id attribute, and only ids that appear in the tool results. Never invent ids or citations.
    - Do not output the <source> XML tags or their attributes. Do not add a separate list of sources.
    - If the sources are missing, unreadable or do not answer the question, say so, then answer from your own knowledge and make clear that it is not from the sources.
    - If you do not know the answer, say so. If the request is ambiguous, ask for clarification.
    - Respond in the same language as the user's message.
    """
}
