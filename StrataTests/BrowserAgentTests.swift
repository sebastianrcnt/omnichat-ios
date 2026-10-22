import Foundation
import Testing
import UIKit
@testable import Strata

struct BrowserActionParsingTests {
    @Test func indicesComeInAnyShape() {
        #expect(BrowserAction.parse(tool: ToolNames.browserClick, arguments: ["index": 12]) == .success(.click(index: 12)))
        #expect(BrowserAction.parse(tool: ToolNames.browserClick, arguments: ["index": 12.0]) == .success(.click(index: 12)))
        #expect(BrowserAction.parse(tool: ToolNames.browserClick, arguments: ["index": "[12]"]) == .success(.click(index: 12)))
        #expect(BrowserAction.parse(tool: ToolNames.browserClick, arguments: ["index": "*[7]"]) == .success(.click(index: 7)))
        #expect(BrowserAction.index(12.5) == nil && BrowserAction.index(-1) == nil && BrowserAction.index("x") == nil)
    }

    @Test func missingOrBadArgumentsSaySo() throws {
        guard case .failure(let e) = BrowserAction.parse(tool: ToolNames.browserClick, arguments: [:]) else { Issue.record(); return }
        #expect(e.output.isError && e.message.contains("\"index\""))
        guard case .failure(let t) = BrowserAction.parse(tool: ToolNames.browserType, arguments: ["index": 3]) else { Issue.record(); return }
        #expect(t.message.contains("\"text\""))
        guard case .failure = BrowserAction.parse(tool: ToolNames.browserScroll, arguments: ["direction": "left"]) else { Issue.record(); return }
        guard case .failure = BrowserAction.parse(tool: ToolNames.browserFind, arguments: ["text": "  "]) else { Issue.record(); return }
        guard case .failure = BrowserAction.parse(tool: ToolNames.browserSelect, arguments: ["index": 1]) else { Issue.record(); return }
    }

    @Test func optionalArgumentsHaveDefaults() {
        #expect(BrowserAction.parse(tool: ToolNames.browserType, arguments: ["index": 5, "text": "hi"]) == .success(.type(index: 5, text: "hi", submit: false)))
        #expect(BrowserAction.parse(tool: ToolNames.browserType, arguments: ["index": 5, "text": "", "submit": "true"]) == .success(.type(index: 5, text: "", submit: true)))
        #expect(BrowserAction.parse(tool: ToolNames.browserScroll, arguments: [:]) == .success(.scroll(down: true, pages: 1, index: nil)))
        #expect(BrowserAction.parse(tool: ToolNames.browserScroll, arguments: ["direction": "UP", "pages": 40, "index": 3]) == .success(.scroll(down: false, pages: 10, index: 3)))
        #expect(BrowserAction.parse(tool: ToolNames.browserFind, arguments: ["text": "price", "scroll_to": 2]) == .success(.find(text: "price", scrollTo: 2)))
        #expect(BrowserAction.parse(tool: ToolNames.browserState, arguments: [:]) == .success(.state))
        #expect(BrowserAction.parse(tool: ToolNames.browserScreenshot, arguments: ["x": 1]) == .success(.screenshot))
    }

    @Test func theScreenshotToolNeedsAModelThatReadsImages() {
        let without = ToolDefinition.available(python: true, images: false, browser: true).map(\.function.name)
        let with = ToolDefinition.available(python: true, images: true, browser: true).map(\.function.name)
        #expect(!without.contains("browser_screenshot") && with.contains("browser_screenshot"))
        for name in ["browser_state", "browser_click", "browser_type", "browser_select", "browser_scroll", "browser_find"] {
            #expect(without.contains(name) && with.contains(name), "\(name)")
        }
        #expect(!ToolDefinition.available(python: true, images: true).map(\.function.name).contains("browser_click"))
    }

    @Test func theBrowserRulesComeOnlyWithTheBrowser() {
        #expect(!AppPrompt.text(tools: true, python: true).contains("browser_click"))
        #expect(AppPrompt.text(tools: true, python: false, browser: true).contains(AppPrompt.browser))
        #expect(AppPrompt.text(tools: false, python: false, browser: true) == AppPrompt.base)
        #expect(AppPrompt.browser.contains("never say you solved one"))
    }

    @Test func cardsHideElementNumbers() {
        #expect(BrowserActionLabel.readable("Clicked [8] 닫기") == "Clicked \u{201C}닫기\u{201D}")
        #expect(BrowserActionLabel.readable("Clicked [8] ") == "Clicked")
        #expect(BrowserActionLabel.readable(#"Typed "hi" into [3] Search and submitted"#) == "Typed \"hi\" into \u{201C}Search\u{201D} and submitted")
        #expect(BrowserActionLabel.readable(#"Typed "hi" into [3] "#) == #"Typed "hi""#)
        #expect(BrowserActionLabel.readable("Scrolled [4] down 600") == "Scrolled down 600")
        #expect(BrowserActionLabel.readable("Scrolled down 600") == "Scrolled down 600")
        #expect(ToolNote.title(tool: ToolNames.browserType, argument: "[5] \u{201C}cafe\u{201D}", running: true) == "Typing \u{201C}cafe\u{201D}…")
    }

    @Test func cardsSayWhatWasDone() {
        var record = ToolCallRecord(id: "c", name: ToolNames.browserClick, arguments: #"{"index":12}"#,
                                    result: "Clicked [12] Search\nThe page is now https://e.com/s\n\nURL: https://e.com/s\nTitle: S", isError: false)
        #expect(record.primaryArgument == "[12]")
        #expect(record.displayOnly.result == "Clicked [12] Search\nURL: https://e.com/s", "the state is dropped, the summary and URL kept")
        #expect(BrowserActionLabel.summary(tool: record.name, result: record.result) == "Clicked [12] Search")
        #expect(ToolNote.title(tool: record.name, argument: "[12]", running: true) == "Clicking…")
        #expect(ToolNote.title(tool: record.name, argument: "[12]", running: false, summary: "Clicked [12] Search") == "Clicked \u{201C}Search\u{201D}")
        record.name = ToolNames.browserState
        #expect(BrowserActionLabel.summary(tool: record.name, result: "URL: x") == nil)
        let typed = ToolCallRecord(id: "t", name: ToolNames.browserType, arguments: #"{"index":5,"text":"cafe"}"#, result: "", isError: false)
        #expect(typed.primaryArgument == "[5] \u{201C}cafe\u{201D}")
        let cards = ActivityFeed.cards(calls: [FeedCall(record: typed)], sources: [:])
        #expect(cards.first?.kind == .browserAction(tool: ToolNames.browserType, argument: "[5] \u{201C}cafe\u{201D}"))
        #expect(ActivityFeed.liveBrowserCard(cards, isStreaming: true, answerStarted: false) == "t")
        #expect(ToolNames.usesWebPage(ToolNames.browserClick) && !ToolNames.isSafeToRetry(ToolNames.browserClick))
    }

    @Test func theOpenPagesStateFollowsItsSourceAndSurvivesACheckpoint() {
        let out = ToolOutput(text: "page\n\nPage state", sources: [SourceCandidate(title: "T", url: "https://e.com", content: "page")], trailer: "Page state")
        #expect(RawToolResult(callID: "x", output: out).output.trailer == "Page state")
    }

    @Test func findResultsListWhereTheTextIs() {
        let json = #"{"ok":true,"total":2,"matches":[{"snippet":"Price 5,000","where":"in view","index":4},{"snippet":"price list","where":"900 px below"}]}"#
        let reply = try! #require(BrowserAgentReply.decode(json))
        let text = BrowserAgentTool.findText(reply, query: "price")
        #expect(text.hasPrefix("Found 2 matches for \"price\""))
        #expect(text.contains("1. (in view in [4]) Price 5,000") && text.contains("2. (900 px below) price list"))
        #expect(text.contains("scroll_to"))
        #expect(BrowserAgentTool.findText(BrowserAgentReply.decode(#"{"ok":true,"total":0,"matches":[]}"#)!, query: "x").hasPrefix("No visible text"))
    }
}

/// The index tools on fixture pages in a real hidden web view.
@MainActor
struct BrowserAgentPageTests {
    private let chat = UUID()

    private func open(_ body: String, sessions: BrowserSessions) async throws -> HiddenWebView {
        sessions.makePage = { HiddenWebView(guardNavigations: false) }
        let session = sessions.session(for: chat)
        session.hasPage = true
        let page = try #require(session.page as? HiddenWebView)
        let html = "<!doctype html><html><head><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>Fixture</title>"
            + "<style>body{margin:0;font:16px sans-serif} button,input,select{font-size:16px}</style></head><body>\(body)</body></html>"
        try await page.load(html: html, baseURL: URL(string: "https://example.com/start"))
        return page
    }

    private func tool(_ sessions: BrowserSessions, images: ToolImageStore = .shared, readsImages: Bool = true,
                      maxCharacters: Int = 14_000) -> BrowserAgentTool {
        BrowserAgentTool(sessions: sessions, robotCheck: { _, _ in false }, images: images, readsImages: readsImages, maxCharacters: maxCharacters,
                         settle: { _ in try await Task.sleep(for: .milliseconds(120)) })
    }

    /// The index on the line that holds `text` (or on the line above it, for text under its element).
    private func index(of text: String, in state: String) -> Int? {
        let lines = state.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains(text) }) else { return nil }
        for line in [lines[i]] + (i > 0 ? [lines[i - 1]] : []) {
            if let r = line.range(of: #"\[(\d+)\]<"#, options: .regularExpression) {
                return Int(line[r].dropFirst().prefix { $0.isNumber })
            }
        }
        return nil
    }

    @Test func theStateListsWhatIsInViewWithIndices() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        _ = try await open("""
        <h1>Hello world</h1>
        <nav><a href="/about">About us</a> <a href="https://other.com/x?y=1">Other</a></nav>
        <form><input name="q" placeholder="Search"><button type="submit">Go</button></form>
        <div role="button" aria-label="Menu" style="cursor:pointer"><span>Menu</span></div>
        <div style="display:none"><button>Hidden one</button></div>
        <button style="visibility:hidden">Invisible one</button>
        <div style="height:3000px">tall</div>
        <button>Below the fold</button>
        """, sessions: sessions)
        let out = await tool(sessions).run(.state, conversation: chat)
        #expect(!out.isError, "\(out.text)")
        let text = out.text
        #expect(text.hasPrefix("URL: https://example.com/start\nTitle: Fixture\nScroll: 0 px above, "))
        #expect(text.contains("Hello world"))
        #expect(text.range(of: #"\[\d+\]<a href=/about />\n\tAbout us"#, options: .regularExpression) != nil, "\(text)")
        #expect(text.contains("<a href=other.com/x?y=1 />"))
        #expect(text.contains("<input type=text name=q placeholder=Search value= />") || text.contains("<input type=text name=q placeholder=Search />"))
        #expect(text.range(of: #"\[\d+\]<div role=button />\n\tMenu"#, options: .regularExpression) != nil, "the label that repeats the text is left out")
        #expect(!text.contains("Hidden one") && !text.contains("Invisible one"), "hidden elements are left out")
        #expect(!text.contains("Below the fold"), "only the viewport is listed")
        #expect(!text.contains("*["), "a first look marks nothing new")
    }

    @Test func clickingFindsWhatAppearedAndMarksItNew() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        _ = try await open("""
        <button onclick="var b=document.createElement('button');b.textContent='Fresh';document.body.appendChild(b)">Add</button>
        """, sessions: sessions)
        var agent = tool(sessions)
        agent.settle = { try await BrowserAgentSettle.wait($0) }
        let first = await agent.run(.state, conversation: chat)
        let add = try #require(index(of: "Add", in: first.text))
        let clicked = await agent.run(.click(index: add), conversation: chat)
        #expect(clicked.text.hasPrefix("Clicked [\(add)] Add\n"), "\(clicked.text)")
        #expect(clicked.text.range(of: #"\*\[\d+\]<button />\n\tFresh"#, options: .regularExpression) != nil, "\(clicked.text)")
        #expect(clicked.text.contains("[\(add)]<button />"), "the old button keeps its index, without a star")
        let again = await agent.run(.state, conversation: chat)
        #expect(!again.text.contains("*["), "seen once, no longer new")
    }

    @Test func linksNavigateWhenClicked() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        _ = try await open("<a href=\"#second\">Jump</a><div style=\"height:2000px\"></div><h2 id=second>Second part</h2>", sessions: sessions)
        let agent = tool(sessions)
        let state = await agent.run(.state, conversation: chat)
        let jump = try #require(index(of: "Jump", in: state.text))
        let out = await agent.run(.click(index: jump), conversation: chat)
        #expect(out.text.contains("The page is now https://example.com/start#second"), "\(out.text)")
        #expect(out.text.contains("Second part"))
    }

    @Test func shadowRootsAreListed() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        _ = try await open("""
        <div id="host"><span slot="x">Slotted text</span></div>
        <script>
        const r = document.getElementById('host').attachShadow({ mode: 'open' });
        r.innerHTML = '<button id="b">Shadow button</button><slot name="x"></slot>';
        r.getElementById('b').addEventListener('click', () => { document.title = 'clicked in shadow'; });
        </script>
        """, sessions: sessions)
        let agent = tool(sessions)
        let state = await agent.run(.state, conversation: chat)
        #expect(state.text.range(of: #"\[\d+\]<button />\n\tShadow button"#, options: .regularExpression) != nil, "\(state.text)")
        #expect(state.text.contains("Slotted text"))
        let b = try #require(index(of: "Shadow button", in: state.text))
        let out = await agent.run(.click(index: b), conversation: chat)
        #expect(out.text.contains("Title: clicked in shadow"), "\(out.text)")
    }

    @Test func aLongStateIsCutWithANote() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        let buttons = (1...200).map { "<button style=\"display:block;width:100%;height:4px;font-size:2px\">Button number \($0) with a long label</button>" }.joined()
        _ = try await open(buttons, sessions: sessions)
        let out = await tool(sessions, maxCharacters: 1_500).run(.state, conversation: chat)
        #expect(out.text.contains("[Truncated at 1500 characters:"), "\(out.text)")
        #expect(out.text.count < 2_100)
    }

    @Test func typingReachesTheInputsListenersAndSubmits() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        let page = try await open("""
        <form onsubmit="event.preventDefault(); document.getElementById('sent').textContent = 'submitted:' + this.q.value">
        <input name="q" placeholder="Search" oninput="document.getElementById('out').textContent = 'got:' + this.value">
        </form>
        <p id="out"></p><p id="sent"></p>
        """, sessions: sessions)
        let agent = tool(sessions)
        let state = await agent.run(.state, conversation: chat)
        let q = try #require(index(of: "placeholder=Search", in: state.text))
        let typed = await agent.run(.type(index: q, text: "hello", submit: false), conversation: chat)
        #expect(typed.text.hasPrefix("Typed \"hello\" into [\(q)] Search"), "\(typed.text)")
        #expect(typed.text.contains("got:hello") && typed.text.contains("value=hello"))
        let submitted = await agent.run(.type(index: q, text: "cafe", submit: true), conversation: chat)
        #expect(submitted.text.contains("and submitted") && submitted.text.contains("submitted:cafe"), "\(submitted.text)")
        #expect(try await page.evaluate("document.querySelector('input').value", timeout: .seconds(2)) == "cafe")
    }

    @Test func reactStyleValueTrackersSeeTheEdit() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        // React keeps the last value it saw in a hook on the element's own `value`, and reports a change only when the
        // input event finds a different one: a value set through the page's own setter would go unnoticed.
        _ = try await open("""
        <input placeholder="Name"><p id="r"></p>
        <script>
        const i = document.querySelector('input');
        const d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
        let tracked = i.value;
        Object.defineProperty(i, 'value', { configurable: true, get() { return d.get.call(this); }, set(v) { tracked = String(v); d.set.call(this, v); } });
        i.addEventListener('input', () => { const now = d.get.call(i); if (now !== tracked) { tracked = now; document.getElementById('r').textContent = 'react:' + now; } });
        </script>
        """, sessions: sessions)
        let agent = tool(sessions)
        let state = await agent.run(.state, conversation: chat)
        let name = try #require(index(of: "placeholder=Name", in: state.text))
        let out = await agent.run(.type(index: name, text: "Kim", submit: false), conversation: chat)
        #expect(out.text.contains("react:Kim"), "\(out.text)")
    }

    @Test func aFieldThePageFocusesDoesNotKeepTheKeyboard() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        let page = try await open("""
        <button onclick="document.querySelector('input').focus()">Open search</button><input placeholder="Search">
        """, sessions: sessions)
        let agent = tool(sessions)
        let state = await agent.run(.state, conversation: chat)
        let open = try #require(index(of: "Open search", in: state.text))
        _ = await agent.run(.click(index: open), conversation: chat)
        let responder = FirstResponder.current as? UIView
        #expect(!(responder?.isDescendant(of: page.webView) ?? false), "the hidden page gives the focus back")
    }

    @Test func selectChoosesByTextOrValue() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        _ = try await open("""
        <select name="size" onchange="document.getElementById('o').textContent = 'chose:' + this.value">
        <option value="s">Small</option><option value="l">Large</option></select><p id="o"></p>
        """, sessions: sessions)
        let agent = tool(sessions)
        let state = await agent.run(.state, conversation: chat)
        #expect(state.text.contains("<select name=size value=Small options=Small|Large />"), "\(state.text)")
        let s = try #require(index(of: "<select", in: state.text))
        let out = await agent.run(.select(index: s, option: "large"), conversation: chat)
        #expect(out.text.hasPrefix("Selected \"Large\" in [\(s)]") && out.text.contains("chose:l"), "\(out.text)")
        let missing = await agent.run(.select(index: s, option: "Huge"), conversation: chat)
        #expect(missing.isError && missing.text.contains("Small | Large"))
        let notSelect = await agent.run(.type(index: s, text: "x", submit: false), conversation: chat)
        #expect(notSelect.isError && notSelect.text.contains("browser_select"))
    }

    @Test func scrollingMovesTheViewAndFindLooksEverywhere() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        _ = try await open("""
        <p>Top text</p><div style="height:4000px"></div><button>Far button</button><p>The price is 5,000 won</p>
        """, sessions: sessions)
        let agent = tool(sessions)
        _ = await agent.run(.state, conversation: chat)
        let scrolled = await agent.run(.scroll(down: true, pages: 1, index: nil), conversation: chat)
        #expect(scrolled.text.hasPrefix("Scrolled down 1 page"), "\(scrolled.text)")
        let above = scrolled.text.firstMatch(of: /Scroll: (\d+) px above/).flatMap { Int($0.1) } ?? 0
        #expect(above > 300)
        let back = await agent.run(.scroll(down: false, pages: 5, index: nil), conversation: chat)
        #expect(back.text.contains("Scroll: 0 px above"))
        let top = await agent.run(.scroll(down: false, pages: 1, index: nil), conversation: chat)
        #expect(top.text.hasPrefix("Already at the top"))

        let found = await agent.run(.find(text: "PRICE is", scrollTo: nil), conversation: chat)
        #expect(found.text.hasPrefix("Found 1 match for \"PRICE is\""), "\(found.text)")
        #expect(found.text.contains("px below") && found.text.contains("The price is 5,000 won"))
        let there = await agent.run(.find(text: "price is", scrollTo: 1), conversation: chat)
        #expect(there.text.contains("Scrolled the match into view") && there.text.contains("Far button"), "\(there.text)")
        let none = await agent.run(.find(text: "nowhere to be found", scrollTo: nil), conversation: chat)
        #expect(!none.isError && none.text.hasPrefix("No visible text"))
    }

    @Test func aContainerScrollsByItsIndex() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        _ = try await open("""
        <div id="list" style="height:200px;overflow-y:auto"><div style="height:1500px">Inside the list</div></div>
        """, sessions: sessions)
        let agent = tool(sessions)
        let state = await agent.run(.state, conversation: chat)
        #expect(state.text.contains("|SCROLL|["), "\(state.text)")
        let list = try #require(index(of: "|SCROLL|", in: state.text))
        let out = await agent.run(.scroll(down: true, pages: 1, index: list), conversation: chat)
        #expect(out.text.hasPrefix("Scrolled [\(list)] down 1 page"), "\(out.text)")
        #expect(out.text.contains("(200 px above, "), "\(out.text)")
    }

    @Test func staleIndicesAreRefusedWithTheLatestState() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        let page = try await open("<button>One</button>", sessions: sessions)
        let agent = tool(sessions)
        let state = await agent.run(.state, conversation: chat)
        let one = try #require(index(of: "One", in: state.text))
        let unknown = await agent.run(.click(index: 9_999), conversation: chat)
        #expect(unknown.isError && unknown.text.contains("[9999] is not in the latest page state") && unknown.text.contains("URL: "))
        _ = try await page.evaluate("document.body.innerHTML = '<button>Two</button>'; ''", timeout: .seconds(2))
        let gone = await agent.run(.click(index: one), conversation: chat)
        #expect(gone.isError && gone.text.contains("no longer on the page") && gone.text.contains("Two"), "\(gone.text)")
        let fresh = try #require(index(of: "Two", in: gone.text))
        #expect(fresh > one, "indices never repeat in a session")
    }

    @Test func actionsNeedAnOpenPage() async {
        let sessions = BrowserSessions()
        sessions.makePage = { HiddenWebView(guardNavigations: false) }
        defer { sessions.closeAll() }
        let out = await tool(sessions).run(.click(index: 1), conversation: chat)
        #expect(out.isError && out.text.contains("browser_open"))
    }

    @Test func screenshotsAreAttachedOnlyForModelsThatReadImages() async throws {
        let sessions = BrowserSessions()
        defer { sessions.closeAll() }
        _ = try await open("<button style=\"margin:40px\">Snap</button>", sessions: sessions)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ToolImageStore(root: root)
        let refused = await tool(sessions, images: store, readsImages: false).run(.screenshot, conversation: chat)
        #expect(refused.isError && refused.viewedImage == nil)
        let out = await tool(sessions, images: store).run(.screenshot, conversation: chat)
        #expect(!out.isError, "\(out.text)")
        let image = try #require(out.viewedImage)
        #expect(image.id.hasPrefix("screenshot-1-") && image.width > 0 && image.width <= BrowserAgentTool.screenshotWidth)
        #expect(store.image(id: image.id, conversationID: chat) != nil)
        #expect(out.text.contains("Snap"))
        let page = try #require(sessions.existingSession(chat)?.page as? HiddenWebView)
        let marks = try await page.evaluate("String(document.documentElement.children.length)", timeout: .seconds(2))
        #expect(marks == "2", "the boxes are gone after the snapshot")
    }
}
