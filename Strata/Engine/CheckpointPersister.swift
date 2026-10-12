import Foundation
import Foundation

/// Writes a running turn's checkpoint to disk without re-encoding the history on every streamed event.
///
/// - The static part (the exact request body, which already holds the whole history) is encoded once per round,
///   when its fingerprint changes, and the encoded bytes are reused. A round is persisted when its request is
///   submitted, not before: until then the previous round's checkpoint still recovers the turn.
/// - The dynamic part (cursor, accumulator, finished tool results) is small. It is written at most once per `minInterval`, and at once
///   when the stream completes, a tool boundary is reached, or the app leaves the foreground.
/// - Every write carries the whole dynamic part, so the persisted cursor and accumulator are always a matching pair.
///   A slightly stale pair is safe: the server replays from `lastSequence` and duplicates are dropped.
@MainActor
final class CheckpointPersister {
    struct Snapshot {
        var checkpoint: TurnCheckpoint
        /// Set only when the static part changed since the previous write.
        var staticData: Data?
        var dynamicData: Data
    }

    var minInterval: TimeInterval
    private(set) var staticEncodeCount = 0
    private(set) var writeCount = 0

    private let now: () -> TimeInterval
    private let encodeStatic: (TurnCheckpoint) throws -> Data
    private let write: (Snapshot) -> Void
    private let autoTrailing: Bool
    private var latest: TurnCheckpoint?
    private var dirty = false
    private var lastKey: CheckpointStaticKey?
    private var lastFlushAt: TimeInterval?
    private var lastStreamDone = false
    private var lastRecords = 0
    private var lastPending = 0
    private var trailing: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var closed = false
    private let center: NotificationCenter

    init(minInterval: TimeInterval = 1,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         center: NotificationCenter = .default,
         autoTrailing: Bool = true,
         encodeStatic: @escaping (TurnCheckpoint) throws -> Data = { try TurnCheckpoint.encodeStatic($0) },
         write: @escaping (Snapshot) -> Void) {
        self.minInterval = minInterval
        self.now = now
        self.autoTrailing = autoTrailing
        self.encodeStatic = encodeStatic
        self.write = write
        self.center = center
        for name in AppLifecycle.checkpointTriggers {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            })
        }
    }

    /// Records the newest checkpoint and writes it now or later, per the policy above.
    func update(_ checkpoint: TurnCheckpoint) {
        guard !closed, checkpoint.isPersistable else { return }
        latest = checkpoint
        dirty = true
        let t = now()
        let structural = checkpoint.staticKey != lastKey || checkpoint.streamDone != lastStreamDone
            || checkpoint.records.count != lastRecords || (checkpoint.pendingResults?.count ?? 0) != lastPending
        if structural || lastFlushAt == nil || t - (lastFlushAt ?? 0) >= minInterval {
            flush()
        } else if autoTrailing, trailing == nil {
            let delay = max(0.01, minInterval - (t - (lastFlushAt ?? t)))
            trailing = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.trailing = nil
                self?.flush()
            }
        }
    }

    /// Writes the newest checkpoint if it has not been written yet.
    func flush() {
        guard !closed, dirty, let checkpoint = latest else { return }
        trailing?.cancel()
        trailing = nil
        dirty = false
        var staticData: Data?
        let key = checkpoint.staticKey
        if key != lastKey {
            staticData = try? encodeStatic(checkpoint)
            if staticData != nil { lastKey = key; staticEncodeCount += 1 }
        }
        guard let dynamicData = try? JSONEncoder().encode(checkpoint.dynamicPart) else { return }
        lastStreamDone = checkpoint.streamDone
        lastRecords = checkpoint.records.count
        lastPending = checkpoint.pendingResults?.count ?? 0
        lastFlushAt = now()
        writeCount += 1
        write(Snapshot(checkpoint: checkpoint, staticData: staticData, dynamicData: dynamicData))
    }

    /// Stops all further writes (the turn ended and its checkpoint was cleared).
    func close() {
        closed = true
        dirty = false
        trailing?.cancel()
        trailing = nil
        for o in observers { center.removeObserver(o) }
        observers = []
    }
}
