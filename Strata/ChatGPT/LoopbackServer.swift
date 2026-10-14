import Foundation
import Network

/// A one-purpose HTTP listener on 127.0.0.1 for the OAuth redirect: a free port chosen by the system, GET requests
/// only, the `Host` header checked, one small response per connection. Lives only while a sign-in waits.
final class LoopbackServer: @unchecked Sendable { // state is only touched on `queue`
    /// Decides the reply to a request and whether it ends the wait (the callback of the pending attempt).
    struct Reply: Sendable {
        var status: Int
        var html: String
        var finishes: Bool
    }

    private let queue = DispatchQueue(label: "cc.coolservices.strata.siwc.loopback")
    private var listener: NWListener?
    private var respond: @Sendable (URL) -> Reply
    private var callbacks: AsyncStream<URL>.Continuation?
    let received: AsyncStream<URL>
    private(set) var port: UInt16 = 0

    init(respond: @escaping @Sendable (URL) -> Reply) {
        self.respond = respond
        var continuation: AsyncStream<URL>.Continuation!
        received = AsyncStream { continuation = $0 }
        callbacks = continuation
    }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    let port = listener.port?.rawValue ?? 0
                    self?.port = port
                    continuation.resume(returning: port)
                case .failed, .cancelled:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: ChatGPTAuthError.listenerFailed)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            callbacks?.finish()
            callbacks = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
        // A request that never completes is dropped.
        queue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), connection: connection)
            } else if isComplete || error != nil || buffer.count > 16 * 1024 {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ head: String, connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        let reply: Reply
        if parts.count == 3, parts[0] == "GET", host == "127.0.0.1:\(port)",
           let url = URL(string: "http://127.0.0.1:\(port)" + parts[1]) {
            reply = respond(url)
            if reply.finishes { callbacks?.yield(url) }
        } else {
            reply = Reply(status: 404, html: "Not found", finishes: false)
        }
        let body = Data(reply.html.utf8)
        let reason = reply.status == 200 ? "OK" : reply.status == 400 ? "Bad Request" : "Not Found"
        let header = "HTTP/1.1 \(reply.status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
            + "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The page the browser shows once the callback arrived.
    static func page(title: String, message: String) -> String {
        """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\
        <title>\(title)</title><style>body{font:17px -apple-system,system-ui,sans-serif;max-width:32rem;margin:18vh auto;\
        padding:24px;color:#202123}@media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#f2f2f7}}\
        h1{font-size:24px}</style><h1>\(title)</h1><p>\(message)</p></html>
        """
    }
}
