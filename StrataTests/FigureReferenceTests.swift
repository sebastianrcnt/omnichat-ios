import Testing
import Foundation
@testable import Strata

struct FigureReferenceTests {
    @Test func aParagraphOfReferencesIsAFigureBlock() {
        #expect(FigureReference.block("![Monthly sales](figure-2)") == [.init(id: "figure-2", caption: "Monthly sales")])
        #expect(FigureReference.block("  ![](Figure-1)  \n![b]( figure-3 )") == [.init(id: "figure-1", caption: ""),
                                                                              .init(id: "figure-3", caption: "b")])
        #expect(FigureReference.block("See ![a](figure-1) here") == nil)
        #expect(FigureReference.block("![a](https://x/y.png)") == nil)
        #expect(FigureReference.block("") == nil)
    }

    @Test func figuresTheAnswerDidNotPlaceAreLeftOver() {
        let figs = (1...3).map { ToolImage(id: "figure-\($0)", width: 1, height: 1, file: "c/figure-\($0).png") }
        let text = "Here it is.\n\n![Trend](figure-2)\n\nAnd inline ![x](figure-3) does not count."
        #expect(FigureReference.placedIDs(in: text) == ["figure-2"])
        #expect(FigureReference.unplaced(figs, text: text).map(\.id) == ["figure-1", "figure-3"])
        #expect(FigureReference.unplaced(figs, text: "No figures.").count == 3)
    }

    @Test func theAppPromptSaysHowToShowAFigure() {
        #expect(AppPrompt.text(tools: true, python: true).contains("![short caption](figure-N)"))
        #expect(!AppPrompt.text(tools: true, python: false).contains("figure-N"))
    }
}
