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
    func restorePending(context: ModelContext) {
        let messages = Self.pendingMessages(context: context)
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

    /// Unfinished turns only, found by a predicate (not by loading every message on each foreground). Only this device's
    /// own: a turn another device is running syncs here with its checkpoint, and must not run twice.
    /// Turns saved before the `hasResume` flag existed are flagged once.
    static func pendingMessages(context: ModelContext, defaults: UserDefaults = .standard,
                                device: String = DeviceIdentity.current) -> [Message] {
        let key = "strata.resumeFlagMigrated.v1"
        if !defaults.bool(forKey: key) {
            for message in (try? context.fetch(FetchDescriptor<Message>())) ?? [] where message.resumeData != nil && !message.hasResume {
                message.hasResume = true
            }
            try? context.save()
            defaults.set(true, forKey: key)
        }
        let device: String? = device
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> {
            ($0.cancelPending || $0.hasResume) && ($0.resumeDeviceID == nil || $0.resumeDeviceID == device)
        })
        descriptor.fetchLimit = 20
        return (try? context.fetch(descriptor)) ?? []
    }
}
