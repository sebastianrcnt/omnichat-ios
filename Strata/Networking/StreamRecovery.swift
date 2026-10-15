import Foundation
import Network

protocol ResumableChatStreaming: ChatStreaming {
    func stream(_ request: ChatRequest, endpoint: Endpoint, checkpoint: TurnCheckpoint)
        -> AsyncThrowingStream<ChatDelta, Error>
    func cancel(requestID: String, endpoint: Endpoint) async throws
    func requestID(forIdempotencyKey key: String, endpoint: Endpoint) async throws -> String?
}

extension ResumableChatStreaming {
    func requestID(forIdempotencyKey key: String, endpoint: Endpoint) async throws -> String? { nil }
}

/// The server couldn't be reached for the whole recovery window. The reply is still on the server: its checkpoint is
/// kept, and the next time the app comes to the front it reconnects again.
struct StreamOutage: LocalizedError, Equatable {
    var minutes: Int
    var errorDescription: String? {
        String(localized: "Could not reconnect to the server for \(minutes) minutes. Strata tries again when you come back to the app.")
    }
}

enum StreamRecoveryPolicy {
    /// How long a reply keeps trying to reconnect without receiving anything.
    nonisolated(unsafe) static var maxOutage: TimeInterval = 600
}

/// Foreground and path changes wake reconnect backoff, without owning the turn. A waiter sleeps on a timer and is
/// resumed early by a signal; nothing polls.
final class RecoverySignals: @unchecked Sendable {
    static let shared = RecoverySignals()
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledEarly = Set<UUID>()
    /// Waiters currently sleeping (tests).
    var waiterCount: Int { lock.withLock { waiters.count } }
    private var monitor: NWPathMonitor?
    private var observer: NSObjectProtocol?

    /// `observing: false` makes a signal source that only `signal()` drives (tests).
    init(observing: Bool = true) {
        guard observing else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { self?.signal() }
        }
        monitor.start(queue: DispatchQueue(label: "Strata.networkRecovery"))
        self.monitor = monitor
        observer = NotificationCenter.default.addObserver(forName: AppLifecycle.didBecomeActive,
                                                          object: nil, queue: nil) { [weak self] _ in self?.signal() }
    }

    deinit {
        monitor?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Wakes everything waiting now.
    func signal() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for w in all { w.resume() }
    }

    /// Returns after `seconds`, or as soon as a signal arrives. Throws `CancellationError` when cancelled.
    func wait(seconds: Double) async throws {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.resume(id)
        }
        defer {
            timer.cancel()
            lock.withLock { _ = cancelledEarly.remove(id) }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let early = lock.withLock { () -> Bool in
                    if cancelledEarly.remove(id) != nil { return true }
                    waiters[id] = cont
                    return false
                }
                if early { cont.resume() }
            }
        } onCancel: {
            let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                if let w = waiters.removeValue(forKey: id) { return w }
                cancelledEarly.insert(id) // cancelled before it began waiting
                return nil
            }
            cont?.resume()
        }
        try Task.checkCancellation()
    }

    /// The timer for `id` fired. If it fired before the waiter registered (a delayed scheduler), the waiter finds the
    /// mark and returns at once instead of waiting for an unrelated signal.
    private func resume(_ id: UUID) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let w = waiters.removeValue(forKey: id) { return w }
            cancelledEarly.insert(id)
            return nil
        }
        cont?.resume()
    }
}

extension ChatClient: ResumableChatStreaming {
    func requestID(forIdempotencyKey key: String, endpoint: Endpoint) async throws -> String? {
        let req = HTTP.makeRequest(url: endpoint.baseURL.appendingPathComponent("streams/by-key/\(key)"), endpoint: endpoint)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, message: HTTP.errorMessage(from: data))
        }
        struct Lookup: Decodable { var request_id: String }
        return try JSONDecoder().decode(Lookup.self, from: data).request_id
    }

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
                var failingSince: Date?
                do {
                    let postBody = try checkpoint.requestData ?? request.encoded()
                    while true {
                        try Task.checkCancellation()
                        do {
                            let url = requestID.map {
                                endpoint.baseURL.appendingPathComponent("streams/\($0)").appending(queryItems: [URLQueryItem(name: "after", value: String(lastSequence))])
                            } ?? endpoint.baseURL.appendingPathComponent("chat/completions")
                            var req = HTTP.makeRequest(url: url, endpoint: endpoint,
                                                       method: requestID == nil ? "POST" : "GET",
                                                       body: requestID == nil ? postBody : nil)
                            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                            if let key = checkpoint.idempotencyKey { req.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
                            if requestID == nil { req.setValue(String(lastSequence), forHTTPHeaderField: "Last-Event-ID") }
                            if requestID == nil { req.setValue("1", forHTTPHeaderField: "X-Strata-Resumable") }
                            req.timeoutInterval = 300
                            let (bytes, response) = try await session.bytes(for: req)
                            guard let http = response as? HTTPURLResponse else { throw APIError.transport(String(localized: "Invalid HTTP response")) }
                            if !(200..<300).contains(http.statusCode) {
                                var data = Data()
                                for try await byte in bytes { data.append(byte); if data.count >= 4096 { break } }
                                if requestID != nil, http.statusCode == 404 || http.statusCode == 410 {
                                    // The gateway let the stream go (kept too long while the app was away).
                                    throw APIError.server(String(localized: "The server no longer has this reply. Try again to get a new one."))
                                }
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
                            /// True once `[DONE]` arrived.
                            func handle(_ events: [SSEEvent]) throws -> Bool {
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
                                    failingSince = nil
                                    continuation.yield(delta)
                                    if delta.isDone { return true }
                                }
                                return false
                            }
                            for try await byte in bytes {
                                try Task.checkCancellation()
                                line.append(byte)
                                if byte != 0x0A && byte != 0x0D { continue } // CR alone also ends an SSE line
                                let events = parser.feed(line)
                                line.removeAll(keepingCapacity: true)
                                if try handle(events) { continuation.finish(); return }
                            }
                            // The last event may end without its blank line: flush it before calling EOF a drop.
                            if !line.isEmpty, try handle(parser.feed(line)) { continuation.finish(); return }
                            if try handle(parser.finish()) { continuation.finish(); return }
                            // EOF without [DONE] is a dropped stream, never a completed reply.
                            throw URLError(.networkConnectionLost)
                        } catch {
                            try Task.checkCancellation()
                            // The persisted key makes pre-header POST retries safe within registry retention.
                            guard requestID != nil || checkpoint.idempotencyKey != nil else { throw error }
                            if let api = error as? APIError {
                                if case .http(let status, _) = api, status >= 500 || status == 429 {} else { throw error }
                            } else if !(error is URLError) { throw error }
                            attempt += 1
                            // Give up after a long outage; the saved checkpoint still lets the next launch resume.
                            let since = failingSince ?? Date()
                            failingSince = since
                            if Date().timeIntervalSince(since) > StreamRecoveryPolicy.maxOutage {
                                throw StreamOutage(minutes: Int(StreamRecoveryPolicy.maxOutage / 60))
                            }
                            DiagnosticCounters.shared.recoveryWaitStarted()
                            defer { DiagnosticCounters.shared.recoveryWaitEnded() }
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
