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
    /// Why a failed call failed, from its result text.
    var failure: FetchFailure?
    /// The plugin a `run_plugin` call ran (its row is the plugin's page, titled with the plugin's name).
    var plugin: String?
    /// The tool, when it is not a search or a page read: `run_python` (its own card with code and output),
    /// `view_image`, or a browser tool (`ToolNames.hasOwnCard`).
    var tool: String?
    /// A Python run's output as the model read it (empty while it runs).
    var output = ""
    var figures: [ToolImage] = []
    var viewedImage: ToolImage?
    /// What a `show_places` call put on the map.
    var places: PlaceCollection?
    /// The artifact a `show_html` call saved.
    var artifact: ArtifactRef?

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
        if record.isError { failure = FetchFailure(errorText: record.result) }
        if record.name == ToolNames.runPlugin { plugin = PluginCall.name(in: record.arguments) }
        if ToolNames.hasOwnCard(record.name) {
            tool = record.name
            output = record.result
            figures = record.figures ?? []
            viewedImage = record.viewedImage
            places = record.places
            artifact = record.artifact
        }
    }

    init(pending: PendingToolCall) {
        self.init(id: pending.id, isSearch: pending.name == ToolNames.webSearch, argument: pending.primaryArgument, status: .running)
        plugin = pending.plugin
        if ToolNames.hasOwnCard(pending.name) { tool = pending.name }
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
    /// When the first read of this page started (the call's place in the turn): read rows are listed in this order.
    var readOrder: Int?
    /// Set while `read` is `.failed`: the short reason shown in place of the domain.
    var failure: FetchFailure?
}

/// Why a Python run failed, from its result text, for a short label like a page read's.
enum PythonFailure: Equatable, Sendable {
    case timedOut, outOfMemory, exception, failed

    init(errorText: String) {
        let t = errorText.lowercased()
        if t.contains("timed out after") { self = .timedOut }
        else if t.contains("out of memory") { self = .outOfMemory }
        else if t.contains("could not run") || t.hasPrefix("error: ") { self = .failed }
        else { self = .exception }
    }

    var label: String {
        switch self {
        case .timedOut: String(localized: "Timed out")
        case .outOfMemory: String(localized: "Out of memory")
        case .exception: String(localized: "Error")
        case .failed: String(localized: "Failed")
        }
    }
}

/// Why a page could not be read, from the tool's error text, for a short label on the row.
enum FetchFailure: Equatable, Sendable {
    case timedOut, blocked, certificate, noText, failed

    init(errorText: String) {
        let t = errorText.lowercased()
        if t.contains("timed out") || t.contains("took too long") { self = .timedOut }
        else if t.contains("certificate") { self = .certificate }
        else if t.contains("no readable text") { self = .noText }
        else if ["blocked", "not allowed", "challenge", "captcha", "403", "forbidden", "denied", "private"].contains(where: t.contains) {
            self = .blocked
        } else { self = .failed }
    }

    var label: String {
        switch self {
        case .timedOut: String(localized: "Timed out")
        case .blocked: String(localized: "Blocked")
        case .certificate: String(localized: "Bad certificate")
        case .noText: String(localized: "No text")
        case .failed: String(localized: "Failed")
        }
    }
}

struct FeedCard: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case search(query: String)
        /// Pages read: one card per run of consecutive reads, wherever the links came from.
        case pages
        /// One `run_python` call.
        case python(code: String)
        /// One `view_image` call.
        case image(id: String)
        /// One `browser_open` call: the page it opened.
        case browser(url: String)
        /// One `browser_eval` call: the script it ran.
        case script(code: String)
        /// A one-line card for a call with nothing to unfold (`load_skill`, ...): the tool and its argument.
        case note(tool: String, argument: String)
        /// One `show_places` call: the map and the place cards.
        case places
        /// One `show_html` call: the artifact's title; a tap opens the page.
        case artifact(title: String)
    }

    var id: String
    var kind: Kind
    var engine: String?
    /// The search is still running.
    var isRunning = false
    var isError = false
    var results: [FeedRow] = []
    /// The pages of a `.pages` card.
    var extras: [FeedRow] = []
    /// A `.python` card's output and figures, a `.image` card's image, and why either failed.
    var output = ""
    var figures: [ToolImage] = []
    var pythonFailure: PythonFailure?
    /// Why a `.browser` card's page could not be opened.
    var pageFailure: FetchFailure?
    /// A `.places` card's places.
    var places: PlaceCollection?
    /// An `.artifact` card's artifact (nil while it is written, or when it failed).
    var artifact: ArtifactRef?

    var rows: [FeedRow] { results + extras }
    var hasLoadingRow: Bool { rows.contains { if case .loading? = $0.read { return true } else { return false } } }
    /// Pages read successfully (or with little content).
    var readCount: Int { rows.filter { $0.read == .read || $0.read == .thin }.count }
    var failedCount: Int { rows.filter { $0.read == .failed }.count }

    /// Results shown before "+N more".
    static let initialRows = 5

    /// Folded: the first `initialRows` results. Expanded: every result.
    func visibleResults(expanded: Bool) -> [FeedRow] {
        expanded ? results : Array(results.prefix(Self.initialRows))
    }

    func hiddenCount(expanded: Bool) -> Int { results.count - visibleResults(expanded: expanded).count }
}

enum ActivityFeed {
    /// The cards for a turn's calls, in call order.
    static func cards(calls: [FeedCall], sources: [Int: SourceInfo]) -> [FeedCard] {
        var cards: [FeedCard] = []
        var readRun = false // the previous call was a read
        for (order, call) in calls.enumerated() {
            if let tool = call.tool {
                readRun = false
                let kind: FeedCard.Kind = switch tool {
                case ToolNames.runPython: .python(code: call.argument)
                case ToolNames.browserOpen: .browser(url: call.argument)
                case ToolNames.browserEval: .script(code: call.argument)
                case ToolNames.viewImage: .image(id: call.argument)
                case ToolNames.showPlaces: .places
                case ToolNames.showHTML: .artifact(title: call.argument)
                default: .note(tool: tool, argument: call.argument)
                }
                var card = FeedCard(id: call.id, kind: kind, isRunning: call.status == .running, isError: call.status == .failed)
                card.output = call.output
                card.places = call.places
                card.artifact = call.artifact
                card.figures = tool == ToolNames.runPython ? call.figures : (call.viewedImage.map { [$0] } ?? [])
                if call.status == .failed {
                    if tool == ToolNames.browserOpen { card.pageFailure = call.failure ?? .failed }
                    else { card.pythonFailure = PythonFailure(errorText: call.output) }
                }
                cards.append(card)
            } else if call.isSearch {
                readRun = false
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
                attach(fetch: call, order: order, to: &cards, continuingRun: readRun, sources: sources)
                readRun = true
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

    /// Adds a read to the feed's "Read pages" card: one card per run of consecutive reads (a parallel batch is one run),
    /// in call order, so the feed only grows at the bottom and search cards never change. Reading the same page again
    /// within the run (a retry, or reading on) updates its row.
    private static func attach(fetch call: FeedCall, order: Int, to cards: inout [FeedCard], continuingRun: Bool,
                               sources: [Int: SourceInfo]) {
        let page = call.sourceIDs.first.flatMap { sources[$0] }
        var keys = [FeedURL.key(call.argument)]
        if let page { keys.append(FeedURL.key(page.url)) } // the page's own URL, after redirects
        let state = readState(call)
        if continuingRun, let c = cards.indices.last, cards[c].kind == .pages,
           let r = cards[c].extras.firstIndex(where: { keys.contains($0.id) }) {
            cards[c].extras[r].read = cards[c].extras[r].read.map { $0.merged(with: state) } ?? state
            cards[c].extras[r].failure = cards[c].extras[r].read == .failed ? call.failure : nil
            return
        }
        // Until the page's own source arrives, a search result listing the link gives the row its title.
        let listed = cards.reversed().lazy.flatMap(\.results).first { keys.contains($0.id) }
        let url = page?.url ?? call.argument
        let host = SourceInfo(id: 0, title: "", url: url, snippet: "").host
        var title = page.map { $0.title.isEmpty ? $0.host : $0.title } ?? listed?.title ?? host
        if let plugin = call.plugin, !plugin.isEmpty { title = page.map { $0.title.isEmpty || $0.title == plugin ? plugin : plugin + " · " + $0.title } ?? plugin }
        let row = FeedRow(id: keys[0], title: title, host: host, url: url,
                          read: state, readOrder: order, failure: state == .failed ? call.failure : nil)
        if !continuingRun || cards.last?.kind != .pages { cards.append(FeedCard(id: "pages-" + call.id, kind: .pages)) }
        cards[cards.count - 1].extras.append(row)
    }
}

/// Which cards are folded to their header line.
enum FeedCollapse {
    /// The state the feed picks by itself:
    /// - everything is folded once the answer is being written, and in a finished message;
    /// - while working, the newest card is open and older ones fold, except one whose page is still loading;
    /// - a search never opens by itself: what it found matters less than the answer (a tap shows it).
    static func autoCollapsed(index: Int, cards: [FeedCard], isStreaming: Bool, answerStarted: Bool) -> Bool {
        guard isStreaming, !answerStarted else { return true }
        guard cards.indices.contains(index) else { return true }
        if case .search = cards[index].kind { return true }
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
