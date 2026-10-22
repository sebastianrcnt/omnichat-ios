import Foundation

/// An image a tool made (today: a matplotlib figure from `run_python`). The id is what the model passes to
/// `view_image`: `figure-<n>-<8 hex digits>`, unique across devices (`ToolImageStore.newID`); chats from before that
/// have `figure-<n>`. Other kinds of image can take other prefixes later (for example `web-<n>` or `attachment-<n>`)
/// without changing the tool.
struct ToolImage: Codable, Hashable, Sendable {
    var id: String
    var width: Int
    var height: Int
    /// Path of the PNG relative to `ToolImageStore`'s root: `<conversation id>/<id>.png`.
    var file: String

    /// "figure-2-3f9a2c1b (640x480)".
    var listing: String { "\(id) (\(width)x\(height))" }
}

/// PNGs of tool images, one folder per conversation under Application Support. A file never changes once written, so
/// the data URL built from it (and the request prefix holding it) stays byte-identical.
final class ToolImageStore: @unchecked Sendable {
    static let shared = ToolImageStore()
    static let figurePrefix = "figure-"
    /// `browser_screenshot`'s images.
    static let screenshotPrefix = "screenshot-"

    let root: URL
    private let lock = NSLock()
    private let dataURLs = NSCache<NSString, NSString>()
    /// The app's own store (not a test's): its figures sync with their chats (`FileMirror`).
    private let mirrored: Bool

    init(root: URL? = nil) {
        mirrored = root == nil
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("ToolImages", isDirectory: true)
        }
        dataURLs.totalCostLimit = 48 * 1024 * 1024
    }

    private func folder(_ conversationID: UUID) -> URL { root.appendingPathComponent(conversationID.uuidString, isDirectory: true) }

    /// Stores a new figure and gives it a new id (`newID`).
    func addFigure(png: Data, conversationID: UUID) -> ToolImage? {
        addImage(png: png, conversationID: conversationID, prefix: Self.figurePrefix)
    }

    /// Stores a new image and gives it a new id (`newID`).
    func addImage(png: Data, conversationID: UUID, prefix: String) -> ToolImage? {
        let size = Self.pngSize(png) ?? (0, 0)
        return lock.withLock {
            let dir = folder(conversationID)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let id = Self.newID(prefix: prefix, after: Self.numbers(in: dir, prefix: prefix).max() ?? 0)
            let file = conversationID.uuidString + "/" + id + ".png"
            guard (try? png.write(to: root.appendingPathComponent(file), options: .atomic)) != nil else { return nil }
            if mirrored { FileMirror.handler?.wrote(png, area: FileSync.toolImages, conversationID: conversationID, name: id + ".png") }
            return ToolImage(id: id, width: size.0, height: size.1, file: file)
        }
    }

    /// A new image's id: `<prefix><n>-<8 hex digits>`, n one more than the conversation's highest here. The number keeps
    /// ids readable and in order; the random part keeps them apart when two devices add an image to the same synced chat
    /// before either has the other's (`FileSync` treats one path as one file).
    static func newID(prefix: String, after highest: Int) -> String {
        prefix + String(highest + 1) + "-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
    }

    /// The number of an id with `prefix` (`figure-3-3f9a2c1b` or, from before, `figure-3`); nil for anything else, so an
    /// id never names a path.
    static func number(of id: String, prefix: String) -> Int? {
        guard id.hasPrefix(prefix) else { return nil }
        let parts = id.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard let n = Int(parts[0]), parts[0].allSatisfy(\.isNumber) else { return nil }
        if parts.count == 1 { return n }
        guard parts.count == 2, parts[1].count == 8, parts[1].allSatisfy(\.isHexDigit), parts[1] == parts[1].lowercased() else { return nil }
        return n
    }

    /// The image with this id in the conversation, if it is stored. A bare `figure-3` the model wrote for a stored
    /// `figure-3-3f9a2c1b` finds it when it is the only one with that number.
    func image(id: String, conversationID: UUID) -> ToolImage? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let prefix = [Self.figurePrefix, Self.screenshotPrefix].first(where: { trimmed.hasPrefix($0) }),
              Self.number(of: trimmed, prefix: prefix) != nil else { return nil }
        let stored = exists(file: conversationID.uuidString + "/" + trimmed + ".png") ? trimmed
            : resolve(id: trimmed, conversationID: conversationID)
        guard let stored else { return nil }
        let file = conversationID.uuidString + "/" + stored + ".png"
        guard let png = data(file: file) else { return nil }
        let size = Self.pngSize(png) ?? (0, 0)
        return ToolImage(id: stored, width: size.0, height: size.1, file: file)
    }

    /// The stored id a shortened one (`figure-3`) stands for: the conversation's only image with that number; nil when
    /// there is none or more than one.
    func resolve(id: String, conversationID: UUID) -> String? {
        guard let prefix = [Self.figurePrefix, Self.screenshotPrefix].first(where: { id.hasPrefix($0) }),
              let n = Self.number(of: id, prefix: prefix) else { return nil }
        let matches = Self.ids(in: folder(conversationID), prefix: prefix).filter { $0.number == n }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// Ids of the conversation's stored figures, in order.
    func figureIDs(conversationID: UUID) -> [String] {
        Self.ids(in: folder(conversationID), prefix: Self.figurePrefix).sorted { ($0.number, $0.id) < ($1.number, $1.id) }.map(\.id)
    }

    func exists(file: String) -> Bool {
        !file.contains("..") && !file.hasPrefix("/") && FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path)
    }

    func data(file: String) -> Data? {
        guard !file.contains(".."), !file.hasPrefix("/") else { return nil }
        return try? Data(contentsOf: root.appendingPathComponent(file))
    }

    /// `data:image/png;base64,...`, built once per file.
    func dataURL(file: String) -> String? {
        if let hit = dataURLs.object(forKey: file as NSString) { return hit as String }
        guard let png = data(file: file) else { return nil }
        let url = "data:image/png;base64," + png.base64EncodedString()
        dataURLs.setObject(url as NSString, forKey: file as NSString, cost: url.utf8.count)
        return url
    }

    func removeAll(conversationID: UUID) {
        lock.withLock { try? FileManager.default.removeItem(at: folder(conversationID)) }
        if mirrored { FileMirror.handler?.removedAll(area: FileSync.toolImages, conversationID: conversationID) }
    }

    func purgeCache() { dataURLs.removeAllObjects() }

    private static func numbers(in dir: URL, prefix: String) -> [Int] { ids(in: dir, prefix: prefix).map(\.number) }

    private static func ids(in dir: URL, prefix: String) -> [(id: String, number: Int)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".png") else { return nil }
            let id = String(name.dropLast(4))
            return number(of: id, prefix: prefix).map { (id, $0) }
        }
    }

    /// Width and height from a PNG's IHDR chunk.
    static func pngSize(_ data: Data) -> (Int, Int)? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, bytes[0] == 0x89, bytes[1] == 0x50, bytes[12] == 0x49, bytes[13] == 0x48 else { return nil }
        func be(_ i: Int) -> Int { Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) }
        return (be(16), be(20))
    }
}
