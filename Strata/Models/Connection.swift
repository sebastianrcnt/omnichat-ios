import Foundation

/// A model offered by a connection, with per-model capability flags.
struct ModelInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    /// Context length reported by `/models` (if any).
    var fetchedContextLength: Int?
    /// User override of the context length.
    var contextLength: Int?
    /// The largest answer the model can give, when `/models` says (compaction keeps room for it).
    var maxOutputTokens: Int?
    var supportsImages: Bool
    /// The user set `supportsImages` by hand; `/models` never overrides it.
    var supportsImagesUserSet: Bool = false
    var supportsEffort: Bool
    var supportsTools: Bool
    /// Entered by hand rather than discovered from `/models`.
    var isManual: Bool

    init(id: String,
         fetchedContextLength: Int? = nil,
         contextLength: Int? = nil,
         supportsImages: Bool = false,
         supportsEffort: Bool = false,
         supportsTools: Bool = true,
         isManual: Bool = false) {
        self.id = id
        self.fetchedContextLength = fetchedContextLength
        self.contextLength = contextLength
        self.supportsImages = supportsImages
        self.supportsEffort = supportsEffort
        self.supportsTools = supportsTools
        self.isManual = isManual
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fetchedContextLength = try c.decodeIfPresent(Int.self, forKey: .fetchedContextLength)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        contextLength = try c.decodeIfPresent(Int.self, forKey: .contextLength)
        supportsImages = try c.decodeIfPresent(Bool.self, forKey: .supportsImages) ?? false
        supportsImagesUserSet = try c.decodeIfPresent(Bool.self, forKey: .supportsImagesUserSet) ?? false
        supportsEffort = try c.decodeIfPresent(Bool.self, forKey: .supportsEffort) ?? false
        supportsTools = try c.decodeIfPresent(Bool.self, forKey: .supportsTools) ?? true
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
    }

    /// User override, then the value from `/models`, then the app-wide default.
    func effectiveContextLength(default fallback: Int) -> Int {
        contextLength ?? fetchedContextLength ?? fallback
    }
}

/// An OpenAI-compatible endpoint. The API key lives in the Keychain, keyed by `id`.
struct Connection: Codable, Identifiable, Hashable, Sendable {
    static let strataID = UUID(uuidString: "5712A7A0-0000-4000-8000-000000000001")!
    static let strataBaseURL = "https://llm-api.coolservices.cc/v1"

    var id: UUID
    var name: String
    var baseURL: String
    /// One header per line, `Name: value`.
    var customHeaders: String
    var models: [ModelInfo]
    /// Sent as the first (system) message. Empty disables it.
    var systemPrompt: String
    var supportsResumable: Bool
    /// User-set display names, keyed by model id. Display-only: requests always send the real id. Kept apart from
    /// `models` so a name survives `/models` refreshes, even when a model briefly drops out of the list.
    var modelAliases: [String: String] = [:]

    init(id: UUID = UUID(), name: String, baseURL: String, customHeaders: String = "", models: [ModelInfo] = [],
         systemPrompt: String = DefaultPrompts.citation, supportsResumable: Bool? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.customHeaders = customHeaders
        self.models = models
        self.systemPrompt = systemPrompt
        self.supportsResumable = supportsResumable ?? (id == Self.strataID)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        customHeaders = try c.decodeIfPresent(String.self, forKey: .customHeaders) ?? ""
        models = try c.decodeIfPresent([ModelInfo].self, forKey: .models) ?? []
        supportsResumable = try c.decodeIfPresent(Bool.self, forKey: .supportsResumable) ?? (id == Self.strataID)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? DefaultPrompts.citation
        modelAliases = try c.decodeIfPresent([String: String].self, forKey: .modelAliases) ?? [:]
    }

    static func strataPreset() -> Connection {
        Connection(id: strataID, name: "Strata", baseURL: strataBaseURL)
    }

    var isStrata: Bool { id == Connection.strataID }

    /// Defaults for newly discovered models on this connection.
    func defaultModel(id modelID: String, fetchedContextLength: Int?, fetchedImages: Bool? = nil) -> ModelInfo {
        ModelInfo(id: modelID,
                  fetchedContextLength: fetchedContextLength,
                  supportsImages: fetchedImages ?? isStrata, // the Strata engine reads images
                  supportsEffort: isStrata,
                  supportsTools: true)
    }

    /// The user's name for a model, or nil when it has none.
    func alias(forModel modelID: String) -> String? { modelAliases[modelID] }

    /// What the UI shows for a model: its alias when set, else its id.
    func displayName(forModel modelID: String) -> String { alias(forModel: modelID) ?? modelID }

    /// Sets (or, for nil / blank text, removes) a model's alias. The text is trimmed and capped.
    mutating func setAlias(_ alias: String?, forModel modelID: String) {
        modelAliases[modelID] = ModelAlias.normalized(alias)
    }

    var parsedHeaders: [(name: String, value: String)] {
        customHeaders
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                guard let idx = line.firstIndex(of: ":") else { return nil }
                let name = line[..<idx].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : (name, value)
            }
    }

    /// Base URL with whitespace and any trailing slash removed.
    var normalizedBaseURL: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// Rules for user-set model display names.
enum ModelAlias {
    static let maxLength = 64

    /// Trimmed and capped at `maxLength` characters; nil when nothing is left.
    static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Everything needed to talk to one model on one connection.
struct Endpoint: Sendable {
    var connectionID: UUID
    var connectionName: String
    var baseURL: URL
    var apiKey: String?
    var headers: [String: String]
    var model: ModelInfo
    var systemPrompt: String = ""
    var supportsResumable: Bool = false
}
