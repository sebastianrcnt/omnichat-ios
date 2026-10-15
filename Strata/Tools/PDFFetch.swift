import Foundation
import PDFKit

/// `web_fetch` for PDFs. The hidden web view shows a PDF in its own viewer, where the page reader finds no text, so a
/// PDF is downloaded instead and its text layer read with PDFKit, a "[Page N]" line before each page.
enum PDFFetch {
    static let maxBytes = 40 * 1024 * 1024

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

    /// Downloads `url` and returns its text. Redirects are checked like the first URL (public http(s) hosts only).
    static func load(_ url: URL, timeout: Duration, resolver: any HostResolving = SystemHostResolver()) async throws -> FetchedPage {
        var request = URLRequest(url: url, timeoutInterval: timeout.seconds)
        request.httpShouldHandleCookies = false
        request.setValue("application/pdf,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue(HiddenWebView.userAgent, forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(resolver: resolver), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw Failure.http(http.statusCode) }
        if response.expectedContentLength > maxBytes { throw Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { throw Failure.tooLarge }
        }
        guard isPDF(data) else { throw Failure.notPDF }
        let finalURL = response.url ?? url
        return try await Task.detached(priority: .userInitiated) { try text(of: data, url: finalURL) }.value
    }

    /// The PDF's text, page by page. The title is the document's own, else the file name.
    static func text(of data: Data, url: URL) throws -> FetchedPage {
        guard let document = PDFDocument(data: data) else { throw Failure.unreadable }
        var parts: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !page.isEmpty else { continue }
            parts.append("[Page \(index + 1)]\n" + page)
        }
        guard !parts.isEmpty else { throw Failure.noText(pages: document.pageCount) }
        let own = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = own.isEmpty ? url.lastPathComponent : own
        return FetchedPage(title: title, url: url.absoluteString, text: parts.joined(separator: "\n\n"))
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        let resolver: any HostResolving
        init(resolver: any HostResolving) { self.resolver = resolver }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, (try? await URLGuard.validate(url, resolver: resolver)) != nil else { return nil }
            return request
        }
    }
}
