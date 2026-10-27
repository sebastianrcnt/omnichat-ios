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
        for id in calls.filter({ ToolNames.readsPage($0.name) || ToolNames.readsTranscript($0.name) }).flatMap(\.sourceIDs)
        where !ids.contains(id) { ids.append(id) }
        for id in CitationParser.citedIDs(in: text, known: known) where !ids.contains(id) { ids.append(id) }
        return ids
    }
}

/// The sources each tool call numbered, kept with the call (`ToolCallRecord.sources`), so a message's citations read
/// the same on every device. The conversation's own list syncs as one value: on another device it can lag behind the
/// messages, or, when two devices replied, number different pages alike.
enum SourceSnapshots {
    /// What a call keeps: the snippet shortened, the rest as numbered.
    static let snippetLimit = 200

    static func snapshot(_ infos: [SourceInfo]) -> [SourceInfo] {
        infos.map { var s = $0; s.snippet = String(s.snippet.prefix(snippetLimit)); return s }
    }

    /// The conversation's list, plus every source a call numbered that the list lacks (the conversation's own copy
    /// wins for an id it has). A turn numbers from here, so a new id never repeats one already in a message.
    static func merged(_ list: [SourceInfo], calls: some Sequence<ToolCallRecord>) -> [SourceInfo] {
        var known = Set(list.map(\.id))
        var out = list
        for call in calls {
            for info in call.sources ?? [] where known.insert(info.id).inserted { out.append(info) }
        }
        return out
    }

    /// The citations one message reads: `base`, with the sources its own calls numbered on top. Where devices numbered
    /// different pages alike, the message's own numbering is the one its text meant.
    static func overlay(_ base: [Int: SourceInfo], calls: some Sequence<ToolCallRecord>) -> [Int: SourceInfo] {
        var out = base
        for call in calls { for info in call.sources ?? [] { out[info.id] = info } }
        return out
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
        var candidate = candidate
        candidate.title = PageMetadata.capped(candidate.title) // it goes back to the model in every <source title>
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
    You are an AI assistant in OmniChat, a chat app.

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
    - Tool calls in one reply run in parallel. When you need several searches or pages that don't depend on each other, request them all in the same reply instead of one at a time. Call tools one after another only when a call needs an earlier result.
    """

    static let python = """
    - For anything beyond simple arithmetic, calculate with run_python instead of in your head.
    - To show a figure run_python saved, put ![short caption](figure-N) on its own line where it belongs in your reply.
    """

    /// When to offer `save_skill` on your own: after hard-won work that is likely to come back, once, in one line.
    static let skillOffer = """
    - When a task took real work to figure out (several failed tries before one worked, the user correcting your approach, a site that needed a special script) and the user is likely to ask for something like it again, end your reply with one short line offering to save what worked as a skill, so next time is faster. Write the skill with save_skill only after the user says yes.
    - Don't offer for one-off questions, for tasks that worked on the first try, or again in a chat where the user declined. If a loaded skill was wrong or incomplete, offer to update it instead.
    """

    /// When to read a video's transcript.
    static let video = """
    - When the user shares a YouTube link or asks what is said in a video, read it with video_transcript (web_fetch can't). Point to moments by their [mm:ss] timestamps, and say so when the captions are auto-generated and a word or name may be misheard.
    """

    /// Driving the browser with the index tools; rules adapted from browser-use (MIT).
    static let browser = """
    - In the browser, act on pages with the index tools: browser_click, browser_type, browser_select and browser_scroll take an [index] from the latest page state, and each returns the new state. Use only indices from the latest state.
    - Close pop-ups, cookie banners and overlays first if they cover the page.
    - For a search box with suggestions, type, then click the suggestion marked *[n] instead of submitting.
    - To find specific text, use browser_find rather than scrolling.
    - Don't repeat an action that failed more than 2 or 3 times; try another way. If you're stuck, or a page needs a sign-in or the user's decision, use browser_show. Robot checks are handed to the user automatically; never say you solved one.
    """

    /// The SSH tools: what they are for, long jobs in the background, and keeping what the user gives.
    static let ssh = """
    - The ssh_ tools run commands and move files on the user's servers. Use a saved server by name (ssh_server_list), or pass host, user and a password or private key. When the user gives you a password, a key or a server, save it with ssh_credential_save or ssh_server_save so later chats can use it by name.
    - Each ssh_exec is a new connection that drops when the app goes to the background. Start anything that may take more than a minute with nohup or in tmux, writing to a log file, and check on it with later calls.
    """

    /// The app prompt for a model with (or without) tools, with `run_python` offered or not, with the browser's index
    /// tools offered or not, with skills (`save_skill`) offered or not, with `video_transcript` offered or not, with
    /// the SSH tools offered or not, with Apple Health (`health_query`, `HealthTool.swift`) or not, and with interactive
    /// views (`views`, `OpenUIPrompt.swift`) or not.
    static func text(tools: Bool, python: Bool, browser: Bool = false, skills: Bool = false, video: Bool = false,
                     ssh: Bool = false, health: Bool = false, views: Bool = false) -> String {
        // Views need no tools: a model without them still writes `openui` blocks.
        guard tools else { return base + (views ? "\n\n" + Self.views : "") }
        return base + "\n\n" + Self.tools + (python ? "\n" + Self.python : "") + (browser ? "\n" + Self.browser : "")
            + (skills ? "\n" + Self.skillOffer : "") + (video ? "\n" + Self.video : "") + (ssh ? "\n" + Self.ssh : "")
            + (health ? "\n" + Self.health : "") + (views ? "\n\n" + Self.views : "")
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
