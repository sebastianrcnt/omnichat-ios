import Foundation
import Observation

/// A limited resource shared by the chats that run at once (the browser's pages): up to `capacity` keys hold it, the
/// rest wait in order of arrival. A key that already holds it gets in again at once, so calls of one chat never wait
/// for each other here. Waiting can be cancelled.
@MainActor
final class FairSlots {
    var capacity: Int {
        didSet { grant() }
    }
    /// How many holds each key has now.
    private var holders: [UUID: Int] = [:]
    private var waiters: [(id: UUID, key: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(capacity: Int) { self.capacity = capacity }

    /// The keys holding a slot now.
    var holderKeys: Set<UUID> { Set(holders.keys) }
    /// The keys waiting, oldest first.
    var waitingKeys: [UUID] { waiters.map(\.key) }

    /// Whether `acquire(key)` would return at once.
    func admitsNow(_ key: UUID) -> Bool {
        holders[key] != nil || (holders.count < capacity && waiters.isEmpty)
    }

    /// Waits for a slot. False when the waiting task was cancelled (it holds nothing then).
    func acquire(_ key: UUID) async -> Bool {
        if admitsNow(key) {
            holders[key, default: 0] += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) } else { waiters.append((id, key, continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let i = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                self.waiters.remove(at: i).continuation.resume(returning: false)
            }
        }
    }

    /// Gives back one hold of `key`; the next waiters get in while there is room.
    func release(_ key: UUID) {
        guard let n = holders[key] else { return }
        if n > 1 { holders[key] = n - 1 } else { holders[key] = nil }
        grant()
    }

    private func grant() {
        while let first = waiters.first, holders[first.key] != nil || holders.count < capacity {
            waiters.removeFirst()
            holders[first.key, default: 0] += 1
            first.continuation.resume(returning: true)
        }
    }
}

/// Tool calls waiting for something another chat is using (a browser slot, the Python runtime), by call id: the
/// chat's live line says what its call waits for.
@MainActor
@Observable
final class ToolWaits {
    static let shared = ToolWaits()

    enum Reason: Equatable, Sendable {
        /// Two other chats are using the browser (`BrowserSessions.maxActiveConversations`).
        case browser
        /// Another chat's Python code is running (one runtime, calls in order).
        case python

        var label: String {
            switch self {
            case .browser: String(localized: "Waiting for the browser")
            case .python: String(localized: "Waiting for Python")
            }
        }
    }

    private(set) var reasons: [String: Reason] = [:]

    func reason(for callID: String) -> Reason? { reasons[callID] }

    /// The first wait among `callIDs` (a running round's calls).
    func reason(among callIDs: [String]) -> Reason? {
        guard !reasons.isEmpty else { return nil }
        return callIDs.lazy.compactMap { self.reasons[$0] }.first
    }

    func begin(_ callID: String?, _ reason: Reason) {
        guard let callID else { return }
        reasons[callID] = reason
    }

    func end(_ callID: String?) {
        guard let callID, reasons[callID] != nil else { return }
        reasons[callID] = nil
    }
}
