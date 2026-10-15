import SwiftUI
import SwiftData

/// Every artifact of every chat, last updated first (opened from the sidebar). A row opens the page; from there "Go to
/// chat" selects the chat that made it.
struct ArtifactsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    var store: ArtifactStore = .shared
    let onOpenChat: (Conversation) -> Void

    @State private var entries: [ArtifactStore.Entry] = []
    @State private var loaded = false
    @State private var viewing: ArtifactStore.Entry?

    var body: some View {
        let chats = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        SheetScaffold(title: "Artifacts") {
            if loaded && entries.isEmpty {
                GroupedSection(footer: "Pages the assistant makes in a chat, like small apps and visualizations, appear here.") {
                    SettingsRow(title: "No artifacts yet")
                }
            } else {
                GroupedSection {
                    ForEach(entries) { entry in
                        SettingsRow(systemImage: ArtifactFeedCard.icon, title: "", subtitle: subtitle(entry, chat: chats[entry.conversationID]),
                                    showsChevron: true, verbatimTitle: entry.artifact.title) {
                            viewing = entry
                        }
                    }
                }
            }
        }
        // Only chats that still exist: a deleted chat's artifacts never show, even if its folder outlived it.
        .task(id: conversations.map(\.id)) {
            let existing = Set(conversations.map(\.id))
            let store = store
            entries = await Task.detached { store.allArtifacts(existing: existing) }.value
            loaded = true
        }
        .fullScreenCoverOrSheet(item: $viewing) { entry in
            ArtifactViewer(ref: entry.ref, store: store, onGoToChat: chats[entry.conversationID].map { chat in
                {
                    viewing = nil
                    dismiss()
                    onOpenChat(chat)
                }
            })
        }
    }

    /// "Chat title · Oct 15".
    private func subtitle(_ entry: ArtifactStore.Entry, chat: Conversation?) -> String {
        let date = entry.artifact.updated.formatted(date: .abbreviated, time: .omitted)
        guard let chat else { return date }
        return chat.displayTitle + " · " + date
    }
}
