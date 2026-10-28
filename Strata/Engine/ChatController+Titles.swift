import Foundation
import SwiftUI
import SwiftData
import Observation

/// Naming chats: the automatic title after the first answer, and "Regenerate title".
extension ChatController {
    func isTitling(_ conversationID: UUID?) -> Bool {
        conversationID.map { titlingConversationIDs.contains($0) } ?? false
    }

    /// Names the conversation with a standalone side request, in the background. Failure keeps the old title, quietly.
    /// `force` ("Regenerate title") overwrites even a user-set title and marks the new title as not user-set; it runs
    /// whether or not automatic titles are on in Settings.
    func autoRename(conversation: Conversation, context: ModelContext, force: Bool) {
        guard !titlingConversationIDs.contains(conversation.id) else { return }
        // "Name chats on device" asks Apple's on-device model instead of the chat's own, when it can run.
        let onDevice = OnDevice.titleEndpoint(enabled: settings.nameChatsOnDevice, connections: connections.connections)
        guard let endpoint = onDevice ?? connections.endpoint(connectionID: conversation.connectionID, modelID: conversation.modelID,
                                                              sessionID: conversation.id.uuidString),
              !Self.needsKey(endpoint, connections: connections),
              healthBlock(conversation, endpoint) == nil,
              let prompt = AutoRename.prompt(lines: conversation.namingLines,
                                             replacing: force ? conversation.displayTitle : nil) else {
            if force { titleFailedConversationID = conversation.id }
            return
        }
        // The title is asked as a follow-up to the chat's own request: the cached prefix is reused, and the model sees
        // everything, not just the first exchange. Not on device: there is no cache, and the clipped exchange fits its
        // small window better.
        let path = conversation.activePath
        var followUp: ChatRequest?
        if path.last?.role == .assistant, endpoint.kind != .appleOnDevice {
            var base = ChatRequest(model: endpoint.model.id,
                                   messages: apiHistory(path: path, conversation: conversation, endpoint: endpoint))
            if endpoint.model.supportsEffort { base.reasoningEffort = conversation.effort.apiValue }
            if endpoint.model.supportsTools { base.tools = requestTools(endpoint, conversation: conversation) }
            followUp = AutoRename.followUp(base, replacing: force ? conversation.displayTitle : nil,
                                           forbidTools: endpoint.kind != .anthropic)
        }
        let streamer = streamer
        let ring = requestRing
        let conversationID = conversation.id
        let titleAtStart = conversation.title
        conversation.autoRenameDone = true
        titlingConversationIDs.insert(conversationID)
        titleTasks[conversationID] = Task { @MainActor [weak self] in
            defer {
                self?.titlingConversationIDs.remove(conversationID)
                self?.titleTasks[conversationID] = nil
            }
            let name = await AutoRename.generate(prompt: prompt, endpoint: endpoint, streamer: streamer, followUp: followUp) { event in
                switch event {
                case .sent(let id, let url, let body): ring.record(conversationID: conversationID, url: url, body: body, id: id)
                case .finished(let id, let reason, let usage): ring.complete(id, finishReason: reason, usage: usage)
                }
            }
            guard let name else {
                // "Regenerate title" says it failed; a failed automatic title is tried again after a later answer.
                if force { self?.titleFailedConversationID = conversationID }
                if !force, conversation.modelContext != nil, !conversation.isDeleted { conversation.autoRenameDone = false }
                return
            }
            guard conversation.modelContext != nil, !conversation.isDeleted else { return }
            // Renamed by hand while the request ran: the user's title wins.
            if conversation.title != titleAtStart || (!force && conversation.titleIsUserSet) { return }
            conversation.title = name
            if force { conversation.titleIsUserSet = false }
            try? context.save()
        }
    }
}
