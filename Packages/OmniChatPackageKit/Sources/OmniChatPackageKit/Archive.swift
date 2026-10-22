import Foundation
import Compression

/// Reads and writes the zip files `.ocpkg` packages are: stored or deflated entries, no encryption, no zip64. Reading
/// checks every path (relative, no `..`, no symlinks) and the size and count limits before anything is inflated.
public enum PackageArchive {
    public struct Limits: Sendable {
        public var zipped = 5 * 1024 * 1024
        public var unzipped = 15 * 1024 * 1024
        public var files = 200
        public init() {}
    }

    /// The files of a zip, by path. Folders, `__MACOSX/` and `.DS_Store` are skipped; a zip of a folder (everything
    /// under one top folder holding manifest.json) is read as the folder's contents.
    public static func read(_ data: Data, limits: Limits = Limits()) throws -> [String: Data] {
        guard data.count <= limits.zipped else {
            throw PackageError.archive("The package is larger than \(limits.zipped / 1024 / 1024) MB.")
        }
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // The end of central directory record: within the last 64 KB (its comment can be that long).
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 22 - 65_535) {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw PackageError.archive("The package is not a zip file.") }
        let count = u16(eocd + 10)
        let dirSize = u32(eocd + 12)
        var p = u32(eocd + 16)
        guard count <= limits.files * 2 + 50 else { throw PackageError.archive("The package has more than \(limits.files) files.") }
        guard p >= 0, p + dirSize <= eocd else { throw PackageError.archive("The zip's directory is damaged.") }

        struct Entry { var name: String; var method: Int; var crc: UInt32; var compressed: Int; var size: Int; var offset: Int }
        var entries: [Entry] = []
        var total = 0
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x02014b50 else { throw PackageError.archive("The zip's directory is damaged.") }
            let madeBy = u16(p + 4) >> 8
            let flags = u16(p + 8)
            let method = u16(p + 10)
            let crc = UInt32(u32(p + 16))
            let compressed = u32(p + 20)
            let size = u32(p + 24)
            let nameLength = u16(p + 28), extraLength = u16(p + 30), commentLength = u16(p + 32)
            let external = u32(p + 38)
            let offset = u32(p + 42)
            guard p + 46 + nameLength <= bytes.count, let name = String(bytes: bytes[(p + 46)..<(p + 46 + nameLength)], encoding: .utf8) else {
                throw PackageError.archive("A file name in the package is not UTF-8.")
            }
            p += 46 + nameLength + extraLength + commentLength
            if name.hasSuffix("/") || name.hasPrefix("__MACOSX/") || name.split(separator: "/").last == ".DS_Store" { continue }
            if flags & 1 != 0 { throw PackageError.archive("\(name) is encrypted; packages can't be.") }
            if compressed == 0xFFFF_FFFF || size == 0xFFFF_FFFF { throw PackageError.archive("Zip64 archives aren't supported.") }
            if madeBy == 3, (external >> 16) & 0o170000 == 0o120000 { throw PackageError.archive("\(name) is a symbolic link; packages can't hold links.") }
            guard method == 0 || method == 8 else { throw PackageError.archive("\(name) uses a compression other than deflate.") }
            try checkPath(name)
            total += size
            guard total <= limits.unzipped else {
                throw PackageError.archive("The package unpacks to more than \(limits.unzipped / 1024 / 1024) MB.")
            }
            entries.append(Entry(name: name, method: method, crc: crc, compressed: compressed, size: size, offset: offset))
        }
        guard entries.count <= limits.files else { throw PackageError.archive("The package has more than \(limits.files) files.") }

        var files: [String: Data] = [:]
        for e in entries {
            guard e.offset + 30 <= bytes.count, u32(e.offset) == 0x04034b50 else { throw PackageError.archive("\(e.name) is damaged.") }
            let start = e.offset + 30 + u16(e.offset + 26) + u16(e.offset + 28)
            guard start + e.compressed <= bytes.count else { throw PackageError.archive("\(e.name) is damaged.") }
            let raw = Data(bytes[start..<(start + e.compressed)])
            let content = e.method == 0 ? raw : try inflate(raw, size: e.size, name: e.name)
            guard content.count == e.size, CRC32.checksum(content) == e.crc else { throw PackageError.archive("\(e.name) is damaged.") }
            guard files.updateValue(content, forKey: e.name) == nil else { throw PackageError.archive("\(e.name) is in the package twice.") }
        }
        return unwrapFolder(files)
    }

    /// Packages are made of relative UTF-8 paths without `..`, empty parts or backslashes.
    public static func checkPath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"), path.utf8.count <= 255,
              parts.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }) else {
            throw PackageError.archive("\(path) is not an allowed path: use relative paths without .. or a leading /.")
        }
    }

    /// `acme/manifest.json`, `acme/prompt.md` → `manifest.json`, `prompt.md`.
    static func unwrapFolder(_ files: [String: Data]) -> [String: Data] {
        guard files["manifest.json"] == nil else { return files }
        let tops = Set(files.keys.compactMap { $0.split(separator: "/").first.map(String.init) })
        guard tops.count == 1, let top = tops.first, files["\(top)/manifest.json"] != nil else { return files }
        return Dictionary(uniqueKeysWithValues: files.map { (String($0.key.dropFirst(top.count + 1)), $0.value) })
    }

    static func inflate(_ data: Data, size: Int, name: String) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw PackageError.archive("\(name) is damaged (it doesn't inflate to its size).") }
        return out
    }

    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var out = Data(count: data.count + 64)
        let capacity = out.count
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return nil }
        return out.prefix(written)
    }

    /// A zip of `files`, sorted by path, with a fixed date, so the same files always make the same bytes.
    public static func write(_ files: [String: Data]) -> Data {
        var out = Data()
        var directory = Data()
        func le16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xff)); d.append(UInt8(v >> 8 & 0xff)) }
        func le32(_ v: Int, _ d: inout Data) { le16(v & 0xffff, &d); le16(v >> 16 & 0xffff, &d) }
        let dosTime = 0, dosDate = (0 << 9) | (1 << 5) | 1 // 1980-01-01 00:00
        for path in files.keys.sorted(by: JSONValue.byteOrder) {
            let content = files[path]!
            let packed = deflate(content)
            let body = packed ?? content
            let method = packed == nil ? 0 : 8
            let crc = Int(CRC32.checksum(content))
            let name = Data(path.utf8)
            let offset = out.count
            le32(0x04034b50, &out); le16(20, &out); le16(0x0800, &out); le16(method, &out); le16(dosTime, &out); le16(dosDate, &out)
            le32(crc, &out); le32(body.count, &out); le32(content.count, &out); le16(name.count, &out); le16(0, &out)
            out.append(name); out.append(body)
            le32(0x02014b50, &directory); le16(0x031E, &directory); le16(20, &directory); le16(0x0800, &directory)
            le16(method, &directory); le16(dosTime, &directory); le16(dosDate, &directory)
            le32(crc, &directory); le32(body.count, &directory); le32(content.count, &directory)
            le16(name.count, &directory); le16(0, &directory); le16(0, &directory); le16(0, &directory); le16(0, &directory)
            le32(0o100644 << 16, &directory); le32(offset, &directory)
            directory.append(name)
        }
        let dirOffset = out.count
        out.append(directory)
        le32(0x06054b50, &out); le16(0, &out); le16(0, &out); le16(files.count, &out); le16(files.count, &out)
        le32(directory.count, &out); le32(dirOffset, &out); le16(0, &out)
        return out
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
