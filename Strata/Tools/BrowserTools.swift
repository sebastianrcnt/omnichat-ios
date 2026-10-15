import Foundation

// `browser_open` and `browser_eval`: a hidden browser the model drives itself. One page per conversation, in a web view
// with the shared non-persistent data store (no cookies or logins of the user's), guarded navigations like a fetch, a
// mobile Safari user agent, and no script message handlers: model JavaScript runs in the page and can reach nothing of
// the app's.

/// What the browser tools need of a page, so they can be tested with a fake.
@MainActor
protocol BrowserPage: PluginPage {}

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
          return JSON.stringify({ title: document.title || "", url: String(location.href), text: (t || "").slice(0, \(maxCharacters)) });
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

/// One browser page per conversation. Calls on it run one at a time (a round may ask for several), and a page left
/// alone for a while is torn down.
@MainActor
final class BrowserSessions {
    static let shared: BrowserSessions = {
        let sessions = BrowserSessions()
        MemoryPurge.register { sessions.closeAll() }
        return sessions
    }()

    var idleLifetime: Duration = .seconds(600)
    /// Makes the page of a new session. Test seam; by default a hidden web view.
    var makePage: @MainActor () -> any BrowserPage = { HiddenWebView(guardNavigations: true, store: BrowserData.store) }

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

        init(page: any BrowserPage) { self.page = page }
    }

    private var sessions: [UUID: Session] = [:]
    private var sweeper: Task<Void, Never>?
    /// Calls without a conversation (tests, the debug hooks) share one session.
    static let defaultKey = UUID(uuidString: "00000000-0000-0000-0000-00000000B0B0")!

    var count: Int { sessions.count }

    func session(for conversation: UUID?) -> Session {
        let key = conversation ?? Self.defaultKey
        if let existing = sessions[key] { existing.lastUsed = .now; return existing }
        let created = Session(page: makePage())
        sessions[key] = created
        scheduleSweep()
        return created
    }

    /// Runs `operation` on the conversation's page once the calls before it are done.
    func run<T: Sendable>(conversation: UUID?, _ operation: @escaping @MainActor @Sendable (Session) async throws -> T) async throws -> T {
        let session = session(for: conversation)
        let previous = session.tail
        let task = Task { @MainActor () -> Result<T, Error> in
            await previous?.value
            session.busy += 1
            defer { session.busy -= 1; session.lastUsed = .now }
            do { return .success(try await operation(session)) } catch { return .failure(error) }
        }
        session.tail = Task { @MainActor in _ = await task.value }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        session.lastUsed = .now
        return try result.get()
    }

    func close(_ conversation: UUID) {
        guard let session = sessions.removeValue(forKey: conversation) else { return }
        dispose(session)
    }

    func closeAll() {
        for session in sessions.values { dispose(session) }
        sessions.removeAll()
        sweeper?.cancel()
        sweeper = nil
    }

    private func dispose(_ session: Session) {
        session.tail?.cancel()
        session.page.stop()
        (session.page as? HiddenWebView)?.dispose()
    }

    private func scheduleSweep() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while let self, !Task.isCancelled, !self.sessions.isEmpty {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                let now = ContinuousClock.now
                for (key, session) in self.sessions where session.busy == 0 && now - session.lastUsed >= self.idleLifetime { self.close(key) }
            }
            self?.sweeper = nil
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

    @MainActor
    func run(urlString: String, conversation: UUID?) async -> ToolOutput {
        let started = ContinuousClock.now
        let url: URL
        do {
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: trimmed) else { throw URLGuardError.invalidURL }
            try await URLGuard.validate(parsed, resolver: resolver)
            url = parsed
        } catch {
            return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
        }
        let callID = ToolContext.callID
        let report: @MainActor (Double) -> Void = { value in if let callID { ToolProgress.shared.report(callID, value) } }
        let overall = timeouts.overall
        let settleLimit = min(settleLimit, timeouts.load)
        let limit = limit
        let timeouts = timeouts
        do {
            return try await (sessions ?? .shared).run(conversation: conversation) { session in
                try await Deadline.run(overall, onAbort: { session.page.stop() }) {
                    let page = try await Self.open(url, page: session.page, settleLimit: settleLimit, timeouts: timeouts, progress: report)
                    session.hasPage = true
                    let out = await Task.detached(priority: .userInitiated) { BrowserText.capped(page.text, limit: limit) }.value
                    let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !out.text.isEmpty else {
                        return ToolOutput(text: "Title: \(title)\nURL: \(page.url)\n\n[The page shows no text. It may need a moment more, or the content may be in images or frames; try browser_eval.]")
                    }
                    return ToolOutput(text: "Title: \(title)\nURL: \(page.url)\n\n" + out.text,
                                      sources: [SourceCandidate(title: title.isEmpty ? page.url : title, url: page.url, content: out.text)])
                }
            }
        } catch is CancellationError {
            return ToolOutput(text: "Error: cancelled.", isError: true)
        } catch WebToolError.timeout {
            let text = WebToolError.timeoutMessage(after: ContinuousClock.now - started, limit: overall, what: "opening the page")
            return ToolOutput(text: "Error: \(text)", isError: true)
        } catch {
            return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    @MainActor
    private final class LoadState { var result: Result<Void, Error>? }

    /// Loads `url` and polls the page until it settles (or `settleLimit` passes), then reads it. A page that never
    /// finishes loading is read once it is there at all.
    @MainActor
    static func open(_ url: URL, page: some BrowserPage, settleLimit: Duration, timeouts: FetchTimeouts,
                     progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> FetchedPage {
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
        progress(FetchProgress.extracting)
        let json = try await page.evaluate(BrowserSettle.extraction(maxCharacters: FetchPipeline.maxPageCharacters), timeout: timeouts.script)
        guard let e = try? JSONDecoder().decode(BrowserSettle.Extracted.self, from: Data(json.utf8)) else {
            throw WebToolError.script("could not read the page.")
        }
        progress(FetchProgress.done)
        return FetchedPage(title: e.title, url: e.url.isEmpty ? (page.currentURL?.absoluteString ?? url.absoluteString) : e.url, text: e.text)
    }
}

/// `browser_eval(js)`: runs the model's JavaScript in the page `browser_open` opened and returns the result.
struct BrowserEvalTool {
    /// Characters of result returned (Settings > Fetch length).
    var limit: Int = AppSettings.currentFetchLength
    /// Scripts may click and wait for what appears.
    var timeout: Duration = .seconds(20)
    var sessions: BrowserSessions?

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
        do {
            return try await (sessions ?? .shared).run(conversation: conversation) { session in
                guard session.hasPage, let current = session.page.currentURL, current.scheme?.hasPrefix("http") == true else {
                    return ToolOutput(text: "Error: no page is open. Call browser_open first.", isError: true)
                }
                let json = try await session.page.callAsync(BrowserScript.invocation(trimmed, maxCharacters: FetchPipeline.maxPageCharacters),
                                                            timeout: timeout)
                return await Task.detached(priority: .userInitiated) { BrowserScript.format(json: json, limit: limit) }.value
            }
        } catch is CancellationError {
            return ToolOutput(text: "Error: cancelled.", isError: true)
        } catch WebToolError.timeout {
            return ToolOutput(text: "Error: the script did not finish within \(FetchTimeouts.seconds(timeout)).", isError: true)
        } catch {
            return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }
}

/// Pages the model asked the user to use (`browser_show`): the chat shows `pending` as a sheet with the page in it.
@MainActor
@Observable
final class BrowserShowRequests {
    static let shared = BrowserShowRequests()

    struct Request: Identifiable {
        let id = UUID()
        /// Why the model wants the user there, in its words ("Sign in to X so I can read your feed").
        let reason: String
        let page: HiddenWebView
    }

    private var queue: [(request: Request, answer: CheckedContinuation<Bool, Never>)] = []

    var pending: Request? { queue.first?.request }

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

    func answer(_ id: UUID, done: Bool) {
        guard let i = queue.firstIndex(where: { $0.request.id == id }) else { return }
        queue.remove(at: i).answer.resume(returning: done)
    }
}

/// `browser_show(reason)`: shows the page `browser_open` opened to the user, so they can sign in, pass a check or do a
/// step only they should do, and returns where the page is when they are done. Cookies from a sign-in are kept
/// (`BrowserData`).
struct BrowserShowTool {
    var sessions: BrowserSessions?
    var ask: @MainActor (BrowserShowRequests.Request) async -> Bool = { await BrowserShowRequests.shared.ask($0) }

    @MainActor
    func run(reason: String, conversation: UUID?) async -> ToolOutput {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = ask
        do {
            return try await (sessions ?? .shared).run(conversation: conversation) { session in
                guard session.hasPage, let page = session.page as? HiddenWebView else {
                    return ToolOutput(text: "Error: no page is open. Open it with browser_open first, then call browser_show.", isError: true)
                }
                let done = await ask(BrowserShowRequests.Request(reason: reason, page: page))
                let place = [page.webView.title, page.webView.url?.absoluteString].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: " — ")
                if done {
                    return ToolOutput(text: "The user tapped Done. The page is now: \(place). Read it with browser_eval or open the next page with browser_open; a sign-in stays saved for later.")
                }
                return ToolOutput(text: "The user closed the browser without tapping Done. The page is now: \(place). Don't show it again unless they ask.", isError: true)
            }
        } catch {
            return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }
}
