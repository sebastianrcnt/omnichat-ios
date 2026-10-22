import Foundation

// Sharing into OmniChat from another app's share sheet. The share extension (StrataShare) writes what was shared, and
// what to do with it, into the App Group container; the app picks it up when it opens and starts a chat with it.
// Shared by the app and the extension, so Foundation only.

/// The App Group the app and its share extension both read and write.
enum ShareGroup {
    static let identifier = "group.cc.coolservices.strata"

    /// Nil without the entitlement (the Mac app, a test host without it).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// One share, waiting for the app: the person's request plus links, text, images and files.
struct SharePayload: Codable, Identifiable, Equatable, Sendable {
    /// The sheet's quick actions. Each is an instruction at the top of the message.
    enum Action: String, Codable, CaseIterable, Identifiable, Sendable {
        case summarize, translate, explain, transcript
        var id: String { rawValue }
    }

    /// Where the message goes: a new chat, or the chat that was on screen when OmniChat was last left.
    enum Destination: Codable, Hashable, Sendable {
        case newChat
        case conversation(UUID)
    }

    struct Link: Codable, Equatable, Sendable {
        var url: URL
        var title: String?
    }

    /// A file stored next to the payload, by its file name in the share's folder.
    struct File: Codable, Equatable, Sendable {
        /// `package`: an OmniChat package (`.ocpkg`), opened in the app's review sheet instead of a chat.
        enum Kind: String, Codable, Sendable { case pdf, text, other, package }
        /// Shown and named in the message ("report.pdf").
        var name: String
        /// The copy in the share's folder.
        var storedName: String
        var kind: Kind
    }

    var id = UUID()
    var createdAt = Date()
    var action: Action?
    /// The language `translate` translates into, as an English name ("Korean"), fixed when the share is made.
    var translateLanguage: String?
    /// What the person typed.
    var note = ""
    var links: [Link] = []
    var texts: [String] = []
    /// JPEGs (already downscaled) in the share's folder.
    var images: [String] = []
    var files: [File] = []
    var destination: Destination = .newChat

    var isEmpty: Bool {
        links.isEmpty && texts.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && images.isEmpty
            && files.isEmpty && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - The message

extension SharePayload {
    /// Characters of one shared text or file that go into the message; the rest is cut with a note.
    static let maxItemCharacters = 30_000

    /// The instruction a quick action puts at the top of the message.
    static func instruction(_ action: Action, language: String?) -> String {
        switch action {
        case .summarize: "Summarize this."
        case .translate: "Translate this into \(language ?? "English")."
        case .explain: "Explain this."
        case .transcript: "Get the transcript of this video and summarize it."
        }
    }

    /// The user message the app sends: the action's instruction and the note, then the links, texts and files (each
    /// file as its extracted text, from `fileTexts` by stored name). Images go along as attachments.
    func messageText(fileTexts: [String: String] = [:]) -> String {
        var request: [String] = []
        if let action { request.append(Self.instruction(action, language: translateLanguage)) }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { request.append(note) }

        var blocks: [String] = []
        if !request.isEmpty { blocks.append(request.joined(separator: "\n")) }
        for link in links {
            let title = link.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            blocks.append(title.isEmpty || title == link.url.absoluteString ? link.url.absoluteString : "\(title)\n\(link.url.absoluteString)")
        }
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(Self.capped(trimmed)) }
        }
        for file in files where file.kind != .package {
            let body = fileTexts[file.storedName]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            blocks.append(body.isEmpty ? "[\(file.name): no readable text]" : "[\(file.name)]\n\(Self.capped(body))")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// A title for the new chat until the automatic one comes: what was shared rather than the instruction.
    var titleBasis: String {
        if let title = links.first?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let file = files.first { return file.name }
        if let text = texts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        if let host = links.first?.url.host(percentEncoded: false) { return host }
        return note
    }

    static func capped(_ text: String) -> String {
        guard text.count > maxItemCharacters else { return text }
        return String(text.prefix(maxItemCharacters)) + "\n[… cut: the rest of this text was too long to send]"
    }
}

// MARK: - Links into the app

/// `omnichat://share?id=<uuid>`: the extension opens the app with it after saving a share (`openchat://share` from
/// before the rename is still read).
enum ShareURL {
    static let scheme = AppURLScheme.current
    static let host = "share"

    static func url(for id: UUID) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        return c.url!
    }

    static func isShareURL(_ url: URL) -> Bool {
        AppURLScheme.matches(url) && url.host(percentEncoded: false)?.lowercased() == host
    }

    /// The share a link names; nil for another link, or a share link without a valid id (which still means "look").
    static func id(in url: URL) -> UUID? {
        guard isShareURL(url) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "id" }?.value.flatMap(UUID.init(uuidString:))
    }
}

/// Video links the `video_transcript` tool reads, for the sheet's Transcript action. (The tool's own parser,
/// `YouTubeURL`, is app-only; a test keeps the two in step.)
enum ShareVideoLink {
    static func isVideo(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        if host == "youtu.be" { return url.path().count > 1 }
        guard ["youtube.com", "youtube-nocookie.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return false }
        let parts = url.path(percentEncoded: false).split(separator: "/")
        if parts.first == "watch" { return true }
        return parts.count >= 2 && ["shorts", "live", "embed", "v", "e"].contains(String(parts[0]))
    }
}

// MARK: - What the sheet shows about the app

/// Written by the app when it goes to the background, read by the sheet: the model a new chat would use, the accent
/// and the chat on screen (for "Add to current chat").
struct ShareContext: Codable, Equatable, Sendable {
    struct Chat: Codable, Equatable, Sendable {
        var id: UUID
        var title: String
    }

    var accentHex: String?
    /// Nil when there is no connection with a model.
    var modelTitle: String?
    var connectionName: String?
    var hasConnection = false
    var currentChat: Chat?
}

// MARK: - The inbox

/// The App Group folder of shares: `Shares/<id>/payload.json` plus its images and files. The extension builds a share in
/// `Shares/.incoming-<id>` and renames it into place when Send is tapped, so the app never sees a half-written one.
struct ShareInbox: Sendable {
    let root: URL

    /// Shares older than this are dropped unopened, so an old share doesn't start a chat days later.
    static let maxAge: TimeInterval = 24 * 3600
    static let payloadName = "payload.json"
    static let contextName = "context.json"
    static let incomingPrefix = ".incoming-"

    init(root: URL) { self.root = root }

    /// The App Group's inbox; nil without the App Group.
    static var shared: ShareInbox? {
        ShareGroup.containerURL.map { ShareInbox(root: $0.appending(path: "Shares", directoryHint: .isDirectory)) }
    }

    func folder(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func incomingFolder(_ id: UUID) -> URL { root.appending(path: Self.incomingPrefix + id.uuidString, directoryHint: .isDirectory) }

    // MARK: Extension side

    /// A fresh folder for a share being put together; its images and files are written into it as they load.
    func makeIncoming(_ id: UUID) throws -> URL {
        let url = incomingFolder(id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes the payload and moves the share into place, where the app finds it.
    func commit(_ payload: SharePayload) throws {
        let incoming = try makeIncoming(payload.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(payload).write(to: incoming.appending(path: Self.payloadName), options: .atomic)
        let target = folder(payload.id)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: incoming, to: target)
    }

    func discardIncoming(_ id: UUID) {
        try? FileManager.default.removeItem(at: incomingFolder(id))
    }

    // MARK: App side

    /// Shares waiting, oldest first. Shares past `maxAge`, unreadable ones and abandoned incoming folders are removed.
    func pending(now: Date = .now) -> [SharePayload] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path(percentEncoded: false)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [SharePayload] = []
        for name in names {
            let url = root.appending(path: name, directoryHint: .isDirectory)
            if name.hasPrefix(Self.incomingPrefix) {
                let modified = (try? fm.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date) ?? now
                if now.timeIntervalSince(modified) > Self.maxAge { try? fm.removeItem(at: url) }
                continue
            }
            guard UUID(uuidString: name) != nil else { continue }
            guard let data = try? Data(contentsOf: url.appending(path: Self.payloadName)),
                  let payload = try? decoder.decode(SharePayload.self, from: data),
                  now.timeIntervalSince(payload.createdAt) <= Self.maxAge else {
                try? fm.removeItem(at: url)
                continue
            }
            out.append(payload)
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    func fileURL(_ storedName: String, in id: UUID) -> URL { folder(id).appending(path: storedName) }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    // MARK: Context

    private var contextURL: URL { root.appending(path: Self.contextName) }

    func writeContext(_ context: ShareContext) {
        guard (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil,
              let data = try? JSONEncoder().encode(context) else { return }
        try? data.write(to: contextURL, options: .atomic)
    }

    func readContext() -> ShareContext? {
        (try? Data(contentsOf: contextURL)).flatMap { try? JSONDecoder().decode(ShareContext.self, from: $0) }
    }
}
