import Testing
@testable import Strata

@MainActor
struct BrowserRunTests {
    private func card(_ id: String, _ kind: FeedCard.Kind) -> FeedCard { FeedCard(id: id, kind: kind) }

    @Test func browserCallsAndTheNotesAmongThemAreOneRun() {
        let cards = [
            card("s", .search(query: "q")),
            card("k", .note(tool: ToolNames.loadSkill, argument: "naver-places")),
            card("o", .browser(url: "https://map.naver.com/")),
            card("c", .browserAction(tool: ToolNames.browserClick, argument: "[12]")),
            card("p", .pages),
            card("e", .script(code: "1")),
        ]
        let items = BrowserRun.items(cards)
        #expect(items.map(\.id) == ["s", "run-k", "p", "run-e"])
        guard case .run(let run) = items[1] else { Issue.record("not a run"); return }
        #expect(run.steps.map(\.id) == ["k", "o", "c"])
        #expect(run.host == "map.naver.com" || run.host == "naver.com")
    }

    @Test func aRunWithoutAPageKeepsTheSiteItIsOn() {
        let first = [card("o", .browser(url: "https://flight.naver.com/"))]
        var click = card("c", .browserAction(tool: ToolNames.browserClick, argument: "[8]"))
        click.isRunning = true
        let earlier = BrowserRun.lastHost(first)
        #expect(earlier != nil)
        guard case .run(let run) = BrowserRun.items([click], earlierHost: earlier).first else { Issue.record("not a run"); return }
        #expect(run.host == earlier)
        // A finished action names the page it left.
        click.isRunning = false
        click.output = "Clicked [8] Close\nThe page is now https://example.com/a\n\nURL: https://example.com/a"
        guard case .run(let done) = BrowserRun.items([click], earlierHost: earlier).first else { Issue.record("not a run"); return }
        #expect(done.host == "example.com")
        #expect(BrowserRun.items([click]).count == 1)
    }

    @Test func notesAloneStaySingleLines() {
        let cards = [card("k", .note(tool: ToolNames.loadSkill, argument: "x")), card("l", .note(tool: ToolNames.currentLocation, argument: ""))]
        #expect(BrowserRun.items(cards).map(\.id) == ["k", "l"])
    }

    @Test func runIsRunningWhileAStepRuns() {
        var open = card("o", .browser(url: "https://example.com/"))
        #expect(!BrowserRun(steps: [open]).isRunning)
        open.isRunning = true
        #expect(BrowserRun(steps: [open]).isRunning)
    }
}
