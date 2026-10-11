#if DEBUG
import Foundation

/// Debug-only launch arguments used for simulator smoke runs against a local mock server.
///   -StrataMockBaseURL http://127.0.0.1:8765/v1   point the Strata connection at the mock
///   -StrataMockKey test-key                        store a fake key in the Keychain
///   -StrataFakeTools 1                             canned web_search/web_fetch results (no network)
///   -StrataAutoSend "hello"                        send a message right after launch
///   -StrataOpenSheet usage|model|settings|attach   open a sheet right after launch
/// Canned tool results so the UI can be exercised without the network.
struct FakeWebTools: ToolExecuting {
    func execute(name: String, arguments: String) async -> ToolOutput {
        try? await Task.sleep(for: .seconds(1.4))
        if name == ToolNames.webSearch {
            return ToolOutput(text: "fake", sources: [
                SourceCandidate(title: "Applying Liquid Glass to custom views", url: "https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views", content: "Configure, combine, and morph views using Liquid Glass effects in SwiftUI."),
                SourceCandidate(title: "SwiftUI quick start", url: "https://www.hackingwithswift.com/quick-start/swiftui", content: "Learn SwiftUI and build apps with glass effects."),
                SourceCandidate(title: "Streaming Markdown in Swift", url: "https://github.com/example/streaming-markdown", content: "An incremental Markdown renderer."),
            ])
        }
        return ToolOutput(text: "fake", sources: [
            SourceCandidate(title: "Applying Liquid Glass to custom views", url: "https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views", content: "Use glassEffect on controls, group them in a GlassEffectContainer, and morph with glassEffectID. Body text should never sit on glass."),
        ])
    }
}

enum DebugHooks {
    /// `-StrataAutoPickRecent 1`: the attach sheet's strip picks its first photo by itself.
    static var autoPickRecent: Bool { UserDefaults.standard.bool(forKey: "StrataAutoPickRecent") }

    static var fakeTools: Bool { UserDefaults.standard.bool(forKey: "StrataFakeTools") }

    static func value(_ name: String) -> String? {
        UserDefaults.standard.string(forKey: name)
    }

    @MainActor
    static func applyLaunchConfiguration(connections: ConnectionStore, settings: AppSettings) {
        guard let base = value("StrataMockBaseURL") else { return }
        var strata = connections.connection(Connection.strataID) ?? .strataPreset()
        strata.baseURL = base
        connections.upsert(strata)
        if let key = value("StrataMockKey") { try? connections.setAPIKey(key, for: Connection.strataID) }
    }

    static var autoSend: String? { value("StrataAutoSend") }
    static var openSheet: String? { value("StrataOpenSheet") }
}
#endif
