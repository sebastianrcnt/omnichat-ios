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

    /// A small file can hold far more text than its size suggests (audit): extraction stops at a page and a character
    /// cap, says so, and stops when the fetch is cancelled.
    @Test func extractionIsCappedAndCancellable() async throws {
        let data = try #require(Self.makePDF(pages: (1...6).map { "Page number \($0) text." }))
        let url = URL(string: "https://example.com/a.pdf")!
        let byPages = try PDFFetch.text(of: data, url: url, maxPages: 2)
        #expect(byPages.text.contains("[Page 2]") && !byPages.text.contains("[Page 3]"))
        #expect(byPages.text.contains("Stopped reading at page 3 of 6"))
        let byCharacters = try PDFFetch.text(of: data, url: url, maxCharacters: 30)
        #expect(byCharacters.text.contains("[Page 1]") && !byCharacters.text.contains("[Page 3]"))
        #expect(byCharacters.text.contains("Stopped reading at page"))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PDFFetch.text(of: data, url: url)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test func aDownloadSendsTheBrowsersMatchingCookies() throws {
        // From the audit: a PDF behind a sign-in done in the browser sheet failed with 401, its cookies left behind.
        func cookie(_ name: String, domain: String, path: String = "/", secure: Bool = false) throws -> HTTPCookie {
            var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v", .domain: domain, .path: path]
            if secure { props[.secure] = "TRUE" }
            return try #require(HTTPCookie(properties: props))
        }
        let cookies = [try cookie("session", domain: ".example.com", secure: true), try cookie("other", domain: "other.org"),
                       try cookie("admin", domain: "example.com", path: "/admin")]
        let config = PDFFetch.configuration(cookies: cookies)
        let sent = { (url: String) in Set((config.httpCookieStorage?.cookies(for: URL(string: url)!) ?? []).map(\.name)) }
        #expect(sent("https://files.example.com/invoice.pdf") == ["session"])
        #expect(sent("http://files.example.com/invoice.pdf").isEmpty, "Secure cookies only over HTTPS")
        #expect(sent("https://other.org/a.pdf") == ["other"])
        #expect(sent("https://evil.com/a.pdf").isEmpty)
        #expect(PDFFetch.configuration(cookies: []).httpCookieStorage?.cookies?.isEmpty ?? true)
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
