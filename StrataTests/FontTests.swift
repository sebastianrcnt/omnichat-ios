import Testing
import SwiftUI
import UIKit
@testable import Strata

@MainActor
struct FontTests {
    @Test func pretendardIsRegisteredFromTheBundle() {
        #expect(UIFont(name: "PretendardVariable-Regular", size: 17) != nil)
        #expect(UIFont(name: DS.Typography.regularFontName, size: 17) != nil)
        #expect(UIFont(name: "Pretendard Variable", size: 17) != nil)
        // The weights the app uses exist as named instances.
        for weight in ["Medium", "SemiBold", "Bold"] {
            #expect(UIFont(name: "PretendardVariable-\(weight)", size: 17) != nil, "\(weight)")
        }
        #expect(UIFont.fontNames(forFamilyName: "Pretendard Variable").contains("PretendardVariable-SemiBold"))
    }

    @Test func theStaticFacesAreRegisteredToo() {
        for face in ["Regular", "Medium", "SemiBold", "Bold"] {
            #expect(UIFont(name: "Pretendard-\(face)", size: 17) != nil, "\(face)")
        }
    }

    @Test func theLicenseTravelsWithTheFont() throws {
        let url = try #require(Bundle.main.url(forResource: "Pretendard-OFL", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("SIL Open Font License, Version 1.1"))
        #expect(text.contains("Pretendard"))
    }

    @Test func fontFilesAreListedInTheBundlesInfoPlist() throws {
        let fonts = try #require(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        #expect(fonts.contains("PretendardVariable.ttf"))
    }

    @Test func weightsRenderDifferentlyOnTheVariableFont() {
        // The weight reaches the font: heavier weights are wider on the same text.
        func width(_ weight: UIFont.Weight) -> CGFloat {
            let name = ["PretendardVariable-Regular", "PretendardVariable-Medium", "PretendardVariable-SemiBold", "PretendardVariable-Bold"][
                [UIFont.Weight.regular, .medium, .semibold, .bold].firstIndex(of: weight)!]
            return ("Liquid Glass 사용 가이드" as NSString).size(withAttributes: [.font: UIFont(name: name, size: 17)!]).width
        }
        #expect(width(.regular) < width(.medium) && width(.medium) < width(.semibold) && width(.semibold) < width(.bold))
    }

    @Test func theAnswerLineHeightIsAboutOnePointSixFiveTimesTheSize() {
        for size: CGFloat in [15, 17, 22, 28] {
            let lineHeight = UIFont(name: DS.Typography.regularFontName, size: size)!.lineHeight
            let spacing = DS.Leading.spacing(multiple: DS.Leading.answer.multiple, size: size)
            #expect(abs((lineHeight + spacing) / size - 1.65) < 0.001, "\(size)")
        }
        // UI rows 1.4, thinking text 1.55.
        #expect(abs((UIFont(name: DS.Typography.regularFontName, size: 17)!.lineHeight + DS.Leading.spacing(multiple: 1.4, size: 17)) / 17 - 1.4) < 0.001)
        #expect(DS.Leading.thinking.multiple == 1.55 && DS.Leading.ui.multiple == 1.4 && DS.Leading.answer.multiple == 1.65)
    }

    @Test func theEmGapMatchesThePointGap() {
        let leading = DS.Leading.answer
        #expect(abs(leading.em * 17 - DS.Leading.spacing(multiple: 1.65, size: 17)) < 0.01)
        #expect(leading.em > 0.4)
    }

    @Test func boldInAnAnswerIsDrawnWithTheSemiboldFontNotTheSystemBold() {
        let parsed = InlineMarkdownText.attributed("Plain **bold** and ***both*** words", sources: [:])
        let a = InlineMarkdownText.withSemiboldStrong(parsed)
        #expect(a.runs.filter { $0.font != nil }.count == 2) // "bold" and "both"
        #expect(a.runs.allSatisfy { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) != true })
        #expect(a.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true }) // italic kept
        // Parsing alone leaves the strong runs for the lenient-emphasis code (and headings) to read.
        #expect(parsed.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test func citationChipsKeepTheirOwnFont() {
        let sources = [1: SourceInfo(id: 1, title: "T", url: "https://example.com/x", snippet: "")]
        let a = InlineMarkdownText.attributed("Fact [1] here", sources: sources)
        #expect(a.runs.contains { $0.link?.scheme == CitationParser.scheme && $0.font != nil })
    }

    @Test func codeStaysMonospaced() {
        // Mono roles are not Pretendard.
        #expect(DS.Typography.mono != DS.Typography.ui)
        #expect(DS.Typography.monoSmall != DS.Typography.uiSmall)
    }
}
