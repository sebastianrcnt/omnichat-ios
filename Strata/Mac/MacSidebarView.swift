#if os(macOS)
import SwiftUI
import SwiftData

/// The conversation list: pinned and recent chats, search (Find, ⌘F), and the right-click actions.
struct MacSidebarView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(\.chatController) private var controller
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @Binding var selected: Conversation?
    /// Bumped by the Find command.
    var findToken = 0

    @State private var query = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var deleting: Conversation?
    @FocusState private var searchFocused: Bool

    /// Conversations whose message text matches the current query, found by the store (not by loading messages here).
    @State private var contentMatches: Set<UUID> = []

    private var filtered: [Conversation] {
        ConversationSearch.filter(conversations, query: query, contentMatches: contentMatches)
    }

    var body: some View {
        List(selection: $selected) {
            let pinned = filtered.filter(\.isPinned)
            let recent = filtered.filter { !$0.isPinned }
            if !pinned.isEmpty {
                Section("Pinned") { ForEach(pinned) { row($0) } }
            }
            Section("Recent") {
                ForEach(recent) { row($0) }
                if recent.isEmpty && pinned.isEmpty {
                    Text(query.isEmpty ? "No chats yet" : "No matches")
                        .font(DS.Typography.uiSmall).foregroundStyle(theme.textTertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: findToken) { searchFocused = true }
        .onDeleteCommand { deleting = selected }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { contentMatches = []; return }
            try? await Task.sleep(for: .milliseconds(250)) // typing debounce; a new query cancels this task
            guard !Task.isCancelled else { return }
            contentMatches = ConversationSearch.matchingConversationIDs(query: q, context: context)
        }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let c = renaming, !t.isEmpty { c.setUserTitle(t); try? context.save() }
                renaming = nil
            }
        }
        .confirmationDialog("Delete this chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let c = deleting { delete(c) }
                deleting = nil
            }
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        Label {
            TitlingText(conversation.displayTitle, isTitling: controller.isTitling(conversation.id))
                .font(DS.Typography.uiSmall).lineLimit(1)
        } icon: {
            Image(systemName: conversation.isPinned ? "pin" : "bubble.left")
        }
        .tag(conversation)
        .contextMenu {
            Button(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin") {
                conversation.isPinned.toggle()
                try? context.save()
            }
            Button("Rename", systemImage: "pencil") {
                renameText = conversation.title
                renaming = conversation
            }
            Button("Regenerate title", systemImage: "wand.and.stars") {
                controller.autoRename(conversation: conversation, context: context, force: true)
            }
            .disabled(controller.isStreaming(conversation) || controller.isTitling(conversation.id))
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = conversation }
        }
    }

    private func delete(_ conversation: Conversation) {
        if selected?.id == conversation.id { selected = nil }
        Diagnostics.forget(conversation.id)
        PythonRuntime.shared.conversationDeleted(conversation.id)
        context.delete(conversation)
        try? context.save()
    }
}
#endif
