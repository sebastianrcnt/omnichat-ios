import Testing
import Foundation
@testable import Strata

// MARK: - Deadline

@MainActor
struct DeadlineTests {
    @Test func returnsTheResultOfAFastOperation() async throws {
        let value = try await Deadline.run(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func propagatesTheOperationsError() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await Deadline.run(.seconds(5)) { throw Boom() } as Int }
    }

    @Test func timesOutAndRunsOnAbort() async {
        var aborted = false
        let start = ContinuousClock.now
        await #expect(throws: WebToolError.timeout) {
            try await Deadline.run(.milliseconds(100), onAbort: { aborted = true }) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        #expect(aborted)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    /// The operation never returns and cannot be cancelled (a stuck WebKit call): the caller is still released.
    @Test func releasesTheCallerEvenWhenTheOperationIgnoresCancellation() async {
        let start = ContinuousClock.now
        await #expect(throws: WebToolError.timeout) {
            try await Deadline.run(.milliseconds(100)) {
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
                return 1
            }
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func cancellationReturnsPromptlyAndAborts() async throws {
        var aborted = false
        let task = Task { @MainActor in
            try await Deadline.run(.seconds(60), onAbort: { aborted = true }) {
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(aborted)
    }

    @Test func alreadyCancelledNeverStarts() async {
        var ran = false
        let task = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(50)) // cancelled while sleeping
            return try await Deadline.run(.seconds(5)) { ran = true; return 1 }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!ran)
    }
}

// MARK: - Progress

struct FetchProgressTests {
    @Test func loadingTakesTheFirstEightyPercent() {
        #expect(FetchProgress.loading(0) == 0)
        #expect(FetchProgress.loading(0.5) == 0.4)
        #expect(FetchProgress.loading(1) == 0.8)
        #expect(FetchProgress.loading(1.7) == 0.8) // clamped
        #expect(FetchProgress.loading(-1) == 0)
    }

    @Test func valuesOnlyGoUp() {
        var p = FetchProgress()
        let t0 = ContinuousClock.now
        #expect(p.advance(to: 0.1, at: t0) == 0.1)
        #expect(p.advance(to: 0.05, at: t0 + .seconds(1)) == nil)
        #expect(p.advance(to: 0.1, at: t0 + .seconds(2)) == nil)
        #expect(p.advance(to: 0.3, at: t0 + .seconds(3)) == 0.3)
    }

    @Test func updatesAreLimitedToAboutTenPerSecond() {
        var p = FetchProgress()
        let t0 = ContinuousClock.now
        var published: [Double] = []
        for i in 0..<100 { // a value every 10 ms for a second
            if let v = p.advance(to: 0.001 + Double(i) * 0.005, at: t0 + .milliseconds(i * 10)) { published.append(v) }
        }
        #expect(published.count >= 9 && published.count <= 11)
        #expect(published == published.sorted())
    }

    @Test func theFinalValueAlwaysGetsThrough() {
        var p = FetchProgress()
        let t0 = ContinuousClock.now
        #expect(p.advance(to: 0.9, at: t0) == 0.9)
        #expect(p.advance(to: 1.0, at: t0 + .milliseconds(1)) == 1.0) // inside the 100 ms window
    }
}

@MainActor
struct ToolProgressTests {
    @Test func reportsAreMonotonic() {
        let p = ToolProgress()
        p.report("a", 0.4)
        p.report("a", 0.2)
        #expect(p.value(for: "a") == 0.4)
        p.report("a", 2)
        #expect(p.value(for: "a") == 1)
        #expect(p.value(for: "b") == nil)
    }

    @Test func aSuccessfulCallFillsThenFades() async throws {
        let p = ToolProgress()
        p.report("a", 0.5)
        p.finish("a", success: true)
        #expect(p.value(for: "a") == 1)
        try await Task.sleep(for: ToolProgress.fadeDelay + .milliseconds(300))
        #expect(p.value(for: "a") == nil)
    }

    @Test func aFailedCallLosesItsFillAtOnce() {
        let p = ToolProgress()
        p.report("a", 0.5)
        p.finish("a", success: false)
        #expect(p.value(for: "a") == nil)
    }

    @Test func finishingACallThatNeverReportedDoesNothing() {
        let p = ToolProgress()
        p.finish("x", success: true)
        #expect(p.value(for: "x") == nil)
    }
}

// MARK: - Pipeline

@MainActor
private final class FakePage: FetchablePage {
    enum Load { case succeed([Double]), timeout, hang }
    var currentURL: URL?
    var onProgress: (@MainActor (Double) -> Void)?
    var loadBehavior: Load = .succeed([0.2, 0.6, 1.0])
    var readyState: Result<String, Error> = .success("complete")
    var extraction: Result<String, Error> = .success(#"{"title":"  A page ","text":"Hello\n\n\n  world   here","readable":true}"#)
    private(set) var evaluated: [String] = []
    private(set) var timeoutsSeen: [Duration] = []
    private(set) var stopped = false
    var landedURL = URL(string: "https://example.com/final")!

    func load(_ url: URL, timeout: Duration) async throws {
        timeoutsSeen.append(timeout)
        switch loadBehavior {
        case .succeed(let steps):
            for s in steps { onProgress?(s); try await Task.sleep(for: .milliseconds(120)) }
            currentURL = landedURL
        case .timeout:
            throw WebToolError.timeout
        case .hang:
            try await Task.sleep(for: .seconds(60))
        }
    }

    func evaluate(_ js: String, timeout: Duration) async throws -> String {
        evaluated.append(js)
        timeoutsSeen.append(timeout)
        if js == "document.readyState" { return try readyState.get() }
        return try extraction.get()
    }

    func stop() { stopped = true }
}

@MainActor
struct FetchPipelineTests {
    private let url = URL(string: "https://example.com/start")!
    private let fast = FetchTimeouts(load: .seconds(2), script: .seconds(2), probe: .milliseconds(200), settle: .milliseconds(10), overall: .seconds(5))

    @Test func extractsAndNormalizesThePage() async throws {
        let page = FakePage()
        let result = try await FetchPipeline.fetch(url, page: page, timeouts: fast)
        #expect(result.title == "A page")
        #expect(result.text == "Hello\n\nworld here")
        #expect(result.url == "https://example.com/final")
        #expect(page.evaluated.count == 1 && page.evaluated[0].contains("strataExtract"))
        #expect(page.onProgress == nil) // detached afterwards
    }

    @Test func progressIsMonotonicMappedAndEndsAtOne() async throws {
        let page = FakePage()
        page.loadBehavior = .succeed(stride(from: 0.1, through: 1.0, by: 0.1).map { $0 })
        var seen: [Double] = []
        _ = try await FetchPipeline.fetch(url, page: page, timeouts: fast) { seen.append($0) }
        #expect(seen == seen.sorted())
        #expect(Set(seen).count == seen.count)
        #expect(seen.last == 1.0)
        let loading = seen.filter { $0 <= FetchProgress.loadShare + 1e-9 }
        #expect(!loading.isEmpty) // the load itself used 0...0.8
        #expect(seen.contains { $0 > FetchProgress.loadShare }) // extraction used the rest
    }

    @Test func aFailureReportsNoCompletion() async {
        let page = FakePage()
        page.extraction = .failure(WebToolError.timeout)
        var seen: [Double] = []
        await #expect(throws: WebToolError.timeout) {
            _ = try await FetchPipeline.fetch(url, page: page, timeouts: fast) { seen.append($0) }
        }
        #expect(seen.last != 1.0)
    }

    @Test func aScriptTimeoutIsReported() async {
        let page = FakePage()
        page.extraction = .failure(WebToolError.timeout)
        await #expect(throws: WebToolError.timeout) { _ = try await FetchPipeline.fetch(url, page: page, timeouts: fast) }
    }

    @Test func aLoadTimeoutOnAnInteractivePageProceedsToExtraction() async throws {
        for state in ["interactive", "complete"] {
            let page = FakePage()
            page.loadBehavior = .timeout
            page.currentURL = URL(string: "https://example.com/partial")
            page.readyState = .success(state)
            let result = try await FetchPipeline.fetch(url, page: page, timeouts: fast)
            #expect(result.url == "https://example.com/partial", "state \(state)")
            #expect(page.evaluated.first == "document.readyState")
            #expect(page.timeoutsSeen.contains(fast.probe))
        }
    }

    @Test func aLoadTimeoutOnAStillLoadingPageFails() async {
        let page = FakePage()
        page.loadBehavior = .timeout
        page.currentURL = URL(string: "https://example.com/partial")
        page.readyState = .success("loading")
        await #expect(throws: WebToolError.timeout) { _ = try await FetchPipeline.fetch(url, page: page, timeouts: fast) }
        #expect(page.evaluated == ["document.readyState"]) // never tried to extract
    }

    @Test func aLoadTimeoutWithNothingShowingFailsWithoutProbing() async {
        for current in [nil, URL(string: "about:blank")] {
            let page = FakePage()
            page.loadBehavior = .timeout
            page.currentURL = current
            await #expect(throws: WebToolError.timeout) { _ = try await FetchPipeline.fetch(url, page: page, timeouts: fast) }
            #expect(page.evaluated.isEmpty)
        }
    }

    @Test func aFailedProbeFails() async {
        let page = FakePage()
        page.loadBehavior = .timeout
        page.currentURL = URL(string: "https://example.com/partial")
        page.readyState = .failure(WebToolError.timeout)
        await #expect(throws: WebToolError.timeout) { _ = try await FetchPipeline.fetch(url, page: page, timeouts: fast) }
    }

    @Test func aPageWithNoTextIsAnError() async {
        let page = FakePage()
        page.extraction = .success(#"{"title":"t","text":"  \n \n","readable":false}"#)
        await #expect(throws: WebToolError.self) { _ = try await FetchPipeline.fetch(url, page: page, timeouts: fast) }
    }

    @Test func eachPhaseUsesItsOwnTimeout() async throws {
        let page = FakePage()
        _ = try await FetchPipeline.fetch(url, page: page, timeouts: fast)
        #expect(page.timeoutsSeen == [fast.load, fast.script])
    }

    @Test func cancellingDuringTheLoadReturnsPromptly() async throws {
        let page = FakePage()
        page.loadBehavior = .hang
        let task = Task { @MainActor in try await FetchPipeline.fetch(url, page: page, timeouts: fast) }
        try await Task.sleep(for: .milliseconds(80))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }

    @Test func cancellingDuringTheSettleWaitReturnsPromptly() async throws {
        let page = FakePage()
        page.loadBehavior = .succeed([1.0])
        var slow = fast
        slow.settle = .seconds(30)
        let task = Task { @MainActor in try await FetchPipeline.fetch(url, page: page, timeouts: slow) }
        try await Task.sleep(for: .milliseconds(300)) // inside the settle wait
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }

    @Test func buildDecodesOffTheMainThread() throws {
        let page = try FetchPipeline.build(json: #"{"title":" T ","text":"a   b\n\n\n\nc"}"#, url: "https://x.test/")
        #expect(page == FetchedPage(title: "T", url: "https://x.test/", text: "a b\n\nc"))
        #expect(throws: WebToolError.self) { try FetchPipeline.build(json: "nope", url: "u") }
    }
}

// MARK: - web_fetch as a whole

@MainActor
struct FetchDeadlineTests {
    private struct PublicResolver: HostResolving {
        func resolve(_ host: String) async -> [String] { ["93.184.216.34"] }
    }

    private func tool(timeouts: FetchTimeouts, loader: @escaping PageLoader) -> WebFetchTool {
        var t = WebFetchTool(resolver: PublicResolver(), cache: PageCache(), limit: 1000, loader: loader)
        t.timeouts = timeouts
        return t
    }

    @Test func theOverallDeadlineEndsAFetchThatNeverReturns() async {
        var timeouts = FetchTimeouts.standard
        timeouts.overall = .milliseconds(300)
        let t = tool(timeouts: timeouts) { _ in
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } // ignores cancellation
            return FetchedPage(title: "", url: "", text: "")
        }
        let start = ContinuousClock.now
        let out = await t.run(urlString: "https://example.com/slow")
        #expect(out.isError)
        #expect(out.text.contains("took too long"))
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func stopInterruptsAFetchInAnyPhaseWithinHalfASecond() async throws {
        let t = tool(timeouts: .standard) { _ in
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            return FetchedPage(title: "", url: "", text: "")
        }
        let task = Task { @MainActor in await t.run(urlString: "https://example.com/slow") }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        let out = await task.value
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(out.isError)
    }

    @Test func aFetchThatFinishesBeforeTheDeadlineReturnsItsSlice() async {
        let t = tool(timeouts: .standard) { _ in FetchedPage(title: "T", url: "https://example.com/a", text: "Some text here") }
        let out = await t.run(urlString: "https://example.com/a")
        #expect(!out.isError)
        #expect(out.text.contains("Some text here"))
        #expect(out.sources.count == 1)
    }
}

// MARK: - Tool context

@MainActor
struct ToolContextTests {
    private struct ReportingTool: ToolExecuting {
        var fail = false
        func execute(name: String, arguments: String) async -> ToolOutput {
            let id = ToolContext.callID
            await MainActor.run { if let id { ToolProgress.shared.report(id, 0.5) } }
            return ToolOutput(text: id ?? "no id", isError: fail)
        }
    }

    @Test func aToolSeesItsCallIdAndTheFillFinishes() async throws {
        let id = "call-\(UUID().uuidString)"
        let call = ToolCall(id: id, name: "web_fetch", arguments: "{}")
        let out = try await ToolExecutionRecovery.execute(call, using: ReportingTool())
        #expect(out.text == id)
        #expect(ToolProgress.shared.value(for: id) == 1) // filled, fading
        try await Task.sleep(for: ToolProgress.fadeDelay + .milliseconds(300))
        #expect(ToolProgress.shared.value(for: id) == nil)
    }

    @Test func aFailedToolLeavesNoFill() async throws {
        let id = "call-\(UUID().uuidString)"
        _ = try await ToolExecutionRecovery.execute(ToolCall(id: id, name: "web_fetch", arguments: "{}"), using: ReportingTool(fail: true))
        #expect(ToolProgress.shared.value(for: id) == nil)
    }

    @Test func noCallIdOutsideAToolCall() {
        #expect(ToolContext.callID == nil)
    }
}

// MARK: - Real web view: JS timeout, user script, pooling

private final class BatchFixtureToken {}

@MainActor
@Suite(.serialized)
struct HiddenWebViewBatchTests {
    private func html(_ body: String) -> String { "<!doctype html><html><head><title>Fixture</title></head><body>\(body)</body></html>" }

    @Test func aScriptThatNeverReturnsTimesOut() async throws {
        let view = HiddenWebView(guardNavigations: false)
        defer { view.dispose() }
        try await view.load(html: html("<p>hi</p>"), baseURL: URL(string: "https://example.com/"))
        let start = ContinuousClock.now
        await #expect(throws: WebToolError.timeout) {
            _ = try await view.evaluate("while (true) {}", timeout: .milliseconds(400))
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func cancellingAScriptReturnsPromptly() async throws {
        let view = HiddenWebView(guardNavigations: false)
        defer { view.dispose() }
        try await view.load(html: html("<p>hi</p>"), baseURL: URL(string: "https://example.com/"))
        let task = Task { @MainActor in try await view.evaluate("while (true) {}", timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(150))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }

    @Test func fetchViewsCarryTheReaderAsAUserScript() async throws {
        let plain = HiddenWebView(guardNavigations: false)
        let reader = HiddenWebView(guardNavigations: false, injectsReader: true)
        defer { plain.dispose(); reader.dispose() }
        for v in [plain, reader] { try await v.load(html: html("<p>hi</p>"), baseURL: URL(string: "https://example.com/")) }
        #expect(try await plain.evaluateString("typeof Readability") == "undefined")
        #expect(try await reader.evaluateString("typeof Readability") == "function")
    }

    @Test func theExtractionScriptCapsTheTextInThePage() async throws {
        let view = HiddenWebView(guardNavigations: false, injectsReader: true)
        defer { view.dispose() }
        let paragraphs = (0..<400).map { "<p>Paragraph number \($0) with enough words to look like an article body.</p>" }.joined()
        try await view.load(html: html("<article><h1>Long</h1>\(paragraphs)</article>"), baseURL: URL(string: "https://example.com/"))
        let json = try await view.evaluateString(WebFetchTool.extractionScript(maxCharacters: 1000))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let text = try #require(obj["text"] as? String)
        #expect(text.count <= 1000 && text.count > 500)
    }

    @Test func aLoadTimeoutLeavesAUsableViewForTheNextPage() async throws {
        let view = HiddenWebView(guardNavigations: false)
        defer { view.dispose() }
        await #expect(throws: WebToolError.timeout) {
            // A page that cannot finish within the limit.
            try await view.load(html: self.html("<img src='http://10.255.255.1/never.png'>"), baseURL: URL(string: "https://example.com/"), timeout: .milliseconds(300))
        }
        try await view.load(html: html("<p>second</p>"), baseURL: URL(string: "https://example.com/"))
        #expect(try await view.evaluateString("document.body.innerText") == "second")
    }

    @Test func theLoadProgressIsReported() async throws {
        let view = HiddenWebView(guardNavigations: false)
        defer { view.dispose() }
        var seen: [Double] = []
        view.onProgress = { seen.append($0) }
        try await view.load(html: html("<p>progress</p>"), baseURL: URL(string: "https://example.com/"))
        #expect(seen.contains { $0 > 0 })
    }
}

@MainActor
@Suite(.serialized)
struct WebViewPoolTests {
    private func html(_ body: String) -> String { "<!doctype html><html><body>\(body)</body></html>" }

    @Test func aReleasedViewIsReusedAndComesBackClean() async throws {
        let pool = WebViewPool()
        let first = pool.acquire(reader: true, guardNavigations: false)
        try await first.load(html: html("<p id='a'>first page</p><script>window.leftover = 1</script>"), baseURL: URL(string: "https://example.com/"))
        pool.release(first, reusable: true)
        #expect(pool.idleCount == 1)
        let second = pool.acquire(reader: true, guardNavigations: false)
        #expect(second === first)
        #expect(pool.idleCount == 0)
        try await second.load(html: html("<p>second page</p>"), baseURL: URL(string: "https://example.com/"))
        #expect(try await second.evaluateString("document.body.innerText") == "second page")
        #expect(try await second.evaluateString("String(window.leftover)") == "undefined")
        #expect(try await second.evaluateString("typeof Readability") == "function")
        pool.release(second, reusable: false) // torn down, not kept
        #expect(pool.idleCount == 0)
        pool.drain()
    }

    @Test func kindsDoNotMix() {
        let pool = WebViewPool()
        let search = pool.acquire(reader: false, guardNavigations: false)
        pool.release(search, reusable: true)
        let fetch = pool.acquire(reader: true, guardNavigations: false)
        #expect(fetch !== search && fetch.injectsReader)
        #expect(pool.idleCount == 1)
        pool.release(fetch, reusable: true)
        pool.drain()
        #expect(pool.idleCount == 0)
    }

    @Test func onlyAFewIdleViewsAreKept() {
        let pool = WebViewPool()
        pool.maxIdle = 2
        let views = (0..<4).map { _ in pool.acquire(reader: false, guardNavigations: false) }
        for v in views { pool.release(v, reusable: true) }
        #expect(pool.idleCount == 2)
        pool.drain()
    }

    @Test func idleViewsExpire() async throws {
        let pool = WebViewPool()
        pool.idleLifetime = .milliseconds(150)
        pool.release(pool.acquire(reader: false, guardNavigations: false), reusable: true)
        #expect(pool.idleCount == 1)
        for _ in 0..<100 where pool.idleCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(pool.idleCount == 0)
    }

    @Test func viewsShareOneNonPersistentDataStore() {
        let a = HiddenWebView(guardNavigations: false)
        let b = HiddenWebView(guardNavigations: false, injectsReader: true)
        defer { a.dispose(); b.dispose() }
        #expect(a.webView.configuration.websiteDataStore === b.webView.configuration.websiteDataStore)
        #expect(!a.webView.configuration.websiteDataStore.isPersistent)
    }

    @Test func theCounterTracksLiveViews() {
        let before = DiagnosticCounters.shared.hiddenWebViews
        let v = HiddenWebView(guardNavigations: false)
        #expect(DiagnosticCounters.shared.hiddenWebViews == before + 1)
        v.dispose()
        v.dispose() // idempotent
        #expect(DiagnosticCounters.shared.hiddenWebViews == before)
    }
}
