#if os(macOS)
import SwiftUI
import SwiftData

/// The Mac window: conversations in a persistent sidebar, the chat in the detail column.
struct MacRootView: View {
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings
    @Environment(\.chatController) private var controller
    @Environment(\.modelContext) private var modelContext

    @State private var selected: Conversation?
    @State private var chatKey = ChatViewKey()
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var focusToken = 0
    @State private var findToken = 0

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            MacSidebarView(selected: $selected, findToken: findToken)
                .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 420)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New chat", systemImage: "square.and.pencil", action: newChat)
                            .help("New chat (\u{2318}N)")
                    }
                }
        } detail: {
            ChatView(conversation: $selected, onOpenSidebar: {}, onOpenSettings: { openSettings() },
                     onNewChat: newChat, focusToken: focusToken)
                .id(chatKey.id)
                .background(theme.background)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: selected?.id) { old, new in chatKey.update(old: old, new: new, active: controller.activeConversationID) }
        .chatLifecycle(selected: $selected)
        .onAppear {
            WindowActions.shared.install(newChat: newChat, findChats: findChats)
            WindowActions.shared.selectChat = selectChat
        }
    }

    /// ⌘1…⌘9 and ⌥⌘↑/↓: the chat at that place in the list (pinned first, then newest).
    private func selectChat(_ move: WindowActions.ChatMove) {
        let all = (try? modelContext.fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        let ordered = all.filter(\.isPinned) + all.filter { !$0.isPinned }
        guard !ordered.isEmpty else { return }
        let current = selected.flatMap { s in ordered.firstIndex { $0.id == s.id } }
        switch move {
        case .index(let n): if ordered.indices.contains(n) { selected = ordered[n] }
        case .next: selected = ordered[min((current ?? -1) + 1, ordered.count - 1)]
        case .previous: selected = ordered[max((current ?? ordered.count) - 1, 0)]
        }
    }

    /// Shows the sidebar and puts the cursor in its search field.
    private func findChats() {
        columns = .all
        findToken += 1
    }

    /// Starts an empty chat. Conversations are created on first send, so an already-empty chat only gets focus.
    private func newChat() {
        selected = nil
        focusToken += 1
    }
}

/// What the menu commands can ask of the window. There is one window, and a text view inside it that SwiftUI's focus
/// does not know about, so the commands do not go through focused values.
@MainActor
final class WindowActions {
    static let shared = WindowActions()

    private(set) var newChat: () -> Void = {}
    private(set) var findChats: () -> Void = {}
    enum ChatMove { case index(Int), next, previous }
    var selectChat: (ChatMove) -> Void = { _ in }
    /// Set by the open chat: regenerate its last answer, copy it. Nil when there is none.
    var regenerate: (() -> Void)?
    var copyLastAnswer: (() -> Void)?

    func install(newChat: @escaping () -> Void, findChats: @escaping () -> Void) {
        self.newChat = newChat
        self.findChats = findChats
    }
}
#endif
