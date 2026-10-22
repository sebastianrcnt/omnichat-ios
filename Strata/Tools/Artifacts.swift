import Foundation

// HTML artifacts (`show_html`): pages the model writes that the user opens full screen from a card in the chat. Stored
// per conversation under Application Support, like the figures of `ToolImageStore`; only the newest version is kept.

/// One artifact as its chat's index lists it. The id (`a<n>-<8 hex digits>`, `ArtifactStore.newID`; `a<n>` in chats
/// from before) is what the model passes to update it.
struct Artifact: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    /// 1 for the first HTML, one more for each update.
    var version: Int
    var created: Date
    var updated: Date
    /// The `show_html` call that wrote the current version.
    var callID: String?
}

/// What a `show_html` call's card needs: which artifact, and the title and version that call wrote.
struct ArtifactRef: Codable, Hashable, Sendable {
    var conversationID: UUID
    var id: String
    var title: String
    var version: Int
}

/// Why `show_html` could not store an artifact. Read by the model, so each says what to do instead.
enum ArtifactError: Error, Equatable, LocalizedError {
    case emptyHTML
    case tooLarge(bytes: Int)
    case unknownID(String, known: [String])
    case notStored

    var errorDescription: String? {
        switch self {
        case .emptyHTML: "The html argument is empty. Send the complete HTML document."
        case .tooLarge(let bytes):
            "The HTML is \(ArtifactStore.megabytes(bytes)); an artifact can be at most \(ArtifactStore.megabytes(ArtifactStore.maxBytes)). "
                + "Make it smaller: load libraries from a CDN instead of inlining them, and leave out large embedded data."
        case .unknownID(let id, let known):
            "No artifact with id \"\(id)\" exists in this chat. "
                + (known.isEmpty ? "Leave id out to make a new one." : "Existing: \(known.joined(separator: ", ")). Leave id out to make a new one.")
        case .notStored: "The artifact could not be saved on this device."
        }
    }
}

/// The artifacts of every chat: `<root>/<conversation id>/index.json` plus `<id>.html` for each.
final class ArtifactStore: @unchecked Sendable {
    static let shared = ArtifactStore()
    static let idPrefix = "a"
    /// Largest HTML an artifact may hold, in UTF-8 bytes.
    static let maxBytes = 2 * 1024 * 1024

    /// An artifact and the chat it belongs to, for the list of all artifacts.
    struct Entry: Hashable, Sendable, Identifiable {
        var conversationID: UUID
        var artifact: Artifact
        var id: String { conversationID.uuidString + "/" + artifact.id }
        var ref: ArtifactRef { ArtifactRef(conversationID: conversationID, id: artifact.id, title: artifact.title, version: artifact.version) }
    }

    let root: URL
    private let lock = NSLock()
    /// The app's own store (not a test's): its pages sync with their chats (`FileMirror`).
    private let mirrored: Bool

    init(root: URL? = nil) {
        mirrored = root == nil
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("Artifacts", isDirectory: true)
        }
    }

    private func folder(_ conversationID: UUID) -> URL { root.appendingPathComponent(conversationID.uuidString, isDirectory: true) }
    private func indexURL(_ conversationID: UUID) -> URL { folder(conversationID).appendingPathComponent("index.json") }

    /// The page file of an artifact (it exists once the artifact is saved).
    func fileURL(id: String, conversationID: UUID) -> URL? {
        guard let id = Self.resolve(id, in: artifacts(conversationID: conversationID)) else { return nil }
        return folder(conversationID).appendingPathComponent(id + ".html")
    }

    /// Stores a new artifact, or a new version of the one with `id`.
    @discardableResult
    func save(title: String, html: String, id: String? = nil, conversationID: UUID, callID: String? = nil,
              now: Date = .now) throws(ArtifactError) -> Artifact {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyHTML }
        let bytes = html.utf8.count
        guard bytes <= Self.maxBytes else { throw .tooLarge(bytes: bytes) }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        var index = readIndex(conversationID)
        var artifact: Artifact
        if let id {
            guard let key = Self.resolve(id, in: index), let i = index.firstIndex(where: { $0.id == key }) else {
                throw .unknownID(id.trimmingCharacters(in: .whitespacesAndNewlines), known: index.map(\.id))
            }
            artifact = index[i]
            artifact.version += 1
            artifact.updated = now
            artifact.callID = callID
            if !title.isEmpty { artifact.title = title }
            index[i] = artifact
        } else {
            artifact = Artifact(id: Self.newID(after: index.compactMap { Self.number($0.id) }.max() ?? 0),
                                title: title.isEmpty ? "Untitled" : title,
                                version: 1, created: now, updated: now, callID: callID)
            index.append(artifact)
        }
        let dir = folder(conversationID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = Data(html.utf8)
        guard (try? page.write(to: dir.appendingPathComponent(artifact.id + ".html"), options: .atomic)) != nil,
              writeIndex(index, conversationID: conversationID) else { throw .notStored }
        if mirrored { FileMirror.handler?.wrote(page, area: FileSync.artifacts, conversationID: conversationID, name: artifact.id + ".html") }
        return artifact
    }

    /// The conversation's artifacts, oldest first.
    func artifacts(conversationID: UUID) -> [Artifact] {
        lock.withLock { readIndex(conversationID) }
    }

    func artifact(id: String, conversationID: UUID) -> Artifact? {
        let index = artifacts(conversationID: conversationID)
        guard let key = Self.resolve(id, in: index) else { return nil }
        return index.first { $0.id == key }
    }

    /// The current HTML of an artifact.
    func html(id: String, conversationID: UUID) -> String? {
        guard let url = fileURL(id: id, conversationID: conversationID), let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Every artifact of the chats in `existing` (all stored ones when nil), last updated first. Passing the chats that
    /// still exist keeps a deleted chat's leftovers out even if its folder was never removed.
    func allArtifacts(existing: Set<UUID>? = nil) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let chats = names.compactMap(UUID.init(uuidString:)).filter { existing?.contains($0) ?? true }
        return lock.withLock {
            chats.flatMap { chat in readIndex(chat).map { Entry(conversationID: chat, artifact: $0) } }
        }
        .sorted { $0.artifact.updated != $1.artifact.updated ? $0.artifact.updated > $1.artifact.updated : $0.id < $1.id }
    }

    func removeAll(conversationID: UUID) {
        lock.withLock { try? FileManager.default.removeItem(at: folder(conversationID)) }
        if mirrored { FileMirror.handler?.removedAll(area: FileSync.artifacts, conversationID: conversationID) }
    }

    // MARK: Index

    private func readIndex(_ conversationID: UUID) -> [Artifact] {
        guard let data = try? Data(contentsOf: indexURL(conversationID)) else { return [] }
        return (try? Self.decoder.decode([Artifact].self, from: data)) ?? []
    }

    private func writeIndex(_ index: [Artifact], conversationID: UUID) -> Bool {
        guard let data = try? Self.encoder.encode(index), (try? data.write(to: indexURL(conversationID), options: .atomic)) != nil else {
            return false
        }
        if mirrored { FileMirror.handler?.wrote(data, area: FileSync.artifacts, conversationID: conversationID, name: "index.json") }
        return true
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Ids

    /// A new artifact's id: `a<n>-<8 hex digits>`, n one more than the chat's highest. The random part keeps two
    /// devices adding an artifact to the same synced chat before either has the other's from writing the same page
    /// (`FileSync` treats one path as one file).
    static func newID(after highest: Int) -> String {
        idPrefix + String(highest + 1) + "-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
    }

    /// "a3" from "a3", " A3 " or "3", "a3-3f9a2c1b" from itself in any case; nil for anything else (so an id never names
    /// a path).
    static func normalizedID(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let n = Int(t), n > 0, t.allSatisfy(\.isNumber) { return idPrefix + String(n) }
        guard number(t) != nil else { return nil }
        return t.contains("-") ? t : number(t).map { idPrefix + String($0) }
    }

    /// The index's id `raw` names: the same id, or for a short one ("a3", "3") the chat's only artifact with that number
    /// (the model may leave out the random part).
    static func resolve(_ raw: String, in index: [Artifact]) -> String? {
        guard let key = normalizedID(raw) else { return nil }
        if index.contains(where: { $0.id == key }) || key.contains("-") { return key }
        let n = number(key)
        let matches = index.filter { number($0.id) == n }
        return matches.count == 1 ? matches[0].id : key
    }

    /// The number of `a3` or `a3-3f9a2c1b`.
    private static func number(_ id: String) -> Int? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let parts = id.dropFirst(idPrefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard let n = Int(parts[0]), n > 0, parts[0].allSatisfy(\.isNumber) else { return nil }
        if parts.count == 1 { return n }
        guard parts.count == 2, parts[1].count == 8, parts[1].allSatisfy(\.isHexDigit) else { return nil }
        return n
    }

    /// "2.4 MB".
    static func megabytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1024 / 1024
        return (mb == mb.rounded() ? String(Int(mb)) : String(format: "%.1f", mb)) + " MB"
    }
}

// MARK: - Tool

/// `show_html`: stores the page and tells the model the id to update it with. The card in the chat opens it.
struct ShowHTMLTool {
    var store: ArtifactStore = .shared

    func run(arguments args: [String: Any], conversationID: UUID?, callID: String?) -> ToolOutput {
        guard let html = args["html"] as? String else {
            return ToolOutput(text: "Error: missing required argument \"html\".", isError: true)
        }
        guard let conversationID else { return ToolOutput(text: "Error: artifacts are not available here.", isError: true) }
        let id: String? = switch args["id"] {
        case let s as String: s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        case let n as Int: String(n)
        default: nil
        }
        do {
            let artifact = try store.save(title: args["title"] as? String ?? "", html: html, id: id,
                                          conversationID: conversationID, callID: callID)
            let ref = ArtifactRef(conversationID: conversationID, id: artifact.id, title: artifact.title, version: artifact.version)
            return ToolOutput(text: Self.summary(artifact), artifact: ref)
        } catch {
            return ToolOutput(text: "Error: " + (error.errorDescription ?? "the artifact could not be saved."), isError: true)
        }
    }

    /// What the model reads back.
    static func summary(_ artifact: Artifact) -> String {
        "Shown to the user as artifact \"\(artifact.title)\" (id: \(artifact.id), version \(artifact.version)). "
            + "To change it, call show_html again with id \"\(artifact.id)\" and the full new HTML."
    }
}

// MARK: - Display

enum ArtifactHTML {
    /// The page as the viewer loads it: a fragment is wrapped in a document, and a page without a viewport gets one so
    /// it is laid out for the screen instead of a zoomed-out desktop width. The stored (and shared) file stays as sent.
    static func prepared(_ html: String) -> String {
        let lower = html.lowercased()
        let viewport = #"<meta name="viewport" content="width=device-width, initial-scale=1">"#
        guard lower.contains("<html") || lower.contains("<head") || lower.contains("<body") else {
            return "<!doctype html><html><head><meta charset=\"utf-8\">" + viewport + "</head><body>" + html + "</body></html>"
        }
        guard !lower.contains("name=\"viewport\""), !lower.contains("name='viewport'"), !lower.contains("name=viewport") else { return html }
        if let head = html.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            return html.replacingCharacters(in: head, with: html[head] + viewport)
        }
        return html
    }
}
