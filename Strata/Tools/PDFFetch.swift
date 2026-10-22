import Foundation
import PDFKit

/// `web_fetch` for PDFs. The hidden web view shows a PDF in its own viewer, where the page reader finds no text, so a
/// PDF is downloaded instead and its text layer read with PDFKit, a "[Page N]" line before each page.
enum PDFFetch {
    static let maxBytes = 40 * 1024 * 1024
    /// Extraction caps. The download limit bounds the compressed file only: many pages can share one large content
    /// stream, so a small file can expand to gigabytes of text. A long book still fits, read with `offset`.
    static let maxPages = 5_000
    static let maxCharacters = 4_000_000

    enum Failure: LocalizedError {
        case notPDF, tooLarge, unreadable, noText(pages: Int), http(Int)
        var errorDescription: String? {
            switch self {
            case .notPDF: "the file is not a PDF."
            case .tooLarge: "the PDF is larger than 40 MB."
            case .unreadable: "the PDF could not be opened."
            case .noText(let pages): "the PDF (\(pages) pages) has no text layer; it is probably scanned images."
            case .http(let status): "the server answered HTTP \(status)."
            }
        }
    }

    /// The URL names a PDF: a `.pdf` path, or arXiv's `/pdf/` links (which have no extension).
    static func looksLikePDF(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.hasSuffix(".pdf") { return true }
        if let host = url.host(percentEncoded: false)?.lowercased(), host.hasSuffix("arxiv.org"), path.hasPrefix("/pdf/") { return true }
        return false
    }

    static func isPDF(_ data: Data) -> Bool { data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil }

    /// Downloads `url` and returns its text. The URL and every redirect are checked like a fetch (public http(s) hosts only).
    static func load(_ url: URL, timeout: Duration, resolver: any HostResolving = SystemHostResolver()) async throws -> FetchedPage {
        try await URLGuard.validate(url, resolver: resolver)
        var request = URLRequest(url: url, timeoutInterval: timeout.seconds)
        request.httpShouldHandleCookies = false
        request.setValue("application/pdf,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue(HiddenWebView.userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await LimitedDownload.data(for: request, limit: maxBytes) { next in
                (try? await URLGuard.validate(next, resolver: resolver)) != nil
            }
        } catch LimitedDownload.Failure.tooLarge {
            throw Failure.tooLarge
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw Failure.http(http.statusCode) }
        guard isPDF(data) else { throw Failure.notPDF }
        let finalURL = response.url ?? url
        // Detached so the main actor stays free; the fetch deadline's cancellation is passed on, and checked per page.
        let extraction = Task.detached(priority: .userInitiated) { try text(of: data, url: finalURL) }
        return try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
    }

    /// The PDF's text, page by page, up to `maxPages` pages and about `maxCharacters` characters. The title is the
    /// document's own, else the file name.
    static func text(of data: Data, url: URL, maxPages: Int = maxPages, maxCharacters: Int = maxCharacters) throws -> FetchedPage {
        guard let document = PDFDocument(data: data) else { throw Failure.unreadable }
        var parts: [String] = []
        var characters = 0
        var stoppedAt: Int?
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            if index >= maxPages || characters >= maxCharacters {
                stoppedAt = index
                break
            }
            guard let page = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !page.isEmpty else { continue }
            let part = "[Page \(index + 1)]\n" + page.prefix(maxCharacters - characters)
            characters += part.utf16.count
            parts.append(part)
        }
        guard !parts.isEmpty else { throw Failure.noText(pages: document.pageCount) }
        if let stoppedAt {
            parts.append("[Stopped reading at page \(stoppedAt + 1) of \(document.pageCount): the PDF's text is too long to load in full.]")
        }
        let own = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = own.isEmpty ? url.lastPathComponent : own
        return FetchedPage(title: title, url: url.absoluteString, text: parts.joined(separator: "\n\n"))
    }
}
