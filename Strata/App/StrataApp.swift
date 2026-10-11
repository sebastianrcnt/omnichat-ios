import SwiftUI
import SwiftData

@main
struct StrataApp: App {
    private let container: ModelContainer
    @State private var settings: AppSettings
    @State private var connections: ConnectionStore
    @State private var controller: ChatController

    init() {
        MemoryPurge.install()
        let settings = AppSettings()
        let connections = ConnectionStore()
        #if DEBUG
        DebugHooks.applyLaunchConfiguration(connections: connections, settings: settings)
        #endif
        do {
            container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self)
        } catch {
            fatalError("Could not create the SwiftData container: \(error)")
        }
        _settings = State(initialValue: settings)
        _connections = State(initialValue: connections)
        var tools: any ToolExecuting = ToolRouter()
        #if DEBUG
        if DebugHooks.fakeTools { tools = FakeWebTools() }
        #endif
        _controller = State(initialValue: ChatController(connections: connections, settings: settings, tools: tools))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(connections)
                .environment(controller)
                .environment(\.theme, DSTheme(accent: settings.accent))
                .tint(settings.accent)
                .modelContainer(container)
        }
    }
}
