import Foundation
import Testing
@testable import Strata

private func search(_ id: String) -> FeedCard { FeedCard(id: id, kind: .search(query: "q \(id)")) }
private func pages(_ id: String, count: Int) -> FeedCard {
    var card = FeedCard(id: id, kind: .pages)
    card.extras = (0..<count).map { FeedRow(id: "\(id)-\($0)", title: "t", host: "e.com", url: "https://e.com/\($0)", read: .read) }
    return card
}
private func python(_ id: String) -> FeedCard { FeedCard(id: id, kind: .python(code: "print(1)")) }
private func places(_ id: String) -> FeedCard { FeedCard(id: id, kind: .places) }

private func feed(_ cards: FeedCard...) -> [BrowserRun.Item] { BrowserRun.items(cards) }

struct ProcessFoldTests {
    /// The "many rounds" shape: a thought, a short note and a search per round.
    private func manyRounds(_ rounds: Int) -> (items: [MessageLayout.Item], feeds: [Int: [BrowserRun.Item]], notes: [Int: String]) {
        var items: [MessageLayout.Item] = []
        var feeds: [Int: [BrowserRun.Item]] = [:]
        var notes: [Int: String] = [:]
        for r in 0..<rounds {
            items += [.reasoning(r * 3), .note(r * 3 + 1), .feed(r)]
            notes[r * 3 + 1] = "Let me search for this."
            feeds[r] = feed(search("s\(r)"))
        }
        return (items, feeds, notes)
    }

    @Test func rowsClassifyThoughtsNotesStepsAndResults() {
        let items: [MessageLayout.Item] = [.reasoning(0), .note(1), .feed(0), .note(2), .working, .text]
        let rows = ProcessFold.rows(items: items, feedItems: [0: feed(search("s"), places("p"))],
                                    notes: [1: "Let me check.", 2: String(repeating: "Long findings. ", count: 40)])
        #expect(rows.map(\.kind) == [.thought, .note, .step, .result, .result])
        #expect(rows.map(\.id) == ["reasoning0", "note1", "feed/s", "feed/p", "note2"])
        #expect(rows[2].feedItem == "s")
    }

    @Test func aNoteOfSeveralParagraphsIsForReading() {
        #expect(ProcessFold.isNarrationNote("Let me look more closely at the data."))
        #expect(!ProcessFold.isNarrationNote("First part.\n\nSecond part."))
        #expect(!ProcessFold.isNarrationNote(String(repeating: "x", count: ProcessFold.noteLimit + 1)))
    }

    @Test func aWaitingApprovalNeverFolds() {
        let shape = manyRounds(4)
        let rows = ProcessFold.rows(items: shape.items, feedItems: shape.feeds, notes: shape.notes, attention: ["s0"])
        #expect(rows.first { $0.feedItem == "s0" }?.kind == .attention)
        for working in [true, false] {
            let plan = ProcessFold.plan(rows: rows, working: working, hasAnswer: !working)
            #expect(!plan.hidden.contains("feed/s0"))
        }
    }

    @Test func aFinishedMessageFoldsItsWorkBehindTheSummary() {
        let shape = manyRounds(3)
        let rows = ProcessFold.rows(items: shape.items + [.text], feedItems: shape.feeds, notes: shape.notes)
        let plan = ProcessFold.plan(rows: rows, working: false, hasAnswer: true)
        #expect(plan.mode == .summary)
        #expect(plan.hidden.count == 9)
        #expect(plan.hiddenSteps == 3 && plan.hiddenNarration == 6)
        let shown = ProcessFold.displayed(items: shape.items + [.text], rows: rows, plan: plan, expanded: false)
        #expect(shown == [.fold, .text])
        let open = ProcessFold.displayed(items: shape.items + [.text], rows: rows, plan: plan, expanded: true)
        #expect(open == [.fold] + shape.items + [.text])
    }

    @Test func resultsStayOutsideTheFold() {
        let items: [MessageLayout.Item] = [.reasoning(0), .feed(0), .reasoning(2), .text]
        let rows = ProcessFold.rows(items: items, feedItems: [0: feed(search("s1"), places("map"), search("s2"))], notes: [:])
        let plan = ProcessFold.plan(rows: rows, working: false, hasAnswer: true)
        #expect(plan.mode == .summary)
        #expect(ProcessFold.displayed(items: items, rows: rows, plan: plan, expanded: false) == [.fold, .feed(0), .text])
        #expect(ProcessFold.hiddenFeedItems(feed: 0, rows: rows, plan: plan, expanded: false) == ["s1", "s2"])
        #expect(ProcessFold.hiddenFeedItems(feed: 0, rows: rows, plan: plan, expanded: true).isEmpty)
    }

    @Test func twoRowsDoNotFold() {
        let items: [MessageLayout.Item] = [.reasoning(0), .feed(0), .text]
        let rows = ProcessFold.rows(items: items, feedItems: [0: feed(search("s"))], notes: [:])
        let plan = ProcessFold.plan(rows: rows, working: false, hasAnswer: true)
        #expect(plan == .open)
        #expect(ProcessFold.displayed(items: items, rows: rows, plan: plan, expanded: false) == items)
    }

    @Test func aFinishedMessageWithoutAnAnswerShowsItsWork() {
        let shape = manyRounds(3)
        let rows = ProcessFold.rows(items: shape.items, feedItems: shape.feeds, notes: shape.notes)
        #expect(ProcessFold.plan(rows: rows, working: false, hasAnswer: false) == .open)
    }

    @Test func whileWorkingOnlyTheNewestStepsAndThoughtShow() {
        let shape = manyRounds(4)
        let items = shape.items + [.working]
        let rows = ProcessFold.rows(items: items, feedItems: shape.feeds, notes: shape.notes)
        let plan = ProcessFold.plan(rows: rows, working: true, hasAnswer: false)
        #expect(plan.mode == .earlier)
        // Newest three of: the steps, and the newest narration (round 3's note).
        let shown = Set(rows.map(\.id)).subtracting(plan.hidden)
        #expect(shown == ["feed2/s2", "note10", "feed3/s3"])
        #expect(plan.hiddenSteps == 2)
        #expect(ProcessFold.earlierTitle(plan) == "2 earlier steps")
        #expect(ProcessFold.displayed(items: items, rows: rows, plan: plan, expanded: false)
                == [.fold, .feed(2), .note(10), .feed(3), .working])
        #expect(ProcessFold.displayed(items: items, rows: rows, plan: plan, expanded: true) == [.fold] + items)
    }

    @Test func olderThoughtsFoldWhileWorkingEvenWithFewSteps() {
        let items: [MessageLayout.Item] = [.reasoning(0), .feed(0), .reasoning(2), .reasoning(3), .working]
        let rows = ProcessFold.rows(items: items, feedItems: [0: feed(search("s"))], notes: [:])
        let plan = ProcessFold.plan(rows: rows, working: true, hasAnswer: false)
        #expect(plan.mode == .earlier)
        #expect(plan.hidden == ["reasoning0", "reasoning2"])
        #expect(ProcessFold.earlierTitle(plan) == "2 earlier thoughts")
    }

    @Test func aShortWorkingFeedShowsEverything() {
        let items: [MessageLayout.Item] = [.reasoning(0), .feed(0), .working]
        let rows = ProcessFold.rows(items: items, feedItems: [0: feed(search("s1"), pages("p", count: 2))], notes: [:])
        #expect(ProcessFold.plan(rows: rows, working: true, hasAnswer: false) == .open)
        // One row would hide behind a line of its own: not worth it.
        let four = ProcessFold.rows(items: items, feedItems: [0: feed(search("s1"), pages("p", count: 2), search("s2"))], notes: [:])
        #expect(ProcessFold.plan(rows: four, working: true, hasAnswer: false) == .open)
    }

    @Test func aShortStreamingTextStillCountsAsWorking() {
        #expect(ProcessFold.isWorking(isStreaming: true, answerStarted: false, answerText: ""))
        #expect(ProcessFold.isWorking(isStreaming: true, answerStarted: true, answerText: "Let me check this."))
        #expect(!ProcessFold.isWorking(isStreaming: true, answerStarted: true, answerText: "# Title\n\nThe answer."))
        #expect(!ProcessFold.isWorking(isStreaming: true, answerStarted: true,
                                       answerText: String(repeating: "word ", count: 80)))
        #expect(!ProcessFold.isWorking(isStreaming: false, answerStarted: false, answerText: ""))
    }

    @Test func summaryCountsCardsAndSkipsZeros() {
        let cards = [search("a"), pages("p", count: 3), search("b"), python("py1"), python("py2")]
        let summary = ProcessFold.Summary(cards: cards, thinkingSeconds: 72)
        #expect(summary.title == "Thought for 1m 12s · 2 searches · 3 pages · 2 Python runs")
        #expect(ProcessFold.Summary(cards: [search("a"), pages("p", count: 1), python("x")], thinkingSeconds: nil).title
                == "1 search · 1 page · 1 Python run")
        #expect(ProcessFold.Summary(cards: [], thinkingSeconds: nil).title == "Worked on it")
    }

    @Test func summaryNamesOtherStepsPlainlyWhenAlone() {
        let notes = [FeedCard(id: "n1", kind: .note(tool: "load_skill", argument: "x")),
                     FeedCard(id: "n2", kind: .note(tool: "load_skill", argument: "y"))]
        #expect(ProcessFold.Summary(cards: notes, thinkingSeconds: nil).title == "2 steps")
        #expect(ProcessFold.Summary(cards: [search("s")] + notes, thinkingSeconds: nil).title == "1 search · 2 other steps")
    }

    @Test func thinkingSecondsAddUpRoundsElseTheWholeMessage() {
        let rounds = [ProcessSegment(index: 0, kind: .thinking, text: "a", seconds: 10),
                      ProcessSegment(index: 1, kind: .thinking, text: "b", seconds: 5)]
        #expect(ProcessFold.thinkingSeconds(segments: rounds, whole: 99) == 15)
        #expect(ProcessFold.thinkingSeconds(segments: [], whole: 7) == 7)
        #expect(ProcessFold.thinkingSeconds(segments: [], whole: nil) == nil)
    }

}
