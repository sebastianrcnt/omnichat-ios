import Foundation
import SwiftData

/// Sidebar search that never walks `Conversation.messages`: titles are matched in memory, message text by the store.
enum ConversationSearch {
    static let contentLimit = 200

    /// Ids of conversations with a message whose text contains `query`. The match runs inside SQLite and loads
    /// only the matching messages (capped), not every message of every chat.
    @MainActor
    static func matchingConversationIDs(query: String, context: ModelContext) -> Set<UUID> {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate<Message> { $0.text.localizedStandardContains(q) && !$0.hiddenInstruction })
        descriptor.fetchLimit = contentLimit
        let messages = (try? context.fetch(descriptor)) ?? []
        return Set(messages.compactMap { $0.conversation?.id })
    }

    static func filter(_ conversations: [Conversation], query: String, contentMatches: Set<UUID>) -> [Conversation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return conversations }
        return conversations.filter { $0.title.localizedStandardContains(q) || contentMatches.contains($0.id) }
    }

    /// The chat is listed for its messages, not its title: the list says so, or the match would look random.
    static func matchedOnlyInMessages(_ conversation: Conversation, query: String, contentMatches: Set<UUID>) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !q.isEmpty && contentMatches.contains(conversation.id) && !conversation.displayTitle.localizedStandardContains(q)
    }
}
