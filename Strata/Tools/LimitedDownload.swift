import Foundation

/// Downloads a body into memory, giving up as soon as it passes `limit` instead of after buffering all of it (a
/// multi-gigabyte file would get the app killed first). Redirects go through `allowRedirect`.
final class LimitedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case tooLarge(limit: Int)
        var errorDescription: String? {
            switch self {
            case .tooLarge(let limit): "the download is larger than \(limit / 1_048_576) MB."
            }
        }
    }

    typealias RedirectCheck = @Sendable (URL) async -> Bool

    private let limit: Int
    private let allowRedirect: RedirectCheck?
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

    private init(limit: Int, allowRedirect: RedirectCheck?) {
        self.limit = limit
        self.allowRedirect = allowRedirect
    }

    static func data(for request: URLRequest, configuration: URLSessionConfiguration = .ephemeral, limit: Int,
                     allowRedirect: RedirectCheck? = nil) async throws -> (Data, URLResponse) {
        let delegate = LimitedDownload(limit: limit, allowRedirect: allowRedirect)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<(Data, URLResponse), Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async
        -> URLSession.ResponseDisposition {
        if response.expectedContentLength > Int64(limit) {
            finish(.failure(Failure.tooLarge(limit: limit)))
            return .cancel
        }
        lock.withLock { self.response = response }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let over = lock.withLock { () -> Bool in
            data.append(chunk)
            return data.count > limit
        }
        if over {
            finish(.failure(Failure.tooLarge(limit: limit)))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let allowRedirect else { return request }
        guard let url = request.url, await allowRedirect(url) else { return nil }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        let (body, response) = lock.withLock { (data, self.response) }
        guard let response else { finish(.failure(URLError(.badServerResponse))); return }
        finish(.success((body, response)))
    }
}
