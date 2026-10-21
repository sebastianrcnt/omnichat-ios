import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import Strata

struct RobotCheckDetectorTests {
    private func detect(_ url: String, title: String = "", frames: [String] = [], cloudflare: Bool = false,
                        text: String = "", length: Int? = nil) -> RobotCheck.Kind? {
        RobotCheck.detect(url: URL(string: url), signals: .init(title: title, frames: frames, cloudflare: cloudflare,
                                                                textLength: length ?? text.count, text: text))
    }

    @Test func cloudflareChallengePages() {
        #expect(detect("https://site.com/", title: "Just a moment...", text: "Checking if the site connection is secure") == .cloudflare)
        #expect(detect("https://site.com/", title: "Attention Required! | Cloudflare") == .cloudflare)
        #expect(detect("https://site.com/", cloudflare: true, length: 10_000) == .cloudflare)
        #expect(detect("https://site.com/cdn-cgi/challenge-platform/h/b/orchestrate") == .cloudflare)
        // A long page whose title happens to start that way is an article.
        #expect(detect("https://blog.com/", title: "Just a moment of calm", length: 9_000) == nil)
    }

    @Test func googleUnusualTraffic() {
        #expect(detect("https://www.google.com/sorry/index?continue=x") == .googleSorry)
        #expect(detect("https://www.google.co.kr/sorry/index") == .googleSorry)
        #expect(detect("https://google.de/sorry/") == .googleSorry)
        #expect(detect("https://www.google.com/search?q=sorry") == nil)
        #expect(!RobotCheck.isGoogle("googleusercontent.com"))
        #expect(!RobotCheck.isGoogle("notgoogle.com"))
        #expect(!RobotCheck.isGoogle("docs.google.com.evil.example"))
        #expect(RobotCheck.isGoogle("ipv4.google.com"))
    }

    @Test func naverCaptcha() {
        #expect(detect("https://nid.naver.com/login/ext/captcha?x=1") == .naverCaptcha)
        #expect(detect("https://search.naver.com/search.naver?query=a", text: "자동입력 방지를 위해 아래 문자를 입력해 주세요") == .naverCaptcha)
        #expect(detect("https://blog.naver.com/a", text: String(repeating: "카페 ", count: 1_500)) == nil)
    }

    @Test func checkBoxesOnShortPagesOnly() {
        let anchor = "https://www.google.com/recaptcha/api2/anchor?ar=1&k=abc&size=normal"
        #expect(detect("https://shop.com/verify", frames: [anchor], text: "Please verify") == .recaptcha)
        #expect(detect("https://shop.com/verify", frames: ["https://www.recaptcha.net/recaptcha/enterprise/anchor?k=1"]) == .recaptcha)
        // Invisible reCAPTCHA (the corner badge) is on many normal pages.
        #expect(detect("https://shop.com/login", frames: ["https://www.google.com/recaptcha/api2/anchor?k=1&size=invisible"]) == nil)
        // A long article with a comment form that carries a box is not a check.
        #expect(detect("https://news.com/a", frames: [anchor], length: 12_000) == nil)
        #expect(detect("https://site.com/", frames: ["https://newassets.hcaptcha.com/captcha/v1/abc/static/hcaptcha.html#frame=checkbox"]) == .hcaptcha)
        #expect(detect("https://site.com/", frames: ["https://challenges.cloudflare.com/cdn-cgi/challenge-platform/turnstile/if/ov2"]) == .turnstile)
    }

    @Test func wordingOnShortPages() {
        #expect(detect("https://duckduckgo.com/html", text: "Unfortunately, bots use DuckDuckGo too. Please complete the following challenge") == .other)
        #expect(detect("https://x.com/", text: "Our systems have detected unusual traffic from your computer network.") == .other)
        #expect(detect("https://x.com/", text: "An essay on whether you are a robot or not", length: 30_000) == nil)
        #expect(detect("https://example.com/", title: "Example Domain", text: "This domain is for use in examples.") == nil)
    }

    @Test func signalsDecodeFromTheProbe() throws {
        let s = try #require(RobotCheck.Signals.decode(#"{"title":"T","frames":["a"],"cloudflare":false,"textLength":3,"text":"abc"}"#))
        #expect(s == .init(title: "T", frames: ["a"], cloudflare: false, textLength: 3, text: "abc"))
        #expect(RobotCheck.Signals.decode("nope") == nil)
    }

    @Test func aBlockedReadSaysSo() {
        #expect(FetchFailure(errorText: RobotCheck.skippedMessage(host: "a.com")) == .blocked)
        #expect(RobotCheckError.skipped(host: "a.com").errorDescription?.contains("user skipped this page") == true)
        #expect(RobotCheckError.notAsked(host: "a.com").errorDescription?.contains("turned off") == true)
    }
}

/// A page that shows a check until `solve()` runs.
@MainActor
private final class CheckPage: FetchablePage {
    var currentURL: URL? = URL(string: "https://www.google.com/sorry/index")
    var onProgress: (@MainActor (Double) -> Void)?
    var showsCheck = true
    private(set) var probes = 0

    func solve() {
        showsCheck = false
        currentURL = URL(string: "https://www.google.com/search?q=a")
    }

    func load(_ url: URL, timeout: Duration) async throws { currentURL = url }
    func evaluate(_ js: String, timeout: Duration) async throws -> String {
        if js == "document.readyState" { return "complete" }
        probes += 1
        return #"{"title":"","frames":[],"cloudflare":false,"textLength":5000,"text":""}"#
    }
    func stop() {}
}

@MainActor
@Suite(.serialized)
struct RobotCheckGateTests {
    private var timeouts: FetchTimeouts { FetchTimeouts(probe: .seconds(1), settle: .milliseconds(1)) }

    @Test func aPageWithoutACheckPassesWithoutAsking() async throws {
        let page = CheckPage()
        page.solve()
        var asked = 0
        let solved = try await RobotCheckGate.pass(page, timeouts: timeouts) { _, _ in asked += 1; return .solved }
        #expect(!solved && asked == 0)
    }

    @Test func doneGoesOnInTheSameView() async throws {
        let page = CheckPage()
        var asked: [String] = []
        let solved = try await RobotCheckGate.pass(page, timeouts: timeouts) { host, kind in
            asked.append("\(host) \(kind)")
            page.solve()
            return .solved
        }
        #expect(solved)
        #expect(asked == ["www.google.com googleSorry"])
        #expect(page.probes == 2) // looked again after Done
    }

    @Test func skipAndTheSettingEndTheToolWithAClearResult() async {
        await #expect(throws: RobotCheckError.skipped(host: "www.google.com")) {
            try await RobotCheckGate.pass(CheckPage(), timeouts: timeouts) { _, _ in .skipped }
        }
        var asked = false
        await #expect(throws: RobotCheckError.notAsked(host: "www.google.com")) {
            try await RobotCheckGate.pass(CheckPage(), timeouts: timeouts, asks: false) { _, _ in asked = true; return .solved }
        }
        #expect(!asked)
        await #expect(throws: CancellationError.self) {
            try await RobotCheckGate.pass(CheckPage(), timeouts: timeouts) { _, _ in .cancelled }
        }
    }

    @Test func waitingForTheUserStopsTheDeadline() async throws {
        let value = try await Deadline.run(.milliseconds(100)) {
            try await Deadline.run(.milliseconds(150)) {
                await Deadline.pausing { try? await Task.sleep(for: .milliseconds(400)) }
                return 7
            }
        }
        #expect(value == 7)
        await #expect(throws: WebToolError.timeout) {
            try await Deadline.run(.milliseconds(100)) { try await Task.sleep(for: .milliseconds(400)); return 1 }
        }
    }

    @Test func theCardGoesToTheSheetAndBackUntilDoneOrSkip() async {
        let requests = RobotCheckRequests()
        var shown = 0
        requests.notify = { _ in }
        requests.present = { _ in shown += 1; return shown == 2 } // closed once, then Done
        let view = HiddenWebView(guardNavigations: false)
        defer { view.dispose() }
        let request = RobotCheckRequests.Request(host: "a.com", kind: .cloudflare, page: view, conversationID: nil, callID: "c1")
        let task = Task { await requests.ask(request) }
        for _ in 0..<2 { // the card comes back after the sheet was closed without Done
            while requests.pending.isEmpty { await Task.yield() }
            #expect(requests.pending.first?.id == request.id)
            requests.answer(request.id, .open)
        }
        #expect(await task.value == .solved)
        #expect(shown == 2 && requests.pending.isEmpty)

        let skipping = Task { await requests.ask(request) }
        while requests.pending.isEmpty { await Task.yield() }
        requests.answer(request.id, .skip)
        #expect(await skipping.value == .skipped)
    }
}

@MainActor
private final class FakeKept: KeepablePage {
    let pageID: String
    var currentURL: URL? = URL(string: "https://e.com/")
    var isOnScreen = false
    private(set) var isDisposed = false
    init(_ id: String) { pageID = id }
    func dispose() { isDisposed = true }
}

@MainActor
struct KeptPagesTests {
    @Test func theOldestGoesFirstButNeverOneOnScreen() {
        let kept = KeptPages()
        kept.maxKept = 2
        let a = FakeKept("page1"), b = FakeKept("page2"), c = FakeKept("page3"), d = FakeKept("page4")
        kept.keep(a, callID: "1")
        kept.keep(b, callID: "2")
        kept.keep(c, callID: "3")
        #expect(a.isDisposed && !b.isDisposed && !c.isDisposed)
        #expect(kept.page(id: "page1") == nil && kept.page(id: "page2") === b)
        b.isOnScreen = true
        kept.keep(d, callID: "4")
        #expect(!b.isDisposed && c.isDisposed && kept.count == 2)
        #expect(kept.page(forCall: "4") === d)
        #expect(kept.page(id: " \"page4\" ") === d)
    }

    @Test func pagesLastUntilTheReplyEndsPlusAFewMinutes() {
        let kept = KeptPages()
        kept.lingering = .seconds(300)
        let a = FakeKept("page1"), session = FakeKept("page2")
        let start = ContinuousClock.now
        kept.keep(a, callID: "1", now: start)
        kept.keep(session, callID: "2", owned: false, now: start)
        kept.sweep(now: start + .seconds(3_600)) // the reply is still running
        #expect(!a.isDisposed && kept.page(id: "page1") === a)
        kept.turnEnded(now: start)
        kept.sweep(now: start + .seconds(299))
        #expect(!a.isDisposed)
        a.isOnScreen = true // the user is looking at it: it waits
        kept.sweep(now: start + .seconds(301))
        #expect(!a.isDisposed)
        a.isOnScreen = false
        kept.sweep(now: start + .seconds(302))
        #expect(a.isDisposed && kept.page(id: "page1") == nil)
        // A browser session's page is only listed, never torn down here.
        #expect(!session.isDisposed && kept.page(id: "page2") == nil)
    }

    @Test func failedResultsNameTheKeptPage() {
        let kept = KeptPages()
        kept.keep(FakeKept("page9"), callID: "c")
        #expect(kept.note(forCall: "c").contains("browser_show with page \"page9\""))
        #expect(kept.note(forCall: "other").isEmpty && kept.note(forCall: nil).isEmpty)
    }

    @Test func onlyPagesWorthShowingAreKept() {
        #expect(KeptPages.shouldKeep(after: WebToolError.timeout))
        #expect(KeptPages.shouldKeep(after: SearchExtractorError.challenge))
        #expect(KeptPages.shouldKeep(after: RobotCheckError.skipped(host: "a")))
        #expect(!KeptPages.shouldKeep(after: CancellationError()))
        #expect(!KeptPages.shouldKeep(after: WebToolError.insecure))
        #expect(!KeptPages.shouldKeep(after: URLGuardError.invalidURL))
    }

    @Test func aFailedPooledViewIsKeptForTheUser() async throws {
        let pool = WebViewPool()
        let view = pool.acquire(reader: false, guardNavigations: false)
        try await view.load(html: "<p>hi</p>", baseURL: URL(string: "https://example.com/"))
        ToolContext.$callID.withValue("pool-call") {
            pool.release(view, reusable: false, keep: true)
        }
        #expect(!view.isDisposed && pool.idleCount == 0)
        #expect(KeptPages.shared.page(forCall: "pool-call") === view)
        #expect(!BackgroundLoadingSound.shared.isRegistered(view))
        KeptPages.shared.release(view)
        view.dispose()
        // A view that never loaded a page has nothing to show.
        let blank = pool.acquire(reader: false, guardNavigations: false)
        pool.release(blank, reusable: false, keep: true)
        #expect(blank.isDisposed)
    }
}

@MainActor
struct ScreenOwnershipTests {
    private func c(_ kind: ScreenClaim.Kind, _ order: Int, _ inWindow: Bool = true) -> ScreenOwnership.Candidate {
        .init(kind: kind, order: order, inWindow: inWindow)
    }

    @Test func theSheetOutranksTheCardAndTheNewestOfEqualsWins() {
        #expect(ScreenOwnership.owner([]) == nil)
        #expect(ScreenOwnership.owner([c(.preview, 1), c(.sheet, 2)]) == 1)
        #expect(ScreenOwnership.owner([c(.sheet, 1), c(.preview, 5)]) == 0)
        #expect(ScreenOwnership.owner([c(.preview, 1), c(.preview, 3), c(.preview, 2)]) == 1)
    }

    @Test func aContainerOutOfAWindowNeverHoldsTheView() {
        // A card scrolled out of the lazy stack, or a sheet not up yet.
        #expect(ScreenOwnership.owner([c(.preview, 1, false)]) == nil)
        #expect(ScreenOwnership.owner([c(.preview, 1), c(.sheet, 2, false)]) == 0)
    }

    @Test func handOffsMoveTheOneViewAndParkItAtTheEnd() throws {
        #if canImport(UIKit)
        let view = HiddenWebView(guardNavigations: false)
        defer { view.dispose() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let card = WebStageView(frame: CGRect(x: 0, y: 0, width: 195, height: 150))
        let sheet = WebStageView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.addSubview(card)
        card.hold(view, kind: .preview, interactive: false)
        #expect(view.webView.superview === card && view.isOnScreen && !view.webView.isUserInteractionEnabled)
        #expect(abs(view.webView.frame.width - 195) < 0.5 && view.webView.bounds.width == 390) // drawn at half size
        window.addSubview(sheet)
        sheet.hold(view, kind: .sheet, interactive: true)
        #expect(view.webView.superview === sheet && view.isInSheet && view.webView.isUserInteractionEnabled)
        #expect(view.webView.transform == .identity)
        sheet.letGo()
        #expect(view.webView.superview === card) // back to the card
        card.removeFromSuperview() // scrolled away
        #expect(view.webView.superview !== card && !view.isOnScreen && view.webView.transform == .identity)
        card.letGo()
        #endif
    }
}

@MainActor
private final class SlowPage: BrowserPage {
    var currentURL: URL? = URL(string: "https://e.com/")
    var onProgress: (@MainActor (Double) -> Void)?
    var scripts = 0
    func load(_ url: URL, timeout: Duration) async throws { currentURL = url }
    func evaluate(_ js: String, timeout: Duration) async throws -> String { "" }
    /// Never answers on its own: only cancelling ends it.
    func callAsync(_ body: String, timeout: Duration) async throws -> String {
        scripts += 1
        try await Task.sleep(for: .seconds(60))
        return #"{"body":"late","total":4}"#
    }
    func abandonLoad() {}
    func stop() {}
}

@MainActor
@Suite(.serialized)
struct BrowserHandoverTests {
    private func setUp() -> (BrowserSessions, SlowPage, UUID) {
        let sessions = BrowserSessions()
        let page = SlowPage()
        sessions.makePage = { page }
        let chat = UUID()
        sessions.session(for: chat).hasPage = true
        return (sessions, page, chat)
    }

    @Test func stopBrowsingEndsOnlyTheBrowserCallsOfThisReply() async {
        let (sessions, page, chat) = setUp()
        let running = Task { await BrowserEvalTool(sessions: sessions, robotCheck: { _, _ in false }).run(code: "return 1", conversation: chat) }
        while page.scripts == 0 { await Task.yield() }
        sessions.stopBrowsing(chat)
        let out = await running.value
        #expect(out.text == BrowserStoppedError.message && out.isError)
        // The rest of the reply's browser calls return at once.
        let next = await BrowserEvalTool(sessions: sessions, robotCheck: { _, _ in false }).run(code: "return 2", conversation: chat)
        #expect(next.text == BrowserStoppedError.message && page.scripts == 1)
        // Another chat's browser is untouched, and the next reply may browse again.
        sessions.turnEnded()
        #expect(sessions.existingSession(chat)?.stopped == false)
        sessions.closeAll()
    }

    @Test func takeOverHoldsCallsUntilDone() async {
        let (sessions, page, chat) = setUp()
        sessions.takeOver(chat)
        let held = Task { await BrowserEvalTool(sessions: sessions, robotCheck: { _, _ in false }).run(code: "return 1", conversation: chat) }
        for _ in 0..<50 { await Task.yield() }
        #expect(page.scripts == 0) // waiting for the user
        sessions.handBack(chat)
        while page.scripts == 0 { await Task.yield() }
        held.cancel()
        _ = await held.value
        sessions.closeAll()
    }

    @Test func browserShowFindsThePageById() async throws {
        let sessions = BrowserSessions()
        sessions.makePage = { HiddenWebView(guardNavigations: false) }
        let kept = KeptPages()
        let chat = UUID()
        let session = sessions.session(for: chat)
        let own = try #require(session.page as? HiddenWebView)
        let other = HiddenWebView(guardNavigations: false)
        defer { other.dispose(); sessions.closeAll() }
        kept.keep(other, callID: "f1")
        #expect({ if case .session = BrowserShowTool.target(pageID: nil, session: session, kept: kept) { true } else { false } }())
        #expect({ if case .session = BrowserShowTool.target(pageID: own.pageID, session: session, kept: kept) { true } else { false } }())
        #expect({ if case .kept(let p) = BrowserShowTool.target(pageID: other.pageID, session: session, kept: kept) { p === other } else { false } }())
        #expect({ if case .missing("page0") = BrowserShowTool.target(pageID: "page0", session: session, kept: kept) { true } else { false } }())

        let missing = await BrowserShowTool(sessions: sessions, kept: kept, ask: { _ in true }).run(reason: "x", page: "page0", conversation: chat)
        #expect(missing.isError && missing.text.contains("page0"))

        try await other.load(html: "<title>Seats</title><p>3 seats left</p>", baseURL: URL(string: "https://rail.example/"))
        var shown: HiddenWebView?
        let done = await BrowserShowTool(sessions: sessions, kept: kept, ask: { shown = $0.page; return true })
            .run(reason: "Close the pop-up", page: other.pageID, conversation: chat)
        #expect(shown === other)
        #expect(!done.isError && done.text.contains("3 seats left") && done.text.contains("rail.example"))
        let skipped = await BrowserShowTool(sessions: sessions, kept: kept, ask: { _ in false })
            .run(reason: "Close the pop-up", page: other.pageID, conversation: chat)
        #expect(skipped.isError && skipped.text.contains("without tapping Done"))
    }

    @Test func everyWebViewSharesTheOnePersistentStore() {
        let pool = WebViewPool()
        let fetch = pool.acquire(reader: true, guardNavigations: false)
        let search = pool.acquire(reader: false, guardNavigations: false)
        let browser = BrowserSessions().makePage() as? HiddenWebView
        defer { fetch.dispose(); search.dispose(); browser?.dispose() }
        for view in [fetch, search, browser].compactMap({ $0 }) {
            #expect(view.webView.configuration.websiteDataStore === BrowserData.store)
        }
        #expect(BrowserData.store.isPersistent)
    }

    @Test func onlyTheNewestBrowserCardOfAWorkingReplyIsLive() {
        let cards = [FeedCard(id: "o1", kind: .browser(url: "https://a")), FeedCard(id: "s1", kind: .script(code: "1")),
                     FeedCard(id: "n1", kind: .note(tool: ToolNames.loadSkill, argument: "x"))]
        #expect(ActivityFeed.liveBrowserCard(cards, isStreaming: true, answerStarted: false) == "s1")
        #expect(ActivityFeed.liveBrowserCard(cards, isStreaming: true, answerStarted: true) == nil)
        #expect(ActivityFeed.liveBrowserCard(cards, isStreaming: false, answerStarted: false) == nil)
        #expect(ActivityFeed.liveBrowserCard([cards[2]], isStreaming: true, answerStarted: false) == nil)
    }
}
