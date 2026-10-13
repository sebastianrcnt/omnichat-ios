import Foundation
import Testing
@testable import Strata

private func source(_ id: Int, _ url: String, _ title: String = "") -> SourceInfo {
    SourceInfo(id: id, title: title.isEmpty ? "Page \(id)" : title, url: url, snippet: "")
}

private func search(_ id: String, _ query: String = "q", ids: [Int], engine: String? = "Bing", status: FeedCall.Status = .done) -> FeedCall {
    FeedCall(id: id, isSearch: true, argument: query, status: status, sourceIDs: ids, engine: engine)
}

private func fetch(_ id: String, _ url: String, status: FeedCall.Status = .done, ids: [Int] = [], thin: Bool = false) -> FeedCall {
    FeedCall(id: id, isSearch: false, argument: url, status: status, sourceIDs: ids, thin: thin)
}

struct FeedURLTests {
    @Test func schemeWwwTrailingSlashAndFragmentDoNotMatter() {
        let base = FeedURL.key("https://www.example.com/news/1")
        #expect(FeedURL.key("http://example.com/news/1/") == base)
        #expect(FeedURL.key("https://EXAMPLE.com/news/1#section-2") == base)
        #expect(FeedURL.key("  https://www.example.com/news/1// ") == base)
        #expect(FeedURL.key("https://example.com/news/2") != base)
        #expect(FeedURL.key("https://example.com/news/1?id=2") != base, "the query still tells pages apart")
    }

    @Test func mobileHostsAndTrackingParametersMatch() {
        #expect(FeedURL.key("https://m.blog.naver.com/user/223") == FeedURL.key("https://blog.naver.com/user/223"))
        #expect(FeedURL.key("https://a.com/x?id=1&utm_source=bing") == FeedURL.key("https://a.com/x?id=1"))
        #expect(FeedURL.key("https://m.io/") == "m.io", "a short host is not stripped down to nothing")
    }

    @Test func percentEncodingDoesNotMatter() {
        // Bing and Naver redirect links are decoded when the results are read, so result rows hold the target URL;
        // the model may send it encoded or not.
        let decoded = "https://ko.wikipedia.org/wiki/합계출산율"
        let encoded = "https://ko.wikipedia.org/wiki/%ED%95%A9%EA%B3%84%EC%B6%9C%EC%82%B0%EC%9C%A8"
        #expect(FeedURL.key(decoded) == FeedURL.key(encoded))
        #expect(FeedURL.key("https://news.example.com/a?q=%EC%B6%9C%EC%82%B0") == FeedURL.key("https://news.example.com/a?q=출산"))
    }
}

struct FetchOutcomeTests {
    @Test func totalLengthComesFromTheFooter() {
        #expect(FetchOutcome.totalCharacters(in: "<source id=\"1\">body\n\n[End of page, 3214 characters total.]</source>") == 3214)
        #expect(FetchOutcome.totalCharacters(in: "body\n\n[Showing characters 0\u{2013}12000 of 48211. Call web_fetch with the same url and offset=12000 to read more.]") == 48211)
        #expect(FetchOutcome.totalCharacters(in: "no footer") == nil)
    }

    @Test func thinPagesAreShortOrChallenges() {
        #expect(FetchOutcome.isThin(result: "x", characters: 120))
        #expect(!FetchOutcome.isThin(result: String(repeating: "a", count: 400), characters: 400))
        #expect(FetchOutcome.isThin(result: "Just a moment... Checking your browser" + String(repeating: " ", count: 500), characters: 900))
        #expect(!FetchOutcome.isThin(result: "An article about CAPTCHA design." + String(repeating: "x", count: 5000), characters: 5100),
                "a long page that mentions a phrase is a real page")
    }

    @Test func displayOnlyKeepsTheOutcomeWithoutTheText() {
        let fetchRecord = ToolCallRecord(id: "f", name: ToolNames.webFetch, arguments: "{\"url\":\"https://a.com\"}",
                                         result: "<source id=\"1\">" + String(repeating: "w ", count: 400) + "\n\n[End of page, 800 characters total.]</source>",
                                         isError: false, sourceIDs: [1])
        let slim = fetchRecord.displayOnly
        #expect(slim.result.isEmpty)
        #expect(slim.fetchedCharacters == 800 && !slim.isThinPage)
        let searchRecord = ToolCallRecord(id: "s", name: ToolNames.webSearch, arguments: "{\"query\":\"q\"}",
                                          result: "Results from Naver:\n<source id=\"1\">x</source>", isError: false, sourceIDs: [1])
        #expect(searchRecord.searchEngine == "Naver")
        #expect(searchRecord.displayOnly.searchEngine == "Naver")
        // A record saved before these fields existed decodes without them.
        let old = #"{"id":"a","name":"web_search","arguments":"{}","result":"","isError":false,"sourceIDs":[1]}"#
        let decoded = try? JSONDecoder().decode(ToolCallRecord.self, from: Data(old.utf8))
        #expect(decoded?.engine == nil && decoded?.searchEngine == nil)
    }

    @Test func fullRecordsEncodeAsBefore() throws {
        // Full records (the history replayed to the API is built from them) get no new keys.
        let record = ToolCallRecord(id: "a", name: ToolNames.webFetch, arguments: "{}", result: "r", isError: false)
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(!json.contains("engine") && !json.contains("pageCharacters") && !json.contains("thinPage"))
    }
}

struct ActivityFeedTests {
    let sources: [Int: SourceInfo] = [
        1: source(1, "https://kostat.go.kr/board/1"),
        2: source(2, "https://www.hani.co.kr/arti/2"),
        3: source(3, "https://chosun.com/a/3"),
        4: source(4, "https://ko.wikipedia.org/wiki/합계출산율"),
        5: source(5, "https://naver.com/5"),
        6: source(6, "https://oecd.org/6"),
        7: source(7, "https://blog.naver.com/u/7"),
        8: source(8, "https://joongang.co.kr/8"),
        9: source(9, "https://reuters.com/9"),
        10: source(10, "https://bbc.com/10"),
        11: source(11, "https://other.org/picked-by-the-model", "Picked page"),
    ]

    @Test func oneCardPerSearchWithItsResults() {
        let cards = ActivityFeed.cards(calls: [search("s1", "출산율", ids: [1, 2, 3], engine: "Naver"), search("s2", ids: [9, 10])], sources: sources)
        #expect(cards.count == 2)
        #expect(cards[0].kind == .search(query: "출산율") && cards[0].engine == "Naver")
        #expect(cards[0].results.map(\.host) == ["kostat.go.kr", "hani.co.kr", "chosun.com"])
        #expect(cards[1].results.count == 2)
        #expect(cards.allSatisfy { $0.extras.isEmpty })
    }

    @Test func aFetchAttachesToTheMatchingResultRow() {
        let calls = [
            search("s1", ids: [1, 2, 3]),
            fetch("f1", "http://kostat.go.kr/board/1/"),               // scheme and slash differ
            fetch("f2", "https://hani.co.kr/arti/2#top", status: .running),
            fetch("f3", "https://chosun.com/a/3", status: .failed),
        ]
        let card = ActivityFeed.cards(calls: calls, sources: sources)[0]
        #expect(card.results.map(\.read) == [.read, .loading(callID: "f2"), .failed])
        #expect(card.extras.isEmpty, "no separate fetch rows")
        #expect(card.hasLoadingRow && card.readCount == 1)
    }

    @Test func aRedirectedPageMatchesThroughItsSource() {
        // The model asked for a short link; the page that loaded (its source) is a result.
        let card = ActivityFeed.cards(calls: [search("s1", ids: [1, 2]), fetch("f1", "https://t.co/abc", ids: [2])], sources: sources)[0]
        #expect(card.results[1].read == .read && card.extras.isEmpty)
    }

    @Test func aThinPageIsMarked() {
        let card = ActivityFeed.cards(calls: [search("s1", ids: [1]), fetch("f1", "https://kostat.go.kr/board/1", thin: true)], sources: sources)[0]
        #expect(card.results[0].read == .thin)
    }

    @Test func unlistedPagesGoToAPagesCardPerRunOfDirectReads() {
        let before = ActivityFeed.cards(calls: [fetch("f0", "https://other.org/picked-by-the-model", ids: [11])], sources: sources)
        #expect(before.count == 1 && before[0].kind == .pages)
        #expect(before[0].extras.map(\.title) == ["Picked page"])

        // Never appended to the latest search card.
        let calls = [search("s1", ids: [1]), search("s2", ids: [9]), fetch("f1", "https://elsewhere.net/x"), fetch("f2", "https://elsewhere.net/x/", status: .running)]
        let cards = ActivityFeed.cards(calls: calls, sources: sources)
        #expect(cards.count == 3)
        #expect(cards[0].extras.isEmpty && cards[1].extras.isEmpty)
        #expect(cards[2].kind == .pages)
        #expect(cards[2].extras.count == 1, "the same page read twice is one row")
        #expect(cards[2].extras[0].host == "elsewhere.net" && cards[2].extras[0].read == .loading(callID: "f2"))
    }

    @Test func aSearchOrAListedReadEndsARunOfDirectReads() {
        let calls = [
            fetch("f1", "https://a.org/1"), fetch("f2", "https://b.org/2"),   // one Pages card
            search("s1", ids: [1, 2]),
            fetch("f3", "https://c.org/3"),                                    // a second one, after the search
            fetch("f4", "https://kostat.go.kr/board/1"),                       // listed by s1
            fetch("f5", "https://d.org/4"),                                    // a third
            fetch("f6", "https://a.org/1", status: .failed),                   // a re-read updates its old row
        ]
        let cards = ActivityFeed.cards(calls: calls, sources: sources)
        #expect(cards.map(\.kind) == [.pages, .search(query: "q"), .pages, .pages])
        #expect(cards[0].extras.map(\.host) == ["a.org", "b.org"])
        #expect(cards[0].extras[0].read == .read, "a failed retry never hides a success")
        #expect(cards[2].extras.map(\.host) == ["c.org"])
        #expect(cards[3].extras.map(\.host) == ["d.org"])
        #expect(cards[1].results[0].read == .read)
    }

    @Test func aLaterReadOfTheSamePageUpdatesTheNewestCardHoldingIt() {
        // Both searches found the same page: the newer card gets the read.
        let calls = [search("s1", ids: [1, 2]), search("s2", ids: [2, 9]), fetch("f1", "https://hani.co.kr/arti/2")]
        let cards = ActivityFeed.cards(calls: calls, sources: sources)
        #expect(cards[0].results[1].read == nil)
        #expect(cards[1].results[0].read == .read)
    }

    @Test func readStatesMerge() {
        #expect(FeedRead.read.merged(with: .failed) == .read, "a failed retry never hides a success")
        #expect(FeedRead.failed.merged(with: .read) == .read)
        #expect(FeedRead.read.merged(with: .loading(callID: "x")) == .loading(callID: "x"), "reading on shows progress again")
        #expect(FeedRead.loading(callID: "x").merged(with: .failed) == .failed)
        #expect(FeedRead.read.merged(with: .thin) == .read)
    }

    @Test func fiveRowsThenMoreUntilReadingStarts() {
        let card = ActivityFeed.cards(calls: [search("s1", ids: Array(1...8))], sources: sources)[0]
        #expect(!card.isReading)
        #expect(card.visibleResults(expanded: false).map(\.host) == ["kostat.go.kr", "hani.co.kr", "chosun.com", "ko.wikipedia.org", "naver.com"])
        #expect(card.hiddenCount(expanded: false) == 3)
    }

    @Test func onceReadingStartsOnlyReadRowsShowInTheOrderTheirReadsStarted() {
        let calls = [
            search("s1", ids: Array(1...8)),
            fetch("f1", "https://blog.naver.com/u/7"),                         // result 7 first
            fetch("f2", "https://hani.co.kr/arti/2", status: .running),         // then result 2
            fetch("f3", "https://chosun.com/a/3", status: .failed),             // a failed read counts too
            fetch("f4", "https://blog.naver.com/u/7"),                         // reading on keeps its place
        ]
        let card = ActivityFeed.cards(calls: calls, sources: sources)[0]
        #expect(card.isReading)
        #expect(card.visibleResults(expanded: false).map(\.host) == ["blog.naver.com", "hani.co.kr", "chosun.com"])
        #expect(card.hiddenCount(expanded: false) == 5)
        #expect(card.readCount == 1)
        // Expanded: every result in its original order, read rows still marked.
        let all = card.visibleResults(expanded: true)
        #expect(all.map(\.host) == ["kostat.go.kr", "hani.co.kr", "chosun.com", "ko.wikipedia.org", "naver.com", "oecd.org", "blog.naver.com", "joongang.co.kr"])
        #expect(all[6].read == .read && all[1].read == .loading(callID: "f2"))
        #expect(card.hiddenCount(expanded: true) == 0)
    }

    @Test func callsKeepRequestOrderAndAppearOnce() {
        let s = ToolCallRecord(id: "s", name: ToolNames.webSearch, arguments: "{\"query\":\"q\"}", result: "", isError: false)
        let f = ToolCallRecord(id: "f", name: ToolNames.webFetch, arguments: "{\"url\":\"https://a.com\"}", result: "", isError: true)
        let requested = [PendingToolCall(id: "a", name: ToolNames.webFetch, primaryArgument: "https://b.com"),
                         PendingToolCall(id: "f", name: ToolNames.webFetch, primaryArgument: "https://a.com")]
        let calls = FeedCall.ordered(finished: [s], requested: requested, roundFinished: [f, s])
        #expect(calls.map(\.id) == ["s", "a", "f"])
        #expect(calls.map(\.status) == [.done, .running, .failed])
    }
}

struct FeedCollapseTests {
    let cards = [FeedCard(id: "a", kind: .search(query: "a")), FeedCard(id: "b", kind: .search(query: "b"))]

    @Test func theNewestCardIsOpenWhileWorking() {
        #expect(FeedCollapse.autoCollapsed(index: 0, cards: cards, isStreaming: true, answerStarted: false))
        #expect(!FeedCollapse.autoCollapsed(index: 1, cards: cards, isStreaming: true, answerStarted: false))
        #expect(!FeedCollapse.autoCollapsed(index: 0, cards: [cards[0]], isStreaming: true, answerStarted: false))
    }

    @Test func anOlderCardStaysOpenWhileOneOfItsPagesLoads() {
        var loading = cards
        loading[0].results = [FeedRow(id: "x", title: "x", host: "x.com", url: "https://x.com", read: .loading(callID: "f"))]
        #expect(!FeedCollapse.autoCollapsed(index: 0, cards: loading, isStreaming: true, answerStarted: false))
    }

    @Test func everythingFoldsWhenTheAnswerStartsAndInFinishedMessages() {
        for i in cards.indices {
            #expect(FeedCollapse.autoCollapsed(index: i, cards: cards, isStreaming: true, answerStarted: true))
            #expect(FeedCollapse.autoCollapsed(index: i, cards: cards, isStreaming: false, answerStarted: false))
        }
    }

    @Test func aTapHoldsUntilTheFeedMovesOn() {
        let working = FeedCollapse.epoch(cardCount: 2, isStreaming: true, answerStarted: false)
        // A folded older card is opened by a tap.
        let opened = FeedCollapse.toggled(auto: true, current: true, epoch: working)
        #expect(opened == FeedCollapse.Override(collapsed: false, epoch: working))
        #expect(!FeedCollapse.isCollapsed(auto: true, override: opened, epoch: working))
        // Tapping the header again folds it: back to the automatic state, no override left.
        #expect(FeedCollapse.toggled(auto: true, current: false, epoch: working) == nil)
        // A new search card starts: the opened card folds like the mockup's.
        let third = FeedCollapse.epoch(cardCount: 3, isStreaming: true, answerStarted: false)
        #expect(FeedCollapse.isCollapsed(auto: true, override: opened, epoch: third))
        // The newest card folded by a tap stays folded while working.
        let folded = FeedCollapse.toggled(auto: false, current: false, epoch: working)
        #expect(FeedCollapse.isCollapsed(auto: false, override: folded, epoch: working))
        // The answer starts: everything folds, and a card opened while it streams stays open when the turn ends.
        let answering = FeedCollapse.epoch(cardCount: 2, isStreaming: true, answerStarted: true)
        #expect(FeedCollapse.isCollapsed(auto: true, override: opened, epoch: answering))
        let reopened = FeedCollapse.toggled(auto: true, current: true, epoch: answering)
        let finished = FeedCollapse.epoch(cardCount: 2, isStreaming: false, answerStarted: false)
        #expect(finished == answering)
        #expect(!FeedCollapse.isCollapsed(auto: true, override: reopened, epoch: finished))
    }
}
