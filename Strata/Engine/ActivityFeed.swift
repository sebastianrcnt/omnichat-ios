import Foundation

// The in-chat activity feed: one card per web_search, with the pages the model read attached to the result rows they
// came from. Pure values, built from the turn's tool calls on every render; nothing here is sent to the API.

/// How a page read turned out, from the `web_fetch` result. The thresholds live here and nowhere else.
enum FetchOutcome {
    /// Fewer characters than this and the page counts as "little content".
    static let thinCharacters = 300
    /// Bot-check and consent-wall phrases are only looked for in pages shorter than this (a long article may mention them).
    static let challengeScanLimit = 3_000
    static let challengePhrases = [
        "verify you are human", "are you a robot", "are you human", "captcha", "checking your browser",
        "just a moment", "enable javascript", "access denied", "accept all cookies", "cookie consent",
        "자동입력 방지", "로봇이 아닙니다",
    ]

    /// The page's total length, from the footer `web_fetch` puts after each slice:
    /// `[End of page, N characters total.]` or `[Showing characters a–b of N. ...]`.
    static func totalCharacters(in result: String) -> Int? {
        let patterns = [#"\[End of page, (\d+) characters total\.\]"#, #"\[Showing characters \d+\D\d+ of (\d+)\."#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = result as NSString
            if let match = regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).last,
               let n = Int(ns.substring(with: match.range(at: 1))) {
                return n
            }
        }
        return nil
    }

    /// Loaded, but almost empty or a challenge page.
    static func isThin(result: String, characters: Int?) -> Bool {
        let count = characters ?? result.count
        if count < thinCharacters { return true }
        guard count < challengeScanLimit else { return false }
        let lower = result.lowercased()
        return challengePhrases.contains { lower.contains($0) }
    }
}

/// URL matching between a page the model read and a search result row.
enum FeedURL {
    /// Scheme, `www.`/`m.`, a trailing slash, the fragment, percent-encoding and `utm_` parameters do not matter.
    static func key(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed) ?? URL(string: trimmed).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              var host = comps.host?.lowercased(), !host.isEmpty else {
            return trimmed.lowercased()
        }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) && host.count > prefix.count + 3 { host.removeFirst(prefix.count) }
        var path = comps.percentEncodedPath.removingPercentEncoding ?? comps.path
        while path.hasSuffix("/") { path.removeLast() }
        let query = (comps.percentEncodedQuery ?? "").split(separator: "&")
            .filter { !$0.lowercased().hasPrefix("utm_") }
            .map { $0.removingPercentEncoding ?? String($0) }
            .joined(separator: "&")
        return host + path + (query.isEmpty ? "" : "?" + query)
    }
}

/// One tool call of the turn, finished or running, as the feed needs it.
struct FeedCall: Equatable, Sendable {
    enum Status: Equatable, Sendable { case running, done, failed }

    var id: String
    var isSearch: Bool
    /// The query or the URL.
    var argument: String
    var status: Status
    var sourceIDs: [Int] = []
    var engine: String?
    var thin = false

    init(id: String, isSearch: Bool, argument: String, status: Status, sourceIDs: [Int] = [], engine: String? = nil, thin: Bool = false) {
        self.id = id
        self.isSearch = isSearch
        self.argument = argument
        self.status = status
        self.sourceIDs = sourceIDs
        self.engine = engine
        self.thin = thin
    }

    init(record: ToolCallRecord) {
        self.init(id: record.id, isSearch: record.name == ToolNames.webSearch, argument: record.primaryArgument,
                  status: record.isError ? .failed : .done, sourceIDs: record.sourceIDs,
                  engine: record.name == ToolNames.webSearch ? record.searchEngine : nil,
                  thin: record.name == ToolNames.webFetch && record.isThinPage)
    }

    init(pending: PendingToolCall) {
        self.init(id: pending.id, isSearch: pending.name == ToolNames.webSearch, argument: pending.primaryArgument, status: .running)
    }

    /// Finished rounds, then the running round in request order (a finished call keeps its place); each id once.
    static func ordered(finished: [ToolCallRecord], requested: [PendingToolCall], roundFinished: [ToolCallRecord]) -> [FeedCall] {
        var seen = Set<String>()
        var out: [FeedCall] = []
        for record in finished where seen.insert(record.id).inserted { out.append(FeedCall(record: record)) }
        let done = Dictionary(roundFinished.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for call in requested where seen.insert(call.id).inserted {
            out.append(done[call.id].map(FeedCall.init(record:)) ?? FeedCall(pending: call))
        }
        // Finished calls of the running round that were never listed as requested (a restored round).
        for record in roundFinished where seen.insert(record.id).inserted { out.append(FeedCall(record: record)) }
        return out
    }
}

/// What happened when the model read a row's page.
enum FeedRead: Equatable, Sendable {
    case loading(callID: String)
    case read
    /// Loaded, but little real content (see `FetchOutcome`).
    case thin
    case failed

    /// A later read of the same page (a retry, or reading on) updates the row; a failure never hides an earlier success.
    func merged(with newer: FeedRead) -> FeedRead {
        switch newer {
        case .loading: return newer
        case .read: return .read
        case .thin: return self == .read ? .read : .thin
        case .failed:
            if case .loading = self { return .failed }
            return self == .read || self == .thin ? self : .failed
        }
    }

    var isFinished: Bool { if case .loading = self { return false } else { return true } }
}

struct FeedRow: Identifiable, Equatable, Sendable {
    /// `FeedURL.key` of the page: unique within a card.
    var id: String
    var title: String
    var host: String
    var url: String
    /// Nil until the model reads the page.
    var read: FeedRead?
}

struct FeedCard: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case search(query: String)
        /// Pages read before any search ("Read").
        case pages
    }

    var id: String
    var kind: Kind
    var engine: String?
    /// The search is still running.
    var isRunning = false
    var isError = false
    var results: [FeedRow] = []
    /// Pages read that were not among the results.
    var extras: [FeedRow] = []

    var rows: [FeedRow] { results + extras }
    var hasLoadingRow: Bool { rows.contains { if case .loading? = $0.read { return true } else { return false } } }
    /// Pages read successfully (or with little content).
    var readCount: Int { rows.filter { $0.read == .read || $0.read == .thin }.count }

    /// How many rows show before "+N more": the first `initialRows` results, plus any read beyond them.
    static let initialRows = 5

    func visibleResults(expanded: Bool) -> [FeedRow] {
        guard !expanded else { return results }
        return results.enumerated().filter { $0.offset < Self.initialRows || $0.element.read != nil }.map(\.element)
    }

    func hiddenCount(expanded: Bool) -> Int { results.count - visibleResults(expanded: expanded).count }
}

enum ActivityFeed {
    /// The cards for a turn's calls, in call order.
    static func cards(calls: [FeedCall], sources: [Int: SourceInfo]) -> [FeedCard] {
        var cards: [FeedCard] = []
        for call in calls {
            if call.isSearch {
                var card = FeedCard(id: call.id, kind: .search(query: call.argument), engine: call.engine,
                                    isRunning: call.status == .running, isError: call.status == .failed)
                var seen = Set<String>()
                for info in call.sourceIDs.compactMap({ sources[$0] }) {
                    let key = FeedURL.key(info.url)
                    guard seen.insert(key).inserted else { continue }
                    card.results.append(FeedRow(id: key, title: info.title.isEmpty ? info.host : info.title,
                                                host: info.host, url: info.url))
                }
                cards.append(card)
            } else {
                attach(fetch: call, to: &cards, sources: sources)
            }
        }
        return cards
    }

    private static func readState(_ call: FeedCall) -> FeedRead {
        switch call.status {
        case .running: .loading(callID: call.id)
        case .failed: .failed
        case .done: call.thin ? .thin : .read
        }
    }

    private static func attach(fetch call: FeedCall, to cards: inout [FeedCard], sources: [Int: SourceInfo]) {
        let page = call.sourceIDs.first.flatMap { sources[$0] }
        var keys = [FeedURL.key(call.argument)]
        if let page { keys.append(FeedURL.key(page.url)) } // the page's own URL, after redirects
        let state = readState(call)
        // The newest card holding the page, among its results first, then the pages appended to it.
        for c in cards.indices.reversed() {
            if let r = cards[c].results.firstIndex(where: { keys.contains($0.id) }) {
                cards[c].results[r].read = cards[c].results[r].read.map { $0.merged(with: state) } ?? state
                return
            }
            if let r = cards[c].extras.firstIndex(where: { keys.contains($0.id) }) {
                cards[c].extras[r].read = cards[c].extras[r].read.map { $0.merged(with: state) } ?? state
                return
            }
        }
        let url = page?.url ?? call.argument
        let host = SourceInfo(id: 0, title: "", url: url, snippet: "").host
        let row = FeedRow(id: keys[0], title: page.map { $0.title.isEmpty ? $0.host : $0.title } ?? host, host: host, url: url, read: state)
        if cards.isEmpty { cards.append(FeedCard(id: "pages-" + call.id, kind: .pages)) }
        cards[cards.count - 1].extras.append(row)
    }
}

/// Which cards are folded to their header line.
enum FeedCollapse {
    /// The state the feed picks by itself:
    /// - everything is folded once the answer is being written, and in a finished message;
    /// - while working, the newest card is open and older ones fold, except one whose page is still loading.
    static func autoCollapsed(index: Int, cards: [FeedCard], isStreaming: Bool, answerStarted: Bool) -> Bool {
        guard isStreaming, !answerStarted else { return true }
        guard cards.indices.contains(index) else { return true }
        if index == cards.count - 1 { return false }
        return !cards[index].hasLoadingRow
    }

    /// A tap that opened or folded a card. It holds until the feed moves on: a new card, or the answer starting.
    struct Override: Equatable, Sendable {
        var collapsed: Bool
        var epoch: Int
    }

    /// Changes whenever the feed folds cards by itself: with each new card while working, and once when the answer
    /// starts (a finished message is in the same epoch, so a card opened while the answer streams stays open).
    static func epoch(cardCount: Int, isStreaming: Bool, answerStarted: Bool) -> Int {
        isStreaming && !answerStarted ? cardCount : -1
    }

    static func isCollapsed(auto: Bool, override: Override?, epoch: Int) -> Bool {
        guard let override, override.epoch == epoch else { return auto }
        return override.collapsed
    }

    /// The override after a tap on a card currently shown `current` (collapsed or not).
    static func toggled(auto: Bool, current: Bool, epoch: Int) -> Override? {
        let wanted = !current
        return wanted == auto ? nil : Override(collapsed: wanted, epoch: epoch)
    }
}
