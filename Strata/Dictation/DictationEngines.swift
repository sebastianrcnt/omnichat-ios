import Foundation

/// The dictation engines Settings offers. A new engine (say an on-device Whisper model) is a case here, a branch in
/// `DictationSettings.resolve` and `ConfiguredDictationEngine.engine(for:)`, and its rows in Settings; callers keep
/// using `ConfiguredDictationEngine` and are not touched.
enum DictationEngineKind: String, CaseIterable, Identifiable, Sendable {
    /// Apple's on-device recognition (`SpeechDictationEngine`): live text, nothing leaves the device. The default.
    case apple
    /// An OpenAI-compatible `/audio/transcriptions` endpoint through one of the connections (`APIDictationEngine`).
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: String(localized: "Apple on-device")
        case .openAICompatible: String(localized: "OpenAI-compatible API")
        }
    }
}

/// Settings > Chats > Dictation: which engine, and for the API engine which connection and model. Read at each start,
/// like `DictationLanguage`, so a change applies to the next dictation.
///
/// The API engine reuses a connection's base URL, custom headers and Keychain key (no secrets of its own); any
/// OpenAI-compatible connection qualifies, including one added only for transcription (Groq, a local whisper server).
/// When the API engine is picked but its connection is gone or no model is set, dictation fails with
/// `DictationError.notConfigured` and says so: it does not fall back to Apple on-device silently, since the user chose
/// where their audio goes.
struct DictationSettings: Equatable, Sendable {
    nonisolated static let engineKey = "dictationEngine"
    nonisolated static let connectionKey = "dictationConnectionID"
    nonisolated static let modelKey = "dictationModel"

    /// Shown as the model field's prompt and offered in its menu.
    static let suggestedModels = ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe",
                                  "whisper-large-v3", "whisper-large-v3-turbo"]

    var engine: DictationEngineKind = .apple
    var connectionID: UUID?
    var model = ""

    static func load(_ defaults: UserDefaults = .standard) -> DictationSettings {
        DictationSettings(
            engine: defaults.string(forKey: engineKey).flatMap(DictationEngineKind.init(rawValue:)) ?? .apple,
            connectionID: defaults.string(forKey: connectionKey).flatMap(UUID.init(uuidString:)),
            model: defaults.string(forKey: modelKey) ?? "")
    }

    /// The connections the API engine can use: OpenAI-compatible ones with a valid base URL (ChatGPT and OpenCode
    /// accounts sign in to APIs without `/audio/transcriptions`).
    static func eligible(_ connections: [Connection]) -> [Connection] {
        connections.filter { $0.kind == .openAICompatible && $0.normalizedBaseURL != nil }
    }

    /// What dictation runs on with these settings.
    enum Resolved: Equatable, Sendable {
        case apple
        case api(TranscriptionEndpoint)
    }

    /// - Parameter key: the Keychain key of a connection.
    func resolve(connections: [Connection], key: (UUID) -> String?) throws(DictationError) -> Resolved {
        switch engine {
        case .apple:
            return .apple
        case .openAICompatible:
            let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, let connectionID,
                  let connection = Self.eligible(connections).first(where: { $0.id == connectionID }),
                  let base = connection.normalizedBaseURL else { throw .notConfigured }
            var headers: [String: String] = [:]
            for h in connection.parsedHeaders { headers[h.name] = h.value }
            return .api(TranscriptionEndpoint(baseURL: base, apiKey: key(connection.id), headers: headers, model: model))
        }
    }
}

/// The engine `DictationController` gets from the composer: it reads `DictationSettings` at each dictation and hands
/// every call to the engine they pick. Engines are kept between dictations (Apple's remembers which models failed).
///
/// A misconfigured API engine asks for no permission and fails at `start` with `.notConfigured`, which the dictation
/// UI shows like any other failure.
@MainActor
final class ConfiguredDictationEngine: DictationEngine {
    private let settings: () -> DictationSettings
    private let connections: () -> ConnectionStore
    private let session: URLSession
    private lazy var apple = SpeechDictationEngine()
    private var api: APIDictationEngine?
    /// The engine of the dictation under way, picked at `authorize`.
    private var active: (any DictationEngine)?
    private var configurationError: DictationError?

    init(settings: @escaping () -> DictationSettings = { DictationSettings.load() },
         connections: @escaping () -> ConnectionStore = { SharedModels.connections },
         session: URLSession = .shared) {
        self.settings = settings
        self.connections = connections
        self.session = session
    }

    var transcribesOnFinish: Bool { active?.transcribesOnFinish ?? false }

    /// The engine for `resolved`, reused when it fits.
    private func engine(for resolved: DictationSettings.Resolved) -> any DictationEngine {
        switch resolved {
        case .apple:
            return apple
        case .api(let endpoint):
            if let api, api.endpoint == endpoint { return api }
            let engine = APIDictationEngine(endpoint: endpoint, session: session)
            api = engine
            return engine
        }
    }

    func authorize() async -> DictationAuthorization {
        active?.cancel()
        active = nil
        configurationError = nil
        let store = connections()
        do {
            active = engine(for: try settings().resolve(connections: store.connections, key: store.apiKey(for:)))
        } catch {
            configurationError = error
            return .authorized // nothing to ask for; `start` reports what is missing
        }
        return await active?.authorize() ?? .authorized
    }

    func needsPreparation(for locale: Locale) async -> Bool {
        await active?.needsPreparation(for: locale) ?? false
    }

    func prepare(for locale: Locale) async throws {
        try await active?.prepare(for: locale)
    }

    func start(locale: Locale) async throws -> AsyncThrowingStream<DictationEvent, Error> {
        if let configurationError { throw configurationError }
        guard let active else { throw DictationError.notConfigured }
        return try await active.start(locale: locale)
    }

    func finish() async {
        await active?.finish()
    }

    func cancel() {
        active?.cancel()
    }
}
