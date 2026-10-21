import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif

// On-device Python: Pyodide in a Web Worker inside one dedicated hidden web view, loaded from the app bundle through
// the `strata-py://` scheme. One interpreter at a time, owned by one conversation and kept across its turns.

/// The Python settings, read by the tool and the request builder off the main actor.
enum PythonSettings {
    static let enabledKey = "pythonEnabled"
    static let timeLimitKey = "pythonTimeLimit"
    static let timeLimitOptions = [10, 30, 60, 120, 300]
    static let defaultTimeLimit = 30

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil ? true : UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var timeLimitSeconds: Int {
        let v = UserDefaults.standard.integer(forKey: timeLimitKey)
        return timeLimitOptions.contains(v) ? v : defaultTimeLimit
    }

    static func label(seconds: Int) -> String {
        seconds < 60 ? String(localized: "\(seconds) s") : String(localized: "\(seconds / 60) min")
    }
}

/// Limits of one run.
struct PythonLimits: Sendable, Equatable {
    /// The user's code.
    var run: Duration
    /// Starting the interpreter, and loading the packages the code imports (downloads on first use).
    var setup: Duration = .seconds(180)

    static var current: PythonLimits { PythonLimits(run: .seconds(PythonSettings.timeLimitSeconds)) }
}

/// What the page answers for one run (`host.js`).
struct PythonReply: Decodable, Sendable, Equatable {
    struct Figure: Decodable, Sendable, Equatable { var png: String }
    var phase: String
    var status: String
    var fresh: Bool?
    var output: String?
    var result: String?
    var error: String?
    var message: String?
    var elapsedMs: Double?
    var figures: [Figure]?
    var truncated: Bool?
    var loadErrors: [String]?
    var errors: [String]?
}

/// How one run ended, for the formatter.
enum PythonOutcome: Sendable, Equatable {
    case finished(output: String, result: String?, error: String?, loadErrors: [String])
    /// A limit ran out (`phase`: "init", "load" or "run"); the worker was terminated.
    case timedOut(phase: String, elapsed: Duration, limit: Duration)
    /// The web view's process was killed (memory) or the worker died.
    case outOfMemory(detail: String?)
    /// Python could not be started at all.
    case failed(String)

    /// The interpreter's state is gone after this outcome.
    var lostState: Bool {
        switch self {
        case .finished, .failed: false
        case .timedOut, .outOfMemory: true
        }
    }

    init(reply: PythonReply, limits: PythonLimits) {
        switch reply.status {
        case "ok" where reply.phase == "run":
            self = .finished(output: reply.output ?? "", result: reply.result, error: reply.error,
                             loadErrors: reply.loadErrors ?? [])
        case "timeout":
            let elapsed = Duration.milliseconds(Int((reply.elapsedMs ?? 0).rounded()))
            self = .timedOut(phase: reply.phase, elapsed: elapsed, limit: reply.phase == "run" ? limits.run : limits.setup)
        case "crashed":
            self = .outOfMemory(detail: reply.message)
        default:
            self = .failed(reply.message ?? "unknown error")
        }
    }
}

/// Turns an outcome into the text the model reads.
enum PythonOutputFormatter {
    static let resetNote = "[Note: the Python session was reset since the last run, so variables, imports and files from earlier runs are gone.]"
    static let stateGone = "The Python session was stopped and reset: variables, imports and files from earlier runs are gone."

    /// - Parameters:
    ///   - limit: characters of output (Settings > Fetch length); longer output keeps its start and end.
    ///   - figures: the figures this run saved.
    ///   - canView: the model can look at figures with `view_image`.
    static func format(_ outcome: PythonOutcome, figures: [ToolImage], limit: Int, sessionReset: Bool,
                       canView: Bool) -> ToolOutput {
        var lines: [String] = []
        if sessionReset { lines.append(resetNote) }
        switch outcome {
        case .finished(let output, let result, let error, let loadErrors):
            if !loadErrors.isEmpty {
                lines.append("[Some packages could not be loaded: " + loadErrors.joined(separator: "; ") + "]")
            }
            var body = output
            if let result, !result.isEmpty {
                if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
                body += result
            }
            if let error, !error.isEmpty {
                if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
                body += error
            }
            body = body.trimmingCharacters(in: .newlines)
            if body.isEmpty && figures.isEmpty { body = "(no output)" }
            if !body.isEmpty { lines.append(cap(body, limit: limit)) }
            if !figures.isEmpty {
                let list = figures.map(\.listing).joined(separator: ", ")
                lines.append((figures.count == 1 ? "Figure saved: " : "Figures saved: ") + list
                             + (canView ? ". Call view_image with an id to look at one." : "."))
            }
            return ToolOutput(text: lines.joined(separator: "\n\n"), isError: error?.isEmpty == false, figures: figures)
        case .timedOut(let phase, let elapsed, let limit):
            let what = switch phase {
            case "init": "starting Python"
            case "load": "loading the packages the code imports"
            default: "the code"
            }
            let hint = phase == "run"
                ? " Make the code faster or split the work into smaller runs (the limit is set in Settings > Python)."
                : " The package download may be slow; try again."
            lines.append("Error: Timed out after \(FetchTimeouts.seconds(elapsed)): \(what) has a \(FetchTimeouts.seconds(limit)) limit. "
                         + stateGone + hint)
            return ToolOutput(text: lines.joined(separator: "\n\n"), isError: true)
        case .outOfMemory(let detail):
            var text = "Error: Python ran out of memory, so the session was stopped and reset: variables, imports and files from earlier runs are gone. Use less memory (smaller arrays, fewer objects at once) and try again."
            if let detail, !detail.isEmpty { text += " (\(detail))" }
            lines.append(text)
            return ToolOutput(text: lines.joined(separator: "\n\n"), isError: true)
        case .failed(let message):
            lines.append("Error: Python could not run: \(message)")
            return ToolOutput(text: lines.joined(separator: "\n\n"), isError: true)
        }
    }

    /// Keeps the first three quarters and the last quarter of `limit` characters, with a note between them.
    static func cap(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 0 else { return text }
        let head = limit * 3 / 4
        let tail = limit - head
        let omitted = text.count - head - tail
        return String(text.prefix(head)) + "\n\n[Output truncated: \(omitted) characters omitted.]\n\n" + String(text.suffix(tail))
    }
}

/// Which conversation owns the interpreter, when it was last used, and which conversations have had one (so the first
/// run after a reset can say that earlier variables are gone). Pure, so the rules are tested without a web view.
struct PythonSessionLedger: Sendable, Equatable {
    static let idleLimit: TimeInterval = 600

    private(set) var owner: UUID?
    private(set) var lastUsed: Date?
    /// Conversations whose loss of state the model has already been told about (a timeout or memory error says so).
    private(set) var announced: Set<UUID> = []

    /// Before a run: true when the live interpreter belongs to another conversation and must be thrown away first.
    mutating func claim(_ conversation: UUID, now: Date) -> Bool {
        let other = owner != nil && owner != conversation
        owner = conversation
        lastUsed = now
        return other
    }

    /// After a run that reached the interpreter. `fresh`: a new interpreter was started for it; `hadSession`: the
    /// conversation had one before. Returns whether the output starts with the reset note.
    mutating func finishRun(_ conversation: UUID, fresh: Bool, hadSession: Bool, lostState: Bool, now: Date) -> Bool {
        lastUsed = now
        let note = fresh && hadSession && !announced.contains(conversation)
        if fresh { announced.remove(conversation) }
        if lostState { announced.insert(conversation) }
        return note
    }

    /// The interpreter is gone (idle, memory, another chat): the next run of its conversation starts fresh.
    mutating func disposed() {
        owner = nil
        lastUsed = nil
    }

    func isIdle(now: Date) -> Bool {
        guard let lastUsed, owner != nil else { return false }
        return now.timeIntervalSince(lastUsed) >= Self.idleLimit
    }

    /// Switching chats disposes the interpreter of the one left, unless that chat's reply is still running (`busy`).
    func shouldDispose(onSwitchTo conversation: UUID?, busy: Set<UUID> = []) -> Bool {
        guard let owner else { return false }
        return owner != conversation && !busy.contains(owner)
    }
}

/// The dedicated web view the interpreter lives in.
@MainActor
final class PythonWebHost: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let handler: PythonSchemeHandler
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private(set) var isLoaded = false
    /// The web content process died (most often: memory).
    private(set) var terminated = false
    var onTerminate: (@MainActor () -> Void)?

    init(server: PyodideServer) {
        handler = PythonSchemeHandler(server: server)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handler, forURLScheme: Pyodide.scheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 32, height: 32), configuration: config)
        #if canImport(UIKit)
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        #endif
        super.init()
        webView.navigationDelegate = self
        #if canImport(UIKit)
        HiddenWebView.keyWindow?.insertSubview(webView, at: 0)
        #else
        OffscreenWebHost.shared.attach(webView)
        #endif
        DiagnosticCounters.shared.webViewCreated()
    }

    func dispose() {
        DiagnosticCounters.shared.webViewDisposed()
        handler.stopAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        let cont = loadContinuation
        loadContinuation = nil
        cont?.resume(throwing: CancellationError())
    }

    /// How long the page may take to load before the run gives up (it would otherwise hold the run lock for good).
    static let loadLimit: Duration = .seconds(60)

    func load() async throws {
        if isLoaded { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadContinuation = cont
            webView.load(URLRequest(url: Pyodide.pageURL))
            Task { [weak self] in
                try? await Task.sleep(for: Self.loadLimit)
                guard let self, let cont = self.loadContinuation else { return }
                self.loadContinuation = nil
                self.webView.stopLoading()
                cont.resume(throwing: WebToolError.timeout)
            }
        }
        isLoaded = true
    }

    /// Runs one cell and returns the page's JSON reply.
    func run(code: String, limits: PythonLimits) async throws -> String {
        let value = try await webView.callAsyncJavaScript(
            "return await window.strataPython.run(code, runMs, setupMs);",
            arguments: ["code": code, "runMs": Self.milliseconds(limits.run), "setupMs": Self.milliseconds(limits.setup)],
            contentWorld: .page)
        return (value as? String) ?? ""
    }

    /// Terminates the worker (the interpreter's state is gone; the page stays).
    func resetWorker() {
        webView.callAsyncJavaScript("return window.strataPython && window.strataPython.reset();", arguments: [:],
                                    in: nil, in: .page) { _ in }
    }

    /// Test hook: tries `url` from the worker without the proxy.
    func probe(_ url: String) async throws -> String {
        let value = try await webView.callAsyncJavaScript("return await window.strataPython.probe(url);",
                                                          arguments: ["url": url], contentWorld: .page)
        return (value as? String) ?? ""
    }

    static func milliseconds(_ d: Duration) -> Int { Int(d.seconds * 1000) }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.scheme?.lowercased() == Pyodide.scheme ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let cont = loadContinuation
        loadContinuation = nil
        cont?.resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let cont = loadContinuation
        loadContinuation = nil
        cont?.resume(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let cont = loadContinuation
        loadContinuation = nil
        cont?.resume(throwing: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        terminated = true
        let cont = loadContinuation
        loadContinuation = nil
        cont?.resume(throwing: PythonHostError.terminated)
        onTerminate?()
    }
}

enum PythonHostError: Error, Equatable {
    case terminated
    case unavailable
}

/// Serves `strata-py://` requests from `PyodideServer`.
@MainActor
final class PythonSchemeHandler: NSObject, WKURLSchemeHandler {
    let server: PyodideServer
    private var active: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(server: PyodideServer) { self.server = server }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        let request = urlSchemeTask.request
        let server = server
        active[key] = Task { @MainActor [weak self] in
            let response = await server.respond(to: request)
            guard let self, self.active.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
            var headers = response.headers
            headers["Content-Type"] = response.mimeType
            headers["Content-Length"] = String(response.body.count)
            let http = HTTPURLResponse(url: request.url ?? Pyodide.pageURL, statusCode: response.status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)
            guard let http else { urlSchemeTask.didFailWithError(URLError(.badServerResponse)); return }
            urlSchemeTask.didReceive(http)
            urlSchemeTask.didReceive(response.body)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        active.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    func stopAll() {
        for task in active.values { task.cancel() }
        active.removeAll()
    }
}

/// The app's Python: runs code for a conversation, one run at a time, and disposes the interpreter when it is idle,
/// when another chat is opened, or on memory pressure.
@MainActor
final class PythonRuntime {
    static let shared = PythonRuntime()

    private var host: PythonWebHost?
    private(set) var ledger = PythonSessionLedger()
    /// One run at a time, from every chat, in order of arrival.
    private let lock = FairSlots(capacity: 1)
    private var running: Bool { !lock.holderKeys.isEmpty }
    /// Bumped as each run ends, so a reset scheduled by a cancelled run can't hit the run after it.
    private var runGeneration = 0
    private var idleTimer: Task<Void, Never>?
    /// Test seam: the server the web view loads from.
    var makeServer: () -> PyodideServer? = { PyodideServer.live() }
    let images: ToolImageStore

    #if os(macOS)
    private var pressureSource: DispatchSourceMemoryPressure?
    #endif

    init(images: ToolImageStore = .shared) {
        self.images = images
        MemoryPurge.register { [weak self, images] in
            self?.memoryPressure()
            images.purgeCache()
            ToolImageCache.purge()
        }
        #if os(macOS)
        // A Mac has no memory warning; the system's memory-pressure signal stands in for it.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.memoryPressure() } }
        source.resume()
        pressureSource = source
        #endif
    }

    var isRunning: Bool { running }
    /// The live web view (tests).
    var testHost: PythonWebHost? { host }
    var hasInterpreter: Bool { host != nil && ledger.owner != nil }

    /// Runs `code` in the conversation's interpreter, after the runs ahead of it (other chats' too) are done.
    func run(code: String, conversationID: UUID, limits: PythonLimits = .current, outputLimit: Int = AppSettings.currentFetchLength,
             canView: Bool) async -> ToolOutput {
        await serialized {
            await self.runNow(code: code, conversationID: conversationID, limits: limits, outputLimit: outputLimit, canView: canView)
        } ?? ToolOutput(text: "Error: cancelled.", isError: true)
    }

    private func runNow(code: String, conversationID: UUID, limits: PythonLimits, outputLimit: Int, canView: Bool) async -> ToolOutput {
        if Task.isCancelled { return ToolOutput(text: "Error: cancelled.", isError: true) }
        let generation = runGeneration
        if ledger.claim(conversationID, now: .now) { disposeHost() }
        let hadSession = hadSession(conversationID)

        var outcome: PythonOutcome
        var fresh = true
        var pngs: [String] = []
        // Backstop for a page that never answers: the page has its own limits and normally answers first.
        let backstop = limits.run + limits.setup * 2 + .seconds(15)
        do {
            let host = try await liveHost()
            let json = try await withTaskCancellationHandler {
                try await Deadline.run(backstop, timeoutError: WebToolError.timeout) { try await host.run(code: code, limits: limits) }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.runGeneration == generation else { return } // this run already ended
                    host.resetWorker()
                }
            }
            if let reply = try? JSONDecoder().decode(PythonReply.self, from: Data(json.utf8)) {
                fresh = reply.fresh ?? true
                outcome = PythonOutcome(reply: reply, limits: limits)
                pngs = reply.figures?.map(\.png) ?? []
                if reply.status == "crashed" { host.resetWorker() }
            } else {
                outcome = .failed("the Python page gave no answer")
            }
        } catch is CancellationError {
            return ToolOutput(text: "Error: cancelled.", isError: true)
        } catch WebToolError.timeout {
            disposeHost()
            outcome = .timedOut(phase: "run", elapsed: backstop, limit: limits.run)
        } catch PythonHostError.unavailable {
            outcome = .failed("the Python runtime is missing from the app bundle")
        } catch {
            // The web content process died (memory), or the call failed with it.
            let wasTerminated = host?.terminated ?? true
            disposeHost()
            outcome = wasTerminated ? .outOfMemory(detail: nil) : .failed(error.localizedDescription)
        }
        if Task.isCancelled { return ToolOutput(text: "Error: cancelled.", isError: true) }

        var figures: [ToolImage] = []
        for png in pngs {
            guard let data = Data(base64Encoded: png), let image = images.addFigure(png: data, conversationID: conversationID) else { continue }
            figures.append(image)
        }
        var note = false
        if case .failed = outcome {} else {
            markSession(conversationID)
            note = ledger.finishRun(conversationID, fresh: fresh, hadSession: hadSession, lostState: outcome.lostState, now: .now)
        }
        scheduleIdleCheck()
        return PythonOutputFormatter.format(outcome, figures: figures, limit: outputLimit, sessionReset: note, canView: canView)
    }

    private func liveHost() async throws -> PythonWebHost {
        if let host, !host.terminated, host.isLoaded { return host }
        disposeHost()
        guard let server = makeServer() else { throw PythonHostError.unavailable }
        let host = PythonWebHost(server: server)
        host.onTerminate = { [weak self, weak host] in
            guard let self, let host, self.host === host else { return }
            if !self.running { self.disposeHost() }
        }
        self.host = host
        try await host.load()
        return host
    }

    private func disposeHost() {
        host?.dispose()
        host = nil
    }

    /// Throws the interpreter away (idle, memory pressure, another chat).
    func dispose() {
        guard !running else { return }
        disposeHost()
        ledger.disposed()
        idleTimer?.cancel()
        idleTimer = nil
    }

    /// The chat on screen changed. `busy`: the conversations whose replies are running (the interpreter of one of them
    /// stays).
    func conversationDidChange(to conversation: UUID?, busy: Set<UUID> = []) {
        if ledger.shouldDispose(onSwitchTo: conversation, busy: busy) { dispose() }
    }

    func memoryPressure() { dispose() }

    /// The chat was deleted: its interpreter and figures go too.
    func conversationDeleted(_ conversation: UUID) {
        if ledger.owner == conversation { dispose() }
        images.removeAll(conversationID: conversation)
    }

    private func scheduleIdleCheck() {
        idleTimer?.cancel()
        idleTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(PythonSessionLedger.idleLimit + 1))
            guard !Task.isCancelled, let self else { return }
            if self.ledger.isIdle(now: .now) { self.dispose() }
        }
    }

    // MARK: Session marks

    private func markURL(_ conversation: UUID) -> URL {
        images.root.appendingPathComponent(conversation.uuidString, isDirectory: true).appendingPathComponent(".python-session")
    }

    private func hadSession(_ conversation: UUID) -> Bool { FileManager.default.fileExists(atPath: markURL(conversation).path) }

    private func markSession(_ conversation: UUID) {
        let url = markURL(conversation)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    // MARK: One run at a time

    /// Runs `body` once the runs ahead of it are done, in order of arrival; nil when the waiting task was cancelled (a
    /// stopped turn doesn't wait out the run ahead). While it waits, its chat says so (`ToolWaits`).
    func serialized<T>(_ body: () async -> T) async -> T? {
        let key = UUID()
        let callID = ToolContext.callID
        if !lock.admitsNow(key) { ToolWaits.shared.begin(callID, .python) }
        let admitted = await lock.acquire(key)
        ToolWaits.shared.end(callID)
        guard admitted else { return nil }
        defer {
            runGeneration += 1
            lock.release(key)
        }
        return await body()
    }
}
