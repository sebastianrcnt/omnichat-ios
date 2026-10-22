import Foundation

/// A package read into memory: its files (normalized), its manifest, and what its signature says. Made from a zip, a
/// folder or a dictionary of files; `load` checks everything format 1 asks before anything is installed.
public struct PackageBundle: Sendable {
    public var files: [String: Data]
    public var manifest: PackageManifest
    /// Keys the format doesn't know, ignored (shown in the review sheet).
    public var warnings: [String]
    public var verification: Verification

    public enum Verification: Sendable, Equatable {
        case unsigned
        /// Signed; the keys from the original to the one that signed, newest last.
        case signed(keys: [PackageKey])

        public var signingKey: PackageKey? { if case .signed(let keys) = self { keys.last } else { nil } }
        public var keys: [PackageKey] { if case .signed(let keys) = self { keys } else { [] } }
    }

    /// SHA-256 of CHECKSUMS (made from the files when the package has none): one version's identity.
    public var digest: String { PackageChecksums.sha256Hex(Data(checksums.utf8)) }

    public var checksums: String {
        files[PackageChecksums.fileName].map { String(decoding: $0, as: UTF8.self) } ?? PackageChecksums.make(files)
    }

    /// Extensions treated as text: normalized to LF and NFC, as their checksums expect.
    public static let textExtensions: Set<String> = ["json", "md", "txt", "js", "mjs", "openui", "html", "css", "csv", "yaml", "yml"]
    public static let iconLimit = 64 * 1024

    public static func load(zip data: Data, limits: PackageArchive.Limits = .init()) throws -> PackageBundle {
        try load(files: try PackageArchive.read(data, limits: limits))
    }

    /// A folder on disk (developer mode, built-in packages, the CLI). Hidden files are skipped; links are refused.
    public static func load(folder: URL, limits: PackageArchive.Limits = .init()) throws -> PackageBundle {
        try load(files: try readFolder(folder, limits: limits))
    }

    public static func readFolder(_ folder: URL, limits: PackageArchive.Limits = .init()) throws -> [String: Data] {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else {
            throw PackageError.archive("\(folder.lastPathComponent) can't be read.")
        }
        var files: [String: Data] = [:]
        var total = 0
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if values.isDirectory == true { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.path.count + 1))
            if values.isSymbolicLink == true { throw PackageError.archive("\(path) is a symbolic link; packages can't hold links.") }
            guard values.isRegularFile == true else { continue }
            try PackageArchive.checkPath(path)
            let data = try Data(contentsOf: url)
            total += data.count
            guard total <= limits.unzipped else { throw PackageError.archive("The package is larger than \(limits.unzipped / 1024 / 1024) MB.") }
            files[path] = data
            guard files.count <= limits.files else { throw PackageError.archive("The package has more than \(limits.files) files.") }
        }
        return files
    }

    /// Normalizes, decodes, validates and verifies. Throws the first problem.
    public static func load(files raw: [String: Data]) throws -> PackageBundle {
        var files: [String: Data] = [:]
        for (path, data) in raw {
            try PackageArchive.checkPath(path)
            try refuseCode(path: path, data: data)
            files[path] = try normalized(path: path, data: data)
        }
        guard let manifestData = files["manifest.json"] else {
            throw PackageError.invalid("The package has no manifest.json at its top level.")
        }
        let manifest = try PackageManifest.decode(manifestData)
        try manifest.validate(files: files)
        if let icon = files["icon.png"], icon.count > iconLimit { throw PackageError.invalid("icon.png is larger than 64 KB.") }
        let verification = try verify(files: files, manifest: manifest)
        return PackageBundle(files: files, manifest: manifest, warnings: PackageManifest.warnings(manifestData), verification: verification)
    }

    static func verify(files: [String: Data], manifest: PackageManifest) throws -> Verification {
        let checksums = files[PackageChecksums.fileName]
        if let checksums { try PackageChecksums.verify(String(decoding: checksums, as: UTF8.self), files: files) }
        // Without a signature it is unsigned, whatever publisher.key says.
        guard let signature = files[PackageSignature.fileName] else { return .unsigned }
        guard let checksums else { throw PackageError.signature("The package has a SIGNATURE but no CHECKSUMS.") }
        let keys = try PackageSignature.decode(signature).verify(checksums: checksums)
        guard let declared = manifest.publisher?.key else {
            throw PackageError.signature("The package is signed, but manifest.json has no publisher.key.")
        }
        let key = try PackageKey(declared)
        guard key == keys.first || key == keys.last else {
            throw PackageError.signature("publisher.key in manifest.json is not the key that signed the package.")
        }
        return .signed(keys: keys)
    }

    /// Text files as LF and NFC; refuses text that isn't UTF-8.
    static func normalized(path: String, data: Data) throws -> Data {
        let ext = (path as NSString).pathExtension.lowercased()
        guard textExtensions.contains(ext) || path == PackageChecksums.fileName || path == PackageSignature.fileName else { return data }
        guard let text = String(data: data, encoding: .utf8) else { throw PackageError.archive("\(path) is not UTF-8 text.") }
        return Data(PackageRender.normalize(text).utf8)
    }

    /// No native code or WebAssembly, by content as well as by name.
    static func refuseCode(path: String, data: Data) throws {
        let ext = (path as NSString).pathExtension.lowercased()
        let magic = [UInt8](data.prefix(4))
        let machO: [[UInt8]] = [[0xfe, 0xed, 0xfa, 0xce], [0xfe, 0xed, 0xfa, 0xcf], [0xce, 0xfa, 0xed, 0xfe], [0xcf, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe]]
        if ["dylib", "so", "wasm", "exe", "dll", "framework", "bundle", "app"].contains(ext) || path.contains(".framework/")
            || machO.contains(magic) || magic == [0x00, 0x61, 0x73, 0x6d] {
            throw PackageError.archive("\(path) is native code or WebAssembly, which packages can't contain.")
        }
    }

    /// The text of a file, if it is one.
    public func text(_ path: String) -> String? { files[path].flatMap { String(data: $0, encoding: .utf8) } }

    public var promptText: String? { manifest.contents?.prompt.flatMap(text) }

    /// The package's skills, in manifest order.
    public var skills: [PackageSkill] { manifest.skillFiles.compactMap { text($0).flatMap(PackageSkill.parse) } }

    /// The tools this version runs (kinds it doesn't know were marked optional and are skipped).
    public var usableTools: [PackageTool] { manifest.tools.filter { PackageTool.kinds.contains($0.kind) } }

    /// The prompt section with this package's own name and namespace (see `PackageRender.promptSection`).
    public func promptSection(namespace: String? = nil) -> String {
        PackageRender.promptSection(name: manifest.name, namespace: namespace ?? manifest.namespace, hasTools: !usableTools.isEmpty,
                                    prompt: promptText, skills: skills.map { ($0.name, $0.description) })
    }

    /// Writes the files to a folder (made if needed).
    public func write(to folder: URL) throws {
        for (path, data) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    /// The files with a fresh CHECKSUMS (and no SIGNATURE): what `omnichat-pkg pack` writes before signing.
    public static func packed(_ files: [String: Data]) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for (path, data) in files where path != PackageChecksums.fileName && path != PackageSignature.fileName {
            try PackageArchive.checkPath(path)
            out[path] = try normalized(path: path, data: data)
        }
        out[PackageChecksums.fileName] = Data(PackageChecksums.make(out).utf8)
        return out
    }
}
