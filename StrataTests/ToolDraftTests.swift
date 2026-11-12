import Testing
import Foundation
@testable import Strata

struct ToolDraftTests {
    @Test func theTitleShowsOnceItsQuoteCloses() {
        #expect(ToolDraft.title(in: #"{"title": "Mortg"#) == "")
        #expect(ToolDraft.title(in: #"{"title": "Mortgage \"calc\"", "html": "<ht"#) == #"Mortgage "calc""#)
        #expect(ToolDraft.title(in: #"{"html": "<p>"#) == "")
        #expect(ToolDraft.title(in: #"{ "title" :"전립선 애니메이션""#) == "전립선 애니메이션")
    }

    @Test func updatesComeForANewCallATitleAndEveryStep() {
        var draft = ToolDraft()
        #expect(draft.update(ToolCall(id: "a", name: ToolNames.webSearch, arguments: "{}")) == nil, "short calls aren't shown")
        #expect(draft.update(ToolCall(id: "a", name: ToolNames.showHTML, arguments: "{")) != nil)
        #expect(draft.update(ToolCall(id: "a", name: ToolNames.showHTML, arguments: "{\"ti")) == nil)
        let titled = draft.update(ToolCall(id: "a", name: ToolNames.showHTML, arguments: #"{"title":"Chart","html":""#))
        #expect(titled?.title == "Chart")
        let long = #"{"title":"Chart","html":""# + String(repeating: "x", count: ToolDraft.step)
        #expect(draft.update(ToolCall(id: "a", name: ToolNames.showHTML, arguments: long))?.bytes == long.utf8.count)
    }

    @Test func thePageSoFarIsReadOutOfCutOffArguments() {
        #expect(ToolDraft.html(in: "") == "")
        #expect(ToolDraft.html(in: #"{"title": "Mortg"#) == "", "the page hasn't started")
        #expect(ToolDraft.html(in: #"{"title":"A","html""#) == "")
        #expect(ToolDraft.html(in: #"{"title":"A","html":"#) == "")
        #expect(ToolDraft.html(in: #"{"title":"A","html":""#) == "")
        #expect(ToolDraft.html(in: #"{"title":"A", "html" : "<h1 class=\"x\">Hi</h1>\n<p>a\\b\/c\td"#) == "<h1 class=\"x\">Hi</h1>\n<p>a\\b/c\td")
        #expect(ToolDraft.html(in: #"{"html":"<p>done</p>","title":"After"}"#) == "<p>done</p>", "the whole value once its quote closed")
        #expect(ToolDraft.html(in: #"{"id":"a1","title":"says \"html\": \"no\"","html":"<b>yes"#) == "<b>yes",
                "a title that mentions the key isn't the page")
    }

    @Test func aCutOffEscapeWaitsForItsRest() {
        #expect(ToolDraft.html(in: #"{"html":"abc\"#) == "abc")
        #expect(ToolDraft.html(in: #"{"html":"abc\u00"#) == "abc")
        #expect(ToolDraft.html(in: #"{"html":"caf\u00e9 \uc804"#) == "café 전")
        #expect(ToolDraft.html(in: #"{"html":"go \ud83d"#) == "go ", "half of a pair")
        #expect(ToolDraft.html(in: #"{"html":"go \ud83d\ude"#) == "go ")
        #expect(ToolDraft.html(in: #"{"html":"go \ud83d\ude80!"#) == "go 🚀!")
        #expect(ToolDraft.html(in: #"{"html":"lone \ud83d and on"#) == "lone \u{FFFD} and on")
        #expect(ToolDraft.html(in: #"{"html":"전립선 🚀 raw"#) == "전립선 🚀 raw", "unescaped text passes as it is")
    }

    @Test func otherValuesBeforeThePageAreSkipped() {
        #expect(ToolDraft.html(in: #"{"n": 3, "meta": {"a": ["x, y", {"b": "}"}]}, "html": "<i>ok"#) == "<i>ok")
        #expect(ToolDraft.html(in: #"{"n": 3, "meta": {"a": ["x"#) == "")
        #expect(ToolDraft.html(in: #"["html", "<p>"#) == "", "not an object")
        #expect(ToolDraft.html(in: #"{"meta": {"html": "<p>inner"}, "title": "T"#) == "", "only the top level counts")
    }

    @Test func aLargePageMatchesAFullDecode() throws {
        let page = String(repeating: "<div class=\"row\">\n\t전립선 🚀 \\ / \u{1}</div>\r\n", count: 4_000)
        let whole = String(decoding: try JSONEncoder().encode(["title": "Big", "html": page]), as: UTF8.self)
        let ordered = #"{"title":"Big","html":"# + String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        #expect(ToolDraft.html(in: whole) == page)
        #expect(ToolDraft.html(in: ordered) == page)
        // Cut anywhere, what has come is the start of the page.
        for cut in stride(from: 30, to: 2_000, by: 37) {
            let part = ToolDraft.html(in: String(ordered.utf8.prefix(cut)) ?? "")
            // Bytes, not characters: a cut between "\r" and "\n" ends on half of one Character.
            #expect(page.utf8.starts(with: part.utf8), "cut at \(cut)")
        }
    }

    @MainActor @Test func aPreviewFollowsTheCallItOpenedOn() {
        let chat = UUID()
        let first = ArtifactRef(conversationID: chat, id: "a1", title: "One", version: 1)
        let second = ArtifactRef(conversationID: chat, id: "a2", title: "Two", version: 1)
        let feed = ArtifactDraftFeed()
        #expect(feed.state(after: 0) == .writing)
        feed.write(#"{"title":"One","html":"<p>"#)
        #expect(feed.arguments.hasSuffix("<p>"))
        feed.finish(first)
        #expect(feed.state(after: 0) == .stored(first))
        // A preview opened on the next artifact isn't sent to the one stored before it.
        #expect(feed.state(after: 1) == .writing)
        feed.finish(second)
        #expect(feed.state(after: 1) == .stored(second))
        feed.end()
        #expect(feed.state(after: 2) == .ended, "the run ended with nothing more made")
    }

    @MainActor @Test func aFailedCallOrAnEndedRunEndsThePreview() {
        let feed = ArtifactDraftFeed()
        feed.finish(nil)
        #expect(feed.state(after: 0) == .ended)
        let cut = ArtifactDraftFeed()
        cut.end()
        #expect(cut.state(after: 0) == .ended)
    }

    @Test func theDraftViewersStatusLine() {
        #expect(ArtifactDraftViewer.status(bytes: 300, ended: false) == "Writing")
        #expect(ArtifactDraftViewer.status(bytes: 12_288, ended: false).hasPrefix("Writing · 12"))
        #expect(ArtifactDraftViewer.status(bytes: 300, ended: true) == "Not finished")
    }

    @Test func answerCardsShowEachArtifactOnceAtItsNewestVersion() {
        let chat = UUID()
        func call(_ id: String, _ version: Int) -> ToolCallRecord {
            var r = ToolCallRecord(id: "c\(id)\(version)", name: ToolNames.showHTML, arguments: "{}", result: "", isError: false)
            r.artifact = ArtifactRef(conversationID: chat, id: id, title: "T\(id)", version: version)
            return r
        }
        let refs = ArtifactAnswerCard.latest([call("a1", 1), call("a2", 1), call("a1", 2)])
        #expect(refs.map(\.id) == ["a1", "a2"])
        #expect(refs.first?.version == 2)
    }
}
