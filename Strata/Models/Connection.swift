import Foundation

/// A model offered by a connection, with per-model capability flags.
struct ModelInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    /// Context length reported by `/models` (if any).
    var fetchedContextLength: Int?
    /// User override of the context length.
    var contextLength: Int?
    var supportsImages: Bool
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
        contextLength = try c.decodeIfPresent(Int.self, forKey: .contextLength)
        supportsImages = try c.decodeIfPresent(Bool.self, forKey: .supportsImages) ?? false
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

    init(id: UUID = UUID(), name: String, baseURL: String, customHeaders: String = "", models: [ModelInfo] = []) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.customHeaders = customHeaders
        self.models = models
    }

    static func strataPreset() -> Connection {
        Connection(id: strataID, name: "Strata", baseURL: strataBaseURL)
    }

    var isStrata: Bool { id == Connection.strataID }

    /// Defaults for newly discovered models on this connection.
    func defaultModel(id modelID: String, fetchedContextLength: Int?) -> ModelInfo {
        ModelInfo(id: modelID,
                  fetchedContextLength: fetchedContextLength,
                  supportsImages: false,
                  supportsEffort: isStrata,
                  supportsTools: true)
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

/// Everything needed to talk to one model on one connection.
struct Endpoint: Sendable {
    var connectionID: UUID
    var connectionName: String
    var baseURL: URL
    var apiKey: String?
    var headers: [String: String]
    var model: ModelInfo
}
