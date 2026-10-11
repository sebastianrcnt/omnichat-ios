import SwiftUI
import SwiftData

/// Chat plus a left drawer with the history.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(ConnectionStore.self) private var connections
    @Environment(ChatController.self) private var controller

    @State private var selected: Conversation?
    @State private var sidebarOpen = false
    @State private var showSettings = false
    @State private var focusToken = 0

    @State private var width: CGFloat = 390
    /// Live finger translation while dragging. Held in a reference type read only by `DrawerLayer`, so a drag
    /// frame does not re-evaluate this view (and with it the chat, which would be rebuilt every frame).
    @State private var drag = DrawerDrag()
    private var sidebarWidth: CGFloat { min(width * 0.84, 360) }

    var body: some View {
        ZStack(alignment: .leading) {
            SidebarView(selected: $selected, onNewChat: newChat, onSettings: { openSettings() }, close: closeSidebar)
                .frame(width: sidebarWidth)

            DrawerLayer(drag: drag, isOpen: sidebarOpen, width: sidebarWidth, onClose: closeSidebar) {
                ChatView(conversation: $selected, onOpenSidebar: { setSidebar(true) }, onOpenSettings: { openSettings() },
                         onNewChat: newChat, focusToken: focusToken)
                    .id(selected?.id)
                    .background(theme.background.ignoresSafeArea())
            }
        }
        .background(EdgeFreePanRecognizer(
            isOpen: sidebarOpen,
            onBegan: { if !sidebarOpen { dismissKeyboard() } },
            onChanged: { drag.value = $0 },
            onEnded: { translation, velocity in
                let projected = (sidebarOpen ? sidebarWidth : 0) + translation + velocity * 0.15
                let open = projected > sidebarWidth / 2
                withAnimation(DS.Motion.spring) { sidebarOpen = open; drag.value = 0 }
            }))
        .background(theme.background.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .sheet(isPresented: $showSettings) { SettingsView().inAppLinks() }
        .inAppLinks()
        .task {
            controller.restorePending(context: context)
            selectRecoveredConversation()
            // Refresh models (and capability flags such as image input) for every connection with a key.
            for c in connections.connections where connections.apiKey(for: c.id) != nil {
                _ = try? await connections.refreshModels(for: c.id)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.restorePending(context: context)
                selectRecoveredConversation()
            }
        }
        .onChange(of: selected?.id) { _, _ in
            controller.forgetRenderStates(except: Set((selected?.messages ?? []).map(\.id)))
        }
    }

    private func selectRecoveredConversation() {
        guard selected == nil, let id = controller.activeConversationID,
              let conversations = try? context.fetch(FetchDescriptor<Conversation>()) else { return }
        selected = conversations.first { $0.id == id }
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

    /// Starts an empty chat. Conversations are created on first send, so an already-empty chat only gets focus.
    private func newChat() {
        selected = nil
        closeSidebar()
        focusToken += 1
    }
}

@MainActor
@Observable
final class DrawerDrag { var value: CGFloat = 0 }

/// Slides its content right as the drawer opens. The only view that reads the drag translation.
private struct DrawerLayer<Content: View>: View {
    let drag: DrawerDrag
    let isOpen: Bool
    let width: CGFloat
    let onClose: () -> Void
    let content: Content

    init(drag: DrawerDrag, isOpen: Bool, width: CGFloat, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.drag = drag
        self.isOpen = isOpen
        self.width = width
        self.onClose = onClose
        self.content = content()
    }

    /// 0 closed ... 1 open, following the finger.
    private var progress: CGFloat {
        let base: CGFloat = isOpen ? width : 0
        return min(1, max(0, (base + drag.value) / width))
    }

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xl * progress))
            .overlay {
                if progress > 0 {
                    Color.black.opacity(0.001)
                        .onTapGesture(perform: onClose)
                }
            }
            .offset(x: progress * width)
            .shadow(color: .black.opacity(0.25 * progress), radius: 20)
    }
}
