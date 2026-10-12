#if os(macOS)
import SwiftUI
import SwiftData

/// The Mac window: conversations in a persistent sidebar, the chat in the detail column.
struct MacRootView: View {
    @Environment(\.theme) private var theme
    @Environment(\.openSettings) private var openSettings

    @State private var selected: Conversation?
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var focusToken = 0

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            MacSidebarView(selected: $selected)
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
                .id(selected?.id)
                .background(theme.background)
        }
        .frame(minWidth: 760, minHeight: 520)
        .chatLifecycle(selected: $selected)
        .focusedSceneValue(\.windowActions, WindowActions(newChat: newChat))
    }

    /// Starts an empty chat. Conversations are created on first send, so an already-empty chat only gets focus.
    private func newChat() {
        selected = nil
        focusToken += 1
    }
}

/// What the menu commands can ask of the window.
struct WindowActions {
    var newChat: () -> Void
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}
#endif
