import Testing
import Foundation
import SwiftUI
@testable import Strata

/// Rendering contract for model output: `**` pairs become bold even where strict CommonMark would
/// leave them raw (CJK text, punctuation, stray spaces); tildes are always literal.
struct LenientEmphasisTests {
    private let known: [Int: SourceInfo] = [1: SourceInfo(id: 1, title: "T", url: "https://apple.com/x", snippet: "")]

    private func render(_ s: String, open: Bool = false) -> AttributedString {
        InlineMarkdownText.attributed(s, sources: known, isOpen: open)
    }

    private func boldText(_ a: AttributedString) -> String {
        a.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(a[$0.range].characters) }.joined()
    }

    private func expectBold(_ source: String, bold: String, sourceLine: Int = #line) {
        let a = render(source)
        let plain = String(a.characters)
        #expect(!plain.contains("**"), "raw ** left in: \(plain)", sourceLocation: .init(fileID: #fileID, filePath: #filePath, line: sourceLine, column: 1))
        #expect(boldText(a) == bold, "bold was '\(boldText(a))' for: \(source)", sourceLocation: .init(fileID: #fileID, filePath: #filePath, line: sourceLine, column: 1))
    }

    @Test func boldFollowedByColonInAListItem() {
        let items = InlineListView.items("- **본명/출생**: 텍스트")
        #expect(items.count == 1)
        expectBold(items[0].content, bold: "본명/출생")
        expectBold("**본명/출생**: 텍스트", bold: "본명/출생")
    }

    @Test func spaceBeforeTheClosingMarker() {
        expectBold("**신체 **: 텍스트", bold: "신체")
        let a = String(render("**신체 **: 텍스트").characters)
        #expect(a.contains("신체") && a.contains("텍스트"))
    }

    @Test func spaceAfterTheOpeningMarker() { expectBold("** 앞공백**", bold: "앞공백") }
    @Test func particleRightAfterTheClosingMarker() { expectBold("**강조**는", bold: "강조") }
    @Test func quotedBold() { expectBold("**\"인용\"**을", bold: "\"인용\"") }
    @Test func boldThenColon() { expectBold("**A**:", bold: "A") }

    @Test func boldImmediatelyFollowedByACitation() {
        let a = render("**x**[1]")
        #expect(!String(a.characters).contains("**"))
        #expect(boldText(a) == "x")
        #expect(a.runs.contains { $0.link?.scheme == CitationParser.scheme }, "citation chip still present")
    }

    @Test func boldInsideAQuotedSentenceClosedByAQuote() {
        expectBold("그는 \"때문에 **꿈을 이뤘다고 생각한다**\"", bold: "꿈을 이뤘다고 생각한다")
    }

    @Test func severalPairsOnOneLine() {
        expectBold("**하나**와 **둘**, 그리고 **셋**.", bold: "하나둘셋")
    }

    @Test func standardCasesStillWork() {
        expectBold("This is **bold** text", bold: "bold")
        expectBold("**bold with *nested italic* inside**", bold: "bold with nested italic inside")
    }

    @Test func listBulletsAndThematicBreaksAreNotPaired() {
        // A lone marker pair with no content between is not emphasis.
        let a = String(render("a **** b").characters)
        #expect(a.contains("a") && a.contains("b"))
        #expect(boldText(render("**")).isEmpty)
        #expect(boldText(render("** **")).isEmpty)
    }

    @Test func escapedAndCodeMarkersAreLeftAlone() {
        #expect(String(render("\\**not bold\\**").characters).contains("not bold"))
        #expect(boldText(render("`**code**` text")).isEmpty)
        #expect(String(render("`**code**` text").characters).contains("**code**"))
    }

    @Test func openStreamingBoldClosesOptimistically() {
        let a = render("Intro **꿈을 이뤘다", open: true)
        #expect(!String(a.characters).contains("**"))
        #expect(boldText(a) == "꿈을 이뤘다")
    }
}

struct StrikethroughOffTests {
    private func render(_ s: String) -> AttributedString { InlineMarkdownText.attributed(s) }

    @Test func tildeRangesStayLiteral() {
        let a = render("조회 2~3천 회에서 8만 → 10만 → 100만으로 … 2~3개월 만에")
        #expect(String(a.characters).contains("2~3천"))
        #expect(String(a.characters).contains("2~3개월"))
        #expect(!a.runs.contains { $0.strikethroughStyle != nil })
        #expect(!a.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
    }

    @Test func doubleTildesStayLiteral() {
        let a = render("keep ~~x~~ literal")
        #expect(String(a.characters) == "keep ~~x~~ literal")
        #expect(!a.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
    }

    @Test func tildesInCodeAreUntouchedAndBlockPathEscapes() {
        #expect(String(render("`a~b`").characters).contains("a~b"))
        #expect(TildeEscaper.escape("a ~~x~~ b `~c~` d") == "a \\~\\~x\\~\\~ b `~c~` d")
        #expect(TildeEscaper.escape("```\n~~keep~~\n```\n~~x~~") == "```\n~~keep~~\n```\n\\~\\~x\\~\\~")
        #expect(TildeEscaper.escape("already \\~ escaped") == "already \\~ escaped")
    }

    @Test func optimisticCloserNoLongerAddsStrikethroughClosers() {
        #expect(OptimisticCloser.closeInline("Strike ~~out") == "Strike ~~out")
    }
}

struct ChipLabelTests {
    @Test func shortensToTheRegistrableDomain() {
        #expect(DomainFormatter.short("www.wikipedia.org") == "wikipedia.org")
        #expect(DomainFormatter.short("ko.wikipedia.org") == "wikipedia.org")
        #expect(DomainFormatter.short("developer.apple.com") == "apple.com")
        #expect(DomainFormatter.short("news.bbc.co.uk") == "bbc.co.uk")
        #expect(DomainFormatter.short("blog.naver.com") == "naver.com")
        #expect(DomainFormatter.short("m.blog.naver.co.kr") == "naver.co.kr")
    }

    @Test func truncatesLongDomainsInTheMiddle() {
        let short = DomainFormatter.short("an-extremely-long-registrable-domain-name.example", maxLength: 20)
        #expect(short.count == 20 && short.contains("…"))
    }

    @Test func chipLabelsNeverContainBreakOpportunities() {
        let sources = [1: SourceInfo(id: 1, title: "t", url: "https://my-site.example.com/a", snippet: ""),
                       2: SourceInfo(id: 2, title: "t", url: "https://other.org/b", snippet: "")]
        let out = CitationParser.transform("x [1][2]", sources: sources, holdBack: false)
        #expect(!out.contains("my-site"), "hyphen replaced by a non-breaking hyphen")
        #expect(out.contains("\u{00A0}+1"))
    }
}
