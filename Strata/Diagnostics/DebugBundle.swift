import Foundation

/// Writes the debug bundle: `Documents/Debug/<yyyyMMdd-HHmmss>/` with `report.json`, `memstats.txt`, `index.txt` and
/// `requests/<conversation>-<n>.json`. The folder shows up in Files (the app shares its Documents) and can be copied
/// off a device with `devicectl device copy from --domain-type appDataContainer`.
enum DebugBundle {
    struct Report: Codable, Equatable, Sendable {
        var generated: Date
        var imagesStripped: Bool
        var app: AppDiagnostics
        var conversations: [ConversationDiagnostics]
    }

    /// `Documents/Debug`.
    static var defaultRoot: URL {
        URL.documentsDirectory.appendingPathComponent("Debug", isDirectory: true)
    }

    static func folderName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// One line of `index.txt`: `file  time  url  N bytes, M messages[; note][; tools differ]`.
    static func indexLine(_ r: ConversationDiagnostics.Request, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute, .second], from: r.time)
        let time = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        var line = "\(r.file)  \(time)  \(BaseURLCredentials.redacted(r.url))  \(r.bodyBytes) bytes, \(r.messageCount ?? 0) messages"
        if let note = r.note { line += "; " + note }
        if r.toolsDiffer { line += "; tools differ" }
        return line
    }

    /// - Parameters:
    ///   - conversations: shown in `report.json`.
    ///   - requestConversations: whose recorded requests are written (default: every conversation in the ring).
    @MainActor
    @discardableResult
    static func write(app: AppDiagnostics, conversations: [ConversationDiagnostics],
                      requestConversations: [UUID]? = nil, ring: RequestRing = .shared,
                      options: DebugRedaction.Options = .init(), root: URL = defaultRoot,
                      now: Date = .now, calendar: Calendar = .current) throws -> URL {
        let fm = FileManager.default
        var folder = root.appendingPathComponent(folderName(for: now, calendar: calendar), isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent(folderName(for: now, calendar: calendar) + "-\(suffix)", isDirectory: true)
            suffix += 1
        }
        let requestsDirectory = folder.appendingPathComponent("requests", isDirectory: true)
        try fm.createDirectory(at: requestsDirectory, withIntermediateDirectories: true)

        // Requests first: the report carries the same per-request notes the index does.
        var index: [String] = []
        var summaries: [UUID: [ConversationDiagnostics.Request]] = [:]
        for id in requestConversations ?? ring.conversationIDs {
            let records = ring.recent(for: id)
            let list = ConversationDiagnostics.requestSummaries(records, conversation: id)
            summaries[id] = list
            for (record, summary) in zip(records, list) {
                guard let body = RequestRing.body(of: record) else { continue }
                let name = (summary.file as NSString).lastPathComponent
                try DebugRedaction.redact(body, options: options).write(to: requestsDirectory.appendingPathComponent(name), options: .atomic)
                index.append(indexLine(summary, calendar: calendar))
            }
        }
        // Redacted like the rest: a request's URL and notes can hold a credential too.
        let indexText = DebugRedaction.redact(index.joined(separator: "\n") + (index.isEmpty ? "" : "\n"), options: .init(stripImages: false))
        try Data(indexText.utf8)
            .write(to: folder.appendingPathComponent("index.txt"), options: .atomic)

        var shown = conversations
        for i in shown.indices { if let list = summaries[shown[i].id] { shown[i].requests = list } }
        let report = Report(generated: now, imagesStripped: options.stripImages, app: app, conversations: shown)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(report), as: UTF8.self)
        try Data(DebugRedaction.redact(json, options: .init(stripImages: false)).utf8)
            .write(to: folder.appendingPathComponent("report.json"), options: .atomic)

        try Data(memstats(app).utf8).write(to: folder.appendingPathComponent("memstats.txt"), options: .atomic)
        return folder
    }

    static func memstats(_ app: AppDiagnostics) -> String {
        func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }
        return [
            "memory: " + app.memorySummary,
            "storage: store \(mb(app.storage.storeBytes)) · external \(mb(app.storage.externalBytes)) in \(app.storage.externalFiles) files"
                + " · favicons \(mb(app.storage.faviconDiskBytes)) in \(app.storage.faviconDiskFiles) files",
            "caches: pages \(app.caches.pageCacheEntries) (\(app.caches.pageCacheCharacters) chars)"
                + " · image data URLs ≤\(mb(Int64(app.caches.dataURLBytesAdded))) of \(mb(Int64(app.caches.dataURLLimit)))"
                + " · favicon images \(app.caches.faviconImages) · request ring \(mb(Int64(app.caches.requestRingBytes)))",
            "live: \(app.live.hiddenWebViews) web views · turn \(app.live.activeTurn ?? "none") · \(app.live.recoveryLoops) recovery loops"
                + " · lease \(app.live.backgroundLease) · \(app.live.registeredBackgroundIdentifiers) background identifiers registered"
                + " · \(app.live.backgroundExpirations) ended by iOS",
            "counters: \(app.counters.checkpointBytesWritten) checkpoint bytes in \(app.counters.checkpointSaves) saves"
                + " · \(app.counters.recoveryAttempts) recovery attempts",
        ].joined(separator: "\n") + "\n"
    }
}
