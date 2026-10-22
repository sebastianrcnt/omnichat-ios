import Foundation

/// One request the app sent, kept in memory for the diagnostics panel.
struct RequestRecord: Identifiable, Sendable {
    enum Storage: Sendable {
        case raw(Data)
        case deflated(Data)
    }

    let id: UUID
    let conversationID: UUID
    let time: Date
    let url: String
    /// Size of the request body as sent.
    let bodyBytes: Int
    var storage: Storage
    /// Filled in once the body has been parsed in the background.
    var messageCount: Int?
    var finishReason: String?
    var usage: Usage?

    /// Bytes this record holds in memory.
    var storedBytes: Int {
        switch storage {
        case .raw(let d), .deflated(let d): d.count
        }
    }
}

/// The last few request bodies per conversation, kept compressed in memory (atto's `keepRecent`). Nothing is read or
/// parsed unless the diagnostics panel opens: recording only keeps a reference and starts a background deflate.
@MainActor
final class RequestRing {
    static let shared = RequestRing()
    static let keepRecent = 6
    static let byteCap = 2 * 1024 * 1024

    let keepRecent: Int
    let byteCap: Int
    private var records: [UUID: [RequestRecord]] = [:] // oldest first
    private var pending: [UUID: Task<Void, Never>] = [:]
    /// Compress right away on the calling thread (tests that do not want to wait).
    var compressesInline = false

    init(keepRecent: Int = RequestRing.keepRecent, byteCap: Int = RequestRing.byteCap) {
        self.keepRecent = keepRecent
        self.byteCap = byteCap
    }

    var totalBytes: Int { records.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.storedBytes } } }
    var conversationIDs: [UUID] { records.filter { !$0.value.isEmpty }.map(\.key) }

    @discardableResult
    func record(conversationID: UUID, url: String, body: Data, time: Date = .now, id: UUID = UUID()) -> UUID {
        // A credential in a request URL never reaches diagnostics (`BaseURLCredentials`), whatever sent it.
        let record = RequestRecord(id: id, conversationID: conversationID, time: time, url: BaseURLCredentials.redacted(url),
                                   bodyBytes: body.count, storage: .raw(body))
        records[conversationID, default: []].append(record)
        if compressesInline {
            let packed = Self.pack(body)
            update(record.id) { $0.storage = packed.storage; $0.messageCount = packed.messageCount }
        } else {
            let id = record.id
            pending[id] = Task { [weak self] in
                let packed = await Task.detached(priority: .utility) { Self.pack(body) }.value
                self?.update(id) { $0.storage = packed.storage; $0.messageCount = packed.messageCount }
                self?.pending[id] = nil
            }
        }
        trim(conversationID)
        return record.id
    }

    func complete(_ id: UUID, finishReason: String?, usage: Usage?) {
        update(id) {
            if let finishReason { $0.finishReason = finishReason }
            if let usage { $0.usage = usage }
        }
    }

    /// Oldest first.
    func recent(for conversationID: UUID) -> [RequestRecord] { records[conversationID] ?? [] }

    func removeConversation(_ id: UUID) {
        for r in records[id] ?? [] { pending[r.id]?.cancel(); pending[r.id] = nil }
        records[id] = nil
    }

    func removeAll() {
        for t in pending.values { t.cancel() }
        pending.removeAll()
        records.removeAll()
    }

    /// Wait for background compression to finish (tests).
    func settle() async {
        for task in Array(pending.values) { await task.value }
    }

    /// The request body as sent.
    nonisolated static func body(of record: RequestRecord) -> Data? {
        switch record.storage {
        case .raw(let d): return d
        case .deflated(let d): return try? (d as NSData).decompressed(using: .zlib) as Data
        }
    }

    // MARK: Private

    private nonisolated static func pack(_ body: Data) -> (storage: RequestRecord.Storage, messageCount: Int) {
        let count = RequestInspection.messages(in: body).count
        if let packed = try? (body as NSData).compressed(using: .zlib) as Data, packed.count < body.count {
            return (.deflated(packed), count)
        }
        return (.raw(body), count)
    }

    private func update(_ id: UUID, _ change: (inout RequestRecord) -> Void) {
        for (conv, list) in records {
            if let i = list.firstIndex(where: { $0.id == id }) {
                change(&records[conv]![i])
                trimTotal()
                return
            }
        }
    }

    private func trim(_ conversationID: UUID) {
        while let list = records[conversationID], list.count > keepRecent {
            pending[list[0].id]?.cancel()
            pending[list[0].id] = nil
            records[conversationID]?.removeFirst()
        }
        trimTotal()
    }

    /// Drops the oldest request of any conversation until the total fits. The newest request overall stays, even when
    /// it alone is over the cap (a conversation full of photos), so the last request is always inspectable.
    private func trimTotal() {
        while totalBytes > byteCap {
            let all = records.values.flatMap { $0 }
            guard all.count > 1, let oldest = all.min(by: { $0.time < $1.time }) else { return }
            pending[oldest.id]?.cancel()
            pending[oldest.id] = nil
            records[oldest.conversationID]?.removeAll { $0.id == oldest.id }
        }
    }
}
