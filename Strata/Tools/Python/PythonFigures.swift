import Foundation

/// An image a tool made (today: a matplotlib figure from `run_python`). The id is what the model passes to
/// `view_image`: `figure-<n>`, unique within the chat. Other kinds of image can take other prefixes later
/// (for example `web-<n>` or `attachment-<n>`) without changing the tool.
struct ToolImage: Codable, Hashable, Sendable {
    var id: String
    var width: Int
    var height: Int
    /// Path of the PNG relative to `ToolImageStore`'s root: `<conversation id>/<id>.png`.
    var file: String

    /// "figure-2 (640x480)".
    var listing: String { "\(id) (\(width)x\(height))" }
}

/// PNGs of tool images, one folder per conversation under Application Support. A file never changes once written, so
/// the data URL built from it (and the request prefix holding it) stays byte-identical.
final class ToolImageStore: @unchecked Sendable {
    static let shared = ToolImageStore()
    static let figurePrefix = "figure-"

    let root: URL
    private let lock = NSLock()
    private let dataURLs = NSCache<NSString, NSString>()

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("ToolImages", isDirectory: true)
        }
        dataURLs.totalCostLimit = 48 * 1024 * 1024
    }

    private func folder(_ conversationID: UUID) -> URL { root.appendingPathComponent(conversationID.uuidString, isDirectory: true) }

    /// Stores a new figure and gives it the next free `figure-<n>` id of the conversation.
    func addFigure(png: Data, conversationID: UUID) -> ToolImage? {
        let size = Self.pngSize(png) ?? (0, 0)
        return lock.withLock {
            let dir = folder(conversationID)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let n = (Self.figureNumbers(in: dir).max() ?? 0) + 1
            let id = Self.figurePrefix + String(n)
            let file = conversationID.uuidString + "/" + id + ".png"
            guard (try? png.write(to: root.appendingPathComponent(file), options: .atomic)) != nil else { return nil }
            return ToolImage(id: id, width: size.0, height: size.1, file: file)
        }
    }

    /// The image with this id in the conversation, if it is stored.
    func image(id: String, conversationID: UUID) -> ToolImage? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix(Self.figurePrefix), Int(trimmed.dropFirst(Self.figurePrefix.count)) != nil else { return nil }
        let file = conversationID.uuidString + "/" + trimmed + ".png"
        guard let png = data(file: file) else { return nil }
        let size = Self.pngSize(png) ?? (0, 0)
        return ToolImage(id: trimmed, width: size.0, height: size.1, file: file)
    }

    /// Ids of the conversation's stored figures, in order.
    func figureIDs(conversationID: UUID) -> [String] {
        Self.figureNumbers(in: folder(conversationID)).sorted().map { Self.figurePrefix + String($0) }
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
    }

    func purgeCache() { dataURLs.removeAllObjects() }

    private static func figureNumbers(in dir: URL) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix(figurePrefix), name.hasSuffix(".png") else { return nil }
            return Int(name.dropFirst(figurePrefix.count).dropLast(4))
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
