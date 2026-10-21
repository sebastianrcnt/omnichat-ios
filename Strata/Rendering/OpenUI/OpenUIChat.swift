import Foundation
import SwiftData

/// How a chat hosts the interactive views in its answers. Each chat runs on its own (`ChatController.runs`), so only
/// the chat's own reply locks its views; a reply running in another chat doesn't.
@MainActor
enum OpenUIChat {
    /// Controls work in the chat's latest answer while no reply runs (or waits its turn) in that chat.
    static func isInteractive(isLast: Bool, conversation: Conversation?, controller: ChatController) -> Bool {
        guard isLast, let conversation else { return false }
        return !controller.isStreaming(conversation)
    }

    /// Saves what was chosen on the answer (`Message.openUIStates`) and sends the follow-up through the chat's own
    /// send, like a typed message. False, and nothing saved, when the chat is replying.
    @discardableResult
    static func send(_ submission: OUISubmission, block: Int, from message: Message, in conversation: Conversation,
                     controller: ChatController, context: ModelContext) -> Bool {
        guard !controller.isStreaming(conversation) else { return false }
        var states = message.openUIStates
        states[block] = submission.saved
        message.openUIStates = states
        controller.send(text: submission.text, images: [], conversation: conversation, context: context)
        return true
    }
}
