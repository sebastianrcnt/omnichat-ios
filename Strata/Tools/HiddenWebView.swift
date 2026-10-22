import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum WebToolError: Error, LocalizedError, Equatable {
    case timeout
    case navigation(String)
    case script(String)
    /// The site's TLS certificate failed validation (expired, self-signed, wrong name...). Never bypassed.
    case insecure

    var errorDescription: String? {
        switch self {
        case .timeout: String(localized: "The page took too long to load.")
        case .navigation(let m): String(localized: "The page failed to load: \(m)")
        case .script(let m): String(localized: "Page script failed: \(m)")
        // Read by the model, so it says what to do next.
        case .insecure: "The site's security certificate is invalid (expired, self-signed or issued for another name), so the page was not opened. This site can't be read; use another source."
        }
    }

    /// What the model reads when a limit ran out: how long it waited and which limit it was.
    static func timeoutMessage(after elapsed: Duration, limit: Duration, what: String) -> String {
        "Timed out after \(FetchTimeouts.seconds(elapsed)): \(what) has a \(FetchTimeouts.seconds(limit)) limit. "
            + "The site may be slow or may not answer automated browsers; try another source."
    }

    /// A load failure from WebKit, with certificate problems told apart from other failures.
    static func loadFailure(_ error: Error) -> WebToolError {
        let e = error as NSError
        if e.domain == NSURLErrorDomain, Self.certificateCodes.contains(e.code) { return .insecure }
        return .navigation(error.localizedDescription)
    }

    static let certificateCodes: Set<Int> = [
        NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
    ]
}

/// The one data store of every hidden web view: search, fetch, plugins and the model's browser (`browser_open`,
/// `browser_eval`, skill scripts). It is kept on disk, so a site the user signed in to or a robot check they solved
/// (Cloudflare's `cf_clearance`, Google's) works for every tool and later chats. It never sees Safari's.
/// Settings > Tools > Clear browsing data empties it (`BrowsingData`).
@MainActor
enum BrowserData {
    static let identifier = UUID(uuidString: "5D1A7E0B-6C1E-4C2B-9A55-B0B5E7C0F1E5")!
    static let store = WKWebsiteDataStore(forIdentifier: identifier)
}

/// Everything the hidden browser keeps: its pages and the store's cookies, storage and caches.
@MainActor
enum BrowsingData {
    static func clearAll() async {
        BrowserSessions.shared.closeAll()
        WebViewPool.shared.drain()
        PageCache.shared.removeAll()
        await BrowserData.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

/// Blocks requests to local-network and loopback address literals, single-label hosts (`http://nas/`) and local name
/// suffixes from inside pages: subframes, images, `fetch` and XHR from `browser_eval` or a page's own scripts, which
/// `decidePolicyFor` (main-frame navigations) never sees. A public-looking name that resolves to a private address is
/// not caught here (content rules see URLs, not addresses; docs/KNOWN-ISSUES.md). Content blockers have no
/// alternation, so each range is its own rule.
@MainActor
enum LocalNetworkRules {
    private static var lists: [String: WKContentRuleList] = [:]
    private static var compiling: [String: Task<WKContentRuleList?, Never>] = [:]

    private static let identifier = "strata.local-network"
    private static let artifactIdentifier = "strata.artifact-network"

    static let patterns = [
        // Host names: localhost, one label (`nas`, `nas.`), and the suffixes `URLGuard.isBlockedHostname` refuses.
        #"^[a-z]+://([^/@]*@)?[^./:@]+\.?[:/]"#,
        #"^[a-z]+://localhost[:/]"#, #"^[a-z]+://[^/]*\.localhost\.?[:/]"#, #"^[a-z]+://[^/]*\.local\.?[:/]"#,
        #"^[a-z]+://[^/]*\.internal\.?[:/]"#, #"^[a-z]+://[^/]*\.lan\.?[:/]"#, #"^[a-z]+://[^/]*\.home\.arpa\.?[:/]"#,
        #"^[a-z]+://[^/]*\.intranet\.?[:/]"#, #"^[a-z]+://[^/]*\.corp\.?[:/]"#,
        // IPv4 literals (WebKit writes `127.1` and `0x7f000001` out as dotted quads first), as in `URLGuard.isBlocked`.
        #"^[a-z]+://127\."#, #"^[a-z]+://10\."#, #"^[a-z]+://0\."#, #"^[a-z]+://192\.168\."#, #"^[a-z]+://169\.254\."#,
        #"^[a-z]+://172\.1[6-9]\."#, #"^[a-z]+://172\.2[0-9]\."#, #"^[a-z]+://172\.3[01]\."#,
        #"^[a-z]+://100\.6[4-9]\."#, #"^[a-z]+://100\.[7-9][0-9]\."#, #"^[a-z]+://100\.1[01][0-9]\."#, #"^[a-z]+://100\.12[0-7]\."#,
        #"^[a-z]+://192\.0\.0\."#, #"^[a-z]+://198\.1[89]\."#, #"^[a-z]+://22[4-9]\."#, #"^[a-z]+://2[3-5][0-9]\."#,
        // Every IPv6 literal.
        #"^[a-z]+://\["#,
    ]

    /// Artifact pages also get no plain `http:` or `ws:` at all: their libraries come from HTTPS CDNs, and most
    /// devices on a LAN (routers, printers, NAS admin pages) answer only plain HTTP.
    static let artifactPatterns = patterns + [#"^http:"#, #"^ws:"#]

    static func json(_ patterns: [String]) -> String {
        let rules = patterns.map { pattern -> [String: Any] in
            ["trigger": ["url-filter": pattern, "url-filter-is-case-sensitive": false], "action": ["type": "block"]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Adds the rules to `controller`, now or once they are compiled.
    static func install(in controller: WKUserContentController) {
        if let list = lists[identifier] { controller.add(list); return }
        let task = compile(identifier, patterns)
        Task { @MainActor [weak controller] in
            if let compiled = await task.value { controller?.add(compiled) }
        }
    }

    /// The compiled rules, for a view that must not load anything before they are in place.
    static func rules() async -> WKContentRuleList? {
        if let list = lists[identifier] { return list }
        return await compile(identifier, patterns).value
    }

    /// The rules for an artifact's page and its thumbnail (`artifactPatterns`).
    static func artifactRules() async -> WKContentRuleList? {
        if let list = lists[artifactIdentifier] { return list }
        return await compile(artifactIdentifier, artifactPatterns).value
    }

    private static func compile(_ identifier: String, _ patterns: [String]) -> Task<WKContentRuleList?, Never> {
        if let task = compiling[identifier] { return task }
        let task = Task { @MainActor in
            let compiled = try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: json(patterns))
            lists[identifier] = compiled
            return compiled
        }
        compiling[identifier] = task
        return task
    }
}

/// The page text extractor, read once from the bundle: Readability, then `Extractor.js` (which defines
/// `strataExtract`), joined into one user script.
enum ReadabilitySource {
    static let script: String? = {
        let parts = ["Readability", "Extractor"].map { name -> String? in
            guard let url = Bundle.main.url(forResource: name, withExtension: "js") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        guard let reader = parts[0], let extractor = parts[1] else { return nil }
        return reader + "\n;\n" + extractor
    }()
}

/// An off-screen WKWebView on the shared `BrowserData` store, used by the search, fetch and browser tools.
/// It stays attached to the key window at near-zero alpha so WebKit does not throttle it. (On a Mac it lives in a
/// borderless, fully transparent window parked far outside every screen.)
@MainActor
final class HiddenWebView: NSObject, WKNavigationDelegate, WKUIDelegate, PluginPage, KeepablePage {
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    let webView: WKWebView
    /// Names the page to the model ("page7"), for `browser_show(page:)` after a tool failed on it (`KeptPages`).
    let pageID: String
    private static var pageCount = 0
    /// Fetch views carry the page reader as a user script, injected once per page by WebKit.
    let injectsReader: Bool
    private var continuation: CheckedContinuation<Void, Error>?
    private var allowNextNavigation = false
    private var guardNavigations: Bool
    private var resolver: any HostResolving
    /// The navigation a pending `load` is waiting for. Callbacks about any other (an abandoned one) are ignored.
    private var activeNavigation: WKNavigation?
    private var progressObservation: NSKeyValueObservation?
    /// Page-load estimate (0...1), as the web view reports it.
    var onProgress: (@MainActor (Double) -> Void)?
    /// Plays the background loading sound while it is on (`BackgroundLoadingSound`). Off only for the developer test's
    /// control page.
    var playsLoadingSound = true

    init(guardNavigations: Bool = true, resolver: any HostResolving = SystemHostResolver(), injectsReader: Bool = false,
         store: WKWebsiteDataStore? = nil) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store ?? BrowserData.store
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // New windows reach `createWebViewWith`, which drops them unless a click just asked for them (`acceptPopups`).
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        if guardNavigations { LocalNetworkRules.install(in: config.userContentController) }
        if injectsReader, let source = ReadabilitySource.script {
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: CGRect(origin: .zero, size: Self.layoutSize), configuration: config)
        Self.pageCount += 1
        pageID = "page\(Self.pageCount)"
        webView.customUserAgent = Self.userAgent
        #if canImport(UIKit)
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        #endif
        self.guardNavigations = guardNavigations
        self.resolver = resolver
        self.injectsReader = injectsReader
        super.init()
        DiagnosticCounters.shared.webViewCreated()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        BackgroundLoadingSound.shared.register(self)
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            let value = view.estimatedProgress
            // KVO for a web view fires on the main thread.
            MainActor.assumeIsolated { self?.onProgress?(value) }
        }
        park()
    }

    /// Puts the view back off screen: nearly transparent, untouchable. A frozen view goes out of every window instead.
    private func park() {
        guard !disposed else { return }
        #if canImport(UIKit)
        webView.transform = .identity
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.autoresizingMask = []
        webView.frame = CGRect(x: 0, y: 0, width: Self.layoutSize.width, height: Self.layoutSize.height)
        if isFrozen {
            webView.removeFromSuperview()
        } else if let window = Self.keyWindow {
            window.insertSubview(webView, at: 0)
        } else {
            webView.removeFromSuperview() // out of a card or sheet, whatever happens to it next
        }
        #else
        webView.autoresizingMask = []
        webView.frame = CGRect(x: 0, y: 0, width: Self.layoutSize.width, height: Self.layoutSize.height)
        if isFrozen { webView.removeFromSuperview() } else { OffscreenWebHost.shared.attach(webView) }
        #endif
    }

    // MARK: Frozen

    /// Parked out of every window (`freeze`): WebKit treats a view in no window as hidden for good and lets its page's
    /// process be suspended, so scripts, timers and animations stop draining the battery; the page (its DOM, scroll,
    /// form input and sign-ins) stays as it is. A claim still shows it (Open page): ownership doesn't change, only where
    /// the view goes when nothing holds it.
    private(set) var isFrozen = false

    /// After its reply: out of the window when nothing shows it, else as soon as nothing does. It plays no loading
    /// sound (that would keep its process awake).
    func freeze() {
        guard !disposed, !isFrozen else { return }
        isFrozen = true
        BackgroundLoadingSound.shared.unregister(self)
        if owner == nil { park() }
    }

    /// Before the page is used again (a tool call): back in the window, running at full speed.
    func thaw() {
        guard !disposed, isFrozen else { return }
        isFrozen = false
        BackgroundLoadingSound.shared.register(self)
        if owner == nil { park() }
    }

    /// The size pages are laid out at, wherever the view is: a phone's screen. A card's live preview scales it down.
    nonisolated static let layoutSize = CGSize(width: 390, height: 844)

    // MARK: On screen

    /// Who wants the view on screen. A web view has one superview, so one claim holds it at a time
    /// (`ScreenOwnership`): a sheet before a card's preview, the newest of equals; with none it is parked.
    private var claims: [ScreenClaim] = []
    private weak var owner: ScreenClaim?
    private static var claimCount = 0

    /// Shown in a sheet or a card now.
    var isOnScreen: Bool { owner != nil }
    /// Shown in a sheet now (the user is looking at it full size).
    var isInSheet: Bool { owner?.kind == .sheet }

    /// Asks for the view in `container`. It moves there when the claim is the strongest whose container is in a
    /// window; `release` gives it back (to the next claim, or off screen).
    func claim(_ kind: ScreenClaim.Kind, in container: PlatformView, interactive: Bool) -> ScreenClaim {
        Self.claimCount += 1
        let claim = ScreenClaim(kind: kind, container: container, interactive: interactive, order: Self.claimCount)
        claims.append(claim)
        updatePlacement()
        return claim
    }

    func release(_ claim: ScreenClaim) {
        claims.removeAll { $0 === claim }
        updatePlacement()
    }

    /// Moves the view to the claim that should hold it now (a container joined or left a window, or a claim changed).
    func updatePlacement() {
        guard !disposed else { return }
        claims.removeAll { $0.container == nil }
        let index = ScreenOwnership.owner(claims.map { .init(kind: $0.kind, order: $0.order, inWindow: $0.container?.window != nil) })
        let top = index.map { claims[$0] }
        owner = top
        guard let top, let container = top.container else {
            if isAttachedToStage { park() }
            return
        }
        if webView.superview !== container {
            webView.removeFromSuperview()
            container.addSubview(webView)
        }
        layout(in: container, preview: top.kind == .preview, interactive: top.interactive)
    }

    /// The view is in a sheet or a card (not parked).
    private var isAttachedToStage: Bool {
        guard let superview = webView.superview else { return false }
        return claims.contains { $0.container === superview } || !isParkedSuperview(superview)
    }

    private func isParkedSuperview(_ view: PlatformView) -> Bool {
        #if canImport(UIKit)
        view is UIWindow
        #else
        view.window === OffscreenWebHost.shared.window
        #endif
    }

    /// Lays the view out in its container again (the container changed size).
    func layoutOnStage(_ container: PlatformView) {
        guard let owner, owner.container === container, webView.superview === container else { return }
        layout(in: container, preview: owner.kind == .preview, interactive: owner.interactive)
    }

    private func layout(in container: PlatformView, preview: Bool, interactive: Bool) {
        let size = Self.layoutSize
        #if canImport(UIKit)
        webView.alpha = 1
        if preview {
            // Laid out at full size and drawn at the card's width: the page looks as it would on the phone.
            let scale = container.bounds.width / size.width
            webView.autoresizingMask = []
            webView.transform = .identity
            webView.bounds = CGRect(origin: .zero, size: size)
            webView.transform = CGAffineTransform(scaleX: scale, y: scale)
            webView.center = CGPoint(x: size.width * scale / 2, y: size.height * scale / 2)
            webView.isUserInteractionEnabled = false
        } else {
            webView.transform = .identity
            webView.frame = container.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            webView.isUserInteractionEnabled = interactive
        }
        #else
        if preview {
            // The container's bounds are scaled (as NSScrollView magnifies), so the page keeps its phone layout.
            let scale = max(container.frame.width / size.width, 0.01)
            container.setBoundsSize(NSSize(width: container.frame.width / scale, height: container.frame.height / scale))
            webView.autoresizingMask = []
            webView.frame = CGRect(origin: .zero, size: size)
        } else {
            container.setBoundsSize(container.frame.size)
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
        }
        (container as? WebStageView)?.passesEvents = !preview && interactive
        #endif
    }

    #if canImport(UIKit)
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
    #endif

    private var disposed = false
    var isDisposed: Bool { disposed }

    /// Tears the view down for good.
    func dispose() {
        if !disposed { disposed = true; DiagnosticCounters.shared.webViewDisposed() }
        claims.removeAll()
        owner = nil
        BackgroundLoadingSound.shared.unregister(self)
        progressObservation = nil
        onProgress = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    /// Makes a used view ready for the next page: stops what is running, drops the page, forgets callbacks.
    func reset(resolver: any HostResolving, guardNavigations: Bool) {
        stop()
        onProgress = nil
        allowNextNavigation = false
        self.resolver = resolver
        self.guardNavigations = guardNavigations
        activeNavigation = nil
        hasAbortedScript = false // the page goes anyway
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// Interrupts whatever is pending: a load waiting for its navigation ends with `CancellationError`.
    func stop() {
        finish(.failure(CancellationError()))
        webView.stopLoading()
    }

    var currentURL: URL? { webView.url }

    /// Loads a URL and waits for the navigation to finish.
    func load(_ url: URL, timeout: Duration = FetchTimeouts.standard.load) async throws {
        try await wait(timeout: timeout) { self.webView.load(URLRequest(url: url)) }
    }

    /// Loads literal HTML (used by tests with saved fixtures).
    func load(html: String, baseURL: URL?, timeout: Duration = FetchTimeouts.standard.load) async throws {
        allowNextNavigation = true
        try await wait(timeout: timeout) { self.webView.loadHTMLString(html, baseURL: baseURL) }
    }

    private func wait(timeout: Duration, start: () -> WKNavigation?) async throws {
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(.failure(WebToolError.timeout))
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // A load started while another is pending replaces it; the earlier caller must not wait forever.
                if let earlier = self.continuation {
                    self.continuation = nil
                    earlier.resume(throwing: CancellationError())
                }
                self.continuation = cont
                self.activeNavigation = start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        if case .failure = result { webView.stopLoading() }
        cont.resume(with: result)
    }

    /// A `callAsync` or `callAgent` call (the model's script, a click or typing) ran out of time or was cancelled.
    /// `stopLoading()` doesn't stop its promises or timers, so it may still act on the page later (a delayed click, a
    /// POST); `discardAbortedScript` replaces the document.
    private(set) var hasAbortedScript = false

    private func abortScript() {
        hasAbortedScript = true
        webView.stopLoading()
    }

    /// After an aborted script, loads a blank document and waits for it (a few seconds at most), so nothing the script
    /// left pending can run. The page is lost. Not cancellable: Stop browsing is what usually gets here. True when the
    /// document was replaced.
    func discardAbortedScript() async -> Bool {
        guard hasAbortedScript else { return false }
        hasAbortedScript = false
        return await Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                try await self.wait(timeout: .seconds(5)) { self.webView.load(URLRequest(url: URL(string: "about:blank")!)) }
                return true
            } catch {
                return false
            }
        }.value
    }

    /// Evaluates JavaScript in the page and returns the result as a string. A page that never answers ends with
    /// `WebToolError.timeout` after `timeout` (the load is stopped), and cancelling returns at once.
    func evaluate(_ js: String, timeout: Duration) async throws -> String {
        // The app's own probes and readers run here: they schedule nothing, so a cut-short one leaves the page be.
        try await Deadline.run(timeout, timeoutError: WebToolError.timeout, onAbort: { [weak self] in self?.webView.stopLoading() }) { [webView] in
            do {
                let value = try await webView.evaluateJavaScript(js)
                return (value as? String) ?? ""
            } catch {
                throw WebToolError.script(error.localizedDescription)
            }
        }
    }

    /// Runs a function body that may `await` (a plugin's promise) and returns its string result, like `evaluate`.
    func callAsync(_ body: String, timeout: Duration) async throws -> String {
        rememberFocus()
        defer { releaseFocus() }
        return try await Deadline.run(timeout, timeoutError: WebToolError.timeout, onAbort: { [weak self] in self?.abortScript() }) { [webView] in
            do {
                let value = try await webView.callAsyncJavaScript(body, contentWorld: .page)
                return (value as? String) ?? ""
            } catch {
                throw WebToolError.script(error.localizedDescription)
            }
        }
    }

    /// The isolated world of the index tools (`BrowserAgentScript`): the page shares the DOM, not the script.
    static let agentWorld = WKContentWorld.world(name: "StrataAgent")

    /// Runs a function body in `agentWorld` with `input` as its argument, like `callAsync`.
    func callAgent(_ body: String, input: String, timeout: Duration) async throws -> String {
        rememberFocus()
        defer { releaseFocus() }
        return try await Deadline.run(timeout, timeoutError: WebToolError.timeout, onAbort: { [weak self] in self?.abortScript() }) { [webView] in
            do {
                let value = try await webView.callAsyncJavaScript(body, arguments: ["input": input], in: nil, contentWorld: Self.agentWorld)
                return (value as? String) ?? ""
            } catch {
                throw WebToolError.script(error.localizedDescription)
            }
        }
    }

    var isLoading: Bool { webView.isLoading }

    /// What the view shows, as a PNG at most `width` pixels wide.
    func snapshotPNG(width: Int) async throws -> Data {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = true
        #if canImport(UIKit)
        // iOS snapshots the view as drawn: a parked view (nearly transparent, under the app's own views) is drawn
        // opaque for the moment it takes.
        let parked = webView.alpha < 1
        if parked { webView.alpha = 1 }
        defer { if parked && !isOnScreen { webView.alpha = 0.01 } }
        #endif
        let image = try await webView.takeSnapshot(configuration: config)
        #if canImport(UIKit)
        let cg = image.cgImage
        #else
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
        guard let cg, let png = SnapshotPNG.encode(cg, width: width) else { throw WebToolError.script("could not take a screenshot.") }
        return png
    }

    #if canImport(UIKit)
    /// What had the focus in the app before a call into the page (the composer, say), to give it back.
    private weak var appResponder: UIResponder?
    #endif

    /// Notes what has the app's focus before script runs in the page.
    private func rememberFocus() {
        #if canImport(UIKit)
        if let current = FirstResponder.current, !((current as? UIView)?.isDescendant(of: webView) ?? false) { appResponder = current }
        #endif
    }

    /// Script the app runs counts as a user's gesture, so a field it (or the page's handler) focuses takes the keyboard.
    /// Unless the user has the page in the sheet, the focus goes back to where it was.
    func releaseFocus() {
        #if canImport(UIKit)
        guard !isInSheet, let current = FirstResponder.current as? UIView, current.isDescendant(of: webView) else { return }
        current.resignFirstResponder()
        appResponder?.becomeFirstResponder()
        #endif
    }

    private var popupsUntil: ContinuousClock.Instant?

    func acceptPopups(for duration: Duration) { popupsUntil = .now + duration }

    /// A link with a target or `window.open` right after a click opens in this page (the model has one page); any
    /// other new window is dropped.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let until = popupsUntil, ContinuousClock.now < until, let url = navigationAction.request.url,
           url.scheme?.lowercased().hasPrefix("http") == true {
            popupsUntil = nil
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// Ends a pending `load` with `CancellationError` but leaves the page loading: a plugin runs on a page that is
    /// ready to read though it has not finished (and may never).
    func abandonLoad() {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(throwing: CancellationError())
    }

    func evaluateString(_ js: String) async throws -> String {
        try await evaluate(js, timeout: FetchTimeouts.standard.script)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if allowNextNavigation { allowNextNavigation = false; return .allow }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "blob" || scheme == "data" || scheme == "javascript" { return .allow }
        guard guardNavigations else { return .allow }
        do {
            // Subframes too: an iframe pointed at a router's admin page is as much a way in as the page itself.
            try await URLGuard.validate(url, resolver: resolver)
            return .allow
        } catch {
            if isMainFrame { finish(.failure(error)) }
            return .cancel
        }
    }

    /// A callback for the navigation being waited for (or any, when none is tracked).
    private func isCurrent(_ navigation: WKNavigation?) -> Bool { activeNavigation == nil || navigation === activeNavigation }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        BackgroundLoadingSound.shared.pageDidCommit(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isCurrent(navigation) { finish(.success(())) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isCurrent(navigation) { finish(.failure(WebToolError.loadFailure(error))) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A policy cancel already resolved the continuation with the guard error.
        if isCurrent(navigation) { finish(.failure(WebToolError.loadFailure(error))) }
    }
}

#if canImport(UIKit)
/// The app's first responder, found by asking whoever takes a nil-targeted action.
@MainActor
enum FirstResponder {
    fileprivate static weak var found: UIResponder?

    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.strataReportFirstResponder), to: nil, from: nil, for: nil)
        return found
    }
}

extension UIResponder {
    @objc fileprivate func strataReportFirstResponder() { FirstResponder.found = self }
}
#endif

#if canImport(AppKit)
/// The window the hidden web views of a Mac live in. A web view with no window is treated as not visible and WebKit
/// throttles it; one in a transparent, borderless window outside every screen is loaded and scripted like a visible one,
/// and nothing is ever drawn or focusable.
@MainActor
final class OffscreenWebHost {
    static let shared = OffscreenWebHost()

    private(set) lazy var window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: HiddenWebView.layoutSize.width, height: HiddenWebView.layoutSize.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.canHide = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenAuxiliary]
        window.level = .normal
        window.orderFrontRegardless()
        return window
    }()

    func attach(_ view: NSView) {
        window.contentView?.addSubview(view)
    }
}
#endif
