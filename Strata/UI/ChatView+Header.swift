import SwiftUI
import SwiftData

extension ChatView {
    // MARK: Header

    #if os(iOS)
    var header: some View {
        GlassEffectContainer(spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                GlassIconButton(systemName: "line.3.horizontal", label: "Sidebar") { composerFocused = false; onOpenSidebar() }
                // No title: the chat is what's on the page, and the sidebar and the menu name it (Rename is there).
                // The model and effort are in the composer's chip.
                Spacer(minLength: 0)
                // New chat, the context gauge and the menu share one glass capsule, like a toolbar group.
                HStack(spacing: 0) {
                    Button {
                        composerFocused = false
                        onNewChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: DS.IconSize.headerIcon, weight: .medium)) // as the menu's
                            .frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Chat")
                    Button {
                        composerFocused = false
                        showContext = true
                    } label: {
                        ContextRing(fraction: conversation?.lastUsage == nil ? nil : contextFraction)
                            .frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    GlassIconMenuPlain(systemName: "ellipsis", label: "More") { menuContent }
                }
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm) // 8pt below the 44pt buttons, clear of the blur edge
        }
        // Glass under every piece: the list's soft top edge effect only blurs and fades what scrolls by.
    }
    #endif

    @ViewBuilder
    var menuContent: some View {
        Button("New Chat", systemImage: "square.and.pencil", action: onNewChat)
        Divider()
        if let c = conversation {
            Button(c.isPinned ? "Unpin" : "Pin", systemImage: c.isPinned ? "pin.slash" : "pin") {
                c.isPinned.toggle()
                try? context.save()
            }
            Button("Rename", systemImage: "pencil") {
                renameText = c.displayTitle
                showRename = true
            }
            Button("Regenerate title", systemImage: "wand.and.stars") {
                controller.autoRename(conversation: c, context: context, force: true)
            }
            .disabled(controller.isStreaming(c) || controller.isTitling(c.id))
            ShareLink(item: c.transcript) { Label("Share as text", systemImage: "square.and.arrow.up") }
            Button("Summarize now", systemImage: "text.line.first.and.arrowtriangle.forward") {
                controller.compactNow(conversation: c, context: context)
            }
            .disabled(controller.isStreaming(c) || c.activePath.isEmpty)
            Button("Conversation details", systemImage: "info.circle") { showDetails = true }
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            Divider()
        }
        Button("Settings", systemImage: "gearshape", action: onOpenSettings)
    }
}
