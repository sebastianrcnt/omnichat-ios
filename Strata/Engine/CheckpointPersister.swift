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
/// - A write that fails leaves the checkpoint dirty. At a new round's submission, a tool-result boundary or the start
///   of a call that can act outside the app (`TurnCheckpoint.startedCalls`) the
///   failure is thrown to the runner, which stops rather than send a request (or move past a result) that a restart
///   couldn't find again; a failed throttled write is retried with the next one.
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
    private let write: (Snapshot) throws -> Void
    private let autoTrailing: Bool
    private var latest: TurnCheckpoint?
    private var dirty = false
    private var lastKey: CheckpointStaticKey?
    private var lastFlushAt: TimeInterval?
    private var lastStreamDone = false
    private var lastRecords = 0
    private var lastPending = 0
    private var lastStarted = 0
    private var trailing: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var closed = false
    private let center: NotificationCenter

    init(minInterval: TimeInterval = 1,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         center: NotificationCenter = .default,
         autoTrailing: Bool = true,
         encodeStatic: @escaping (TurnCheckpoint) throws -> Data = { try TurnCheckpoint.encodeStatic($0) },
         write: @escaping (Snapshot) throws -> Void) {
        self.minInterval = minInterval
        self.now = now
        self.autoTrailing = autoTrailing
        self.encodeStatic = encodeStatic
        self.write = write
        self.center = center
        for name in AppLifecycle.checkpointTriggers {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { try? self?.flush() }
            })
        }
    }

    /// Records the newest checkpoint and writes it now or later, per the policy above. Throws when a new round's
    /// request or a tool result could not be written.
    func update(_ checkpoint: TurnCheckpoint) throws {
        guard !closed, checkpoint.isPersistable else { return }
        latest = checkpoint
        dirty = true
        let t = now()
        let boundary = checkpoint.staticKey != lastKey
            || checkpoint.records.count != lastRecords || (checkpoint.pendingResults?.count ?? 0) != lastPending
            || (checkpoint.startedCalls?.count ?? 0) != lastStarted
        if boundary {
            try flush()
        } else if checkpoint.streamDone != lastStreamDone || lastFlushAt == nil || t - (lastFlushAt ?? 0) >= minInterval {
            try? flush()
        } else if autoTrailing, trailing == nil {
            let delay = max(0.01, minInterval - (t - (lastFlushAt ?? t)))
            trailing = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.trailing = nil
                try? self?.flush()
            }
        }
    }

    /// Writes the newest checkpoint if it has not been written yet. Throws `CheckpointWriteError` when it can't be
    /// encoded or the write fails; it then stays dirty.
    func flush() throws {
        guard !closed, dirty, let checkpoint = latest else { return }
        trailing?.cancel()
        trailing = nil
        var staticData: Data?
        let key = checkpoint.staticKey
        if key != lastKey {
            // A new round's request that can't be encoded must not be paired with the previous round's body: write
            // nothing (and stay dirty) rather than a dynamic half that would replay against the wrong request.
            guard let encoded = try? encodeStatic(checkpoint) else { throw CheckpointWriteError() }
            staticData = encoded
        }
        guard let dynamicData = try? JSONEncoder().encode(checkpoint.dynamicPart) else { throw CheckpointWriteError() }
        if staticData != nil { staticEncodeCount += 1 }
        // Clean only once it is on disk: a failed write keeps the round's request to write again.
        do {
            try write(Snapshot(checkpoint: checkpoint, staticData: staticData, dynamicData: dynamicData))
        } catch {
            throw CheckpointWriteError()
        }
        dirty = false
        if staticData != nil { lastKey = key }
        lastStreamDone = checkpoint.streamDone
        lastRecords = checkpoint.records.count
        lastPending = checkpoint.pendingResults?.count ?? 0
        lastStarted = checkpoint.startedCalls?.count ?? 0
        lastFlushAt = now()
        writeCount += 1
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

/// A turn's checkpoint could not be saved, so the turn stops instead of sending what a restart couldn't recover.
struct CheckpointWriteError: Error, LocalizedError, Equatable {
    var errorDescription: String? {
        String(localized: "This reply couldn't be saved on this device, so it stopped before going further. Free up some storage and try again.")
    }
}
