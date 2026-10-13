import Testing
import Foundation
@testable import Strata

private func src(_ id: Int, _ host: String) -> SourceInfo {
    SourceInfo(id: id, title: "T\(id)", url: "https://\(host)/p\(id)", snippet: "")
}

private let known: [Int: SourceInfo] = [1: src(1, "apple.com"), 2: src(2, "github.com"), 3: src(3, "swift.org")]

struct CitationParserTests {
    @Test func knownMarkerBecomesChipLink() {
        let out = CitationParser.transform("Glass is new [1].", sources: known, holdBack: false)
        #expect(out.contains("strata-cite://1"))
        #expect(out.contains("apple.com"))
        #expect(!out.contains("[1]"))
    }

    @Test func consecutiveMarkersMergeIntoOneChip() {
        for text in ["x [1][2][3]", "x [1] [2] [3]"] {
            let out = CitationParser.transform(text, sources: known, holdBack: false)
            #expect(out.components(separatedBy: "strata-cite://").count == 2, "one chip for \(text)")
            #expect(out.contains("strata-cite://1,2,3"))
            #expect(out.contains("+2"))
        }
    }

    @Test func duplicateIDsInARunCollapse() {
        let out = CitationParser.transform("x [1][1][2]", sources: known, holdBack: false)
        #expect(out.contains("strata-cite://1,2"))
    }

    @Test func unknownIDsAreHidden() {
        let out = CitationParser.transform("Claim [97] stands.", sources: known, holdBack: false)
        #expect(out == "Claim stands.")
        // A mixed run keeps only the known ids.
        let mixed = CitationParser.transform("Claim [97][2].", sources: known, holdBack: false)
        #expect(mixed.contains("strata-cite://2") && !mixed.contains("97"))
    }

    @Test func realMarkdownAndCodeAreLeftAlone() {
        #expect(CitationParser.transform("see [1](https://a.b)", sources: known, holdBack: false) == "see [1](https://a.b)")
        #expect(CitationParser.transform("`a[1]` and \\[1]", sources: known, holdBack: false) == "`a[1]` and \\[1]")
        #expect(CitationParser.transform("[1]: https://a.b", sources: known, holdBack: false) == "[1]: https://a.b")
    }

    @Test func partialMarkerAtTheEndIsHeldBackWhileStreaming() {
        #expect(CitationParser.transform("Text [", sources: known, holdBack: true) == "Text")
        #expect(CitationParser.transform("Text [1", sources: known, holdBack: true) == "Text")
        #expect(CitationParser.transform("Text [1", sources: known, holdBack: false) == "Text [1")
    }

    @Test func markersSplitAcrossDeltasNeverFlicker() {
        // Replay a stream one character at a time: no prefix may ever show raw "[" digits or a half marker.
        let full = "Glass is new [1][2] and old [3]."
        var shown: [String] = []
        var buffer = ""
        for ch in full {
            buffer.append(ch)
            shown.append(CitationParser.transform(buffer, sources: known, holdBack: true))
        }
        for s in shown {
            #expect(!s.contains("[1") || s.contains("strata-cite"), "raw marker visible in: \(s)")
            #expect(!s.hasSuffix("["))
        }
        let final = CitationParser.transform(full, sources: known, holdBack: false)
        #expect(final == shown.last)
        #expect(final.contains("strata-cite://1,2"))
        #expect(final.contains("strata-cite://3"))
    }

    @Test func mergedRunSplitAcrossDeltasEndsAsOneChip() {
        let first = CitationParser.transform("x [1][", sources: known, holdBack: true)
        #expect(first.contains("strata-cite://1") && !first.hasSuffix("["))
        let second = CitationParser.transform("x [1][2]", sources: known, holdBack: true)
        #expect(second.contains("strata-cite://1,2"))
    }

    @Test func idsFromURLAndCitedIDs() {
        #expect(CitationParser.ids(from: URL(string: "strata-cite://1,3")!) == [1, 3])
        #expect(CitationParser.ids(from: URL(string: "https://x.y")!) == [])
        #expect(CitationParser.citedIDs(in: "a [2] b [9] c [2][1]", known: [1, 2]) == [2, 1])
    }
}

@MainActor
struct SourceStoreTests {
    private func cand(_ url: String, _ title: String = "t", _ content: String = "body") -> SourceCandidate {
        SourceCandidate(title: title, url: url, content: content)
    }

    @Test func idsAreSequentialAndStable() {
        let store = SourceStore()
        let a = store.assign(cand("https://a.com/x"))
        let b = store.assign(cand("https://b.com/y"))
        #expect(a.id == 1 && b.id == 2)
        // Same URL (fragment, trailing slash, host case) keeps its id.
        #expect(store.assign(cand("https://A.com/x#frag")).id == 1)
        #expect(store.assign(cand("https://b.com/y/")).id == 2)
        #expect(store.items.count == 2)
    }

    @Test func idsContinueAcrossTurnsWhenSeededFromHistory() {
        let turn1 = SourceStore()
        turn1.assign(cand("https://a.com"))
        turn1.assign(cand("https://b.com"))
        // Next turn starts from the persisted list.
        let turn2 = SourceStore(items: turn1.items)
        #expect(turn2.assign(cand("https://b.com")).id == 2)
        #expect(turn2.assign(cand("https://c.com")).id == 3)
    }

    @Test func fillsMissingDetailsOnRepeat() {
        let store = SourceStore()
        store.assign(cand("https://a.com", "", ""))
        let again = store.assign(cand("https://a.com", "Title", "snippet text"))
        #expect(again.id == 1 && again.title == "Title" && again.snippet == "snippet text")
    }

    @Test func sourceBlocksEscapeAttributesAndClosingTags() {
        let info = SourceInfo(id: 4, title: "A \"quoted\" <b>", url: "https://a.com/?q=1&r=2", snippet: "")
        let block = SourceFormatter.block(info, content: "x </source> y")
        #expect(block.hasPrefix("<source id=\"4\" title=\"A &quot;quoted&quot; &lt;b&gt;\" url=\"https://a.com/?q=1&amp;r=2\">"))
        #expect(block.components(separatedBy: "</source>").count == 2)
    }
}

@MainActor
struct TurnSourcesTests {
    private struct SourceTools: ToolExecuting {
        func execute(name: String, arguments: String) async -> ToolOutput {
            ToolOutput(text: "raw", sources: [
                SourceCandidate(title: "One", url: "https://a.com/1", content: "alpha"),
                SourceCandidate(title: "Two", url: "https://b.com/2", content: "beta"),
            ])
        }
    }

    @Test func toolResultsBecomeNumberedSourceBlocks() async throws {
        let streamer = ScriptedStreamer([
            [ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}")])],
            [ChatDelta(content: "Answer [1][2]")],
        ])
        let store = SourceStore()
        let runner = TurnRunner(streamer: streamer, tools: SourceTools())
        let ep = Endpoint(connectionID: UUID(), connectionName: "t", baseURL: URL(string: "http://localhost/v1")!, apiKey: nil, headers: [:],
                          model: ModelInfo(id: "m", supportsTools: true))
        let outcome = try await runner.run(endpoint: ep, messages: [.user("hi")], effort: nil, sources: store) { _ in }
        let call = try #require(outcome.steps.first?.calls.first)
        #expect(call.sourceIDs == [1, 2])
        #expect(call.result.contains("<source id=\"1\" title=\"One\" url=\"https://a.com/1\">alpha</source>"))
        #expect(call.result.contains("<source id=\"2\""))
        #expect(store.items.map(\.id) == [1, 2])
        // The model sees the numbered blocks in the follow-up request.
        let tool = try #require(streamer.requests[1].messages.last)
        #expect(tool.role == "tool")
        if case .text(let content) = tool.content { #expect(content.contains("<source id=\"1\"")) } else { Issue.record("expected text content") }
    }
}

struct TimelineItemTests {
    @Test func interleavesThinkingWithToolsInStreamOrder() {
        let search = ToolCallRecord(id: "s", name: ToolNames.webSearch, arguments: "{\"query\":\"q\"}", result: "r", isError: false, sourceIDs: [1])
        let fetch = ToolCallRecord(id: "f", name: ToolNames.webFetch, arguments: "{\"url\":\"https://a.com\"}", result: "r", isError: false)
        let steps = [ToolStep(assistantContent: "", calls: [search], reasoningParagraphs: 1),
                     ToolStep(assistantContent: "", calls: [fetch], reasoningParagraphs: 2)]
        let pending = [PendingToolCall(id: "p", name: ToolNames.webFetch, primaryArgument: "https://b.com")]
        let items = TimelineItem.build(chunks: ["one", "two", "three"], steps: steps, pending: pending, sources: known)
        #expect(items.map(\.id) == ["t0", "s", "t1", "f", "t2", "p"])
        if case .activity(let e) = items[1], case .search(_, let found) = e.kind { #expect(found.map(\.id) == [1]) } else { Issue.record("expected search entry") }
    }

    @Test func emptyInputsYieldNoItems() {
        #expect(TimelineItem.build(chunks: [], steps: [], pending: [], sources: [:]).isEmpty)
    }
}

struct MarkdownTableTests {
    private func citeRuns(_ s: AttributedString) -> [String] {
        s.runs.compactMap { run in run.link?.scheme == CitationParser.scheme ? run.link!.absoluteString : nil }
    }

    @Test func parsesHeaderAlignmentsAndRows() throws {
        let t = try #require(MarkdownTable.parse("| 항목 | **설명** | n |\n| :--- | :-: | --: |\n| a | b [1] | 1 |\n| only |"))
        #expect(t.header == ["항목", "**설명**", "n"])
        #expect(t.alignments == [.leading, .center, .trailing])
        #expect(t.rows == [["a", "b [1]", "1"], ["only", "", ""]])
    }

    @Test func escapedPipesStayInTheCell() {
        #expect(MarkdownTable.cells("| a \\| b | `x \\| y` | c |") == ["a | b", "`x | y`", "c"])
        #expect(MarkdownTable.cells("a | b") == ["a", "b"]) // no edge pipes
    }

    @Test func notATableWithoutADelimiterRow() {
        #expect(MarkdownTable.parse("| a | b |\n| c | d |") == nil)
    }

    @Test func cellCitationsBecomeChipLinks() {
        let cell = TableCellText.attributed("공식 [1][2]", sources: known)
        #expect(citeRuns(cell) == ["strata-cite://1,2"])
        #expect(!String(cell.characters).contains("[1]"))
        #expect(String(cell.characters).contains("apple.com"))
        // Header cells go through the same path.
        let header = TableCellText.attributed("출처 [3]", sources: known)
        #expect(citeRuns(header) == ["strata-cite://3"])
    }

    @Test func markersInCodeSpansStayLiteralInCells() {
        let cell = TableCellText.attributed("`glass[1]` and [2]", sources: known)
        #expect(String(cell.characters).contains("glass[1]"))
        #expect(citeRuns(cell) == ["strata-cite://2"])
    }

    @Test func boldInACellIsSemiboldNotSystemBold() {
        let cell = TableCellText.attributed("**설명**", sources: [:])
        #expect(cell.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) != true })
        #expect(String(cell.characters) == "설명")
    }

    @Test func closedTableBlockRendersWithTheTableView() {
        let blocks = IncrementalBlockParser.parse("| a | b |\n|---|---|\n| 1 [1] | 2 |\n\nAfter.")
        #expect(blocks[0].kind == .table && blocks[0].isClosed)
        #expect(MarkdownTable.parse(blocks[0].text)?.rows == [["1 [1]", "2"]])
    }
}
