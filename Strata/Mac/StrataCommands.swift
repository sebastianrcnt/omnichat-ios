#if os(macOS)
import SwiftUI

struct StrataCommands: Commands {
    private let controller = SharedModels.controller
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                showMainWindow()
                WindowActions.shared.newChat()
            }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("Find Chats") {
                showMainWindow()
                WindowActions.shared.findChats()
            }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("Chat") {
            // The chat on screen: other chats' replies go on.
            Button("Stop Generating") { controller.visibleConversationID.map { controller.stop(conversationID: $0) } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!(controller.visibleConversationID.map(controller.isRunning) ?? false))
            Button("Regenerate Response") { WindowActions.shared.regenerate?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(controller.visibleConversationID.map(controller.isRunning) ?? false)
            Button("Copy Last Answer") { WindowActions.shared.copyLastAnswer?() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button("Previous Chat") { WindowActions.shared.selectChat(.previous) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Chat") { WindowActions.shared.selectChat(.next) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            ForEach(1...9, id: \.self) { n in
                Button("Chat \(n)") { WindowActions.shared.selectChat(.index(n - 1)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }
    }

    /// The chat window in front, even when it was minimized, closed or behind Settings: these commands act on it.
    private func showMainWindow() {
        openWindow(id: "main")
        for window in NSApp.windows where window.isMiniaturized && window.identifier?.rawValue.hasPrefix("main") == true {
            window.deminiaturize(nil)
        }
    }
}
#endif
