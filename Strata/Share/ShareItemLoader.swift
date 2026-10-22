#if os(iOS)
import UIKit
import UniformTypeIdentifiers

// Shared by the share extension and the app's tests.

/// Reads an extension item's attachments into links, texts, downscaled images and file copies in the share's folder.
/// On the main actor with the providers; decoding and copying run off it.
@MainActor
struct ShareItemLoader {
    let folder: URL
    let maxImages: Int
    let maxFileBytes: Int64

    private(set) var links: [SharePayload.Link] = []
    private(set) var texts: [String] = []
    private(set) var images: [ShareComposeModel.SharedImage] = []
    private(set) var files: [ShareComposeModel.SharedFile] = []
    private(set) var skipped = 0

    init(folder: URL, maxImages: Int, maxFileBytes: Int64) {
        self.folder = folder
        self.maxImages = maxImages
        self.maxFileBytes = maxFileBytes
    }

    mutating func load(_ provider: NSItemProvider) async {
        do {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                try await loadFile(provider, type: .pdf)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                try await loadImage(provider)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let url = try await Self.object(NSURL.self, from: provider) as URL
                if url.isFileURL { try await addFile(at: url) } else { addLink(url, title: nil) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if provider.canLoadObject(ofClass: NSString.self) {
                    addText(try await Self.object(NSString.self, from: provider) as String)
                } else {
                    let item = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
                    if let url = item as? URL, url.isFileURL { try await addFile(at: url) }
                    else if let data = item as? Data, let text = String(data: data, encoding: .utf8) { addText(text) }
                    else { throw Skip() }
                }
            } else if let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .data) }) {
                try await loadFile(provider, type: type)
            } else {
                throw Skip()
            }
        } catch {
            skipped += 1
        }
    }

    /// Text that is only a link counts as the link; text that repeats a link or another text is dropped.
    mutating func addText(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains(where: \.isWhitespace), let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host() != nil {
            addLink(url, title: nil)
            return
        }
        guard !texts.contains(text), !links.contains(where: { $0.url.absoluteString == text || $0.title == text }) else { return }
        texts.append(text)
    }

    mutating func addLink(_ url: URL, title: String?) {
        guard !links.contains(where: { $0.url == url }) else { return }
        links.append(SharePayload.Link(url: url, title: title))
    }

    /// A text that turned out to be a shared link's title becomes its title.
    mutating func finish() {
        guard links.count == 1, links[0].title == nil, texts.count == 1, texts[0].count < 200, !texts[0].contains("\n") else { return }
        links[0].title = texts.removeFirst()
    }

    private mutating func loadImage(_ provider: NSItemProvider) async throws {
        guard images.count < maxImages else { throw Skip() }
        let limit = maxFileBytes
        let jpeg: Data
        do {
            // Provider URLs may disappear as soon as this callback returns. Downsample while the file is valid.
            jpeg = try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    guard let url else { continuation.resume(throwing: NoFileRepresentation()); return }
                    guard let data = ImageProcessor.jpegData(fromFile: url, maxBytes: limit) else {
                        continuation.resume(throwing: Skip()); return
                    }
                    continuation.resume(returning: data)
                }
            }
        } catch is NoFileRepresentation {
            // Some providers only vend UIImage. Resize before encoding; never make a full-resolution PNG copy.
            let item = try await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
            switch item {
            case let url as URL:
                try await addImage(at: url)
                return
            case let data as Data:
                guard Int64(data.count) <= limit,
                      let result = await Task.detached(priority: .userInitiated, operation: { ImageProcessor.jpegData(from: data) }).value else { throw Skip() }
                jpeg = result
            case let image as UIImage:
                let pixels = image.size.width * image.scale * image.size.height * image.scale
                guard pixels.isFinite, pixels > 0, pixels <= Double(limit) / 4,
                      let result = ImageProcessor.jpegData(from: image) else { throw Skip() }
                jpeg = result
            default: throw Skip()
            }
        }
        try await storeImage(jpeg)
    }

    private mutating func addImage(at url: URL) async throws {
        guard images.count < maxImages else { throw Skip() }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let limit = maxFileBytes
        guard let jpeg = await Task.detached(priority: .userInitiated, operation: {
            ImageProcessor.jpegData(fromFile: url, maxBytes: limit)
        }).value else { throw Skip() }
        try await storeImage(jpeg)
    }

    private mutating func storeImage(_ jpeg: Data) async throws {
        let name = "image-\(images.count + 1).jpg"
        let target = folder.appending(path: name)
        let thumbnail = try await Task.detached(priority: .userInitiated) { () throws -> CGImage? in
            try jpeg.write(to: target)
            return ImageProcessor.thumbnailData(from: jpeg).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }.value
        images.append(.init(storedName: name, thumbnail: thumbnail))
    }

    private mutating func loadFile(_ provider: NSItemProvider, type: UTType) async throws {
        let item = try await provider.loadItem(forTypeIdentifier: type.identifier)
        if let url = item as? URL, url.isFileURL {
            try await addFile(at: url, name: provider.suggestedName)
        } else if let data = item as? Data {
            let ext = type.preferredFilenameExtension.map { "." + $0 } ?? ""
            let name = (provider.suggestedName ?? String(localized: "Shared file")) + (provider.suggestedName?.contains(".") == true ? "" : ext)
            try store(data: data, name: name, type: type)
        } else {
            throw Skip()
        }
    }

    private mutating func addFile(at url: URL, name: String? = nil) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        guard let size, size <= maxFileBytes else { throw Skip() }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image), !type.conforms(to: .pdf) {
            try await addImage(at: url)
            return
        }
        let stored = "file-\(files.count + 1)" + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
        try FileManager.default.copyItem(at: url, to: folder.appending(path: stored))
        files.append(.init(file: .init(name: name ?? url.lastPathComponent, storedName: stored, kind: Self.kind(type)), byteCount: size))
    }

    private mutating func store(data: Data, name: String, type: UTType) throws {
        guard Int64(data.count) <= maxFileBytes else { throw Skip() }
        let ext = type.preferredFilenameExtension.map { "." + $0 } ?? ""
        let stored = "file-\(files.count + 1)\(ext)"
        try data.write(to: folder.appending(path: stored))
        files.append(.init(file: .init(name: name, storedName: stored, kind: Self.kind(type)), byteCount: Int64(data.count)))
    }

    static func kind(_ type: UTType) -> SharePayload.File.Kind {
        if type.identifier == "cc.coolservices.openchat.package" || type.preferredFilenameExtension == "ocpkg" { return .package }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) { return .text }
        return .other
    }

    /// `loadObject`, which decodes what `loadItem` may hand over as archived data (a link arrives as a bplist).
    private static func object<T: NSItemProviderReading & NSObject>(_ type: T.Type, from provider: NSItemProvider) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            _ = provider.loadObject(ofClass: type) { object, error in
                if let object = object as? T { nonisolated(unsafe) let o = object; c.resume(returning: o) }
                else { c.resume(throwing: error ?? Skip()) }
            }
        }
    }

    private struct Skip: Error {}
    private struct NoFileRepresentation: Error {}
}
#endif
