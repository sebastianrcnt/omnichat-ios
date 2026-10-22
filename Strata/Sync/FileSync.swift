import Foundation
import SwiftData

/// A file a synced chat shows, in the synced store: a figure `run_python` saved (`ToolImageStore`) or an artifact page
/// and its chat's index (`ArtifactStore`). The stores keep reading their folders; this carries the bytes to other
/// devices, where `FileSync` writes them back into the same folders. Browser screenshots stay on the device that took
/// them (they are many and large, and a chat shows a placeholder without them).
/// CloudKit rules apply (see `Conversation.swift`); `SyncDedupe` keeps one record per path.
@Model
final class SyncedFile {
    /// `<area>/<conversation id>/<file name>`, relative to Application Support (`FileSync.areas`).
    var path: String = ""
    var conversationID: UUID?
    @Attribute(.externalStorage) var data: Data?
    var updatedAt: Date = Date.now
    /// The device that first wrote it (`DeviceIdentity`); it never changes, so dedupe picks the same copy everywhere.
    var origin: String?

    init(path: String, conversationID: UUID?, data: Data, origin: String = DeviceIdentity.current) {
        self.path = path
        self.conversationID = conversationID
        self.data = data
        self.origin = origin
    }
}

/// Where the file stores report what they write and remove: `FileSync` while sync runs, nobody in tests.
protocol FileMirroring: AnyObject, Sendable {
    func wrote(_ data: Data, area: String, conversationID: UUID, name: String)
    func removedAll(area: String, conversationID: UUID)
}

enum FileMirror {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: (any FileMirroring)?

    static var handler: (any FileMirroring)? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Writes the files of `FileMirror` reports into the synced store, and the store's files that are missing (or older)
/// on this device into their folders.
final class FileSync: FileMirroring, @unchecked Sendable {
    static let toolImages = "ToolImages"
    static let artifacts = "Artifacts"
    static let areas: Set<String> = [toolImages, artifacts]
    static let migratedKey = "sync.filesMigrated.v1"

    let container: ModelContainer
    let root: URL
    private let queue = DispatchQueue(label: "cc.coolservices.strata.filesync", qos: .utility)

    init(container: ModelContainer,
         root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        self.container = container
        self.root = root
    }

    /// The synced path of a file, or nil when it is not one that syncs.
    static func path(area: String, conversationID: UUID, name: String) -> String? {
        guard areas.contains(area), !name.isEmpty, !name.contains("/"), !name.contains(".."),
              area != toolImages || name.hasPrefix(ToolImageStore.figurePrefix) else { return nil }
        return "\(area)/\(conversationID.uuidString)/\(name)"
    }

    /// The local file of a synced path; nil for a path that names anything else.
    func localURL(_ path: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let id = UUID(uuidString: parts[1]),
              Self.path(area: parts[0], conversationID: id, name: parts[2]) == path else { return nil }
        return root.appendingPathComponent(parts[0], isDirectory: true)
            .appendingPathComponent(parts[1], isDirectory: true).appendingPathComponent(parts[2])
    }

    // MARK: FileMirroring

    func wrote(_ data: Data, area: String, conversationID: UUID, name: String) {
        guard let path = Self.path(area: area, conversationID: conversationID, name: name) else { return }
        queue.async { [container] in
            let context = ModelContext(container)
            let existing = (try? context.fetch(FetchDescriptor<SyncedFile>(predicate: #Predicate { $0.path == path }))) ?? []
            for record in existing where record.data != data {
                record.data = data
                record.updatedAt = .now
            }
            if existing.isEmpty { context.insert(SyncedFile(path: path, conversationID: conversationID, data: data)) }
            try? context.save()
        }
    }

    func removedAll(area: String, conversationID: UUID) {
        let prefix = "\(area)/\(conversationID.uuidString)/"
        queue.async { [container] in
            let context = ModelContext(container)
            let id: UUID? = conversationID
            let records = (try? context.fetch(FetchDescriptor<SyncedFile>(predicate: #Predicate { $0.conversationID == id }))) ?? []
            for record in records where record.path.hasPrefix(prefix) { context.delete(record) }
            try? context.save()
        }
    }

    /// Returns once the writes reported so far are in the store (tests).
    func waitForPendingWork() { queue.sync {} }

    // MARK: Store to disk

    /// Writes each synced file that is missing here, or that another device changed after this copy was written.
    func materialize(completion: (@Sendable (Int) -> Void)? = nil) {
        queue.async { [self] in
            let written = materializeNow()
            completion?(written)
        }
    }

    @discardableResult
    func materializeNow() -> Int {
        let context = ModelContext(container)
        _ = try? SyncDedupe.files(context)
        let records = (try? context.fetch(FetchDescriptor<SyncedFile>())) ?? []
        var written = 0
        for record in records {
            guard let url = localURL(record.path) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified {
                // Figures never change once written. An artifact page or index changed after this copy was written
                // replaces it when the bytes differ (this device's own upload is a little newer than its file).
                guard !record.path.hasPrefix(Self.toolImages + "/"), record.updatedAt > modified.addingTimeInterval(1),
                      let data = record.data, data != (try? Data(contentsOf: url)) else { continue }
            }
            guard let data = record.data else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? data.write(to: url, options: .atomic)) != nil {
                // The file is dated by the version it holds, not when it arrived: a newer version that syncs in late
                // (made before this copy was downloaded) must still replace it.
                try? FileManager.default.setAttributes([.modificationDate: record.updatedAt], ofItemAtPath: url.path)
                written += 1
            }
        }
        return written
    }

    // MARK: Disk to store, once

    /// The figures and artifacts saved before sync, of chats that still exist, become records once.
    func migrateExisting(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        queue.async { [self] in
            let context = ModelContext(container)
            let chats = Set(((try? context.fetch(FetchDescriptor<Conversation>())) ?? []).map(\.id))
            let known = Set(((try? context.fetch(FetchDescriptor<SyncedFile>())) ?? []).map(\.path))
            var pending = 0
            for area in Self.areas.sorted() {
                let folder = root.appendingPathComponent(area, isDirectory: true)
                for chat in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                    guard let id = UUID(uuidString: chat), chats.contains(id) else { continue }
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(chat).path)) ?? []
                    for name in names.sorted() {
                        guard let path = Self.path(area: area, conversationID: id, name: name), !known.contains(path),
                              let url = localURL(path), let data = try? Data(contentsOf: url) else { continue }
                        context.insert(SyncedFile(path: path, conversationID: id, data: data))
                        pending += 1
                        if pending % 20 == 0 { try? context.save() }
                    }
                }
            }
            if (try? context.save()) != nil { defaults.set(true, forKey: Self.migratedKey) }
        }
    }
}
