import AppIntents

/// The App Shortcuts: in Shortcuts and Spotlight from installation, and spoken to Siri with no setup. Every phrase
/// names the app (the system requires it); Siri asks for the prompt or the chat when the phrase doesn't give it.
struct OpenChatShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskOpenChatIntent(), phrases: [
            "Ask \(.applicationName)",
            "Ask \(.applicationName) a question",
            "Ask a question in \(.applicationName)",
            "Chat with \(.applicationName)",
        ], shortTitle: "Ask OpenChat", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: NewChatIntent(), phrases: [
            "New chat in \(.applicationName)",
            "Start a new chat in \(.applicationName)",
            "Start a chat in \(.applicationName)",
            "New \(.applicationName) chat",
        ], shortTitle: "New Chat", systemImageName: "square.and.pencil")
        AppShortcut(intent: OpenChatIntent(), phrases: [
            "Open \(\.$target) in \(.applicationName)",
            "Open a chat in \(.applicationName)",
            "Continue a chat in \(.applicationName)",
        ], shortTitle: "Open Chat", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: SummarizeIntent(), phrases: [
            "Summarize with \(.applicationName)",
            "Summarize this with \(.applicationName)",
            "Summarize a page with \(.applicationName)",
        ], shortTitle: "Summarize", systemImageName: "text.append")
        AppShortcut(intent: TranscribeVideoIntent(), phrases: [
            "Transcribe a video with \(.applicationName)",
            "Get a video transcript with \(.applicationName)",
        ], shortTitle: "Transcribe Video", systemImageName: "captions.bubble")
    }

    static let shortcutTileColor: ShortcutTileColor = .grayBlue
}
