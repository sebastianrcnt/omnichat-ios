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
    private var sidebarWidth: CGFloat { min(width * 0.84, 360) }

    var body: some View {
        ZStack(alignment: .leading) {
            SidebarView(selected: $selected, onNewChat: newChat, onSettings: { showSettings = true }, close: closeSidebar)
                .frame(width: sidebarWidth)

            ChatView(conversation: $selected, onOpenSidebar: { setSidebar(true) }, onOpenSettings: { showSettings = true })
                .id(selected?.id)
                .background(theme.background.ignoresSafeArea())
                .clipShape(RoundedRectangle(cornerRadius: sidebarOpen ? DS.Radius.xl : 0))
                .overlay {
                    if sidebarOpen {
                        Color.black.opacity(0.001)
                            .onTapGesture(perform: closeSidebar)
                            .gesture(DragGesture().onEnded { if $0.translation.width < -40 { closeSidebar() } })
                    }
                }
                .offset(x: sidebarOpen ? sidebarWidth : 0)
                .shadow(color: .black.opacity(sidebarOpen ? 0.25 : 0), radius: 20)
                .overlay(alignment: .leading) {
                    if !sidebarOpen {
                        Color.clear.frame(width: 18).contentShape(Rectangle())
                            .gesture(DragGesture().onEnded { if $0.translation.width > 40 { setSidebar(true) } })
                    }
                }
        }
        .background(theme.background.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: selected?.id) { _, _ in
            controller.forgetRenderStates(except: Set((selected?.messages ?? []).map(\.id)))
        }
    }

    private func setSidebar(_ open: Bool) {
        withAnimation(DS.Motion.spring) { sidebarOpen = open }
    }

    private func closeSidebar() { setSidebar(false) }

    private func newChat() {
        selected = nil
        closeSidebar()
    }
}
