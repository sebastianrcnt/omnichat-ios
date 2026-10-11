import Foundation
import Network
import UIKit

protocol ResumableChatStreaming: ChatStreaming {
    func stream(_ request: ChatRequest, endpoint: Endpoint, checkpoint: TurnCheckpoint)
        -> AsyncThrowingStream<ChatDelta, Error>
    func cancel(requestID: String, endpoint: Endpoint) async throws
}

/// Foreground and path changes wake reconnect backoff, without owning the turn.
final class RecoverySignals: @unchecked Sendable {
    static let shared = RecoverySignals()
    private let lock = NSLock()
    private var revision = 0
    private let monitor = NWPathMonitor()
    private var observer: NSObjectProtocol?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { self?.signal() }
        }
        monitor.start(queue: DispatchQueue(label: "Strata.networkRecovery"))
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                          object: nil, queue: nil) { [weak self] _ in self?.signal() }
    }
    private func signal() { lock.withLock { revision += 1 } }
    func wait(seconds: Double) async throws {
        let initial = lock.withLock { revision }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            if lock.withLock({ revision != initial }) { return }
        }
    }
}

extension ChatClient: ResumableChatStreaming {
    func cancel(requestID: String, endpoint: Endpoint) async throws {
        let req = HTTP.makeRequest(url: endpoint.baseURL.appendingPathComponent("streams/\(requestID)/cancel"),
                                   endpoint: endpoint, method: "POST")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), http.statusCode != 404 {
            throw APIError.http(status: http.statusCode, message: HTTP.errorMessage(from: data))
        }
    }

    func stream(_ request: ChatRequest, endpoint: Endpoint, checkpoint: TurnCheckpoint)
        -> AsyncThrowingStream<ChatDelta, Error> {
        guard endpoint.supportsResumable else { return stream(request, endpoint: endpoint) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var requestID = checkpoint.requestID
                var lastSequence = checkpoint.lastSequence
                var attempt = 0
                do {
                    while true {
                        try Task.checkCancellation()
                        do {
                            let url = requestID.map {
                                endpoint.baseURL.appendingPathComponent("streams/\($0)").appending(queryItems: [URLQueryItem(name: "after", value: String(lastSequence))])
                            } ?? endpoint.baseURL.appendingPathComponent("chat/completions")
                            var req = HTTP.makeRequest(url: url, endpoint: endpoint,
                                                       method: requestID == nil ? "POST" : "GET",
                                                       body: requestID == nil ? try request.encoded() : nil)
                            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                            if requestID == nil { req.setValue("1", forHTTPHeaderField: "X-Strata-Resumable") }
                            req.timeoutInterval = 300
                            let (bytes, response) = try await session.bytes(for: req)
                            guard let http = response as? HTTPURLResponse else { throw APIError.transport(String(localized: "Invalid HTTP response")) }
                            if !(200..<300).contains(http.statusCode) {
                                var data = Data()
                                for try await byte in bytes { data.append(byte); if data.count >= 4096 { break } }
                                throw APIError.http(status: http.statusCode, message: HTTP.errorMessage(from: data))
                            }
                            if requestID == nil {
                                guard let id = http.value(forHTTPHeaderField: "X-Billing-Request-Id"),
                                      id.hasPrefix("req_"), id.count == 28 else {
                                    throw APIError.server(String(localized: "This connection does not support resumable replies."))
                                }
                                requestID = id
                                continuation.yield(ChatDelta(requestID: id))
                            }
                            var parser = SSEParser(includeIDOnlyEvents: true)
                            var line = Data()
                            for try await byte in bytes {
                                try Task.checkCancellation()
                                line.append(byte)
                                if byte != 10 { continue }
                                let events = parser.feed(line)
                                line.removeAll(keepingCapacity: true)
                                for event in events {
                                    guard let id = event.id, let seq = Int(id), seq > 0 else {
                                        throw APIError.server(String(localized: "Missing resumable event sequence."))
                                    }
                                    if seq <= lastSequence { continue }
                                    guard seq == lastSequence + 1 else { throw URLError(.networkConnectionLost) }
                                    var delta = try ChatChunkDecoder.decode(event.data)
                                    delta.sequence = seq
                                    lastSequence = seq
                                    attempt = 0
                                    continuation.yield(delta)
                                    if delta.isDone { continuation.finish(); return }
                                }
                            }
                            // EOF without [DONE] is a dropped stream, never a completed reply.
                            throw URLError(.networkConnectionLost)
                        } catch {
                            try Task.checkCancellation()
                            // Without headers, retrying POST could double-generate/double-bill.
                            guard requestID != nil else { throw error }
                            if let api = error as? APIError {
                                if case .http(let status, _) = api, status >= 500 || status == 429 {} else { throw error }
                            } else if !(error is URLError) { throw error }
                            attempt += 1
                            try await RecoverySignals.shared.wait(seconds: min(15, pow(2, Double(min(attempt, 4)))))
                        }
                    }
                } catch {
                    if Task.isCancelled, let requestID {
                        // Covers Stop arriving before the metadata delta reaches the main actor.
                        // The controller also persists and retries cancellation when it knows the id.
                        Task { try? await cancel(requestID: requestID, endpoint: endpoint) }
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
