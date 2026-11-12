import Testing
import Foundation
import SwiftUI
@testable import Strata

struct MathScannerTests {
    private func latex(_ text: String, isOpen: Bool = false) -> [String?] { MathScanner.spans(in: text, isOpen: isOpen).map(\.latex) }

    @Test func findsTheFourDelimiters() {
        let found = MathScanner.spans(in: #"Inline $a^2$ and \(b_i\), display $$c = d$$ and \[e \le f\]."#)
        #expect(found.map(\.latex) == ["a^2", "b_i", "c = d", #"e \le f"#])
        #expect(found.map(\.display) == [false, false, true, true])
    }

    @Test func spanCoversItsDelimiters() {
        let text = "한글 $x$ 뒤"
        let found = MathScanner.spans(in: text)
        #expect(found.count == 1)
        let utf8 = Array(text.utf8)
        #expect(String(decoding: utf8[found[0].range], as: UTF8.self) == "$x$")
    }

    @Test func moneyStaysText() {
        #expect(latex("It costs $5 and $10 today.").isEmpty)
        #expect(latex("Between $5-$10 per month").isEmpty)
        #expect(latex("US$ 20 or US$30").isEmpty)
        #expect(latex("a $ b $ c").isEmpty) // spaces inside the dollars
        #expect(latex(#"Escaped \$x\$ stays"#).isEmpty)
        #expect(latex("one $ alone").isEmpty)
        #expect(latex("$a\nb$").isEmpty) // a single dollar does not cross a line
    }

    @Test func dollarInsideAFormulaIsEscaped() {
        #expect(latex(#"$\text{cost} = \$5$"#) == [#"\text{cost} = \$5"#])
    }

    @Test func codeLinksAndURLsAreSkipped() {
        #expect(latex("Run `echo $HOME and $PATH` now").isEmpty)
        #expect(latex("``a ` $x$ ``").isEmpty)
        #expect(latex("[doc](https://e.com/$a$) then $y$") == ["y"])
        #expect(latex("see https://e.com/?q=$a$ and $z$") == ["z"])
        #expect(latex("`code` then $x$") == ["x"])
    }

    @Test func emptyAndOversizedAreNotMath() {
        #expect(latex("$$$$").isEmpty)
        #expect(latex(#"\(\)"#).isEmpty)
        #expect(latex("$" + String(repeating: "x", count: MathScanner.maxLength + 1) + "$").isEmpty)
    }

    @Test func unclosedSpanIsHeldOnlyWhileStreaming() {
        #expect(latex(#"so \(x + "#).isEmpty)
        let open = MathScanner.spans(in: #"so \(x + "#, isOpen: true)
        #expect(open.count == 1 && open[0].latex == nil && open[0].range == 3..<9)
        #expect(MathScanner.spans(in: "then $$a_1 + a_2", isOpen: true).first?.latex == nil)
        // A lone dollar is not held: it is more often money than a formula.
        #expect(MathScanner.spans(in: "costs $5 and", isOpen: true).isEmpty)
    }

    @Test func extractionRoundTrips() throws {
        let source = #"A $x_1$ and \(y*z*w\) end"#
        let extraction = try #require(MathScanner.extract(source, isOpen: false))
        #expect(!extraction.text.contains("$") && !extraction.text.contains("\\"))
        #expect(extraction.spans.map(\.source) == ["$x_1$", #"\(y*z*w\)"#])
        var attributed = AttributedString(extraction.text)
        MathScanner.restore(extraction.spans, in: &attributed)
        #expect(String(attributed.characters) == source)
        #expect(MathScanner.extract("no formulas here", isOpen: false) == nil)
    }

    @Test func blockLatexStripsDelimiters() {
        #expect(MathScanner.blockLatex("$$\nE = mc^2\n$$") == "E = mc^2")
        #expect(MathScanner.blockLatex("\\[\n\\int_0^1 x\\,dx\n\\]") == #"\int_0^1 x\,dx"#)
        #expect(MathScanner.blockLatex("$$ a $$") == "a")
        #expect(MathScanner.blockLatex("$$\na") == nil)
        #expect(MathScanner.blockLatex("$$$$") == nil)
    }
}

struct MathBlockTests {
    private func kinds(_ text: String) -> [MarkdownBlock.Kind] { IncrementalBlockParser.parse(text).map(\.kind) }

    static let document = """
    The roots are:

    $$
    x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}
    $$

    Text right before
    \\[
    \\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}
    \\]
    and right after, with $a_1$ inline.

    - item with $x$
    $$ e^{i\\pi} + 1 = 0 $$

    | a | b |
    |---|---|
    | $x$ | 2 |

    Price is $$ not math

    done
    """

    @Test func displayFormulasAreTheirOwnBlocks() {
        let blocks = IncrementalBlockParser.parse(Self.document)
        #expect(blocks.map(\.kind) == [.paragraph, .math, .paragraph, .math, .paragraph, .list, .math, .table, .paragraph, .paragraph])
        #expect(blocks[1].text == "$$\nx = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}\n$$")
        #expect(blocks[1].isClosed && blocks[3].isClosed && blocks[6].isClosed)
        #expect(blocks[1].renderText == blocks[1].text)
    }

    @Test func openFormulaAndProse() {
        let open = IncrementalBlockParser.parse("$$\na + b")
        #expect(open.count == 1 && open[0].kind == .math && !open[0].isClosed)
        // The newline that just arrived is not a blank line yet.
        #expect(IncrementalBlockParser.parse("$$\na + b\n").first?.kind == .math)
        #expect(kinds("$$\na + b\n\nmore") == [.paragraph, .paragraph]) // a blank line: prose
        #expect(kinds("$$x$$ is the answer") == [.paragraph]) // text after the closer: inline
        #expect(kinds("\\[x\\] and more") == [.paragraph])
        #expect(kinds("$$") == [.math]) // may still become a formula
        #expect(kinds("    $$\n    x\n    $$") == [.code]) // indented code wins
        #expect(kinds("```\n$$\nx\n$$\n```") == [.code])
    }

    @Test(arguments: [1, 2, 3, 7, 42, 99] as [UInt64])
    func incrementalEqualsOneShot(seed: UInt64) {
        var parser = IncrementalBlockParser()
        for chunk in SampleMarkdown.chunks(of: Self.document, seed: seed) { _ = parser.append(chunk) }
        let live = parser.blocks
        let oneShot = IncrementalBlockParser.parse(Self.document)
        #expect(parser.finish() == oneShot)
        #expect(live == oneShot)
    }

    @Test(arguments: [5, 11, 23] as [UInt64])
    func finalizedBlocksNeverChange(seed: UInt64) {
        var parser = IncrementalBlockParser()
        var seen: [Int: MarkdownBlock] = [:]
        for chunk in SampleMarkdown.chunks(of: Self.document, seed: seed) {
            for b in parser.append(chunk).newlyFinalized {
                #expect(seen[b.id] == nil, "block \(b.id) finalized twice")
                seen[b.id] = b
            }
            for b in parser.finalized { #expect(seen[b.id] == b) }
        }
        #expect(!seen.isEmpty)
    }
}

struct MathInlineTests {
    private func spans(_ a: AttributedString) -> [MathSpan] {
        var out: [MathSpan] = []
        for run in a.runs { if let m = run[MathAttribute.self], out.last != m { out.append(m) } }
        return out
    }

    @Test func formulaKeepsItsSourceAndIsTagged() {
        let a = InlineMarkdownText.attributed(#"Let $a_i * b_j * c$ and **bold** \(x_1\)."#)
        #expect(String(a.characters) == #"Let $a_i * b_j * c$ and bold \(x_1\)."#)
        #expect(spans(a).map(\.latex) == ["a_i * b_j * c", "x_1"])
        // Nothing inside a formula was read as emphasis, and the emphasis outside still is.
        for run in a.runs where run[MathAttribute.self] != nil { #expect(run.inlinePresentationIntent == nil) }
        #expect(a.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test func equalFormulasStayApart() {
        let a = InlineMarkdownText.attributed("$x$$x$ and $x$")
        #expect(spans(a).map(\.index) == [0, 1, 2])
    }

    @Test func formulaInsideEmphasisKeepsTheEmphasis() {
        let a = InlineMarkdownText.attributed("**Result: $E = mc^2$**")
        let math = a.runs.first { $0[MathAttribute.self] != nil }
        #expect(math?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(String(a.characters) == "Result: $E = mc^2$")
    }

    @Test func moneyAndCodeAreUntouched() {
        let a = InlineMarkdownText.attributed("Pay $5 or $10, run `echo $A$B`")
        #expect(spans(a).isEmpty)
        #expect(String(a.characters) == "Pay $5 or $10, run echo $A$B")
    }

    @Test func openFormulaIsShownAsTypedWhileStreaming() {
        let a = InlineMarkdownText.attributed(#"so \(a_1 * b"#, isOpen: true)
        #expect(String(a.characters) == #"so \(a_1 * b"#)
        #expect(spans(a).isEmpty) // not typeset until it is closed
    }

    @Test func citationsNextToFormulasStillBecomeChips() {
        let sources = [1: SourceInfo(id: 1, title: "T", url: "https://example.com/x", snippet: "")]
        let a = InlineMarkdownText.attributed("Since $x^2 \\ge 0$ [1] holds", sources: sources)
        #expect(spans(a).map(\.latex) == [#"x^2 \ge 0"#])
        #expect(a.runs.contains { $0.link?.scheme == CitationParser.scheme })
    }

    @Test func plainTextCopyKeepsLatex() {
        #expect(MarkdownPlain.text(from: #"**Sum** $\sum_{i=1}^{n} a_i$ and \(x*y*z\)"#) == #"Sum $\sum_{i=1}^{n} a_i$ and \(x*y*z\)"#)
    }

    @MainActor @Test func composedTextWithoutAStyleLeavesTheSource() {
        let a = InlineMarkdownText.attributed("a $x$ b")
        #expect(InlineMarkdownText.composed(a).hasChips == false)
    }
}

struct MathTypesetterTests {
    private func request(_ latex: String, display: Bool = false, size: CGFloat = 17) -> MathRequest {
        MathRequest(latex: latex, display: display, pointSize: size, scale: 2)
    }

    @Test func typesetsAFraction() async throws {
        let image = try #require(await MathTypesetter.shared.render(request(#"\frac{a}{b}"#)))
        #expect(image.size.width > 4 && image.size.height > 17)
        #expect(image.descent > 2 && image.descent < image.size.height) // the denominator hangs below the baseline
        #expect(image.image.width == Int(image.size.width * 2))
    }

    @Test func baselineFollowsTheGlyphs() async throws {
        let x = try #require(await MathTypesetter.shared.render(request("x")))
        let y = try #require(await MathTypesetter.shared.render(request("y")))
        #expect(y.descent > x.descent + 1) // y has a descender
        #expect(x.descent < 2)
    }

    @Test func sizeFollowsThePointSize() async throws {
        let small = try #require(await MathTypesetter.shared.render(request("x+y", size: 15)))
        let large = try #require(await MathTypesetter.shared.render(request("x+y", size: 30)))
        #expect(large.size.width > small.size.width * 1.8)
    }

    @Test func whatModelsWrite() async {
        let samples = [
            #"\sum_{i=1}^{n} i = \frac{n(n+1)}{2}"#, // needs the corrected digits pattern
            #"\boxed{x = 5}"#,
            #"\begin{aligned} a &= b \\ c &= d \end{aligned}"#,
            #"\begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix}"#,
            #"\begin{cases} x & x > 0 \\ -x & \text{otherwise} \end{cases}"#,
            #"\mathbf{v} \in \R^n,\ \bm{w} \cdot \vec{u}"#,
            #"E = mc^2 \tag{1}"#,
            #"\ce{H2O}"#,
            #"1{,}000.5 \times 10^{-3}"#,
            #"\int_{-\infty}^{\infty} e^{-x^2}\,\dd x = \sqrt{\pi}"#,
        ]
        for latex in samples {
            let image = await MathTypesetter.shared.render(request(latex, display: true))
            #expect(image != nil, "\(latex)")
        }
    }

    @Test func malformedInputIsRefused() async {
        #expect(await MathTypesetter.shared.render(request(#"\frac{a}{b"#)) == nil)
        #expect(await MathTypesetter.shared.render(request("x^2^3")) == nil)
    }

    @Test func engineComesBackAfterUnload() async {
        await MathTypesetter.shared.unload()
        #expect(await MathTypesetter.shared.render(request("a+b")) != nil)
    }

    @Test func equationNumbersBecomeText() {
        #expect(MathTypesetter.prepared(#"a = b \tag{1}"#) == #"a = b \qquad\text{(1)}"#)
        #expect(MathTypesetter.prepared(#"a \tag*{A} \label{eq:a}"#) == #"a \qquad\text{A} "#)
        #expect(MathTypesetter.prepared(#"a \nonumber \\ b \notag"#) == #"a  \\ b "#)
        #expect(MathTypesetter.prepared(#"\notagx"#) == #"\notagx"#)
    }

    @Test func requestsRoundToSharedSizes() {
        #expect(MathRequest(latex: "x", display: false, pointSize: 17.01, scale: 3.0001)
            == MathRequest(latex: "x", display: false, pointSize: 17, scale: 3))
    }

    @MainActor @Test func storeAnswersPendingThenReady() async throws {
        let request = MathRequest(latex: #"\alpha + \beta_{\text{store}}"#, display: false, pointSize: 17, scale: 2)
        if case .ready = MathStore.shared.state(request) { return } // another test already asked
        for _ in 0..<200 {
            if case .ready(let image) = MathStore.shared.state(request) {
                #expect(image.size.width > 0)
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("formula never became ready")
    }

    @MainActor @Test func storeRemembersFailures() async throws {
        let request = MathRequest(latex: #"\frac{store}{"#, display: false, pointSize: 17, scale: 2)
        for _ in 0..<200 {
            if case .failed = MathStore.shared.state(request) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("failure never recorded")
    }
}
