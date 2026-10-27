import Testing
import Foundation
@testable import Strata

@MainActor
struct BrowserShowTests {
    @Test func showingNeedsAnOpenPage() async {
        let sessions = BrowserSessions()
        let out = await BrowserShowTool(sessions: sessions, ask: { _ in true }).run(reason: "Sign in", conversation: UUID())
        #expect(out.isError)
        #expect(out.text.contains("browser_open"))
    }

    @Test func doneAndClosedTellTheModelWhereThePageIs() async throws {
        let sessions = BrowserSessions()
        sessions.makePage = { HiddenWebView(guardNavigations: false, store: BrowserData.store) }
        let chat = UUID()
        let session = sessions.session(for: chat)
        session.hasPage = true
        let page = try #require(session.page as? HiddenWebView)
        try await page.load(html: "<title>Login</title><p>hi</p>", baseURL: URL(string: "https://example.com/login"))
        var asked: String?
        let done = await BrowserShowTool(sessions: sessions, ask: { asked = $0.reason; return true }).run(reason: "  Sign in to X  ", conversation: chat)
        #expect(asked == "Sign in to X")
        #expect(!done.isError)
        #expect(done.text.contains("Login") && done.text.contains("example.com"))
        let closed = await BrowserShowTool(sessions: sessions, ask: { _ in false }).run(reason: "Sign in", conversation: chat)
        #expect(closed.isError)
        sessions.closeAll()
    }

    /// Right after a load the web view's `title` is often still empty or the last page's; the page is named by its
    /// document's title.
    @Test func aJustLoadedPageIsNamedByItsTitle() async throws {
        let page = HiddenWebView(guardNavigations: false, store: BrowserData.store)
        defer { page.dispose() }
        for i in 1...6 {
            try await page.load(html: "<title>Login \(i)</title><p>hi</p>", baseURL: URL(string: "https://example.com/login"))
            let place = await BrowserShowTool.place(page)
            #expect(place == "Login \(i) — https://example.com/login", "\(place)")
        }
    }

    @Test func theModelsBrowserKeepsItsOwnCookies() {
        let page = BrowserSessions().makePage() as? HiddenWebView
        #expect(page?.webView.configuration.websiteDataStore === BrowserData.store)
        #expect(BrowserData.store.isPersistent)
        page?.dispose()
    }
}
