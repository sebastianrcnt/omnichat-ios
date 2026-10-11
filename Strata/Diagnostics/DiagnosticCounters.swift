import Foundation
import Darwin

/// A few cheap counters the diagnostics panel reads. Everything else is measured only while the panel is open.
final class DiagnosticCounters: @unchecked Sendable {
    static let shared = DiagnosticCounters()

    struct CheckpointStats: Codable, Equatable, Sendable {
        var staticBytes = 0
        var dynamicBytes = 0
        var flushCount = 0
        var bytesWritten = 0
        var lastFlush: Date?
    }

    private let lock = NSLock()
    private var _checkpointBytes = 0
    private var _checkpointSaves = 0
    private var _recoveryAttempts = 0
    private var _recoveryActive = 0
    private var _hiddenWebViews = 0
    private var _registeredIdentifiers = 0
    private var _memoryPeak: UInt64 = 0
    private var _turnStats: [UUID: CheckpointStats] = [:]

    var checkpointBytesWritten: Int { lock.withLock { _checkpointBytes } }
    var checkpointSaves: Int { lock.withLock { _checkpointSaves } }
    var recoveryAttempts: Int { lock.withLock { _recoveryAttempts } }
    var recoveryLoopsActive: Int { lock.withLock { _recoveryActive } }
    var hiddenWebViews: Int { lock.withLock { _hiddenWebViews } }
    var registeredBackgroundIdentifiers: Int { lock.withLock { _registeredIdentifiers } }

    func beginTurn(conversation: UUID) { lock.withLock { _turnStats[conversation] = CheckpointStats() } }

    func checkpointStats(for conversation: UUID) -> CheckpointStats? { lock.withLock { _turnStats[conversation] } }

    /// One checkpoint write. `staticBytes` is nil when the large half was not rewritten.
    func recordCheckpointWrite(conversation: UUID, staticBytes: Int?, dynamicBytes: Int, at date: Date = .now) {
        lock.withLock {
            let written = (staticBytes ?? 0) + dynamicBytes
            _checkpointBytes += written
            _checkpointSaves += 1
            var s = _turnStats[conversation] ?? CheckpointStats()
            if let staticBytes { s.staticBytes = staticBytes }
            s.dynamicBytes = dynamicBytes
            s.flushCount += 1
            s.bytesWritten += written
            s.lastFlush = date
            _turnStats[conversation] = s
        }
    }

    func forget(conversation: UUID) { lock.withLock { _turnStats[conversation] = nil } }

    func recoveryWaitStarted() { lock.withLock { _recoveryAttempts += 1; _recoveryActive += 1 } }
    func recoveryWaitEnded() { lock.withLock { _recoveryActive = max(0, _recoveryActive - 1) } }
    func webViewCreated() { lock.withLock { _hiddenWebViews += 1 } }
    func webViewDisposed() { lock.withLock { _hiddenWebViews = max(0, _hiddenWebViews - 1) } }
    func backgroundIdentifierRegistered() { lock.withLock { _registeredIdentifiers += 1 } }

    /// The highest footprint seen, for devices that do not report a peak.
    func notePeak(_ footprint: UInt64) -> UInt64 {
        lock.withLock { _memoryPeak = max(_memoryPeak, footprint); return _memoryPeak }
    }
}

/// The app's memory use as the system accounts for it (the number jetsam looks at).
enum ProcessMemory {
    struct Snapshot: Codable, Equatable, Sendable {
        var footprintBytes: UInt64
        var peakBytes: UInt64
        var availableBytes: UInt64
    }

    static func snapshot() -> Snapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
        let ledgerPeak = result == KERN_SUCCESS ? UInt64(info.ledger_phys_footprint_peak) : 0
        let peak = max(ledgerPeak, DiagnosticCounters.shared.notePeak(footprint))
        return Snapshot(footprintBytes: footprint, peakBytes: peak, availableBytes: UInt64(os_proc_available_memory()))
    }
}

/// Sizes of files on disk.
enum DiskUsage {
    struct Size: Codable, Equatable, Sendable {
        var files = 0
        var bytes: Int64 = 0
    }

    /// A file, or every file below a directory.
    static func size(of url: URL, fileManager fm: FileManager = .default) -> Size {
        var result = Size()
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        func add(_ file: URL) {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return }
            result.files += 1
            result.bytes += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return result }
        if !isDirectory.boolValue { add(url); return result }
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: []) {
            for case let file as URL in walker { add(file) }
        }
        return result
    }

    /// The SwiftData store (database, write-ahead log and shared memory files) and its external-storage directory.
    static func swiftDataStore(in root: URL, fileManager fm: FileManager = .default) -> (store: Size, external: Size) {
        var store = Size()
        var external = Size()
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.contains(".store") {
                let s = size(of: entry, fileManager: fm)
                store.files += s.files; store.bytes += s.bytes
            } else if name.hasSuffix("_SUPPORT") {
                let s = size(of: entry.appendingPathComponent("_EXTERNAL_DATA"), fileManager: fm)
                external.files += s.files; external.bytes += s.bytes
            }
        }
        return (store, external)
    }
}
