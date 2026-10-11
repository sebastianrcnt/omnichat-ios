import Foundation

/// What the fetch pipeline needs of a web page, so it can be tested with a fake.
@MainActor
protocol FetchablePage: AnyObject {
    /// The URL currently showing (nil or about:blank before anything loaded).
    var currentURL: URL? { get }
    /// Page-load estimate (0...1) while loading.
    var onProgress: (@MainActor (Double) -> Void)? { get set }
    /// Loads the URL; throws `WebToolError.timeout` when it has not finished after `timeout`.
    func load(_ url: URL, timeout: Duration) async throws
    /// Evaluates JavaScript and returns a string; throws `WebToolError.timeout` after `timeout`.
    func evaluate(_ js: String, timeout: Duration) async throws -> String
    /// Stops whatever the page is doing.
    func stop()
}

/// Load a page, wait for it to settle, extract its text.
enum FetchPipeline {
    /// The page text is capped in the page itself, so a huge document is never copied across to Swift.
    static let maxPageCharacters = 400_000

    struct Extracted: Decodable, Sendable { var title: String; var text: String }

    /// - Parameter progress: called with a value that only goes up, at most about ten times a second, ending with 1.
    @MainActor
    static func fetch(_ url: URL, page: some FetchablePage, timeouts: FetchTimeouts = .standard,
                      progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> FetchedPage {
        let tracker = ProgressTracker(progress)
        tracker.report(0)
        page.onProgress = { tracker.report(FetchProgress.loading($0)) }
        defer { page.onProgress = nil }

        do {
            try await page.load(url, timeout: timeouts.load)
        } catch WebToolError.timeout {
            // A page that never finishes loading (a stuck tracker, a streaming ad) may still have all its content.
            guard let current = page.currentURL, current.absoluteString != "about:blank" else { throw WebToolError.timeout }
            let state = (try? await page.evaluate("document.readyState", timeout: timeouts.probe)) ?? ""
            guard state == "interactive" || state == "complete" else { throw WebToolError.timeout }
        }
        tracker.report(FetchProgress.loaded)

        try await Task.sleep(for: timeouts.settle) // client-side rendering
        tracker.report(FetchProgress.settled)

        tracker.report(FetchProgress.extracting)
        let json = try await page.evaluate(WebFetchTool.extractionScript(maxCharacters: maxPageCharacters), timeout: timeouts.script)
        tracker.report(FetchProgress.extracted)

        let finalURL = page.currentURL?.absoluteString ?? url.absoluteString
        let built = try await Task.detached(priority: .userInitiated) { try build(json: json, url: finalURL) }.value
        try Task.checkCancellation()
        tracker.report(FetchProgress.done)
        return built
    }

    /// Decode the script's JSON and normalize the text. Pure, and run off the main thread.
    nonisolated static func build(json: String, url: String) throws -> FetchedPage {
        guard let data = json.data(using: .utf8), let e = try? JSONDecoder().decode(Extracted.self, from: data) else {
            throw WebToolError.script("could not read the page.")
        }
        let body = PageTextFormatter.normalizeFull(e.text)
        if body.isEmpty { throw WebToolError.script("the page has no readable text.") }
        return FetchedPage(title: e.title.trimmingCharacters(in: .whitespacesAndNewlines), url: url, text: body)
    }

    @MainActor
    private final class ProgressTracker {
        private var state = FetchProgress()
        private let sink: @MainActor (Double) -> Void
        init(_ sink: @escaping @MainActor (Double) -> Void) { self.sink = sink }
        func report(_ value: Double) { if let v = state.advance(to: value) { sink(v) } }
    }
}
