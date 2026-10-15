import Testing
import Foundation
import PDFKit
@testable import Strata

struct PDFFetchTests {
    @Test func pdfLinksAreRecognized() {
        #expect(PDFFetch.looksLikePDF(URL(string: "https://example.com/paper.PDF")!))
        #expect(PDFFetch.looksLikePDF(URL(string: "https://arxiv.org/pdf/2506.10641")!))
        #expect(!PDFFetch.looksLikePDF(URL(string: "https://arxiv.org/abs/2506.10641")!))
    }

    @Test func aPDFsTextIsReadPageByPage() throws {
        let data = try #require(Self.makePDF(pages: ["First page text.", "Second page text."]))
        #expect(PDFFetch.isPDF(data))
        let page = try PDFFetch.text(of: data, url: URL(string: "https://example.com/a.pdf")!)
        #expect(page.text.contains("[Page 1]") && page.text.contains("First page text."))
        #expect(page.text.contains("[Page 2]") && page.text.contains("Second page text."))
        #expect(page.title == "a.pdf")
    }

    @Test func notAPDFIsRefused() {
        #expect(!PDFFetch.isPDF(Data("<html></html>".utf8)))
    }

    /// A small PDF with a text layer, drawn with Core Graphics.
    static func makePDF(pages: [String]) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for text in pages {
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]))
            ctx.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
