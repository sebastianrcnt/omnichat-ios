import SwiftUI
import SwiftData

/// History drawer: search, pinned, recent, new chat and settings.
struct SidebarView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(\.chatController) private var controller
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @Binding var selected: Conversation?
    let onNewChat: () -> Void
    let onSettings: () -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var deleting: Conversation?
    @State private var showArtifacts = false

    /// Conversations whose message text matches the current query, found by the store (not by loading messages here).
    @State private var contentMatches: Set<UUID> = []

    private var filtered: [Conversation] {
        ConversationSearch.filter(conversations, query: query, contentMatches: contentMatches)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
                .padding(.leading, DS.Spacing.lg)
                .padding(.trailing, DS.Spacing.md)
                .padding(.top, DS.Spacing.sm)
                .padding(.bottom, DS.Spacing.md)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    if query.isEmpty { artifactsRow }
                    let pinned = filtered.filter(\.isPinned)
                    let recent = filtered.filter { !$0.isPinned }
                    if !pinned.isEmpty {
                        header("Pinned")
                        ForEach(pinned) { row($0) }
                    }
                    if recent.isEmpty && pinned.isEmpty {
                        header("Recent")
                        Text(query.isEmpty ? "No chats yet" : "No matches")
                            .font(DS.Typography.uiSmall).foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, DS.Spacing.lg)
                    }
                    ForEach(ConversationGroups.group(recent)) { group in
                        header(LocalizedStringKey(group.title))
                        ForEach(group.items) { row($0) }
                    }
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
        .confirmationDialog("Delete this chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let c = deleting {
                    if selected?.id == c.id { selected = nil }
                    ConversationDeletion.delete(c, context: context, controller: controller)
                }
                deleting = nil
            }
        }
        .renameChat(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), text: $renameText) { title in
            renaming?.setUserTitle(title)
            try? context.save()
            renaming = nil
        }
        .artifactGallery(isPresented: $showArtifacts) { chat in
            selected = chat
            close()
        }
        #if DEBUG
        .task {
            guard DebugHooks.openSheet == "artifacts" else { return }
            if DebugHooks.value("StrataSeedArtifacts") != nil { DebugHooks.seedArtifacts(context: context) }
            showArtifacts = true
        }
        #endif
    }

    /// Opens the list of every chat's artifacts.
    private var artifactsRow: some View {
        Button { showArtifacts = true } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: ArtifactFeedCard.icon)
                    .font(.system(size: DS.IconSize.md))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: DS.IconSize.lg)
                Text("Artifacts").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The app name with a search button; searching swaps the row for the field and Cancel.
    @ViewBuilder
    private var titleBar: some View {
        if searching {
            HStack(spacing: DS.Spacing.sm) {
                searchField
                Button("Cancel") {
                    query = ""
                    searching = false
                }
                .font(DS.Typography.ui)
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
            }
            .onAppear { searchFocused = true }
        } else {
            HStack {
                Text(verbatim: "OpenChat")
                    .font(DS.Typography.largeTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                GlassIconButton(systemName: "magnifyingglass", label: "Search") {
                    searching = true
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
            TextField("", text: $query, prompt: Text("Search").foregroundStyle(theme.textTertiary))
                .focused($searchFocused)
                .font(DS.Typography.ui)
                .foregroundStyle(theme.textPrimary)
                .plainTextInput()
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
                VStack(alignment: .leading, spacing: 0) {
                    TitlingText(conversation.displayTitle, isTitling: controller.isTitling(conversation.id))
                        .font(DS.Typography.ui)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if ConversationSearch.matchedOnlyInMessages(conversation, query: query, contentMatches: contentMatches) {
                        Text("Found in messages").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
                    }
                }
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
                renameText = conversation.displayTitle
                renaming = conversation
            }
            Button("Regenerate title", systemImage: "wand.and.stars") {
                controller.autoRename(conversation: conversation, context: context, force: true)
            }
            .disabled(controller.isStreaming(conversation) || controller.isTitling(conversation.id))
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = conversation }
        }
    }
}

/// Deleting a chat, the same from every place that offers it: its running reply stops first, then its diagnostics,
/// Python interpreter, figures and artifacts go with it.
@MainActor
enum ConversationDeletion {
    static func delete(_ conversation: Conversation, context: ModelContext, controller: ChatController) {
        if controller.activeConversationID == conversation.id { controller.stop() }
        Diagnostics.forget(conversation.id)
        PythonRuntime.shared.conversationDeleted(conversation.id)
        ArtifactStore.shared.removeAll(conversationID: conversation.id)
        context.delete(conversation)
        try? context.save()
    }
}

/// The chat list by age: Today, Yesterday, Previous 7 Days, Previous 30 Days, then by month.
enum ConversationGroups {
    struct Group: Identifiable {
        var title: String
        var items: [Conversation]
        var id: String { title }
    }

    static func group(_ conversations: [Conversation], now: Date = .now, calendar: Calendar = .current) -> [Group] {
        var out: [Group] = []
        for c in conversations {
            let title = label(for: c.updatedAt, now: now, calendar: calendar)
            if out.last?.title == title { out[out.count - 1].items.append(c) } else { out.append(Group(title: title, items: [c])) }
        }
        return out
    }

    static func label(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        let startOfToday = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
        if days < 7 { return String(localized: "Previous 7 Days") }
        if days < 30 { return String(localized: "Previous 30 Days") }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.wide)) }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

/// "Rename chat". On iPhone a small sheet of our own: the system alert's text field came out shifted past the alert's
/// edge with the app's font and line height applied. A Mac keeps the alert.
private struct RenameChat: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var text: String
    let onSave: (String) -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.sheet(isPresented: $isPresented) {
            RenameChatSheet(text: $text) { title in
                onSave(title) // first: the sidebar's binding forgets which chat when the sheet closes
                isPresented = false
            }
        }
        #else
        content.alert("Rename chat", isPresented: $isPresented) {
            TextField("Title", text: $text)
            Button("Cancel", role: .cancel) {}
            Button("Save") { save() }
        }
        #endif
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { onSave(t) }
    }
}

#if os(iOS)
private struct RenameChatSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let onSave: (String) -> Void
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text("Rename chat").font(DS.Typography.uiEmphasis).foregroundStyle(theme.textPrimary)
                Spacer()
                Button("Save") { onSave(trimmed) }.disabled(trimmed.isEmpty).fontWeight(.semibold)
            }
            TextField("Title", text: $text)
                .font(DS.Typography.ui)
                .foregroundStyle(theme.textPrimary)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { if !trimmed.isEmpty { onSave(trimmed) } }
                .padding(.horizontal, DS.Spacing.lg)
                .frame(height: DS.IconSize.controlDiameter)
                .background(theme.surfaceRaised, in: Capsule())
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.lg)
        .presentationDetents([.height(150)])
        .presentationBackground(theme.background)
        .onAppear { focused = true }
    }
}
#endif

extension View {
    func renameChat(isPresented: Binding<Bool>, text: Binding<String>, onSave: @escaping (String) -> Void) -> some View {
        modifier(RenameChat(isPresented: isPresented, text: text, onSave: onSave))
    }
}
