import AppIntents
import CoreSpotlight
import SwiftData
import SwiftUI

/// Hands the app's controller, connections and SwiftData container to the intents and entity queries (`@Dependency`).
/// Registered from the app's `init`, which runs before the system performs an intent, also when it launches the app in
/// the background for one.
@MainActor
enum IntentDependencies {
    static func register(container: ModelContainer) {
        let controller = SharedModels.controller
        let connections = SharedModels.connections
        let settings = SharedModels.settings
        AppDependencyManager.shared.add(dependency: container)
        AppDependencyManager.shared.add(dependency: controller)
        AppDependencyManager.shared.add(dependency: connections)
        AppDependencyManager.shared.add(dependency: settings)
    }
}

/// Where an intent sends the window: to a chat (through `ReplyNotificationRouter.pending`, as a tapped notification
/// does) or to a new chat with text in the composer. A request can come before the window is up (an intent that
/// launched the app); the root takes it when it appears.
@MainActor
@Observable
final class IntentRouter {
    static let shared = IntentRouter()

    struct NewChat: Equatable {
        let id = UUID()
        var text: String?
    }

    /// A new chat the root should start.
    var newChat: NewChat?
    /// Text for the new chat's composer, taken by the chat view once it shows the new chat.
    var draft: NewChat?

    func open(_ conversationID: UUID) {
        _ = SharedModels.controller // creates the notification router the window watches
        ReplyNotificationRouter.shared?.pending = conversationID
    }

    func startNewChat(text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        newChat = NewChat(text: trimmed.isEmpty ? nil : trimmed)
    }

    /// The root started the new chat: its text goes to the composer.
    func took(_ request: NewChat) {
        guard newChat == request else { return }
        newChat = nil
        if request.text != nil { draft = request }
    }

    /// The text for an empty composer, once.
    func takeDraft() -> String? {
        defer { draft = nil }
        return draft?.text
    }
}

/// On the iPhone root and the Mac window: starts the new chats intents ask for, and keeps Spotlight's list of chats
/// current.
private struct IntentRoutes: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    let newChat: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: IntentRouter.shared.newChat, initial: true) { _, request in
                guard let request else { return }
                newChat()
                IntentRouter.shared.took(request)
            }
            .task { ChatSpotlight.reindex(context: context) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { ChatSpotlight.reindex(context: context) }
            }
    }
}

/// On the chat view: an empty chat takes the text an intent gave the new chat.
private struct IntentDraft: ViewModifier {
    let draft: ComposerDraft
    let isNewChat: Bool

    func body(content: Content) -> some View {
        content.onChange(of: DraftKey(isNewChat: isNewChat, request: IntentRouter.shared.draft?.id), initial: true) { _, key in
            guard key.isNewChat, key.request != nil, let text = IntentRouter.shared.takeDraft() else { return }
            draft.text = text
        }
    }

    private struct DraftKey: Equatable {
        var isNewChat: Bool
        var request: UUID?
    }
}

extension View {
    func intentRoutes(newChat: @escaping () -> Void) -> some View {
        modifier(IntentRoutes(newChat: newChat))
    }

    func intentDraft(_ draft: ComposerDraft, isNewChat: Bool) -> some View {
        modifier(IntentDraft(draft: draft, isNewChat: isNewChat))
    }
}

/// Recent chats in Spotlight: searching finds them by title and opening one runs Open Chat. The list is replaced
/// whole at launch and when the app goes to the background, which also drops deleted chats; cheaper than tracking
/// every rename and delete, and Spotlight only needs the recent ones.
@MainActor
enum ChatSpotlight {
    static let limit = 100
    private static var running: Task<Void, Never>?

    static func reindex(context: ModelContext) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return } // unit tests: no index
        #endif
        let entities = ConversationQuery.recent(in: context, limit: limit)
        running?.cancel()
        running = Task {
            let index = CSSearchableIndex.default()
            try? await index.deleteAppEntities(ofType: ConversationEntity.self)
            guard !Task.isCancelled else { return }
            try? await index.indexAppEntities(entities)
            OmniChatShortcuts.updateAppShortcutParameters() // "Open <chat> in OmniChat" knows the chats' names
        }
    }
}
