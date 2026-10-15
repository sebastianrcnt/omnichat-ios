import SwiftUI
import SwiftData

/// What the root of the app does besides laying out the chat: pick up a reply that kept running (or finished) while the
/// app was away, refresh every connection's models, and let go of the render state of chats that are no longer open.
/// Shared by the iPhone root and the Mac window.
private struct ChatLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @Environment(\.connectionStore) private var connections
    @Environment(\.chatController) private var controller

    @Binding var selected: Conversation?

    func body(content: Content) -> some View {
        content
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
            .onChange(of: ReplyNotificationRouter.shared?.pending, initial: true) { _, id in
                guard let id, let router = ReplyNotificationRouter.shared else { return }
                router.pending = nil
                let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
                if let conversation = try? context.fetch(descriptor).first { selected = conversation }
            }
            .onChange(of: selected?.id) { _, _ in
                controller.forgetRenderStates(except: Set((selected?.messages ?? []).map(\.id)))
                // The chat left behind loses its Python interpreter, unless its reply is still running.
                PythonRuntime.shared.conversationDidChange(to: selected?.id, busy: controller.activeConversationID)
            }
    }

    private func selectRecoveredConversation() {
        guard selected == nil, let id = controller.activeConversationID,
              let conversations = try? context.fetch(FetchDescriptor<Conversation>()) else { return }
        selected = conversations.first { $0.id == id }
    }
}

extension View {
    func chatLifecycle(selected: Binding<Conversation?>) -> some View {
        modifier(ChatLifecycle(selected: selected))
    }
}
