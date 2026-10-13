import Foundation
import Testing
@testable import Strata

struct QuoteCitationTests {
    private func trailing(_ s: String) -> (String, [Int])? {
        QuoteCitations.trailingMarkers(in: s).map { ($0.text, $0.ids) }
    }

    @Test func markersEndingTheQuoteBecomeItsSource() {
        #expect(trailing("> Births rose 3.6%. [1]")! == ("> Births rose 3.6%.", [1]))
        #expect(trailing("> Births rose 3.6% [1][2]")! == ("> Births rose 3.6%", [1, 2]))
        #expect(trailing("> one\n> two [3] [4]  \n")! == ("> one\n> two", [3, 4]))
        #expect(trailing("> Births rose [2].")! == ("> Births rose.", [2]), "a period after the marker stays")
    }

    @Test func otherQuotesHaveNoSource() {
        #expect(trailing("> No marker here.") == nil)
        #expect(trailing("> A marker [1] in the middle of the quote.") == nil)
        #expect(trailing("> [1]") == nil, "nothing would be left to quote")
        #expect(trailing("> see [1](https://a.com)") == nil, "a link is not a citation")
        #expect(trailing("> escaped \\[1]") == nil)
    }

    @Test func codeSpansStayLiteral() {
        #expect(trailing("> use `arr[1]`") == nil)
        #expect(trailing("> open `code [1]") == nil, "inside an unclosed code span")
        #expect(trailing("> use `arr` [5]")! == ("> use `arr`", [5]), "a marker after a closed code span is still a source")
    }

    @Test func markersOnlyParagraphs() {
        #expect(QuoteCitations.markersOnly("[3]") == [3])
        #expect(QuoteCitations.markersOnly(" [3][4] ") == [3, 4])
        #expect(QuoteCitations.markersOnly("[3] [4]") == [3, 4])
        #expect(QuoteCitations.markersOnly("See [3]") == nil)
        #expect(QuoteCitations.markersOnly("[3] see") == nil)
        #expect(QuoteCitations.markersOnly("`[3]`") == nil)
    }

    @Test func planAbsorbsTheMarkerParagraphAfterAQuote() {
        let blocks = IncrementalBlockParser.parse("> Marriages rose.\n\n[7]\n\nNext paragraph [1].\n\n> Kept as is.\n\n> Own source [2]\n\nAfter.")
        let plan = QuoteCitations.plan(blocks)
        #expect(blocks.map(\.kind) == [.blockquote, .paragraph, .paragraph, .blockquote, .blockquote, .paragraph])
        #expect(plan[blocks[0].id] == .quote(ids: [7], text: nil))
        #expect(plan[blocks[1].id] == .absorbed)
        #expect(plan[blocks[2].id] == nil, "an ordinary paragraph with a citation stays")
        #expect(plan[blocks[3].id] == nil, "no marker: no source line")
        #expect(plan[blocks[4].id] == .quote(ids: [2], text: "> Own source"))
    }

    @Test func aQuoteStillOpenGetsNoSourceLine() {
        // While streaming, callers pass closed blocks only; the last (open) quote is not planned.
        var parser = IncrementalBlockParser()
        let update = parser.append("Intro.\n\n> Still being written [1]")
        let all = update.tail
        let closedOnly = QuoteCitations.plan(Array(all.dropLast()))
        #expect(closedOnly.isEmpty)
    }

    @Test func quoteParagraphsAndInnerMarkdown() {
        #expect(QuoteBlockView.paragraphs("> one\n> two\n>\n> three") == ["one two", "three"])
        #expect(QuoteBlockView.inner("> - item\n>   more\n> > nested") == "- item\n  more\n> nested")
    }
}
