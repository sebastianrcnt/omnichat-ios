#if DEBUG
import Foundation

/// Debug-only launch arguments used for simulator smoke runs against a local mock server.
///   -StrataMockBaseURL http://127.0.0.1:8765/v1   point the Strata connection at the mock
///   -StrataMockKey test-key                        store a fake key in the Keychain
///   -StrataFakeTools 1                             canned web_search/web_fetch results (no network)
///   -StrataAutoSend "hello"                        send a message right after launch
///   -StrataDebugBranch switch|editbar               after the first answer: edit + regenerate, or open edit mode
///   -StrataOpenSheet usage|model|settings|attach|details|diagnostics   open a sheet right after launch
/// Canned tool results so the UI can be exercised without the network.
struct FakeWebTools: ToolExecuting {
    func execute(name: String, arguments: String) async -> ToolOutput {
        if name == ToolNames.webFetch, let id = ToolContext.callID {
            // Walks the progress fill the way a real fetch would: loading, settling, extracting.
            let seconds = Double(DebugHooks.value("StrataFakeFetchSeconds") ?? "") ?? 1.4
            let steps = 20
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                let value = Double(i) / Double(steps)
                await MainActor.run { ToolProgress.shared.report(id, value) }
            }
        } else {
            try? await Task.sleep(for: .seconds(1.4))
        }
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

/// Stands in for the system translator in simulator runs: marks each block so structure and protected spans show.
struct FakeTranslator: TextTranslating {
    func translate(_ texts: [String]) async throws -> [String] {
        try await Task.sleep(for: .seconds(Double(DebugHooks.value("StrataFakeTranslateSeconds") ?? "") ?? 1.5))
        return texts.map { "(fr) " + $0 }
    }
}

enum DebugHooks {
    /// `-StrataWebSelfTest 1`: one real web_search (DuckDuckGo) and two real web_fetch calls through the on-device tools
    /// (hidden WKWebView, Readability), reported to stderr.
    @MainActor
    static func runWebSelfTest() {
        guard UserDefaults.standard.bool(forKey: "StrataWebSelfTest") else { return }
        func say(_ text: String) { FileHandle.standardError.write(Data("[web-selftest] \(text)\n".utf8)) }
        Task { @MainActor in
            let tools = ToolRouter()
            var started = ContinuousClock.now
            let search = await tools.execute(name: ToolNames.webSearch, arguments: #"{"query":"swift concurrency actors"}"#)
            say("search: error=\(search.isError) sources=\(search.sources.count) in \(ContinuousClock.now - started)")
            for source in search.sources.prefix(3) { say("  \(source.title.prefix(60)) | \(source.url.prefix(80))") }
            if search.isError || search.sources.isEmpty { say("  text: \(search.text.prefix(200))") }
            for url in ["https://example.com/", "https://en.wikipedia.org/wiki/Swift_(programming_language)"] {
                started = ContinuousClock.now
                let fetch = await tools.execute(name: ToolNames.webFetch, arguments: #"{"url":"\#(url)"}"#)
                say("fetch \(url): error=\(fetch.isError) chars=\(fetch.text.count) in \(ContinuousClock.now - started)")
                say("  \(fetch.text.prefix(160).replacingOccurrences(of: "\n", with: " "))")
            }
            say("done")
        }
    }

    /// `-StrataKeychainSelfTest 1`: saves, reads back, replaces and deletes a throwaway key through the same store the
    /// connections use, and prints the outcome (never the value) to stderr.
    static func runKeychainSelfTest() {
        guard UserDefaults.standard.bool(forKey: "StrataKeychainSelfTest") else { return }
        func say(_ text: String) { FileHandle.standardError.write(Data("[keychain-selftest] \(text)\n".utf8)) }
        let store = KeychainKeyStore(service: "cc.coolservices.strata.selftest")
        let id = UUID()
        do {
            try store.setKey("self-test-value-1", for: id)
            say("saved: \(store.key(for: id) == "self-test-value-1" ? "read back ok" : "READ BACK FAILED")")
            try store.setKey("self-test-value-2", for: id)
            say("replaced: \(store.key(for: id) == "self-test-value-2" ? "read back ok" : "READ BACK FAILED")")
            try store.setKey(nil, for: id)
            say("deleted: \(store.key(for: id) == nil ? "gone" : "STILL THERE")")
        } catch {
            say("FAILED: \(error.localizedDescription)")
        }
    }

    /// `-StrataPreferredLanguage fr` makes the reader's language French; `-StrataFakeTranslation 1` translates with
    /// `FakeTranslator` (the simulator has no languages installed).
    @MainActor
    static func configure(_ translation: TranslationService) {
        if let language = value("StrataPreferredLanguage") { translation.preferredLanguage = { language } }
        if UserDefaults.standard.bool(forKey: "StrataFakeTranslation") {
            translation.availability = { _, _ in .installed }
            translation.installedTranslator = { _, _ in FakeTranslator() }
        }
    }

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

    /// Opt-in simulator smoke artifacts. Never enabled for non-loopback endpoints.
    @MainActor
    static func recordResumeSmoke(_ message: Message, checkpoint: TurnCheckpoint? = nil) {
        guard UserDefaults.standard.bool(forKey: "StrataResumeReport"),
              let base = value("StrataMockBaseURL"),
              ["127.0.0.1", "localhost"].contains(URL(string: base)?.host ?? ""),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        var fields: [String: Any] = ["text": message.text, "reasoning": message.reasoning,
                                    "stopped": message.stoppedByUser, "steps": message.steps.count,
                                    "error": message.errorText ?? "", "pending": message.resumeData != nil]
        if let checkpoint {
            fields["request_id"] = checkpoint.requestID ?? ""
            fields["seq"] = checkpoint.lastSequence
            fields["idempotency_key"] = checkpoint.idempotencyKey ?? ""
            fields["submission_started"] = checkpoint.submissionStarted
        }
        let name = checkpoint == nil ? "resume-completion.json" : "resume-checkpoint.json"
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }

    static var autoSend: String? { value("StrataAutoSend") }
    @MainActor static var autoSendFired = false
    static var openSheet: String? { value("StrataOpenSheet") }
}
#endif
