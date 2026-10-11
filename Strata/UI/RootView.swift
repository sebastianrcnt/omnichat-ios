import SwiftUI
import SwiftData

/// Chat plus a left drawer with the history.
struct RootView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(ConnectionStore.self) private var connections
    @Environment(ChatController.self) private var controller

    @State private var selected: Conversation?
    @State private var sidebarOpen = false
    @State private var showSettings = false

    @State private var width: CGFloat = 390
    /// Live finger translation while dragging; zero otherwise.
    @State private var drag: CGFloat = 0
    @State private var dragging = false
    private var sidebarWidth: CGFloat { min(width * 0.84, 360) }

    /// 0 closed ... 1 open, following the finger.
    private var progress: CGFloat {
        let base: CGFloat = sidebarOpen ? sidebarWidth : 0
        return min(1, max(0, (base + drag) / sidebarWidth))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            SidebarView(selected: $selected, onNewChat: newChat, onSettings: { openSettings() }, close: closeSidebar)
                .frame(width: sidebarWidth)

            ChatView(conversation: $selected, onOpenSidebar: { setSidebar(true) }, onOpenSettings: { openSettings() })
                .id(selected?.id)
                .background(theme.background.ignoresSafeArea())
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xl * progress))
                .overlay {
                    if progress > 0 {
                        Color.black.opacity(0.001)
                            .onTapGesture(perform: closeSidebar)
                    }
                }
                .offset(x: progress * sidebarWidth)
                .shadow(color: .black.opacity(0.25 * progress), radius: 20)
        }
        .background(EdgeFreePanRecognizer(
            isOpen: sidebarOpen,
            onBegan: { dragging = true; if !sidebarOpen { dismissKeyboard() } },
            onChanged: { drag = $0 },
            onEnded: { translation, velocity in
                let projected = (sidebarOpen ? sidebarWidth : 0) + translation + velocity * 0.15
                let open = projected > sidebarWidth / 2
                dragging = false
                withAnimation(DS.Motion.spring) { sidebarOpen = open; drag = 0 }
            }))
        .background(theme.background.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task {
            // Refresh models (and capability flags such as image input) for every connection with a key.
            for c in connections.connections where connections.apiKey(for: c.id) != nil {
                _ = try? await connections.refreshModels(for: c.id)
            }
        }
        .onChange(of: selected?.id) { _, _ in
            controller.forgetRenderStates(except: Set((selected?.messages ?? []).map(\.id)))
        }
    }

    private func openSettings() {
        dismissKeyboard()
        showSettings = true
    }

    private func setSidebar(_ open: Bool) {
        if open { dismissKeyboard() }
        withAnimation(DS.Motion.spring) { sidebarOpen = open }
    }

    private func closeSidebar() { setSidebar(false) }

    private func newChat() {
        selected = nil
        closeSidebar()
    }
}
