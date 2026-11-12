import Foundation
import SwiftUI
import SwiftData
import Observation

/// Replies that outlive the process: telling the server to cancel, and picking up turns left pending.
extension ChatController {
    static let cancelRetryWindow: TimeInterval = 600
    /// How long after its message a cancel whose request the server doesn't know yet is kept for a later foreground.
    /// Past it, the server has no stream left for the turn.
    static let cancelLookupLifetime: TimeInterval = 3600

    func cancelOnServer(_ message: Message, endpoint: Endpoint, context: ModelContext) {
        guard cancelTasks[message.id] == nil else { return }
        guard let checkpoint = message.resumeCheckpoint,
              checkpoint.requestID != nil || (checkpoint.idempotencyKey != nil && checkpoint.submissionStarted),
              let client = streamer as? any ResumableChatStreaming else {
            message.cancelPending = false
            message.clearResume()
            try? context.save()
            return
        }
        let messageID = message.id
        let createdAt = message.createdAt
        cancelTasks[messageID] = Task { @MainActor [weak self] in
            // The chat may be deleted while this retries (deleting a chat stops its reply): the server is still told,
            // but nothing is written to a deleted message.
            func alive() -> Bool { message.modelContext != nil && !message.isDeleted }
            let lookupDeadline = Date().addingTimeInterval(30)
            // Bounded: after this long the flag stays set and the next foreground retries (restorePending).
            let giveUp = Date().addingTimeInterval(Self.cancelRetryWindow)
            while !Task.isCancelled, Date() < giveUp {
                do {
                    var id = checkpoint.requestID
                    if id == nil, let key = checkpoint.idempotencyKey {
                        id = try await client.requestID(forIdempotencyKey: key, endpoint: endpoint)
                    }
                    if let id {
                        try await client.cancel(requestID: id, endpoint: endpoint)
                    } else if Date() < lookupDeadline {
                        // The original POST may still be in gateway authentication/routing.
                        try await RecoverySignals.shared.wait(seconds: 0.5)
                        continue
                    } else if Date().timeIntervalSince(createdAt) < Self.cancelLookupLifetime {
                        // Still no request for the key: it may yet arrive (a slow upload). Nothing was cancelled, so
                        // the flag stays and the next foreground looks again (restorePending).
                        break
                    }
                    // A cancel went out, or the turn is too old for the server to still run it.
                    guard alive() else { break }
                    message.cancelPending = false
                    message.clearResume()
                    try? context.save()
                    break
                } catch {
                    try? await RecoverySignals.shared.wait(seconds: 5)
                }
            }
            self?.cancelTasks[messageID] = nil
        }
    }

    /// Called at launch and foreground. Live runs reconnect themselves; every other unfinished reply is picked up, each
    /// in its own chat (later ones queue like any send).
    func restorePending(context: ModelContext) async {
        guard !queryingPending else { return }
        queryingPending = true
        defer { queryingPending = false }
        let container = context.container
        let device = DeviceIdentity.current
        let identifiers = (try? await Task.detached(priority: .utility) {
            try PendingRecoveryQuery.identifiers(container: container, device: device)
        }.value) ?? []
        // In particular, an empty result never fetches, faults or saves on the main context.
        let messages = identifiers.filter { recoveryAttempts.isEligible($0) }.compactMap {
            context.model(for: $0) as? Message
        }
        for message in messages where message.cancelPending {
            if let conversation = message.conversation,
               let endpoint = connections.endpoint(connectionID: conversation.connectionID, modelID: conversation.modelID,
                                                   sessionID: conversation.id.uuidString) {
                cancelOnServer(message, endpoint: endpoint, context: context)
            }
        }
        var claimed = Set(runs.keys)
        for message in messages.sorted(by: { $0.createdAt < $1.createdAt })
        where message.resumeData != nil && !message.stoppedByUser && !message.cancelPending {
            guard let conversation = message.conversation, !claimed.contains(conversation.id),
                  let checkpoint = message.resumeCheckpoint else { continue }
            claimed.insert(conversation.id)
            recoveryAttempts.record(message.persistentModelID)
            generate(conversation: conversation, context: context, restoring: message, checkpoint: checkpoint)
        }
    }

    /// The checkpoint of a reply this device can still pick up (`restorePending` would), or nil.
    static func recoverableCheckpoint(_ message: Message, device: String = DeviceIdentity.current) -> TurnCheckpoint? {
        guard message.hasResume, !message.stoppedByUser, !message.cancelPending,
              message.resumeDeviceID == nil || message.resumeDeviceID == device else { return nil }
        return message.resumeCheckpoint
    }

    /// A new reply supersedes the chat's unfinished ones kept for a later reconnect (an outage keeps its checkpoint):
    /// left alone, the next foreground would resume one and run its tools on a branch no longer on screen. Each is
    /// cancelled on the server as for Stop, and its checkpoint goes.
    func retireRecoverableTurns(in conversation: Conversation, except kept: Message, context: ModelContext) {
        let device = DeviceIdentity.current
        let stale = conversation.messages.filter {
            $0.id != kept.id && $0.hasResume && !$0.cancelPending && ($0.resumeDeviceID == nil || $0.resumeDeviceID == device)
        }
        guard !stale.isEmpty else { return }
        let endpoint = connections.endpoint(connectionID: conversation.connectionID, modelID: conversation.modelID,
                                            sessionID: conversation.id.uuidString)
        for message in stale {
            if let endpoint, message.resumeData != nil {
                message.cancelPending = true
                cancelOnServer(message, endpoint: endpoint, context: context)
            } else {
                message.clearResume()
            }
        }
    }

}

/// Only identifiers cross the executor boundary. The legacy flag migration also runs in this context, once.
enum PendingRecoveryQuery {
    static func identifiers(container: ModelContainer, device: String,
                            defaults: UserDefaults = .standard) throws -> [PersistentIdentifier] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let key = "strata.resumeFlagMigrated.v1"
        if !defaults.bool(forKey: key) {
            for message in try context.fetch(FetchDescriptor<Message>()) where message.resumeData != nil && !message.hasResume {
                message.hasResume = true
            }
            try context.save()
            defaults.set(true, forKey: key)
        }
        let device: String? = device
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> {
            ($0.cancelPending || $0.hasResume) && ($0.resumeDeviceID == nil || $0.resumeDeviceID == device)
        })
        descriptor.fetchLimit = 20
        return try context.fetchIdentifiers(descriptor)
    }
}

/// The first foreground after an outage always retries. Only repeated automatic recoveries back off; Try again is
/// explicit and bypasses this policy. State is local to this controller, never synced to another device.
struct RecoveryAttempts {
    private var attempts: [PersistentIdentifier: (count: Int, next: Date)] = [:]

    func isEligible(_ id: PersistentIdentifier, now: Date = .now) -> Bool {
        attempts[id].map { now >= $0.next } ?? true
    }

    mutating func record(_ id: PersistentIdentifier, now: Date = .now) {
        let count = min((attempts[id]?.count ?? 0) + 1, 6)
        attempts[id] = (count, now.addingTimeInterval(min(600, 30 * pow(2, Double(count - 1)))))
    }
}
