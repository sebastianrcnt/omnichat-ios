import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import Strata

@MainActor
private final class FreezablePage: BrowserPage, KeepablePage {
    var currentURL: URL?
    var onProgress: (@MainActor (Double) -> Void)?
    var isOnScreen = false
    private(set) var isFrozen = false
    private(set) var thawCount = 0
    private(set) var loads: [URL] = []
    private(set) var isDisposed = false
    let pageID = "pageF"

    func load(_ url: URL, timeout: Duration) async throws { loads.append(url); currentURL = url }
    func evaluate(_ js: String, timeout: Duration) async throws -> String { "" }
    func callAsync(_ body: String, timeout: Duration) async throws -> String { "" }
    func abandonLoad() {}
    func stop() {}
    func dispose() { isDisposed = true }
    func freeze() { isFrozen = true }
    func thaw() { if isFrozen { thawCount += 1 }; isFrozen = false }
}

/// A clock the tests move by hand.
@MainActor
private final class TestClock {
    var now = ContinuousClock.now
    func advance(_ d: Duration) { now += d }
}

@MainActor
struct BrowserFreezeTests {
    private func rig() -> (BrowserSessions, TestClock, () -> [FreezablePage]) {
        let sessions = BrowserSessions()
        let clock = TestClock()
        var made: [FreezablePage] = []
        sessions.makePage = { let p = FreezablePage(); made.append(p); return p }
        sessions.clock = { clock.now }
        return (sessions, clock, { made })
    }

    /// One browser call in `conversation`, as the tools make it, opening `url`.
    private func call(_ sessions: BrowserSessions, _ conversation: UUID, id: String = UUID().uuidString,
                      url: String = "https://example.com/a", check: @escaping @MainActor (BrowserSessions.Session) -> Void = { _ in }) async throws {
        try await ToolContext.$callID.withValue(id) {
            try await sessions.run(conversation: conversation) { session in
                check(session)
                session.hasPage = true
                try await session.page.load(URL(string: url)!, timeout: .seconds(1))
            }
        }
    }

    @Test func theReplyEndingFreezesThePageAndTheNextCallThawsIt() async throws {
        let (sessions, _, pages) = rig()
        let chat = UUID()
        try await call(sessions, chat)
        let page = try #require(pages().first)
        #expect(!page.isFrozen)
        sessions.turnEnded()
        #expect(page.isFrozen, "kept, but suspended")
        #expect(sessions.count == 1)

        var frozenDuringCall: Bool?
        try await call(sessions, chat) { frozenDuringCall = $0.page.isFrozen }
        #expect(frozenDuringCall == false, "thawed before the call ran")
        #expect(page.thawCount == 1 && pages().count == 1, "the same page")
    }

    @Test func aFourthConversationClosesTheLeastRecentlyUsedPage() async throws {
        let (sessions, clock, _) = rig()
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        try await call(sessions, a, url: "https://a.example/")
        clock.advance(.seconds(10))
        try await call(sessions, b, url: "https://b.example/")
        clock.advance(.seconds(10))
        try await call(sessions, c, url: "https://c.example/")
        clock.advance(.seconds(10))
        try await call(sessions, a) // a is used again: b is now the oldest
        clock.advance(.seconds(10))
        try await call(sessions, d)

        #expect(sessions.count == 3)
        #expect(sessions.existingSession(b) == nil)
        #expect(sessions.existingSession(a) != nil && sessions.existingSession(c) != nil && sessions.existingSession(d) != nil)
        #expect(sessions.closedURL(b) == URL(string: "https://b.example/"))
        #expect(!sessions.openConversations.contains(b) && sessions.openConversations.contains(d))
    }

    @Test func aPageOnScreenIsNotEvicted() async throws {
        let (sessions, clock, pages) = rig()
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        for chat in [a, b, c] {
            try await call(sessions, chat)
            clock.advance(.seconds(10))
        }
        pages()[0].isOnScreen = true // a, the oldest, is in the browser sheet
        try await call(sessions, d)
        #expect(sessions.existingSession(a) != nil && sessions.existingSession(b) == nil)
    }

    @Test func frozenPagesCloseAfterThirtyIdleMinutes() async throws {
        let (sessions, clock, pages) = rig()
        let chat = UUID()
        try await call(sessions, chat)
        sessions.turnEnded()
        #expect(sessions.idleLifetime == .seconds(1800))
        clock.advance(.seconds(29 * 60))
        sessions.sweep()
        #expect(sessions.count == 1)
        pages()[0].isOnScreen = true
        clock.advance(.seconds(2 * 60))
        sessions.sweep()
        #expect(sessions.count == 1, "never from under the user")
        pages()[0].isOnScreen = false
        sessions.sweep()
        #expect(sessions.count == 0 && sessions.page(of: chat) == nil)
    }

    @Test func reopenLoadsTheLastURLInANewSession() async throws {
        let (sessions, _, pages) = rig()
        let chat = UUID()
        try await call(sessions, chat, id: "last", url: "https://example.com/where")
        #expect(sessions.conversation(lastCallIn: ["x", "last"]) == chat)
        #expect(sessions.reopen(chat) == nil, "still open: Open page, not Reopen")
        sessions.close(chat)
        #expect(sessions.page(of: chat) == nil)
        #expect(sessions.closedURL(chat) == URL(string: "https://example.com/where"))

        let reopened = try #require(sessions.reopen(chat) as? FreezablePage)
        for _ in 0..<50 where reopened.loads.isEmpty { await Task.yield() }
        #expect(reopened.loads == [URL(string: "https://example.com/where")!])
        #expect(pages().count == 2 && sessions.existingSession(chat)?.hasPage == true)
        #expect(sessions.closedURL(chat) == nil && sessions.conversation(lastCallIn: ["last"]) == chat,
                "the run keeps its link: Open page again")
    }

    @Test func noURLMeansNoReopen() {
        let (sessions, _, _) = rig()
        let chat = UUID()
        _ = sessions.session(for: chat) // a page that never opened anything
        sessions.close(chat)
        #expect(sessions.closedURL(chat) == nil && sessions.reopen(chat) == nil)
    }

    @Test func memoryPurgeClosesAllAndRemembersWhereTheyWere() async throws {
        let (sessions, _, _) = rig()
        let chat = UUID()
        try await call(sessions, chat, url: "https://example.com/p")
        sessions.closeAll()
        #expect(sessions.count == 0 && sessions.openConversations.isEmpty)
        #expect(sessions.closedURL(chat) == URL(string: "https://example.com/p"))
    }

    @Test func aPageBackFromTheUserIsFrozenAgain() async throws {
        let (sessions, _, pages) = rig()
        let chat = UUID()
        try await call(sessions, chat)
        sessions.turnEnded()
        pages()[0].thaw() // as if a call had used it
        sessions.pageReturned(chat)
        #expect(pages()[0].isFrozen)
    }

    @Test func keptPagesFreezeWhenTheirReplyEnds() {
        let kept = KeptPages()
        let mine = FreezablePage()
        let sessions = FreezablePage()
        kept.keep(mine, callID: "c1")
        kept.keep(sessions, callID: "c2", owned: false)
        kept.turnEnded()
        #expect(mine.isFrozen)
        #expect(!sessions.isFrozen, "a session's page is its session's to freeze")
    }

    @Test func hiddenPageWorkWaitsForForegroundEvenWithAContinuedLease() {
        for tool in [ToolNames.webSearch, ToolNames.webFetch, ToolNames.browserOpen, ToolNames.browserEval,
                     ToolNames.browserClick, ToolNames.runPlugin] {
            #expect(ToolExecutionRecovery.waitsForForeground(tool, hasContinuedLease: true))
        }
        #expect(!ToolExecutionRecovery.waitsForForeground(ToolNames.runPython, hasContinuedLease: true))
        #expect(ToolExecutionRecovery.waitsForForeground(ToolNames.runPython, hasContinuedLease: false))
        #expect(ToolNames.isSafeToRetry(ToolNames.browserOpen))
        #expect(!ToolNames.isSafeToRetry(ToolNames.browserClick))
        #expect(!ToolNames.isSafeToRetry(ToolNames.browserEval))
        #expect(!ToolNames.isSafeToRetry(ToolNames.runPlugin))
    }

    @Test func aRealPageLeavesTheWindowWhenFrozen() {
        let page = HiddenWebView(guardNavigations: false)
        defer { page.dispose() }
        page.freeze()
        #expect(page.isFrozen && page.webView.superview == nil)
        page.thaw()
        #expect(!page.isFrozen)
        #if canImport(UIKit)
        #expect(page.webView.superview === HiddenWebView.keyWindow)
        #endif
    }

    @Test func aFrozenPageStillGoesOnScreenAndLeavesAgain() throws {
        #if canImport(UIKit)
        let window = try #require(HiddenWebView.keyWindow)
        let page = HiddenWebView(guardNavigations: false)
        defer { page.dispose() }
        page.freeze()
        let stage = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        window.addSubview(stage)
        defer { stage.removeFromSuperview() }
        let claim = page.claim(.sheet, in: stage, interactive: true)
        #expect(page.webView.superview === stage && page.isOnScreen)
        page.release(claim)
        #expect(page.webView.superview == nil && !page.isOnScreen, "parked out of the window again")
        #endif
    }
}
