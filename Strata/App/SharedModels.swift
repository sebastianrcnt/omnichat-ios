import SwiftUI

/// The app's one AppSettings, ConnectionStore and ChatController, created on first use.
///
/// Views read them through the environment keys below instead of `@Environment(Type.self)`. That lookup is a
/// fatalError when the object is missing, and a hosting context that does not inherit the root environment (seen on
/// "My Mac (Designed for iPhone)") would take the app down. A key with a default cannot fail.
@MainActor
enum SharedModels {
    static let settings = AppSettings()

    static let connections: ConnectionStore = {
        let connections = ConnectionStore()
        #if DEBUG
        DebugHooks.applyLaunchConfiguration(connections: connections, settings: settings)
        #endif
        return connections
    }()

    static let controller: ChatController = {
        var tools: any ToolExecuting = ToolRouter()
        #if DEBUG
        if DebugHooks.fakeTools { tools = FakeWebTools() }
        #endif
        return ChatController(connections: connections, settings: settings, tools: tools)
    }()
}

extension EnvironmentValues {
    // Environment reads happen on the main thread; the macro's default is not main-actor isolated.
    @Entry var appSettings: AppSettings = MainActor.assumeIsolated { SharedModels.settings }
    @Entry var connectionStore: ConnectionStore = MainActor.assumeIsolated { SharedModels.connections }
    @Entry var chatController: ChatController = MainActor.assumeIsolated { SharedModels.controller }
}
