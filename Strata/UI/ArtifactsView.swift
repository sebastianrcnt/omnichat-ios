import SwiftUI
import SwiftData

/// Every artifact of every chat as a gallery (opened from the sidebar): a grid of page thumbnails, a list, or sections
/// by chat, with search and sort. An item opens the page; from there "Go to chat" selects the chat that made it, and the
/// viewer pages through the gallery's current order.
struct ArtifactsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    var store: ArtifactStore = .shared
    let onOpenChat: (Conversation) -> Void

    // Per device: UserDefaults is not synced.
    @AppStorage("artifactGalleryMode") private var mode = ArtifactGalleryMode.grid
    @AppStorage("artifactGallerySort") private var sort = ArtifactGallerySort.updated

    @State private var entries: [ArtifactStore.Entry] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var viewing: ArtifactBrowsing?

    var body: some View {
        let chats = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = ArtifactGallery.items(entries, chats: chats.mapValues { ($0.displayTitle, $0.updatedAt) })
        let shown = ArtifactGallery.sorted(ArtifactGallery.filter(items, query: query), by: sort)
        NavigationStack {
            ScrollView {
                content(all: items, shown: shown)
                    .padding(.horizontal, mode == .byChat ? 0 : DS.Spacing.page)
                    .padding(.top, DS.Spacing.sm)
                    .padding(.bottom, DS.Spacing.xl)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Artifacts")
            .inlineNavigationTitle()
            .toolbar { toolbar }
            .searchable(text: $query, prompt: "Search artifacts")
        }
        .presentationBackground(theme.background)
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 980, minHeight: 520, idealHeight: 720)
        .background { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        #endif
        // Only chats that still exist: a deleted chat's artifacts never show, even if its folder outlived it.
        .task(id: conversations.map(\.id)) {
            let existing = Set(conversations.map(\.id))
            let store = store
            entries = await Task.detached { store.allArtifacts(existing: existing) }.value
            loaded = true
            #if DEBUG
            if DebugHooks.value("StrataGalleryOpen") != nil, viewing == nil { // -StrataGalleryOpen 1: the second item, in the viewer
                let chats = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let order = ArtifactGallery.ordered(ArtifactGallery.items(entries, chats: chats.mapValues { ($0.displayTitle, $0.updatedAt) }),
                                                    query: query, sort: sort, mode: mode)
                if order.count > 1 { open(order[1], in: order) }
            }
            #endif
            // Thumbnails of artifacts that are gone (deleted chats) go too.
            let identities = Set(entries.map { ArtifactThumbnailKey.identity(conversationID: $0.conversationID, artifactID: $0.artifact.id) })
            Task.detached(priority: .utility) { ArtifactThumbnailCache.shared.prune(keeping: identities) }
        }
        .fullScreenCoverOrSheet(item: $viewing) { browsing in
            ArtifactPager(items: browsing.items, index: browsing.index, store: store) { item in
                goToChat(chats[item.conversationID])
            }
        }
        .inAppLinks()
    }

    // MARK: Content

    @ViewBuilder
    private func content(all: [ArtifactGalleryItem], shown: [ArtifactGalleryItem]) -> some View {
        if loaded && all.isEmpty {
            GroupedSection(footer: "Pages the assistant makes in a chat, like small apps and visualizations, appear here.") {
                SettingsRow(title: "No artifacts yet")
            }
            .padding(.horizontal, mode == .byChat ? DS.Spacing.page : 0)
        } else if loaded && shown.isEmpty {
            Text("No matches")
                .font(DS.Typography.ui).foregroundStyle(theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, DS.Spacing.xxl)
        } else {
            switch mode {
            case .grid: grid(shown)
            case .list: list(shown)
            case .byChat: byChat(shown)
            }
        }
    }

    /// Adaptive columns: two on a phone held upright, more as the window widens.
    private func grid(_ items: [ArtifactGalleryItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 280), spacing: DS.Spacing.md, alignment: .top)],
                  alignment: .leading, spacing: DS.Spacing.lg) {
            ForEach(items) { item in
                itemButton(item, in: items) { ArtifactGridCard(entry: item.entry, subtitle: subtitle(item)) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func list(_ items: [ArtifactGalleryItem]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                itemButton(item, in: items) { ArtifactListRow(entry: item.entry, subtitle: subtitle(item)) }
                    .buttonStyle(GalleryRowButtonStyle())
                if index < items.count - 1 {
                    Rectangle().fill(theme.separator).frame(height: 0.5)
                        .padding(.leading, DS.Spacing.lg + DS.IconSize.thumbnail + DS.Spacing.md)
                }
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    }

    /// A section per chat, newest chat first; each a row of thumbnails that scrolls sideways.
    private func byChat(_ items: [ArtifactGalleryItem]) -> some View {
        let groups = ArtifactGallery.grouped(items)
        let order = groups.flatMap(\.items)
        return LazyVStack(alignment: .leading, spacing: DS.Spacing.xl) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(verbatim: group.chatTitle ?? String(localized: "Chat"))
                            .font(DS.Typography.sectionHeader).foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                        Text(verbatim: "\(group.items.count)")
                            .font(DS.Typography.sectionHeader).foregroundStyle(theme.textTertiary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, DS.Spacing.page)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: DS.Spacing.md) {
                            ForEach(group.items) { item in
                                itemButton(item, in: order) {
                                    ArtifactGridCard(entry: item.entry, subtitle: date(item))
                                }
                                .buttonStyle(.plain)
                                .frame(width: 150)
                            }
                        }
                    }
                    .contentMargins(.horizontal, DS.Spacing.page, for: .scrollContent)
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    /// An item that opens the viewer (paging through `order`), with Open, Go to chat and Share on a long press.
    private func itemButton<ItemLabel: View>(_ item: ArtifactGalleryItem, in order: [ArtifactGalleryItem],
                                         @ViewBuilder label: () -> ItemLabel) -> some View {
        Button { open(item, in: order) } label: { label() }
            .contextMenu {
                Button("Open", systemImage: "arrow.up.forward.app") { open(item, in: order) }
                if let chat = conversations.first(where: { $0.id == item.conversationID }) {
                    Button("Go to chat", systemImage: "bubble.left") { dismiss(); onOpenChat(chat) }
                }
                ShareLink(item: ArtifactFile(entry: item.entry, store: store), preview: SharePreview(item.artifact.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel(Text("Close"))
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("View", selection: $mode) {
                    ForEach(ArtifactGalleryMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                Picker("Sort By", selection: $sort) {
                    ForEach(ArtifactGallerySort.allCases) { sort in Text(sort.title).tag(sort) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("View Options", systemImage: mode.systemImage)
            }
            .menuIndicator(.hidden)
        }
    }

    // MARK: Actions

    private func open(_ item: ArtifactGalleryItem, in order: [ArtifactGalleryItem]) {
        viewing = ArtifactBrowsing(items: order, index: order.firstIndex(of: item) ?? 0)
    }

    private func goToChat(_ chat: Conversation?) -> (() -> Void)? {
        chat.map { chat in
            {
                viewing = nil
                dismiss()
                onOpenChat(chat)
            }
        }
    }

    /// "Chat title · Oct 15".
    private func subtitle(_ item: ArtifactGalleryItem) -> String {
        guard let chat = item.chatTitle else { return date(item) }
        return chat + " · " + date(item)
    }

    private func date(_ item: ArtifactGalleryItem) -> String {
        item.artifact.updated.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The gallery's order as it was when an artifact was opened, and which one.
private struct ArtifactBrowsing: Identifiable {
    let id = UUID()
    let items: [ArtifactGalleryItem]
    let index: Int
}

/// The viewer for one artifact of a list, moving to the one before or after with a swipe across its bar.
private struct ArtifactPager: View {
    let items: [ArtifactGalleryItem]
    @State var index: Int
    let store: ArtifactStore
    let goToChat: (ArtifactGalleryItem) -> (() -> Void)?
    @State private var forward = true

    var body: some View {
        let item = items[index]
        ZStack {
            ArtifactViewer(ref: item.entry.ref, store: store, onGoToChat: goToChat(item), paging: paging)
                .id(item.id)
                .transition(.push(from: forward ? .trailing : .leading))
        }
    }

    private var paging: ArtifactViewer.Paging? {
        guard items.count > 1 else { return nil }
        return ArtifactViewer.Paging(position: index + 1, count: items.count,
                                     previous: index > 0 ? { move(by: -1) } : nil,
                                     next: index < items.count - 1 ? { move(by: 1) } : nil)
    }

    private func move(by step: Int) {
        forward = step > 0
        withAnimation(DS.Motion.snappy) { index = min(max(index + step, 0), items.count - 1) }
    }
}

/// A list row that darkens while pressed (the rows draw no background of their own).
private struct GalleryRowButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? theme.fillTertiary : .clear)
    }
}

extension View {
    /// The Artifacts gallery: full screen on a phone, a large page-sized sheet on an iPad or a Mac.
    func artifactGallery(isPresented: Binding<Bool>, onOpenChat: @escaping (Conversation) -> Void) -> some View {
        #if canImport(UIKit)
        Group {
            if UIDevice.current.userInterfaceIdiom == .phone {
                self.fullScreenCover(isPresented: isPresented) { ArtifactsView(onOpenChat: onOpenChat) }
            } else {
                self.sheet(isPresented: isPresented) { ArtifactsView(onOpenChat: onOpenChat).presentationSizing(.page) }
            }
        }
        #else
        sheet(isPresented: isPresented) { ArtifactsView(onOpenChat: onOpenChat).presentationSizing(.page) }
        #endif
    }
}
