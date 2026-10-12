#if os(macOS)
import SwiftUI

struct StrataCommands: Commands {
    @FocusedValue(\.windowActions) private var window
    private let controller = SharedModels.controller

    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { window?.newChat() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(window == nil)
        }
        CommandMenu("Chat") {
            Button("Stop Generating") { controller.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!controller.isStreaming)
        }
    }
}
#endif
