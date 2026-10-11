import Foundation
import UIKit
import WebKit

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

/// An off-screen WKWebView with a non-persistent data store, used by the search and fetch tools.
/// It stays attached to the key window at near-zero alpha so WebKit does not throttle it.
@MainActor
final class HiddenWebView: NSObject, WKNavigationDelegate {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?
    private var allowNextNavigation = false
    private let guardNavigations: Bool
    private let resolver: any HostResolving

    init(guardNavigations: Bool = true, resolver: any HostResolving = SystemHostResolver()) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        self.guardNavigations = guardNavigations
        self.resolver = resolver
        super.init()
        DiagnosticCounters.shared.webViewCreated()
        webView.navigationDelegate = self
        if let window = Self.keyWindow {
            window.insertSubview(webView, at: 0)
        }
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private var disposed = false

    func dispose() {
        if !disposed { disposed = true; DiagnosticCounters.shared.webViewDisposed() }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
    }

    /// Loads a URL and waits for the navigation to finish.
    func load(_ url: URL, timeout: Duration = .seconds(15)) async throws {
        try await wait(timeout: timeout) { self.webView.load(URLRequest(url: url)) }
    }

    /// Loads literal HTML (used by tests with saved fixtures).
    func load(html: String, baseURL: URL?, timeout: Duration = .seconds(15)) async throws {
        allowNextNavigation = true
        try await wait(timeout: timeout) { self.webView.loadHTMLString(html, baseURL: baseURL) }
    }

    private func wait(timeout: Duration, start: () -> Void) async throws {
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(.failure(WebToolError.timeout))
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                start()
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

    /// Evaluates JavaScript in the page and returns the result as a string.
    func evaluateString(_ js: String) async throws -> String {
        do {
            let value = try await webView.evaluateJavaScript(js)
            return (value as? String) ?? ""
        } catch {
            throw WebToolError.script(error.localizedDescription)
        }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(WebToolError.navigation(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A policy cancel already resolved the continuation with the guard error.
        finish(.failure(WebToolError.navigation(error.localizedDescription)))
    }
}
