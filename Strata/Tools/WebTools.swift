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

/// Runs one search on one engine; the real one loads the results page in a hidden web view.
typealias EngineSearcher = @MainActor @Sendable (SearchEngine, URL) async throws -> [SearchResult]

struct WebSearchTool {
    /// Engines in the order to try them: the first that answers with results wins, the rest are fallbacks for an error,
    /// a bot challenge or an empty page.
    var engines: [SearchEngine]

    var timeouts = FetchTimeouts.current
    /// Test seam; `nil` uses the hidden web view.
    var searcher: EngineSearcher?

    init(engines: [SearchEngine], timeouts: FetchTimeouts = .current, searcher: EngineSearcher? = nil) {
        self.engines = engines
        self.timeouts = timeouts
        self.searcher = searcher
    }

    init(engine: SearchEngine) { self.init(engines: [engine]) }

    @MainActor
    func run(query: String) async -> ToolOutput {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ToolOutput(text: "Error: the search query is empty.", isError: true) }
        guard !engines.isEmpty else { return ToolOutput(text: "Error: no search engine is configured.", isError: true) }
        var failures: [String] = []
        var sawEmpty = false
        var skippedCheck = false
        for engine in engines {
            guard let url = engine.searchURL(for: q) else { continue }
            let started = ContinuousClock.now
            do {
                let search = searcher ?? Self.searchWithWebView(timeouts: timeouts)
                let results = try await Deadline.run(timeouts.overall) { try await search(engine, url) }
                if results.isEmpty { sawEmpty = true; continue }
                return ToolOutput(text: SearchFormatter.format(query: q, results: results, engine: engine.name),
                                  sources: results.map { SourceCandidate(title: $0.title, url: $0.url, content: $0.snippet.isEmpty ? $0.title : $0.snippet) },
                                  engine: engine.name)
            } catch is CancellationError {
                return ToolOutput(text: "Error: cancelled.", isError: true)
            } catch {
                let message = WebToolError.timeout == error as? WebToolError
                    ? WebToolError.timeoutMessage(after: ContinuousClock.now - started, limit: timeouts.overall, what: "the search page")
                    : error.localizedDescription
                failures.append(engines.count > 1 ? "\(engine.name): \(message)" : message)
                skippedCheck = skippedCheck || error is RobotCheckError
            }
        }
        // An engine that answered with nothing is an answer; errors alone are a failure.
        if sawEmpty || failures.isEmpty { return ToolOutput(text: SearchFormatter.format(query: q, results: [])) }
        let note = skippedCheck ? "" : KeptPages.shared.note(forCall: ToolContext.callID)
        return ToolOutput(text: "Error: " + failures.joined(separator: " ") + note, isError: true)
    }

    @MainActor
    static func searchWithWebView(timeouts: FetchTimeouts) -> EngineSearcher {
        { engine, url in
            let pool = WebViewPool.shared
            let page = pool.acquire(reader: false)
            var reusable = false
            var keep = false
            defer { pool.release(page, reusable: reusable, keep: keep) }
            do {
                try await page.load(url, timeout: timeouts.load)
                try await RobotCheckGate.pass(page, timeouts: timeouts)
                let results = try await SearchExtractor.extract(engine: engine, from: page)
                reusable = true
                return results
            } catch {
                keep = KeptPages.shouldKeep(after: error)
                throw error
            }
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

    /// Returns `[offset, offset+limit)` of `text` plus a footer telling the model how to continue: by calling `tool`
    /// again (`video_transcript` pages a transcript the same way, `noun` "transcript").
    static func slice(_ text: String, offset: Int, limit: Int, tool: String = ToolNames.webFetch, noun: String = "page") -> Result {
        let total = text.count
        let start = max(0, offset)
        if start > 0 && start >= total { return .offsetPastEnd(offset: start, total: total) }
        let end = min(total, start + max(1, limit))
        let from = text.index(text.startIndex, offsetBy: start)
        let to = text.index(from, offsetBy: end - start)
        let body = String(text[from..<to])
        let footer = end >= total
            ? "[End of \(noun), \(total) characters total.]"
            : "[Showing characters \(start)\u{2013}\(end) of \(total). Call \(tool) with the same url and offset=\(end) to read more.]"
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

    /// Entries and the characters of text they hold (diagnostics).
    var stats: (entries: Int, characters: Int) {
        lock.withLock { (entries.count, entries.values.reduce(0) { $0 + $1.page.text.utf16.count }) }
    }
}

typealias PageLoader = @MainActor @Sendable (URL) async throws -> FetchedPage

struct WebFetchTool {
    var resolver: any HostResolving = SystemHostResolver()
    var cache: PageCache = .shared
    /// Characters returned per call (Settings > Fetch length).
    var limit: Int = AppSettings.currentFetchLength
    /// Test seam; `nil` loads with the hidden web view.
    var loader: PageLoader?
    var timeouts = FetchTimeouts.current
    /// Loads under way; fetches of the same page in one round share one. `nil` uses the shared registry.
    var inFlight: InFlightLoads?

    /// Runs in the page. `strataExtract` (Extractor.js, after Readability) comes from the user script the fetch views
    /// carry; the flow itself lives there. The text is cut to `maxCharacters` in the page, so nothing larger is ever
    /// sent back to the app. Without the script, the body's text is used.
    static func extractionScript(maxCharacters: Int) -> String {
        """
        (function() {
          var cap = \(maxCharacters);
          if (typeof strataExtract === "function") { try { return strataExtract(cap); } catch (e) {} }
          var t = document.body ? document.body.innerText : "";
          return JSON.stringify({ title: document.title || "", text: (t || "").slice(0, cap), readable: false, method: "page" });
        })()
        """
    }

    static let extractionScript = extractionScript(maxCharacters: FetchPipeline.maxPageCharacters)

    /// Validates and rewrites the URL as `web_fetch` does before loading.
    static func prepare(_ raw: String, resolver: any HostResolving) async throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { throw URLGuardError.invalidURL }
        let rewritten = URLRewriter.rewrite(url)
        try await URLGuard.validate(rewritten, resolver: resolver)
        return rewritten
    }

    /// Fetches a page and returns one slice of its text. The whole call has a deadline (`timeouts.overall`), and
    /// cancelling it returns at once, whatever phase it is in.
    @MainActor
    func run(urlString: String, offset: Int = 0) async -> ToolOutput {
        let started = ContinuousClock.now
        do {
            return try await Deadline.run(timeouts.overall) { await self.fetchSlice(urlString: urlString, offset: offset, started: started) }
        } catch is CancellationError {
            return ToolOutput(text: "Error: cancelled.", isError: true)
        } catch WebToolError.timeout {
            let text = WebToolError.timeoutMessage(after: ContinuousClock.now - started, limit: timeouts.overall, what: "the whole fetch")
            return ToolOutput(text: "Error: \(text)", isError: true)
        } catch {
            return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    @MainActor
    private func fetchSlice(urlString: String, offset: Int, started: ContinuousClock.Instant) async -> ToolOutput {
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
                let load = loader ?? Self.loadWithWebView(resolver: resolver, timeouts: timeouts)
                page = try await (inFlight ?? .shared).load(key: SourceStore.key(for: url.absoluteString), callID: ToolContext.callID) { sink in
                    try await ToolContext.$progressSink.withValue(sink) { try await load(url) }
                }
            } catch WebToolError.timeout {
                let text = WebToolError.timeoutMessage(after: ContinuousClock.now - started, limit: timeouts.load, what: "loading the page")
                return ToolOutput(text: "Error: \(text)" + KeptPages.shared.note(forCall: ToolContext.callID), isError: true)
            } catch let error as RobotCheckError {
                return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
            } catch {
                return ToolOutput(text: "Error: \(error.localizedDescription)" + KeptPages.shared.note(forCall: ToolContext.callID), isError: true)
            }
            cache.store(page, for: url)
        }

        // Counting and slicing a long page is not main-thread work.
        let limit = limit
        let result = await Task.detached(priority: .userInitiated) { PageSlicer.slice(page.text, offset: offset, limit: limit) }.value
        switch result {
        case .offsetPastEnd(let off, let total):
            return ToolOutput(text: "Error: offset \(off) is past the end of the page (\(total) characters). Use an offset below \(total).", isError: true)
        case .slice(let body, let footer):
            let content = body + "\n\n" + footer
            let header = offset == 0 ? "Title: \(page.title)\nURL: \(page.url)\n\n" : "URL: \(page.url)\n\n"
            return ToolOutput(text: header + content,
                              sources: [SourceCandidate(title: page.title.isEmpty ? page.url : page.title, url: page.url, content: content)])
        }
    }

    /// The real loader: a pooled hidden web view plus Readability. Progress goes to `ToolProgress` under the running call's id.
    @MainActor
    static func loadWithWebView(resolver: any HostResolving, timeouts: FetchTimeouts = .standard) -> PageLoader {
        { url in
            // A PDF opens in the web view's own viewer, where the reader finds no text: download and read it instead.
            if PDFFetch.looksLikePDF(url) { return try await PDFFetch.load(url, timeout: timeouts.load, resolver: resolver) }
            guard ReadabilitySource.script != nil else { throw WebToolError.script("the page reader is missing from the app bundle.") }
            let pool = WebViewPool.shared
            let view = pool.acquire(reader: true, resolver: resolver)
            var reusable = false
            var keep = false
            defer { pool.release(view, reusable: reusable, keep: keep) }
            let sink = ToolContext.progressSink
            do {
                let page = try await FetchPipeline.fetch(url, page: view, timeouts: timeouts, progress: { value in sink?(value) },
                                                         check: { try await RobotCheckGate.pass(view, timeouts: timeouts) })
                reusable = true
                return page
            } catch WebToolError.script(let message) {
                // No text in the page: it may be a PDF served from a URL that doesn't say so.
                if let pdf = try? await PDFFetch.load(view.currentURL ?? url, timeout: timeouts.load, resolver: resolver) { return pdf }
                keep = true
                throw WebToolError.script(message)
            } catch {
                keep = KeptPages.shouldKeep(after: error)
                throw error
            }
        }
    }
}

// MARK: - Router

/// Dispatches model tool calls to the on-device tools.
struct ToolRouter: ToolExecuting {
    /// Runs a plugin by name with its args (a JSON object string, "" for none). Test seam; `nil` uses `RunPluginTool`.
    var pluginRunner: (@Sendable (_ name: String, _ args: String) async -> ToolOutput)?
    /// Runs Python code for a conversation. Test seam; `nil` uses `PythonRuntime.shared`.
    var pythonRunner: (@Sendable (_ code: String, _ conversation: UUID, _ canView: Bool) async -> ToolOutput)?
    var images: ToolImageStore = .shared
    var artifacts: ArtifactStore = .shared

    var usesWebKit: Bool { true }
    func execute(name: String, arguments: String) async -> ToolOutput {
        let args = (arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        switch name {
        case ToolNames.webSearch:
            guard let query = args["query"] as? String else {
                return ToolOutput(text: "Error: missing required argument \"query\".", isError: true)
            }
            // The model may pick the engine; anything else (or nothing) uses the user's setting.
            let picked = (args["engine"] as? String).flatMap { SearchEnginePreference(rawValue: $0.lowercased()) }
            let preference = picked.flatMap { $0 == .auto ? nil : $0 } ?? AppSettings.currentSearchEngine
            let engines = SearchEngines.chain(for: query, preference: preference)
            return await WebSearchTool(engines: engines).run(query: query)
        case ToolNames.webFetch:
            guard let url = args["url"] as? String else {
                return ToolOutput(text: "Error: missing required argument \"url\".", isError: true)
            }
            let offset = (args["offset"] as? Int) ?? (args["offset"] as? Double).flatMap { Int(exactly: $0.rounded(.down)) } ?? Int((args["offset"] as? String) ?? "") ?? 0
            return await WebFetchTool().run(urlString: url, offset: offset)
        case ToolNames.videoTranscript:
            guard let url = args["url"] as? String else {
                return ToolOutput(text: "Error: missing required argument \"url\".", isError: true)
            }
            return await VideoTranscriptTool().run(urlString: url, language: args["lang"] as? String,
                                                   offset: ToolCallRecord.fetchOffset(in: arguments))
        case ToolNames.runPlugin:
            guard let plugin = args["name"] as? String else {
                return ToolOutput(text: "Error: missing required argument \"name\".", isError: true)
            }
            let pluginArgs = Self.pluginArguments(args["args"])
            if let pluginRunner { return await pluginRunner(plugin, pluginArgs) }
            return await RunPluginTool().run(name: plugin, arguments: pluginArgs)
        case ToolNames.runPython:
            guard let code = args["code"] as? String else {
                return ToolOutput(text: "Error: missing required argument \"code\".", isError: true)
            }
            guard let conversation = ToolContext.conversationID else {
                return ToolOutput(text: "Error: Python is not available here.", isError: true)
            }
            let canView = ToolContext.readsImages
            if let pythonRunner { return await pythonRunner(code, conversation, canView) }
            return await PythonRuntime.shared.run(code: code, conversationID: conversation, canView: canView)
        case ToolNames.viewImage:
            guard let id = args["id"] as? String else {
                return ToolOutput(text: "Error: missing required argument \"id\".", isError: true)
            }
            return ViewImageTool(store: images).run(id: id, conversationID: ToolContext.conversationID,
                                                    readsImages: ToolContext.readsImages)
        case ToolNames.browserOpen:
            guard let url = args["url"] as? String else {
                return ToolOutput(text: "Error: missing required argument \"url\".", isError: true)
            }
            return await BrowserOpenTool().run(urlString: url, conversation: ToolContext.conversationID)
        case ToolNames.browserEval:
            guard let js = args["js"] as? String else {
                return ToolOutput(text: "Error: missing required argument \"js\".", isError: true)
            }
            return await BrowserEvalTool().run(code: js, conversation: ToolContext.conversationID)
        case let tool where ToolNames.isBrowserAction(tool):
            switch BrowserAction.parse(tool: tool, arguments: args) {
            case .failure(let error): return error.output
            case .success(let action): return await BrowserAgentTool().run(action, conversation: ToolContext.conversationID)
            }
        case ToolNames.browserShow:
            return await BrowserShowTool().run(reason: args["reason"] as? String ?? "", page: args["page"] as? String,
                                               conversation: ToolContext.conversationID)
        case ToolNames.loadSkill:
            guard let skill = args["name"] as? String else {
                return ToolOutput(text: "Error: missing required argument \"name\".", isError: true)
            }
            return LoadSkillTool().run(name: skill, script: args["script"] as? String)
        case ToolNames.runSkillScript:
            guard let skill = args["skill"] as? String, let script = args["script"] as? String else {
                return ToolOutput(text: "Error: run_skill_script needs \"skill\" and \"script\".", isError: true)
            }
            let argsJSON: String?
            switch args["args"] {
            case let s as String: argsJSON = s
            case let o as [String: Any]: argsJSON = (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) }
            default: argsJSON = nil
            }
            return await RunSkillScriptTool().run(skill: skill, script: script, argsJSON: argsJSON,
                                                  conversation: ToolContext.conversationID)
        case ToolNames.saveSkill:
            guard let skill = args["name"] as? String, let description = args["description"] as? String,
                  let body = args["body"] as? String else {
                return ToolOutput(text: "Error: save_skill needs \"name\", \"description\" and \"body\".", isError: true)
            }
            return await SaveSkillTool().run(name: skill, description: description, body: body)
        case ToolNames.showPlaces:
            return await ShowPlacesTool().run(arguments: arguments)
        case ToolNames.currentLocation:
            return await CurrentLocationTool().run()
        case ToolNames.showHTML:
            return ShowHTMLTool(store: artifacts).run(arguments: args, conversationID: ToolContext.conversationID,
                                                      callID: ToolContext.callID)
        default:
            return ToolOutput(text: "Error: unknown tool \"\(name)\".", isError: true)
        }
    }

    /// The `args` of a `run_plugin` call as a string: models send the JSON object string the schema asks for, or
    /// sometimes the object itself.
    static func pluginArguments(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let obj as [String: Any]: return PluginManifest.json(obj)
        default: return ""
        }
    }
}

/// `view_image`: attaches an image made earlier in the chat (see `MessageAssembler.appendToolRound`).
struct ViewImageTool {
    var store: ToolImageStore = .shared

    func run(id: String, conversationID: UUID?, readsImages: Bool) -> ToolOutput {
        guard readsImages else {
            return ToolOutput(text: "Error: the current model can't read images, so view_image is not available.", isError: true)
        }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversationID, let image = store.image(id: trimmed, conversationID: conversationID) else {
            let known = conversationID.map { store.figureIDs(conversationID: $0) } ?? []
            let list = known.isEmpty ? "No images exist in this chat yet." : "Available: " + known.joined(separator: ", ") + "."
            return ToolOutput(text: "Error: no image with id \"\(trimmed)\". " + list, isError: true)
        }
        return ToolOutput(text: "\(image.listing) is attached in the next message.", viewedImage: image)
    }
}
