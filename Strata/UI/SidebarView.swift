import SwiftUI
import SwiftData

/// History drawer: search, pinned, recent, new chat and settings.
struct SidebarView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @Binding var selected: Conversation?
    let onNewChat: () -> Void
    let onSettings: () -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""

    /// Conversations whose message text matches the current query, found by the store (not by loading messages here).
    @State private var contentMatches: Set<UUID> = []

    private var filtered: [Conversation] {
        ConversationSearch.filter(conversations, query: query, contentMatches: contentMatches)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Strata")
                .font(DS.Typography.largeTitle)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.top, DS.Spacing.xl)
            searchField
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.md)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    let pinned = filtered.filter(\.isPinned)
                    let recent = filtered.filter { !$0.isPinned }
                    if !pinned.isEmpty {
                        header("Pinned")
                        ForEach(pinned) { row($0) }
                    }
                    header("Recent")
                    if recent.isEmpty && pinned.isEmpty {
                        Text(query.isEmpty ? "No chats yet" : "No matches")
                            .font(DS.Typography.uiSmall).foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, DS.Spacing.lg)
                    }
                    ForEach(recent) { row($0) }
                }
                .padding(.horizontal, DS.Spacing.sm)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)

            HStack {
                GlassIconButton(systemName: "gearshape", label: "Settings", action: onSettings)
                Spacer()
                Button(action: onNewChat) {
                    Label("New chat", systemImage: "plus")
                        .font(DS.Typography.uiEmphasis)
                        .padding(.horizontal, DS.Spacing.sm)
                        .frame(height: DS.IconSize.controlDiameter - DS.Spacing.sm)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(theme.accent)
            }
            .padding(DS.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    }

    private var searchField: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
            TextField("", text: $query, prompt: Text("Search").foregroundStyle(theme.textTertiary))
                .font(DS.Typography.ui)
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .withoutInputAssistantBar()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.textTertiary) }
                    .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .frame(height: DS.IconSize.controlDiameter)
        .glassEffect(.regular, in: Capsule())
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(DS.Typography.sectionHeader)
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.xs)
    }

    private func row(_ conversation: Conversation) -> some View {
        Button {
            selected = conversation
            close()
        } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: conversation.isPinned ? "pin" : "bubble.left")
                    .font(.system(size: DS.IconSize.md))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: DS.IconSize.lg)
                Text(conversation.displayTitle)
                    .font(DS.Typography.ui)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.md)
            .background(selected?.id == conversation.id ? theme.surfaceRaised : .clear,
                        in: RoundedRectangle(cornerRadius: DS.Radius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin") {
                conversation.isPinned.toggle()
                try? context.save()
            }
            Button("Rename", systemImage: "pencil") {
                renameText = conversation.title
                renaming = conversation
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                if selected?.id == conversation.id { selected = nil }
                Diagnostics.forget(conversation.id)
                context.delete(conversation)
                try? context.save()
            }
        }
    }
}
