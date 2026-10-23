import Testing
import Foundation

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
