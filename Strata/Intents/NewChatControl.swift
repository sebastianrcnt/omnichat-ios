#if os(iOS)
import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center control's action: opens the app to a new chat, as New Chat (`NewChatIntent`) does without text.
/// Compiled into the app and the widget extension (which can't link the app's intents): the system runs it in the
/// app, which it opens first; the extension's copy only names it.
struct NewChatControlIntent: AppIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description = IntentDescription("Opens OmniChat to a new chat.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    /// Shortcuts lists New Chat already; this one is for the control.
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        IntentRouter.shared.startNewChat(text: nil)
        #endif
        return .result()
    }
}

/// "New Chat" in Control Center, on the Lock Screen and on the Action button.
struct NewChatControl: ControlWidget {
    static let kind = "cc.coolservices.strata.control.newChat"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: NewChatControlIntent()) {
                Label("New Chat", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Chat")
        .description("Opens OmniChat to a new chat.")
    }
}
#endif
