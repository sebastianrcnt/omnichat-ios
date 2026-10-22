import Foundation

// `browser_open` and `browser_eval`: a hidden browser the model drives itself. One page per conversation, in a web view
// on the app's own browser store (`BrowserData`; never Safari's cookies), guarded navigations like a fetch, a
// mobile Safari user agent, and no script message handlers: model JavaScript runs in the page and can reach nothing of
// the app's.

/// What the browser tools need of a page, so they can be tested with a fake.
@MainActor
protocol BrowserPage: PluginPage {
    /// Runs a function body in the index tools' isolated content world (`BrowserAgentScript`), with `input` as its
    /// `input` argument, and returns its string result.
    func callAgent(_ body: String, input: String, timeout: Duration) async throws -> String
    /// A navigation is under way.
    var isLoading: Bool { get }
    /// What the view shows, as a PNG at most `width` pixels wide.
    func snapshotPNG(width: Int) async throws -> Data
    /// For a moment, a link or script that opens a new window opens in this page instead (after a click).
    func acceptPopups(for duration: Duration)
    /// Takes the focus back from the page if a script focused a field in it while it is hidden (iOS would raise the
    /// keyboard over the app and send the user's typing to the page).
    func releaseFocus()
    /// Shown in a sheet or a card now.
    var isOnScreen: Bool { get }
    /// Parked out of the window after a reply, so WebKit suspends the page (`HiddenWebView.freeze`).
    var isFrozen: Bool { get }
    func freeze()
    /// Back in the window before the page is used.
    func thaw()
    /// Replaces the document if a script call on it was cut short (its timers and promises keep running otherwise).
    /// True when it did.
    func discardAbortedScript() async -> Bool
}

extension BrowserPage {
    func callAgent(_ body: String, input: String, timeout: Duration) async throws -> String {
        throw WebToolError.script("this page can't run the index tools.")
    }
    var isLoading: Bool { false }
    func snapshotPNG(width: Int) async throws -> Data { throw WebToolError.script("this page can't take screenshots.") }
    func acceptPopups(for duration: Duration) {}
    func releaseFocus() {}
    func discardAbortedScript() async -> Bool { false }
    var isOnScreen: Bool { false }
    var isFrozen: Bool { false }
    func freeze() {}
    func thaw() {}
}

extension HiddenWebView: BrowserPage {}

/// Caps the text the model reads, saying how much was left out.
enum BrowserText {
    /// The page text, whitespace-normalized and cut to `limit` characters, with a note when it was cut.
    static func capped(_ raw: String, limit: Int) -> (text: String, total: Int) {
        let full = PageTextFormatter.normalizeFull(raw)
        let total = full.count
        guard total > limit else { return (full, total) }
        return (String(full.prefix(limit)) + "\n\n" + truncationNote(shown: limit, total: total), total)
    }

    static func truncationNote(shown: Int, total: Int) -> String {
        "[Truncated: showing the first \(shown) of \(total) characters. Use browser_eval to read specific parts of the page.]"
    }

    /// A `browser_eval` result cut to `limit` characters (`total` is its full length, measured in the page).
    static func cappedResult(_ body: String, total: Int, limit: Int) -> String {
        guard total > limit || body.count > limit else { return body }
        let shown = min(limit, body.count)
        return String(body.prefix(shown)) + "\n\n[Truncated: the result has \(max(total, body.count)) characters; showing the first \(shown). Return less, for example a slice or only the fields you need.]"
    }
}

/// When a page counts as rendered: the document is parsed, the DOM has been quiet for a moment and no resource has
/// finished loading just now. Pages that never settle are read when the time limit runs out.
enum BrowserSettle {
    static let domQuiet = 700.0
    static let networkQuiet = 500.0
    static let pollInterval: Duration = .milliseconds(150)
    /// The longest a page is waited for before it is read as it is.
    static let limit: Duration = .seconds(12)

    /// Installs a mutation observer once per document and reports how long the DOM and the network have been quiet.
    static let probe = """
    (function() {
      var w = window;
      if (!w.__strataSettle) {
        w.__strataSettle = { last: Date.now() };
        try {
          new MutationObserver(function() { w.__strataSettle.last = Date.now(); })
            .observe(document.documentElement, { subtree: true, childList: true, characterData: true, attributes: false });
        } catch (e) {}
      }
      var lastResource = 0;
      try { performance.getEntriesByType("resource").forEach(function(r) { lastResource = Math.max(lastResource, r.responseEnd); }); } catch (e) {}
      return JSON.stringify({ href: String(location.href), ready: document.readyState, stale: !!w.__strataStale,
                              domQuiet: Date.now() - w.__strataSettle.last, netQuiet: performance.now() - lastResource,
                              text: document.body ? document.body.innerText.length : 0 });
    })()
    """

    /// Marks the page showing before a navigation, so the probe can tell it from the page being opened.
    static let markStale = "window.__strataStale = true; \"\""

    struct Probe: Decodable, Equatable, Sendable {
        var href: String
        var ready: String
        /// The page from before the navigation is still showing.
        var stale: Bool?
        var domQuiet: Double
        var netQuiet: Double
        var text: Int

        var committed: Bool { !href.isEmpty && !href.lowercased().hasPrefix("about:") && stale != true }

        var isSettled: Bool {
            committed && ready != "loading" && text > 0 && domQuiet >= BrowserSettle.domQuiet && netQuiet >= BrowserSettle.networkQuiet
        }

        static func decode(_ json: String) -> Probe? { try? JSONDecoder().decode(Probe.self, from: Data(json.utf8)) }
    }

    /// The page's visible text, title and URL, cut in the page so nothing huge is copied across.
    static func extraction(maxCharacters: Int) -> String {
        """
        (function() {
          var t = document.body ? document.body.innerText : "";
          return JSON.stringify({ title: (document.title || "").slice(0, \(PageMetadata.titleLimit)), url: String(location.href), text: (t || "").slice(0, \(maxCharacters)) });
        })()
        """
    }

    struct Extracted: Decodable, Sendable { var title: String; var url: String; var text: String }
}

enum BrowserScript {
    /// A function body for `callAsyncJavaScript`: runs the model's code (which may `await` and `return`) and returns one
    /// JSON string. A string result is passed as is; anything else is JSON-serialized. Cut to `maxCharacters` in the page.
    static func invocation(_ code: String, maxCharacters: Int) -> String {
        """
        const __strataCap = \(maxCharacters);
        let __strataValue;
        try {
          __strataValue = await (async () => {
        \(code)
          })();
        } catch (e) {
          return JSON.stringify({ error: String((e && (e.stack || e.message)) || e), url: String(location.href) });
        }
        let __strataBody;
        if (__strataValue === undefined) __strataBody = "undefined (use return to send a value back)";
        else if (typeof __strataValue === "string") __strataBody = __strataValue;
        else { try { __strataBody = JSON.stringify(__strataValue, null, 1); } catch (e) { __strataBody = String(__strataValue); } }
        if (__strataBody === undefined) __strataBody = String(__strataValue);
        return JSON.stringify({ body: __strataBody.slice(0, __strataCap), total: __strataBody.length, url: String(location.href) });
        """
    }

    struct Result: Decodable, Sendable {
        var body: String?
        var total: Int?
        var url: String?
        var error: String?
    }

    /// The model's text for the invocation's JSON.
    static func format(json: String, limit: Int) -> ToolOutput {
        guard let r = try? JSONDecoder().decode(Result.self, from: Data(json.utf8)) else {
            return ToolOutput(text: "Error: the script returned something that is not JSON.", isError: true)
        }
        let header = r.url.map { "URL: \($0)\n\n" } ?? ""
        if let error = r.error { return ToolOutput(text: header + "Error: the script threw: \(error)", isError: true) }
        let body = r.body ?? ""
        return ToolOutput(text: header + BrowserText.cappedResult(body, total: r.total ?? body.count, limit: limit))
    }

    /// The page URL a `browser_eval` result starts with (display only).
    static func url(inResult result: String) -> String? {
        guard result.hasPrefix("URL: "), let end = result.firstIndex(of: "\n") else { return nil }
        return String(result[result.index(result.startIndex, offsetBy: 5)..<end])
    }
}

/// One browser page per conversation. Calls on it run one at a time (a round may ask for several). While a reply runs,
/// the user can watch the page (`BrowserWatch`), stop the browser for the rest of the reply, or take the page over:
/// calls wait until they hand it back.
///
/// When the reply ends the page is kept, frozen (`HiddenWebView.freeze`: out of the window, so WebKit suspends it), for
/// the next reply and for the feed's "Open page"; the next call thaws it. A page left alone for `idleLifetime` is torn
/// down, at most `maxSessions` conversations keep one (a new one closes the least recently used), and a memory warning
/// closes them all. A closed page's last URL is remembered for "Reopen" (in memory only).
@MainActor
@Observable
final class BrowserSessions {
    static let shared: BrowserSessions = {
        let sessions = BrowserSessions()
        MemoryPurge.register { sessions.closeAll() }
        return sessions
    }()

    @ObservationIgnored var idleLifetime: Duration = .seconds(1800)
    /// The most conversations that keep a page.
    @ObservationIgnored var maxSessions = 3
    /// The most conversations whose browser calls run at once; another chat's call waits for one of them to finish
    /// (in order of arrival). Below `maxSessions`, so a new page can always close an idle one to make room.
    static let maxActiveConversations = 2
    var maxActiveConversations: Int {
        get { slots.capacity }
        set { slots.capacity = newValue }
    }
    private let slots = FairSlots(capacity: BrowserSessions.maxActiveConversations)
    /// The idle sweep's and the LRU's clock. Test seam.
    @ObservationIgnored var clock: @MainActor () -> ContinuousClock.Instant = { .now }
    /// Makes the page of a new session. Test seam; by default a hidden web view.
    @ObservationIgnored var makePage: @MainActor () -> any BrowserPage = { HiddenWebView(guardNavigations: true, store: BrowserData.store) }

    @MainActor
    final class Session {
        let page: any BrowserPage
        var lastUsed = ContinuousClock.now
        /// The call that runs last; the next one waits for it.
        fileprivate var tail: Task<Void, Never>?
        /// A page was opened in this session.
        var hasPage = false
        /// Calls running now; the idle sweep leaves a busy session alone (`browser_show` can wait minutes for the user).
        var busy = 0
        /// The user tapped Stop browsing: the reply's further calls return at once. Cleared when the reply ends.
        fileprivate(set) var stopped = false
        /// The user took the page over (Take over): calls wait until they tap Done.
        let hold = HoldGate()
        /// The calls under way, to cancel on Stop browsing.
        fileprivate var running: [UUID: @MainActor () -> Void] = [:]
        /// The last index the index tools handed out on this page: indices never repeat in a session, so one from an
        /// earlier page can't land on an element of the next.
        var agentIndex = 0
        /// The last call's script was cut short and its page replaced: its failure says so.
        fileprivate var pageCleared = false

        init(page: any BrowserPage) { self.page = page }
    }

    @ObservationIgnored private var sessions: [UUID: Session] = [:]
    @ObservationIgnored private var sweeper: Task<Void, Never>?
    /// The session each browser call ran in, by session and call id (call ids are only unique within a request, so
    /// two chats can each have a `call_0`): the feed finds the page of a running call's card here.
    private var callSessions: [ToolProgress.Key: UUID] = [:]
    /// The conversations that have a page now (observed, for the feed's "Open page").
    private(set) var openConversations: Set<UUID> = []
    /// Each conversation's latest browser call: the feed offers its page on the run holding it.
    private(set) var lastCalls: [UUID: String] = [:]
    /// Where each closed page was, for "Reopen".
    private(set) var closedURLs: [UUID: URL] = [:]
    /// Calls without a conversation (tests, the debug hooks) share one session.
    static let defaultKey = UUID(uuidString: "00000000-0000-0000-0000-00000000B0B0")!

    var count: Int { sessions.count }

    func session(for conversation: UUID?) -> Session {
        let key = conversation ?? Self.defaultKey
        if let existing = sessions[key] { existing.lastUsed = clock(); return existing }
        makeRoom()
        let created = Session(page: makePage())
        created.lastUsed = clock()
        sessions[key] = created
        openConversations.insert(key)
        closedURLs[key] = nil
        scheduleSweep()
        return created
    }

    /// Before a new page: over `maxSessions`, the least recently used one that isn't in use or on screen closes.
    private func makeRoom() {
        while sessions.count >= maxSessions,
              let oldest = sessions.filter({ isIdle($0.value) }).min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            close(oldest)
        }
    }

    /// No call runs or waits on it and nobody is looking at it.
    private func isIdle(_ session: Session) -> Bool {
        session.busy == 0 && session.tail == nil && !session.hold.isClosed && !session.page.isOnScreen
    }

    /// The conversation whose latest browser call is one of `callIDs` (a run of the feed). Given the feed's chat, only
    /// that chat's.
    func conversation(lastCallIn callIDs: [String], of conversation: UUID? = nil) -> UUID? {
        if let conversation { return lastCalls[conversation].map(callIDs.contains) == true ? conversation : nil }
        return lastCalls.first { callIDs.contains($0.value) }?.key
    }

    /// The conversation's page, while it has one.
    func page(of conversation: UUID) -> HiddenWebView? {
        openConversations.contains(conversation) ? sessions[conversation]?.page as? HiddenWebView : nil
    }

    /// Where the conversation's closed page was.
    func closedURL(_ conversation: UUID) -> URL? {
        openConversations.contains(conversation) ? nil : closedURLs[conversation]
    }

    /// "Reopen": the conversation's last page, loaded fresh in a new session. Nil when it has a page or none was closed.
    func reopen(_ conversation: UUID) -> (any BrowserPage)? {
        guard !openConversations.contains(conversation), let url = closedURLs[conversation] else { return nil }
        let session = session(for: conversation)
        session.hasPage = true
        let page = session.page
        Task { @MainActor in try? await page.load(url, timeout: FetchTimeouts.current.load) }
        return page
    }

    /// The reply's page came back from the user (Open page, Reopen): frozen again unless a reply is using it.
    func pageReturned(_ conversation: UUID) {
        guard let session = sessions[conversation], session.busy == 0, session.tail == nil else { return }
        session.page.freeze()
    }

    /// The page a browser call of `conversation` used (nil once its session is closed). Without a chat, any call with
    /// that id.
    func page(forCall callID: String, conversation: UUID? = nil) -> HiddenWebView? {
        self.conversation(forCall: callID, conversation: conversation).flatMap { sessions[$0]?.page as? HiddenWebView }
    }

    /// The conversation whose session a browser call used.
    func conversation(forCall callID: String, conversation: UUID? = nil) -> UUID? {
        if let conversation { return callSessions[ToolProgress.Key(conversation: conversation, id: callID)] }
        return callSessions.first { $0.key.id == callID }?.value
    }

    /// The session showing `page`, if it is one's.
    func conversation(showing page: HiddenWebView) -> UUID? {
        sessions.first { $0.value.page === page }?.key
    }

    func existingSession(_ conversation: UUID) -> Session? { sessions[conversation] }

    /// The conversations whose browser calls run now, and the ones waiting for a slot (tests, diagnostics).
    var activeConversations: Set<UUID> { slots.holderKeys }
    var waitingConversations: [UUID] { slots.waitingKeys }

    /// Runs `operation` on the conversation's page once the calls before it are done, once the user handed the page
    /// back if they took it over, and once a browser slot is free (`maxActiveConversations`). After Stop browsing it
    /// throws `BrowserStoppedError` instead.
    func run<T: Sendable>(conversation: UUID?, _ operation: @escaping @MainActor @Sendable (Session) async throws -> T) async throws -> T {
        let key = conversation ?? Self.defaultKey
        let session = session(for: conversation)
        if let callID = ToolContext.callID {
            callSessions[ToolProgress.Key(conversation: key, id: callID)] = key
            lastCalls[key] = callID
        }
        let previous = session.tail
        let id = UUID()
        let slots = slots
        let callID = ToolContext.callID
        let task = Task { @MainActor () -> Result<T, Error> in
            await previous?.value
            do {
                guard !session.stopped else { throw BrowserStoppedError() }
                try await session.hold.wait()
                guard !session.stopped else { throw BrowserStoppedError() }
            } catch {
                return .failure(error)
            }
            // Two other chats are browsing: wait for one of them, and say so on this chat's live line.
            if !slots.admitsNow(key) { ToolWaits.shared.begin(callID, .browser, conversation: conversation) }
            let admitted = await slots.acquire(key)
            ToolWaits.shared.end(callID, conversation: conversation)
            guard admitted else { return .failure(session.stopped ? BrowserStoppedError() : CancellationError()) }
            defer { slots.release(key) }
            guard !session.stopped else { return .failure(BrowserStoppedError()) }
            session.busy += 1
            defer { session.busy -= 1; session.lastUsed = self.clock() }
            session.page.thaw()
            let result: Result<T, Error>
            do { result = .success(try await operation(session)) } catch { result = .failure(error) }
            // A script cut short (time limit, Stop browsing) keeps its timers and promises: the document goes before
            // the next call, or another chat, gets the page's slot.
            session.pageCleared = await session.page.discardAbortedScript()
            return result
        }
        session.running[id] = { task.cancel() }
        let tail = Task { @MainActor in _ = await task.value }
        session.tail = tail
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        session.running[id] = nil
        if session.tail == tail { session.tail = nil } // the last call is done: nothing to wait for
        session.lastUsed = clock()
        // A call Stop browsing cut short says so, whatever error the cut caused inside it.
        if case .failure = result, session.stopped { throw BrowserStoppedError() }
        return try result.get()
    }

    /// Stop browsing: cancels the session's calls under way and makes the rest of the reply's calls return at once,
    /// each with `BrowserStoppedError`. The reply itself goes on.
    func stopBrowsing(_ conversation: UUID) {
        guard let session = sessions[conversation] else { return }
        session.stopped = true
        session.hold.open()
        for cancel in session.running.values { cancel() }
        session.page.stop()
    }

    /// Take over: the user has the page; calls wait until `handBack`.
    func takeOver(_ conversation: UUID) {
        sessions[conversation]?.hold.close()
    }

    func handBack(_ conversation: UUID) {
        sessions[conversation]?.hold.open()
    }

    /// The reply of `conversation` ended: Stop browsing applied to it only, and its page is frozen until the next call.
    /// Other chats' replies keep their pages as they are. Nil: every reply ended.
    func turnEnded(conversation: UUID? = nil) {
        for (key, session) in sessions where conversation == nil || key == conversation {
            session.stopped = false
            if session.busy == 0 { session.page.freeze() }
        }
        callSessions = callSessions.filter { sessions[$0.value] != nil }
    }

    func close(_ conversation: UUID) {
        guard let session = sessions.removeValue(forKey: conversation) else { return }
        callSessions = callSessions.filter { $0.value != conversation }
        remember(session, conversation)
        dispose(session)
    }

    func closeAll() {
        for (key, session) in sessions {
            remember(session, key)
            dispose(session)
        }
        sessions.removeAll()
        openConversations.removeAll()
        callSessions.removeAll()
        sweeper?.cancel()
        sweeper = nil
    }

    /// Tears down the pages left alone for `idleLifetime` (by the clock), unless in use or on screen.
    func sweep() {
        let now = clock()
        for (key, session) in sessions where isIdle(session) && now - session.lastUsed >= idleLifetime {
            close(key)
        }
    }

    private func remember(_ session: Session, _ conversation: UUID) {
        openConversations.remove(conversation)
        if session.hasPage, let url = session.page.currentURL, url.scheme?.hasPrefix("http") == true {
            closedURLs[conversation] = url
        }
    }

    private func dispose(_ session: Session) {
        session.tail?.cancel()
        session.hold.open()
        session.page.stop()
        (session.page as? HiddenWebView)?.dispose()
    }

    private func scheduleSweep() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while let self, !Task.isCancelled, !self.sessions.isEmpty {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self.sweep()
            }
            self?.sweeper = nil
        }
    }
}

/// What a browser call returns after the user tapped Stop browsing.
struct BrowserStoppedError: Error, LocalizedError, Equatable {
    static let message = "The user stopped the browser. Don't use the browser tools again in this reply; answer with what you have."
    var errorDescription: String? { Self.message }
    static var output: ToolOutput { ToolOutput(text: message, isError: true) }
}

/// Holds calls back while the user has the page (Take over). Waiting can be cancelled.
@MainActor
final class HoldGate {
    private(set) var isClosed = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func close() { isClosed = true }

    func open() {
        isClosed = false
        let all = waiters
        waiters.removeAll()
        for waiter in all.values { waiter.resume() }
    }

    /// Returns at once while open.
    func wait() async throws {
        guard isClosed else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                if !isClosed { cont.resume(); return }
                waiters[id] = cont
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }
}

/// `browser_open(url)`: loads the page in the conversation's browser, waits until it has rendered and returns its
/// visible text with the final URL and title.
struct BrowserOpenTool {
    var resolver: any HostResolving = SystemHostResolver()
    /// Characters of page text returned (Settings > Fetch length, as for `web_fetch`).
    var limit: Int = AppSettings.currentFetchLength
    var timeouts = FetchTimeouts.current
    var settleLimit = BrowserSettle.limit
    var sessions: BrowserSessions?
    /// Looks for a robot check once the page has rendered. Test seam; by default `RobotCheckGate` for a hidden view.
    var robotCheck: (@MainActor (any BrowserPage, FetchTimeouts) async throws -> Bool)?

    @MainActor
    func run(urlString: String, conversation: UUID?) async -> ToolOutput {
        let started = ContinuousClock.now
        let url: URL
        do {
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: trimmed) else { throw URLGuardError.invalidURL }
            // Under the overall limit and cancellable: a DNS server that stops answering must not hold the reply (the
            // system resolver can't be interrupted, so it is left behind).
            try await Deadline.run(timeouts.overall) { [resolver] in try await URLGuard.validate(parsed, resolver: resolver) }
            try Task.checkCancellation()
            url = parsed
        } catch is CancellationError {
            return ToolOutput(text: "Error: cancelled.", isError: true)
        } catch WebToolError.timeout {
            let text = WebToolError.timeoutMessage(after: ContinuousClock.now - started, limit: timeouts.overall, what: "looking up the address")
            return ToolOutput(text: "Error: \(text)", isError: true)
        } catch {
            return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
        }
        let callID = ToolContext.callID
        let report: @MainActor (Double) -> Void = { value in if let callID { ToolProgress.shared.report(callID, value) } }
        let overall = timeouts.overall
        let settleLimit = min(settleLimit, timeouts.load)
        let limit = limit
        let timeouts = timeouts
        let check = robotCheck ?? BrowserRobotCheck.gate
        let sessions = sessions ?? .shared
        do {
            return try await sessions.run(conversation: conversation) { session in
                try await Deadline.run(overall, onAbort: { session.page.stop() }) {
                    let page = try await Self.open(url, page: session.page, settleLimit: settleLimit, timeouts: timeouts, progress: report,
                                                   check: { _ = try await check(session.page, timeouts) })
                    session.hasPage = true
                    let out = await Task.detached(priority: .userInitiated) { BrowserText.capped(page.text, limit: limit) }.value
                    let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    // The elements in view with their indices, so the model can act without asking for the state.
                    let state = try? await BrowserAgentTool.observe(session, maxCharacters: BrowserAgentTool.openStateCharacters, markNew: false)
                    let trailer = state.map { "Page state (act on an [index] with browser_click, browser_type, browser_select, browser_scroll):\nScroll: \($0.scroll)\n\n\($0.tree)" }
                    let tail = trailer.map { "\n\n" + $0 } ?? ""
                    guard !out.text.isEmpty else {
                        return ToolOutput(text: "Title: \(title)\nURL: \(page.url)\n\n[The page shows no text. It may need a moment more, or the content may be in images or frames; try browser_eval.]" + tail)
                    }
                    return ToolOutput(text: "Title: \(title)\nURL: \(page.url)\n\n" + out.text + tail,
                                      sources: [SourceCandidate(title: title.isEmpty ? page.url : title, url: page.url, content: out.text)],
                                      trailer: trailer)
                }
            }
        } catch is BrowserStoppedError {
            return BrowserStoppedError.output
        } catch is CancellationError {
            return ToolOutput(text: "Error: cancelled.", isError: true)
        } catch WebToolError.timeout {
            let text = WebToolError.timeoutMessage(after: ContinuousClock.now - started, limit: overall, what: "opening the page")
            return sessions.failure(text, conversation: conversation, error: WebToolError.timeout)
        } catch {
            return sessions.failure(error.localizedDescription, conversation: conversation, error: error)
        }
    }

    @MainActor
    private final class LoadState { var result: Result<Void, Error>? }

    /// Loads `url` and polls the page until it settles (or `settleLimit` passes), then reads it. A page that never
    /// finishes loading is read once it is there at all.
    @MainActor
    static func open(_ url: URL, page: some BrowserPage, settleLimit: Duration, timeouts: FetchTimeouts,
                     progress: @escaping @MainActor (Double) -> Void = { _ in },
                     check: @MainActor () async throws -> Void = {}) async throws -> FetchedPage {
        let state = LoadState()
        progress(0)
        if page.currentURL != nil { _ = try? await page.evaluate(BrowserSettle.markStale, timeout: timeouts.probe) }
        page.onProgress = { progress(FetchProgress.loading($0)) }
        defer { page.onProgress = nil }
        Task { @MainActor in
            do { try await page.load(url, timeout: timeouts.load); state.result = .success(()) } catch { state.result = .failure(error) }
        }
        defer { if state.result == nil { page.abandonLoad() } }

        let started = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            switch state.result {
            case .failure(let error as WebToolError) where error == .timeout: break
            case .failure(is CancellationError): break
            case .failure(let error): throw error // a failed navigation, or a redirect the URL guard refused
            default: break
            }
            let seen = (try? await page.evaluate(BrowserSettle.probe, timeout: timeouts.probe)).flatMap(BrowserSettle.Probe.decode)
            if let seen, seen.isSettled { break }
            if ContinuousClock.now - started >= settleLimit {
                guard seen?.committed == true else { throw WebToolError.timeout }
                break
            }
            try await Task.sleep(for: BrowserSettle.pollInterval)
        }
        try await check()
        progress(FetchProgress.extracting)
        let fetched = try await read(page, timeouts: timeouts, fallbackURL: url)
        progress(FetchProgress.done)
        return fetched
    }

    /// The page's visible text, title and URL as it is now.
    @MainActor
    static func read(_ page: some FetchablePage, timeouts: FetchTimeouts, fallbackURL: URL? = nil) async throws -> FetchedPage {
        let json = try await page.evaluate(BrowserSettle.extraction(maxCharacters: FetchPipeline.maxPageCharacters), timeout: timeouts.script)
        guard let e = try? JSONDecoder().decode(BrowserSettle.Extracted.self, from: Data(json.utf8)) else {
            throw WebToolError.script("could not read the page.")
        }
        return FetchedPage(title: e.title, url: e.url.isEmpty ? (page.currentURL ?? fallbackURL)?.absoluteString ?? "" : e.url, text: e.text)
    }
}

/// The robot-check gate of the model's browser: only a real hidden view can be handed to the user.
@MainActor
enum BrowserRobotCheck {
    static let gate: @MainActor (any BrowserPage, FetchTimeouts) async throws -> Bool = { page, timeouts in
        guard let view = page as? HiddenWebView else { return false }
        return try await RobotCheckGate.pass(view, timeouts: timeouts)
    }
}

extension BrowserSessions {
    /// A failed call's result. The page stays open, and the result names it so `browser_show` can hand it to the user
    /// (it is listed in `KeptPages` for the failed row's "Open this page" too).
    func failure(_ message: String, conversation: UUID?, error: Error) -> ToolOutput {
        var text = "Error: " + message
        if let session = existingSession(conversation ?? Self.defaultKey), session.pageCleared {
            session.pageCleared = false
            return ToolOutput(text: text + " The page was closed so the unfinished script can't act on it later; call browser_open to open it again.",
                              isError: true)
        }
        if KeptPages.shouldKeep(after: error), let page = existingSession(conversation ?? Self.defaultKey)?.page as? HiddenWebView,
           page.currentURL?.scheme?.hasPrefix("http") == true {
            KeptPages.shared.keep(page, callID: ToolContext.callID, owned: false)
            if !(error is RobotCheckError) {
                text += " The page stays open as page \"\(page.pageID)\": browser_show can hand it to the user (to pass a check, sign in or close a pop-up)."
            }
        }
        return ToolOutput(text: text, isError: true)
    }
}

/// `browser_eval(js)`: runs the model's JavaScript in the page `browser_open` opened and returns the result.
struct BrowserEvalTool {
    /// Characters of result returned (Settings > Fetch length).
    var limit: Int = AppSettings.currentFetchLength
    /// Scripts may click and wait for what appears.
    var timeout: Duration = .seconds(20)
    var sessions: BrowserSessions?
    /// Looks for a robot check after the script (it may have navigated). Test seam, as for `BrowserOpenTool`.
    var robotCheck: (@MainActor (any BrowserPage, FetchTimeouts) async throws -> Bool)?

    static let maxCodeCharacters = 20_000

    @MainActor
    func run(code: String, conversation: UUID?) async -> ToolOutput {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ToolOutput(text: "Error: the script is empty.", isError: true) }
        guard trimmed.count <= Self.maxCodeCharacters else {
            return ToolOutput(text: "Error: the script is longer than \(Self.maxCodeCharacters) characters.", isError: true)
        }
        let limit = limit
        let timeout = timeout
        let check = robotCheck ?? BrowserRobotCheck.gate
        let sessions = sessions ?? .shared
        do {
            return try await sessions.run(conversation: conversation) { session in
                guard session.hasPage, let current = session.page.currentURL, current.scheme?.hasPrefix("http") == true else {
                    return ToolOutput(text: "Error: no page is open. Call browser_open first.", isError: true)
                }
                let json = try await session.page.callAsync(BrowserScript.invocation(trimmed, maxCharacters: FetchPipeline.maxPageCharacters),
                                                            timeout: timeout)
                var out = await Task.detached(priority: .userInitiated) { BrowserScript.format(json: json, limit: limit) }.value
                if try await check(session.page, .current) {
                    let now = session.page.currentURL?.absoluteString ?? ""
                    out.text += "\n\n[A robot check appeared on the page after the script, and the user solved it. The page is now \(now); run the script again if its result came from the check.]"
                }
                return out
            }
        } catch is BrowserStoppedError {
            return BrowserStoppedError.output
        } catch is CancellationError {
            return ToolOutput(text: "Error: cancelled.", isError: true)
        } catch WebToolError.timeout {
            return sessions.failure("the script did not finish within \(FetchTimeouts.seconds(timeout)).", conversation: conversation,
                                    error: WebToolError.timeout)
        } catch {
            return sessions.failure(error.localizedDescription, conversation: conversation, error: error)
        }
    }
}

/// The browser sheet's requests: a page handed to the user (`browser_show`, a robot check, a failed row's "Open this
/// page"), or the model's page to watch while it works. The chat shows `pending` as a sheet with that same web view.
@MainActor
@Observable
final class BrowserShowRequests {
    static let shared = BrowserShowRequests()

    enum Mode: Equatable {
        /// The user works on the page; Done or Close.
        case handover
        /// The user watches the model's page (`browser_open` session of `conversation`), read-only, with Stop browsing
        /// and Take over.
        case watch(conversation: UUID)
        /// The user has the model's page (a failed row's "Open this page" while the reply runs): its calls wait until
        /// the sheet closes.
        case takenOver(conversation: UUID)
        /// The user browses the model's page after its reply (the feed's "Open page", "Reopen"): touch on, Done or
        /// Close. Calls of a new reply wait meanwhile; closing freezes the page again.
        case browse(conversation: UUID)
    }

    struct Request: Identifiable {
        let id = UUID()
        /// Why the model wants the user there, in its words ("Sign in to X so I can read your feed").
        let reason: String
        let page: HiddenWebView
        var mode: Mode = .handover
        /// The chat whose reply asked (`browser_show`, a robot check); nil for one the user opened from a chat's feed.
        var conversationID: UUID? = ToolContext.conversationID

        /// The chat the sheet belongs to: the one that asked, or the one whose page it shows.
        var owner: UUID? {
            switch mode {
            case .handover: conversationID
            case .watch(let conversation), .takenOver(let conversation), .browse(let conversation): conversation
            }
        }
    }

    private var queue: [(request: Request, answer: CheckedContinuation<Bool, Never>?)] = []

    /// The oldest request, from any chat.
    var pending: Request? { queue.first?.request }

    /// The sheet the chat shows now: its own oldest request (or one that belongs to no chat). Another chat's request
    /// waits until that chat is open.
    func pending(for conversationID: UUID?) -> Request? {
        queue.first { $0.request.owner == nil || $0.request.owner == conversationID }?.request
    }

    /// Waits until the user taps Done (true) or closes the sheet (false). A cancelled turn closes it.
    func ask(_ request: Request) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled { cont.resume(returning: false); return }
                queue.append((request, cont))
            }
        } onCancel: {
            Task { @MainActor in self.answer(request.id, done: false) }
        }
    }

    /// Shows a page nothing waits for (watching, or a failed row's page). One already showing that page isn't added
    /// again.
    func present(_ request: Request) {
        guard !queue.contains(where: { $0.request.page === request.page }) else { return }
        queue.append((request, nil))
    }

    func answer(_ id: UUID, done: Bool) {
        guard let i = queue.firstIndex(where: { $0.request.id == id }) else { return }
        queue.remove(at: i).answer?.resume(returning: done)
    }

    /// Clear browsing data: every sheet closes as if the user closed it, so no page outlives the clearing on screen.
    func closeAll() {
        let closed = queue
        queue.removeAll()
        for entry in closed { entry.answer?.resume(returning: false) }
    }
}

/// `browser_show(reason, page)`: shows a page to the user, so they can sign in, pass a check or do a step only they
/// should do, and returns where the page is when they are done. The page is the one `browser_open` opened last, or one
/// a failed tool kept (`page`, from its result; `KeptPages`), which is read again after Done. Cookies are kept
/// (`BrowserData`).
struct BrowserShowTool {
    var sessions: BrowserSessions?
    /// Pages failed tools kept; nil uses the shared list.
    var kept: KeptPages?
    var ask: @MainActor (BrowserShowRequests.Request) async -> Bool = { await BrowserShowRequests.shared.ask($0) }
    var limit: Int = AppSettings.currentFetchLength

    enum Target {
        case session
        case kept(HiddenWebView)
        case missing(String)
    }

    /// Which page a call means: none named, or the session's own, is the session's page.
    @MainActor
    static func target(pageID raw: String?, session: BrowserSessions.Session, kept: KeptPages) -> Target {
        let id = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if id.isEmpty || id == (session.page as? HiddenWebView)?.pageID { return .session }
        if let page = kept.page(id: id) as? HiddenWebView { return .kept(page) }
        return .missing(id)
    }

    @MainActor
    func run(reason: String, page pageID: String? = nil, conversation: UUID?) async -> ToolOutput {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = ask
        let kept = kept ?? .shared
        let limit = limit
        do {
            return try await (sessions ?? .shared).run(conversation: conversation) { session in
                switch Self.target(pageID: pageID, session: session, kept: kept) {
                case .missing(let id):
                    return ToolOutput(text: "Error: no page \"\(id)\" is open. Pages a failed tool kept close a few minutes after the reply that kept them; open the URL again instead.", isError: true)
                case .kept(let page):
                    page.thaw() // a page kept by an earlier reply is frozen; it is read after Done
                    let done = await ask(BrowserShowRequests.Request(reason: reason, page: page, conversationID: conversation))
                    let place = Self.place(page)
                    guard done else {
                        return ToolOutput(text: "The user closed the page without tapping Done. It is now: \(place). Don't show it again unless they ask; use other sources.", isError: true)
                    }
                    guard let read = try? await BrowserOpenTool.read(page, timeouts: .current) else {
                        return ToolOutput(text: "The user tapped Done. The page is now: \(place), but its text could not be read.")
                    }
                    let out = await Task.detached(priority: .userInitiated) { BrowserText.capped(read.text, limit: limit) }.value
                    let title = read.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    return ToolOutput(text: "The user tapped Done. The page is now:\nTitle: \(title)\nURL: \(read.url)\n\n" + out.text,
                                      sources: out.text.isEmpty ? [] : [SourceCandidate(title: title.isEmpty ? read.url : title, url: read.url, content: out.text)])
                case .session:
                    guard session.hasPage, let page = session.page as? HiddenWebView else {
                        return ToolOutput(text: "Error: no page is open. Open it with browser_open first, then call browser_show.", isError: true)
                    }
                    let done = await ask(BrowserShowRequests.Request(reason: reason, page: page, conversationID: conversation))
                    let place = Self.place(page)
                    if done {
                        return ToolOutput(text: "The user tapped Done. The page is now: \(place). Read it with browser_state or browser_eval, or open the next page with browser_open; a sign-in stays saved for later.")
                    }
                    return ToolOutput(text: "The user closed the browser without tapping Done. The page is now: \(place). Don't show it again unless they ask.", isError: true)
                }
            }
        } catch is BrowserStoppedError {
            return BrowserStoppedError.output
        } catch {
            return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    @MainActor
    private static func place(_ page: HiddenWebView) -> String {
        [page.webView.title.map { PageMetadata.capped($0) }, page.webView.url?.absoluteString].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " — ")
    }
}
