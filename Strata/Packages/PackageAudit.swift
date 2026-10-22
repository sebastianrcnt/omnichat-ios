import Foundation
import CryptoKit

/// The local record of package tool calls (docs/PACKAGES.md 6.3): one JSON line per call in
/// `Application Support/Audit/YYYY-MM-DD.jsonl`, at the `calls` level: which tool ran, where, how it ended and a hash
/// of its arguments, never the arguments, the result or a secret. Kept 30 days. (`full`, which keeps arguments, is for
/// company policy only and does not exist yet.)
final class PackageAudit: @unchecked Sendable {
    static let shared = PackageAudit()
    static let keptDays = 30

    struct Event: Codable, Sendable, Equatable {
        enum Outcome: String, Codable, Sendable {
            case ok, error, denied, refused
        }

        var time: Date
        var conversation: String?
        var package: String
        var version: String
        var tool: String
        var host: String?
        var method: String?
        var status: Int?
        var outcome: Outcome
        var argsSha256: String
        var milliseconds: Int?
    }

    private let lock = NSLock()
    /// Nil keeps events in memory (tests).
    private let directory: URL?
    private var memory: [Event] = []

    init(directory: URL? = PackageAudit.defaultDirectory) { self.directory = directory }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audit", isDirectory: true)
    }

    static func hash(_ arguments: String) -> String {
        SHA256.hash(data: Data(arguments.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func record(_ event: Event) {
        lock.withLock {
            guard let directory else { memory.append(event); return }
            guard var line = try? Self.encoder.encode(event) else { return }
            line.append(0x0A)
            let file = directory.appendingPathComponent(Self.dayFormat.string(from: event.time) + ".jsonl")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: file, options: .atomic)
                pruneLocked(directory: directory, now: event.time)
            }
        }
    }

    /// The newest events first, optionally for one package.
    func events(package: String? = nil, limit: Int = 500) -> [Event] {
        lock.withLock {
            var out: [Event] = []
            if let directory {
                let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
                for file in files {
                    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    out += text.split(separator: "\n").reversed().compactMap { try? Self.decoder.decode(Event.self, from: Data($0.utf8)) }
                    if out.count >= limit * 2 { break }
                }
            } else {
                out = memory.reversed()
            }
            return Array(out.filter { package == nil || $0.package == package }.prefix(limit))
        }
    }

    /// Clears the record of one package, or all of it.
    func clear(package: String? = nil) {
        lock.withLock {
            guard let directory else { memory.removeAll { package == nil || $0.package == package }; return }
            let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
            for file in files {
                guard let package else { try? FileManager.default.removeItem(at: file); continue }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let kept = text.split(separator: "\n").filter { line in
                    (try? Self.decoder.decode(Event.self, from: Data(line.utf8)))?.package != package
                }
                try? Data((kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).utf8).write(to: file, options: .atomic)
            }
        }
    }

    private func pruneLocked(directory: URL, now: Date) {
        let cutoff = Self.dayFormat.string(from: now.addingTimeInterval(-Double(Self.keptDays) * 86_400))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jsonl" && file.deletingPathExtension().lastPathComponent < cutoff {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
