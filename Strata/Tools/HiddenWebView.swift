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

    var errorDescription: String? {
        switch self {
        case .timeout: String(localized: "The page took too long to load.")
        case .navigation(let m): String(localized: "The page failed to load: \(m)")
        case .script(let m): String(localized: "Page script failed: \(m)")
        }
    }
}

/// One non-persistent data store for the whole session: every hidden view shares it (cookies last until the app quits,
/// nothing is written to disk), instead of each fetch creating and tearing down its own.
@MainActor
enum SharedWebData {
    static let store = WKWebsiteDataStore.nonPersistent()
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

/// An off-screen WKWebView with a non-persistent data store, used by the search and fetch tools.
/// It stays attached to the key window at near-zero alpha so WebKit does not throttle it. (On a Mac it lives in a
/// borderless, fully transparent window parked far outside every screen.)
@MainActor
final class HiddenWebView: NSObject, WKNavigationDelegate, FetchablePage {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    let webView: WKWebView
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

    init(guardNavigations: Bool = true, resolver: any HostResolving = SystemHostResolver(), injectsReader: Bool = false) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = SharedWebData.store
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        if injectsReader, let source = ReadabilitySource.script {
            config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
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
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            let value = view.estimatedProgress
            // KVO for a web view fires on the main thread.
            MainActor.assumeIsolated { self?.onProgress?(value) }
        }
        #if canImport(UIKit)
        if let window = Self.keyWindow {
            window.insertSubview(webView, at: 0)
        }
        #else
        OffscreenWebHost.shared.attach(webView)
        #endif
    }

    #if canImport(UIKit)
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
    #endif

    private var disposed = false

    /// Tears the view down for good.
    func dispose() {
        if !disposed { disposed = true; DiagnosticCounters.shared.webViewDisposed() }
        progressObservation = nil
        onProgress = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
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

    /// Evaluates JavaScript in the page and returns the result as a string. A page that never answers ends with
    /// `WebToolError.timeout` after `timeout` (the load is stopped), and cancelling returns at once.
    func evaluate(_ js: String, timeout: Duration) async throws -> String {
        try await Deadline.run(timeout, timeoutError: WebToolError.timeout, onAbort: { [weak self] in self?.webView.stopLoading() }) { [webView] in
            do {
                let value = try await webView.evaluateJavaScript(js)
                return (value as? String) ?? ""
            } catch {
                throw WebToolError.script(error.localizedDescription)
            }
        }
    }

    func evaluateString(_ js: String) async throws -> String {
        try await evaluate(js, timeout: FetchTimeouts.standard.script)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if allowNextNavigation { allowNextNavigation = false; return .allow }
        guard navigationAction.targetFrame?.isMainFrame ?? true else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "blob" || scheme == "data" { return .allow }
        guard guardNavigations else { return .allow }
        do {
            try await URLGuard.validate(url, resolver: resolver)
            return .allow
        } catch {
            finish(.failure(error))
            return .cancel
        }
    }

    /// A callback for the navigation being waited for (or any, when none is tracked).
    private func isCurrent(_ navigation: WKNavigation?) -> Bool { activeNavigation == nil || navigation === activeNavigation }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isCurrent(navigation) { finish(.success(())) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isCurrent(navigation) { finish(.failure(WebToolError.navigation(error.localizedDescription))) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A policy cancel already resolved the continuation with the guard error.
        if isCurrent(navigation) { finish(.failure(WebToolError.navigation(error.localizedDescription))) }
    }
}

#if canImport(AppKit)
/// The window the hidden web views of a Mac live in. A web view with no window is treated as not visible and WebKit
/// throttles it; one in a transparent, borderless window outside every screen is loaded and scripted like a visible one,
/// and nothing is ever drawn or focusable.
@MainActor
final class OffscreenWebHost {
    static let shared = OffscreenWebHost()

    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 390, height: 844),
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
