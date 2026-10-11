#if DEBUG
import Foundation

/// Debug-only launch arguments used for simulator smoke runs against a local mock server.
///   -StrataMockBaseURL http://127.0.0.1:8765/v1   point the Strata connection at the mock
///   -StrataMockKey test-key                        store a fake key in the Keychain
///   -StrataAutoSend "hello"                        send a message right after launch
///   -StrataOpenSheet usage|model|settings|attach   open a sheet right after launch
enum DebugHooks {
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
