#if os(macOS)
import SwiftUI

struct StrataCommands: Commands {
    private let controller = SharedModels.controller

    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { WindowActions.shared.newChat() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("Find Chats") { WindowActions.shared.findChats() }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("Chat") {
            Button("Stop Generating") { controller.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!controller.isStreaming)
        }
    }
}
#endif
