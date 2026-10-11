import Testing
import Foundation
@testable import Strata

enum SampleMarkdown {
    static let document = """
    # Title

    Intro paragraph with **bold** and `code`,
    continued on a second line.

    ## List

    - one
    - two
      - nested
    - three

    1. first
    2. second

    > quoted text
    > more quote

    ```swift
    let x = 1

    print(x)
    ```

    | a | b |
    |---|---|
    | 1 | 2 |
    | 3 | 4 |

    ---

    Setext Heading
    ==============

    Last paragraph **강조**는 한국어 문장입니다.
    """

    /// Deterministic pseudo-random chunk sizes.
    static func chunks(of text: String, seed: UInt64) -> [String] {
        var state = seed
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % 17) + 1
        }
        let chars = Array(text)
        var out: [String] = []
        var i = 0
        while i < chars.count {
            let n = min(next(), chars.count - i)
            out.append(String(chars[i..<i + n]))
            i += n
        }
        return out
    }
}

struct BlockScannerTests {
    private func kinds(_ text: String) -> [MarkdownBlock.Kind] { IncrementalBlockParser.parse(text).map(\.kind) }

    @Test func splitsTopLevelBlocks() {
        let blocks = IncrementalBlockParser.parse(SampleMarkdown.document)
        #expect(blocks.map(\.kind) == [
            .heading(level: 1), .paragraph, .heading(level: 2), .list, .blockquote, .code, .table,
            .thematicBreak, .heading(level: 1), .paragraph,
        ])
        #expect(blocks.map(\.id) == Array(0..<blocks.count))
        #expect(blocks[1].text == "Intro paragraph with **bold** and `code`,\ncontinued on a second line.")
        // A bullet list followed (after a blank line) by an ordered list stays one block; the renderer splits it.
        #expect(blocks[3].text.contains("- three") && blocks[3].text.hasSuffix("2. second"))
        #expect(blocks[5].text.contains("let x = 1\n\nprint(x)")) // blank line inside the fence stays in the block
        #expect(blocks[6].isClosed)
    }

    @Test func openFenceAndOpenTable() {
        let fence = IncrementalBlockParser.parse("```py\nprint(1)\n")
        #expect(fence.count == 1 && fence[0].kind == .code && !fence[0].isClosed)
        let table = IncrementalBlockParser.parse("| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(table.count == 1 && table[0].kind == .table && !table[0].isClosed)
        let closed = IncrementalBlockParser.parse("| a | b |\n|---|---|\n| 1 | 2 |\n\nafter")
        #expect(closed.map(\.kind) == [.table, .paragraph] && closed[0].isClosed)
    }

    @Test func listsKeepBlankLinesBetweenItemsAndLazyContinuation() {
        #expect(kinds("- a\n\n- b\n\n- c") == [.list])
        #expect(kinds("- a\nlazy continuation\n- b") == [.list])
        #expect(kinds("- a\n\nparagraph") == [.list, .paragraph])
        #expect(kinds("1. one\n   ```\n   code\n\n   more\n   ```\n2. two") == [.list])
    }

    @Test func setextAndThematicBreaks() {
        #expect(kinds("Heading\n---") == [.heading(level: 2)])
        #expect(kinds("Para\n\n---") == [.paragraph, .thematicBreak])
        #expect(kinds("* * *") == [.thematicBreak])
        #expect(kinds("- a\n---") == [.list, .thematicBreak])
    }

    @Test func listMarkersCannotInterruptParagraphsUnlessCommonMarkAllows() {
        #expect(kinds("text\n- item") == [.paragraph, .list])
        #expect(kinds("text\n2. item") == [.paragraph]) // only "1." may interrupt a paragraph
    }

    @Test func indentedCode() {
        #expect(kinds("para\n\n    code\n    more\n\nafter") == [.paragraph, .code, .paragraph])
    }
}

struct IncrementalParserTests {
    @Test(arguments: [1, 2, 3, 7, 42, 99] as [UInt64])
    func finalReconciliationEqualsOneShotParse(seed: UInt64) {
        var parser = IncrementalBlockParser()
        for chunk in SampleMarkdown.chunks(of: SampleMarkdown.document, seed: seed) { _ = parser.append(chunk) }
        let live = parser.blocks
        let reconciled = parser.finish()
        let oneShot = IncrementalBlockParser.parse(SampleMarkdown.document)
        #expect(reconciled == oneShot)
        // The incremental result already matched, since only the open tail was ever mutable.
        #expect(live == oneShot)
    }

    @Test(arguments: [5, 11, 23] as [UInt64])
    func finalizedBlocksNeverChange(seed: UInt64) {
        var parser = IncrementalBlockParser()
        var seen: [Int: MarkdownBlock] = [:]
        for chunk in SampleMarkdown.chunks(of: SampleMarkdown.document, seed: seed) {
            let update = parser.append(chunk)
            for b in update.newlyFinalized {
                #expect(seen[b.id] == nil, "block \(b.id) finalized twice")
                seen[b.id] = b
            }
            // Everything finalized so far is unchanged and ids are contiguous from 0.
            for (i, b) in parser.finalized.enumerated() {
                #expect(b.id == i)
                #expect(seen[b.id] == b)
            }
            #expect(parser.tail.count <= IncrementalBlockParser.tailWindow)
            #expect(parser.tail.first.map { $0.id == parser.finalized.count } ?? true)
        }
        #expect(!seen.isEmpty)
    }

    @Test func rescansOnlyTheTail() {
        var parser = IncrementalBlockParser()
        let para = (0..<50).map { "Paragraph \($0) has some text." }.joined(separator: "\n\n")
        _ = parser.append(para + "\n\n")
        #expect(parser.finalized.count >= 48)
        let before = parser.finalized
        _ = parser.append("tail ")
        #expect(Array(parser.finalized.prefix(before.count)) == before)
    }

    @Test func finishOnEmptyAndWhitespaceOnly() {
        var p = IncrementalBlockParser()
        #expect(p.finish().isEmpty)
        _ = p.append("\n\n  \n")
        #expect(p.finish().isEmpty)
    }
}

struct OptimisticCloserTests {
    @Test(arguments: [
        ("This is **bold", "This is **bold**"),
        ("This is *it", "This is *it*"),
        ("Use `code", "Use `code`"),
        ("See [the docs", "See [the docs](#)"),
        ("See [the docs](https://x.y/a", "See [the docs](https://x.y/a)"),
        ("**bold *and italic", "**bold *and italic***"),
        ("Already **closed**", "Already **closed**"),
        ("2 * 3 = 6", "2 * 3 = 6"),
        ("`a **b` ok", "`a **b` ok"),
        ("Escaped \\*star", "Escaped \\*star"),
    ])
    func closesUnmatchedSyntax(input: String, expected: String) {
        #expect(OptimisticCloser.closeInline(input) == expected)
    }

    @Test func closesOpenFence() {
        #expect(OptimisticCloser.closeFence("```swift\nlet a = 1") == "```swift\nlet a = 1\n```")
        #expect(OptimisticCloser.closeFence("```\nx\n```") == "```\nx\n```")
        #expect(OptimisticCloser.closeFence("~~~~\nx") == "~~~~\nx\n~~~~")
    }

    @Test func attributedStringIsBoldForOpenEmphasis() {
        let a = InlineMarkdownText.attributed("This is **bold", isOpen: true)
        let bold = a.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold)
        #expect(!String(a.characters).contains("*"))
    }
}

struct CJKEmphasisTests {
    private func hasBold(_ source: String, _ word: String) -> Bool {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnly)
        guard let a = try? AttributedString(markdown: source, options: opts) else { return false }
        return a.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true && String(a[run.range].characters).contains(word)
        }
    }

    @Test(arguments: ["**\"강조\"**는 중요합니다", "**강조(설명)**는 중요합니다", "문장**\"인용\"**입니다", "**강조**는 중요합니다"])
    func koreanEmphasisRendersBoldAfterFix(source: String) {
        let fixed = CJKEmphasisFixer.fix(source)
        #expect(hasBold(fixed, "강조") || hasBold(fixed, "인용"), "fixed: \(fixed)")
    }

    @Test func commonMarkAloneFailsOnPunctuationCase() {
        // Documents why the fix exists: the standard flanking rule rejects this.
        #expect(!hasBold("**강조(설명)**는 중요합니다", "강조"))
    }

    @Test func fixLeavesCodeAndAsciiAlone() {
        #expect(CJKEmphasisFixer.fix("**bold** text") == "**bold** text")
        #expect(CJKEmphasisFixer.fix("`**강조(x)**는`") == "`**강조(x)**는`")
        #expect(CJKEmphasisFixer.fix("plain 한국어 text") == "plain 한국어 text")
        #expect(CJKEmphasisFixer.fix("**강조**는") == "**강조**는") // already valid CommonMark
    }

    @Test func insertsHairSpaceOnlyWhereNeeded() {
        let fixed = CJKEmphasisFixer.fix("**강조(설명)**는")
        #expect(fixed == "**강조(설명)**\u{200A}는")
    }
}

struct RevealControllerTests {
    @Test func monotonicAndEventuallyComplete() {
        var rc = RevealController()
        let text = String(repeating: "hello world ", count: 50)
        rc.receive(text)
        var last = 0
        var out = ""
        var ticks = 0
        while rc.hasBacklog && ticks < 10_000 {
            out += rc.tick(dt: 0.033)
            #expect(rc.revealedCount >= last)
            last = rc.revealedCount
            ticks += 1
        }
        #expect(out == text)
        #expect(rc.revealedCount == text.count)
    }

    @Test func drainsWithinTargetLagAfterStreamEnds() {
        var rc = RevealController(targetLag: 0.2, minStep: 3)
        rc.receive(String(repeating: "x", count: 5000))
        rc.markEnded(tick: 0.033)
        var elapsed = 0.0
        while rc.hasBacklog {
            _ = rc.tick(dt: 0.033)
            elapsed += 0.033
            #expect(elapsed <= 0.2 + 0.033)
            if elapsed > 1 { break }
        }
        #expect(!rc.hasBacklog)
    }

    @Test func steadyFlowSmoothsBursts() {
        var rc = RevealController()
        rc.receive(String(repeating: "a", count: 400)) // one burst
        let first = rc.tick(dt: 0.033).count
        #expect(first < 400 && first >= 3)
        // Never more than ~lag behind: after 250 ms of ticks most of the burst is out.
        var total = first
        for _ in 0..<7 { total += rc.tick(dt: 0.033).count }
        #expect(total > 300)
    }

    @Test func neverSplitsGraphemeClusters() {
        var rc = RevealController(targetLag: 0.2, minStep: 1)
        let text = "👨‍👩‍👧‍👦🇰🇷한국어👍🏽 e\u{0301}x 안녕하세요 family 👨‍👩‍👧‍👦 end"
        rc.receive(text)
        var pieces: [String] = []
        while rc.hasBacklog { pieces.append(rc.tick(dt: 0.005)) }
        #expect(pieces.joined() == text)
        // Each piece is made of whole Characters: re-counting adds up and no piece starts with a combining mark.
        #expect(pieces.reduce(0) { $0 + $1.count } == text.count)
        for p in pieces {
            if let f = p.unicodeScalars.first { #expect(!f.properties.isGraphemeExtend) }
        }
    }

    @Test func prefersWordBoundaries() {
        var rc = RevealController(targetLag: 0.2, minStep: 3)
        rc.receive("The quick brown fox jumps over the lazy dog and keeps running")
        let first = rc.tick(dt: 0.033)
        #expect(first.isEmpty == false)
        #expect(first.last == " " || first.count <= 3 || !rc.backlog.hasPrefix(" "))
        // Mid-word cuts only happen when no space is close by.
        var rc2 = RevealController(targetLag: 0.2, minStep: 3)
        rc2.receive(String(repeating: "x", count: 100))
        #expect(rc2.tick(dt: 0.033).count >= 3)
    }

    @Test func flushAllRevealsEverythingAtOnce() {
        var rc = RevealController()
        rc.receive("some text that is still queued")
        #expect(rc.flushAll() == "some text that is still queued")
        #expect(!rc.hasBacklog)
        #expect(rc.flushAll() == "")
    }
}

@MainActor
struct StreamingModelTests {
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func streamingModelMatchesOneShotAfterFinish() async {
        let model = StreamingMarkdownModel(smoothing: true)
        for chunk in SampleMarkdown.chunks(of: SampleMarkdown.document, seed: 9) {
            model.append(chunk)
            try? await Task.sleep(for: .milliseconds(3))
        }
        model.finish()
        let expected = IncrementalBlockParser.parse(SampleMarkdown.document)
        await waitUntil { model.blocks == expected }
        #expect(model.blocks == expected)
        #expect(model.tail.isEmpty)
        #expect(model.hasContent)
        #expect(model.text == SampleMarkdown.document)
    }

    @Test func nonSmoothedModeAlsoReconciles() async {
        let model = StreamingMarkdownModel(smoothing: false)
        model.append("# Hi\n\nSome ")
        model.append("**text**")
        model.finish()
        let expected = IncrementalBlockParser.parse("# Hi\n\nSome **text**")
        await waitUntil { model.blocks == expected }
        #expect(model.blocks == expected)
    }

    @Test func resetClearsForNewToolRound() async {
        let model = StreamingMarkdownModel(smoothing: false)
        model.append("first round\n\n")
        await waitUntil { model.hasContent }
        model.reset()
        #expect(!model.hasContent && model.blocks.isEmpty && model.text.isEmpty)
        model.append("second")
        model.finish()
        await waitUntil { model.blocks.first?.text == "second" }
        #expect(model.blocks.map(\.text) == ["second"])
    }

    @Test func loadedHistoryIsParsedSynchronously() {
        let model = StreamingMarkdownModel(text: SampleMarkdown.document)
        #expect(model.blocks == IncrementalBlockParser.parse(SampleMarkdown.document))
    }

    @Test func reasoningChunksFinalizeByParagraph() async {
        let m = ReasoningChunkModel(smoothing: false)
        m.append("First thought.\n\nSecond thou")
        await waitUntil { m.hasContent && m.finalized.count == 1 }
        #expect(m.finalized.map(\.text) == ["First thought."])
        #expect(m.tail == "Second thou")
        m.append("ght continues.\n\nThird")
        await waitUntil { m.finalized.count == 2 }
        #expect(m.finalized.map(\.id) == [0, 1])
        #expect(m.finalized[0].text == "First thought.") // immutable
        m.revealAll()
        #expect(m.text == "First thought.\n\nSecond thought continues.\n\nThird")
    }

    @Test func reasoningFadeSpansAppearWhileSmoothingAndClearAfterwards() async {
        let m = ReasoningChunkModel(smoothing: true)
        m.append(String(repeating: "word ", count: 40))
        await waitUntil { !m.freshSpans.isEmpty }
        #expect(m.freshSpans.allSatisfy { $0.length > 0 })
        m.revealAll()
        #expect(m.freshSpans.isEmpty)
        let plain = ReasoningChunkModel(smoothing: false)
        plain.append("no fade here")
        await waitUntil { plain.hasContent }
        #expect(plain.freshSpans.isEmpty)
    }

    @Test func timelineKeepsToolCardsInStreamOrderAroundLiveChunks() {
        let call = ToolCallRecord(id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}", result: "", isError: false)
        let step = ToolStep(assistantContent: "", calls: [call], reasoningParagraphs: 1)
        let items = TimelineItem.build(chunks: ["first", "second"], steps: [step], pending: [], sources: [:])
        #expect(items.map(\.id) == ["t0", "c1", "t1"])
        // The live tail is not part of the list, so streaming never changes it.
        let m = ReasoningChunkModel(text: "first\n\nsecond\n\ngrowing")
        #expect(m.finalized.count == 2 && m.tail == "growing")
    }

    @Test func reasoningLoadedFromHistory() {
        let m = ReasoningChunkModel(text: "a\n\nb\n\nc")
        #expect(m.finalized.count == 2 && m.tail == "c")
    }
}

// MARK: - Crash regressions (EXC_BREAKPOINT in String.index(_:offsetBy:) from flushAll)

struct RevealCrashRegressionTests {
    /// Grapheme clusters that arrive split across chunks used to make the cursor count exceed the buffer.
    private static let splitClusters: [[String]] = [
        ["e", "\u{301}"],                 // base + combining acute
        ["\r", "\n"],                     // CRLF is one Character
        ["👨", "\u{200D}", "👩"],          // ZWJ sequence
        ["🇰", "🇷"],                      // regional indicators pair into one flag
        ["\u{1112}", "\u{1161}", "\u{11AB}"], // Hangul jamo compose into one syllable
        ["a", "\u{301}", "\u{302}", "b"],
    ]

    @Test func flushAllAfterSplitClustersReturnsEverythingWithoutTrapping() {
        for chunks in Self.splitClusters {
            var rc = RevealController()
            for c in chunks { rc.receive(c) }
            #expect(rc.backlogCount == rc.backlog.count)
            let out = rc.flushAll()
            #expect(out == chunks.joined())
            #expect(!rc.hasBacklog)
        }
    }

    @Test func tickingThroughSplitClustersNeverTraps() {
        for chunks in Self.splitClusters {
            var rc = RevealController(targetLag: 0.2, minStep: 2)
            var out = ""
            for c in chunks { rc.receive(c); out += rc.tick(dt: 0.033) }
            rc.markEnded(tick: 0.033)
            var guardCount = 0
            while rc.hasBacklog, guardCount < 100 { out += rc.tick(dt: 0.033); guardCount += 1 }
            #expect(out == chunks.joined())
        }
    }

    @Test func flushAllAfterResetIsEmptyAndSafe() {
        var rc = RevealController()
        rc.receive("hello wörld")
        _ = rc.tick(dt: 0.033)
        rc.reset()
        #expect(rc.flushAll() == "")
        #expect(rc.backlogCount == 0 && rc.revealedCount == 0)
        rc.receive("fresh")
        #expect(rc.flushAll() == "fresh")
    }

    @Test func cursorNeverExceedsABufferShorterThanItsCounters() {
        var rc = RevealController()
        rc.receive("ab")
        // Even a huge request is clamped to the buffer.
        #expect(rc.tick(dt: 100) == "ab")
        #expect(rc.flushAll() == "")
    }
}

@MainActor
struct RevealRecoveryTests {
    @Test func revealAllAfterResetAndReplacedBuffer() {
        let model = StreamingMarkdownModel(smoothing: true)
        model.append("first attempt e")
        model.append("\u{301} and more")
        model.reset()                      // new attempt replaces the buffer
        model.revealAll()                  // must not trap
        model.append("second ")
        model.revealAll()
        #expect(model.text == "second ")
    }

    @Test func finishWithDifferentFinalTextAfterInterruption() {
        let model = StreamingMarkdownModel(smoothing: true)
        model.append("partial 👨")
        model.append("\u{200D}👩")
        model.revealAll()
        // Resume/regenerate: the final text is something else entirely.
        model.finish(finalText: "Completely different answer.")
        #expect(model.text == "Completely different answer.")
        model.revealAll()
    }

    @Test func messageRenderStateRevealAllAfterRepeatedUse() {
        let state = MessageRenderState()
        state.markdown.append("a")
        state.markdown.append("\u{301}")
        state.reasoning.append("r")
        state.reasoning.append("\u{301}")
        state.revealAll()
        state.revealAll()
        state.markdown.reset()
        state.revealAll()
    }
}

// MARK: - Code blocks

struct CodeBlockContentTests {
    private func code(lines n: Int) -> String { (1...max(n, 1)).map { "line \($0)" }.joined(separator: "\n") }

    @Test func parsesLanguageAndBodyFromAFence() {
        let c = CodeBlockContent(blockText: "```swift title=\"x\"\nlet a = 1\nprint(a)\n```")
        #expect(c.language == "swift")
        #expect(c.code == "let a = 1\nprint(a)")
        #expect(c.lineCount == 2)
        #expect(c.fileExtension == "swift")
    }

    @Test func openFenceWhileStreamingKeepsPartialBody() {
        let c = CodeBlockContent(blockText: "~~~py\nx = 1\ny = ")
        #expect(c.language == "py" && c.code == "x = 1\ny = ")
        #expect(CodeBlockContent(blockText: "```\nplain\n```").language == "")
        #expect(CodeBlockContent(blockText: "```\nplain\n```").displayLanguage == "Code")
    }

    @Test func collapseThresholdIsMoreThanEighteenLines() {
        #expect(!CodeBlockContent(code: code(lines: 18)).isCollapsible)
        #expect(CodeBlockContent(code: code(lines: 19)).isCollapsible)
        #expect(!CodeBlockContent(code: code(lines: 5)).isCollapsible)
    }

    @Test func collapsedPreviewShowsTheFirstTwelveLines() {
        let c = CodeBlockContent(code: code(lines: 40))
        #expect(c.preview.components(separatedBy: "\n").count == 12)
        #expect(c.preview.hasSuffix("line 12"))
        #expect(c.lineCount == 40)
    }

    @Test func fileExtensionsFallBackToTxt() {
        #expect(CodeBlockContent(language: "Rust", code: "").fileExtension == "rs")
        #expect(CodeBlockContent(language: "zsh", code: "").fileExtension == "sh")
        #expect(CodeBlockContent(language: "brainfuck", code: "").fileExtension == "txt")
    }

    @Test func emptyBodyHasNoLines() {
        #expect(CodeBlockContent(blockText: "```\n```").lineCount == 0)
    }
}
