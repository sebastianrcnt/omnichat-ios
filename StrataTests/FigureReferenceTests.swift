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

    /// New figures carry a random part (`ToolImageStore.newID`); a model that writes the short form still places them.
    @Test func idsWithTheirRandomPartAreReferencesToo() throws {
        #expect(FigureReference.block("![Sales](figure-2-3f9a2c1b)") == [.init(id: "figure-2-3f9a2c1b", caption: "Sales")])
        let figs = ["figure-1-0123abcd", "figure-2-3f9a2c1b"].map { ToolImage(id: $0, width: 1, height: 1, file: "c/\($0).png") }
        #expect(FigureReference.unplaced(figs, text: "![a](figure-2)").map(\.id) == ["figure-1-0123abcd"])
        #expect(FigureReference.unplaced(figs, text: "![a](figure-1-0123abcd)").map(\.id) == ["figure-2-3f9a2c1b"])

        let store = ToolImageStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("figs-\(UUID().uuidString)"))
        let chat = UUID()
        defer { store.removeAll(conversationID: chat) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 2, 0, 0, 0, 2])
        let stored = try #require(store.addFigure(png: png, conversationID: chat))
        #expect(FigureReference.image(id: "figure-1", conversationID: chat, store: store).file == stored.file)
        #expect(FigureReference.image(id: stored.id, conversationID: chat, store: store).file == stored.file)
    }

    @Test func theAppPromptSaysHowToShowAFigure() {
        #expect(AppPrompt.text(tools: true, python: true).contains("![short caption](figure-N)"))
        #expect(!AppPrompt.text(tools: true, python: false).contains("figure-N"))
    }

    @Test func savingOverAFileKeepsItWhenTheCopyFails() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "figure-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appending(path: "chart.png")
        try Data("old".utf8).write(to: existing)
        #expect(throws: (any Error).self) { try ToolImageViewer.export(folder.appending(path: "missing.png"), to: existing) }
        #expect(FileManager.default.contents(atPath: existing.path(percentEncoded: false)) == Data("old".utf8))
        let figure = folder.appending(path: "figure-1.png")
        try Data("new".utf8).write(to: figure)
        try ToolImageViewer.export(figure, to: existing)
        #expect(FileManager.default.contents(atPath: existing.path(percentEncoded: false)) == Data("new".utf8))
        let fresh = folder.appending(path: "fresh.png")
        try ToolImageViewer.export(figure, to: fresh)
        #expect(FileManager.default.contents(atPath: fresh.path(percentEncoded: false)) == Data("new".utf8))
    }
}
