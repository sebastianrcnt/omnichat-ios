import Foundation

/// Which OpenCode inference gateway a connection uses. Both take the same token; Go is the subscription.
enum OpenCodeGateway: String, Codable, Sendable, CaseIterable, Identifiable {
    /// OpenCode Go: open coding models on a monthly plan with usage limits.
    case go
    /// The Console's pay-as-you-go models (formerly OpenCode Zen), billed from the workspace balance.
    case console

    var id: String { rawValue }

    /// The gateway base. models.dev and the docs' model tables give these; the older `/zen/v1` and `/zen/go/v1` paths
    /// forward to the same service.
    var baseURL: URL {
        switch self {
        case .go: URL(string: "https://opencode.ai/inference/go/v1")!
        case .console: URL(string: "https://opencode.ai/inference/v1")!
        }
    }

    /// The provider id in the Console config and in models.dev.
    var providerID: String {
        switch self {
        case .go: "opencode-go"
        case .console: "opencode"
        }
    }

    var title: String {
        switch self {
        case .go: String(localized: "OpenCode Go")
        case .console: String(localized: "Pay as you go")
        }
    }

    /// The gateways a Console config lists (`{"providers": {"opencode": …, "opencode-go": …}}`).
    static func available(inConfig data: Data) -> Set<OpenCodeGateway>? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [String: Any] else { return nil }
        return Set(allCases.filter { providers[$0.providerID] != nil })
    }
}

/// The API family that serves a model. Each model on a gateway is served by exactly one.
enum OpenCodeModelAPI: String, Codable, Sendable {
    /// `POST /chat/completions` (`@ai-sdk/openai-compatible`): the open models.
    case chatCompletions
    /// `POST /responses` (`@ai-sdk/openai`): GPT, Grok, Muse Spark.
    case responses
    /// `POST /messages` (`@ai-sdk/anthropic`): Claude, Qwen, MiniMax on Go.
    case messages
    /// `POST /models/<id>:streamGenerateContent` (`@ai-sdk/google`): Gemini. Not supported yet.
    case gemini

    /// The path under the gateway base.
    func path(model: String) -> String {
        switch self {
        case .chatCompletions: "chat/completions"
        case .responses: "responses"
        case .messages: "messages"
        case .gemini: "models/\(model):streamGenerateContent"
        }
    }

    /// Whether Strata can talk this API.
    var isSupported: Bool { self != .gemini }

    /// From models.dev's `provider.npm` of the model (the provider's own npm, `@ai-sdk/openai-compatible`, when absent).
    init?(npm: String) {
        let npm = npm.lowercased()
        if npm.contains("anthropic") { self = .messages }
        else if npm.contains("google") { self = .gemini }
        else if npm == "@ai-sdk/openai" { self = .responses }
        else if npm.contains("openai-compatible") { self = .chatCompletions }
        else { return nil }
    }

    /// For a model models.dev doesn't describe: the families the docs' endpoint tables put on each API.
    static func guess(model: String, gateway: OpenCodeGateway) -> OpenCodeModelAPI {
        let id = model.lowercased()
        if id.hasPrefix("gpt-") || id.hasPrefix("grok") || id.hasPrefix("muse-spark") { return .responses }
        if id.hasPrefix("claude-") { return .messages }
        if id.hasPrefix("gemini-") { return .gemini }
        if id.hasPrefix("qwen") { return id.hasPrefix("qwen3.8-max") && gateway == .console ? .chatCompletions : .messages }
        if gateway == .go && id.hasPrefix("minimax-") { return .messages }
        return .chatCompletions
    }
}

/// What an OpenCode model needs beyond `ModelInfo`: its API, and the effort levels it takes.
struct OpenCodeModelInfo: Codable, Hashable, Sendable {
    var api: OpenCodeModelAPI
    /// The `effort` values models.dev lists for the model, as Strata levels (lowest first). Empty: no effort control.
    var efforts: [Effort] = []
    /// Reasoning goes back to the model with the turn's tool results (`interleaved.field: "reasoning_content"`).
    var interleavedReasoning = false
}

/// The models of an OpenCode gateway: ids from the gateway's `/models` (what it serves now), described by models.dev
/// (name, API family, limits, image input, reasoning options).
enum OpenCodeModelsAPI {
    struct Entry: Sendable, Equatable {
        var id: String
        var name: String?
        var info: OpenCodeModelInfo
        var contextLength: Int?
        var maxOutputTokens: Int?
        var supportsImages: Bool?
        var supportsTools: Bool?
    }

    /// The gateway's `{"data": [{"id": …}]}`.
    static func parseIDs(_ data: Data) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            throw APIError.server(String(localized: "OpenCode returned an unexpected model list. Try again."))
        }
        return list.compactMap { ($0["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// One gateway's models from models.dev's `api.json` (`{"opencode-go": {"npm": …, "models": {id: {…}}}}`).
    static func parseMetadata(_ data: Data, gateway: OpenCodeGateway) -> [String: Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = root[gateway.providerID] as? [String: Any],
              let models = provider["models"] as? [String: [String: Any]] else { return [:] }
        let defaultNPM = provider["npm"] as? String ?? "@ai-sdk/openai-compatible"
        var out: [String: Entry] = [:]
        for (key, item) in models {
            let id = (item["id"] as? String) ?? key
            let npm = (item["provider"] as? [String: Any])?["npm"] as? String ?? defaultNPM
            let api = OpenCodeModelAPI(npm: npm) ?? .guess(model: id, gateway: gateway)
            let limit = item["limit"] as? [String: Any]
            let inputs = (item["modalities"] as? [String: Any])?["input"] as? [String]
            var info = OpenCodeModelInfo(api: api)
            if item["reasoning"] as? Bool == true {
                info.efforts = efforts(item["reasoning_options"])
            }
            info.interleavedReasoning = (item["interleaved"] as? [String: Any])?["field"] as? String == "reasoning_content"
            out[id] = Entry(id: id, name: item["name"] as? String, info: info,
                            contextLength: positive(limit?["context"]), maxOutputTokens: positive(limit?["output"]),
                            supportsImages: inputs.map { $0.contains("image") },
                            supportsTools: item["tool_call"] as? Bool)
        }
        return out
    }

    /// `reasoning_options: [{"type": "effort", "values": ["none", "low", …]}]` as Strata levels; toggles and token
    /// budgets give none.
    static func efforts(_ options: Any?) -> [Effort] {
        guard let list = options as? [[String: Any]] else { return [] }
        let values = list.filter { $0["type"] as? String == "effort" }.flatMap { $0["values"] as? [String] ?? [] }
        return Effort.allCases.filter { values.contains($0.rawValue) }
    }

    /// Joins the gateway's ids with the metadata, in the gateway's order. Without a gateway list, models.dev's ids are
    /// used (sorted). Models whose API Strata can't talk are returned apart.
    static func merge(ids: [String]?, metadata: [String: Entry], gateway: OpenCodeGateway) -> (supported: [Entry], unsupported: [String]) {
        let list = ids ?? metadata.keys.sorted()
        var seen = Set<String>()
        var supported: [Entry] = []
        var unsupported: [String] = []
        for id in list where seen.insert(id).inserted {
            let entry = metadata[id] ?? Entry(id: id, info: OpenCodeModelInfo(api: .guess(model: id, gateway: gateway)))
            if entry.info.api.isSupported { supported.append(entry) } else { unsupported.append(id) }
        }
        return (supported, unsupported)
    }

    /// Fetches the gateway list (with the token, so it can be the account's) and the metadata, in parallel. Either may
    /// fail alone; both failing is an error.
    static func fetch(connectionID: UUID, gateway: OpenCodeGateway, auth: any OpenCodeTokenProviding,
                      session: URLSession = .shared) async throws -> (supported: [Entry], unsupported: [String]) {
        let token = try await auth.accessToken(connectionID: connectionID)
        async let idsResult = Result { try await gatewayIDs(gateway: gateway, token: token, session: session) }
        async let metadataResult = Result { try await metadata(gateway: gateway, session: session) }
        let (ids, meta) = await (idsResult, metadataResult)
        if case .failure(let error) = ids, case .failure = meta { throw error }
        let merged = merge(ids: try? ids.get(), metadata: (try? meta.get()) ?? [:], gateway: gateway)
        OpenCodeAuth.log.debug("""
            models gateway=\(gateway.rawValue, privacy: .public) supported=\(merged.supported.count, privacy: .public) \
            unsupported=\(merged.unsupported.count, privacy: .public) metadata=\((try? meta.get())?.count ?? -1, privacy: .public)
            """)
        return merged
    }

    private static func gatewayIDs(gateway: OpenCodeGateway, token: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: gateway.baseURL.appendingPathComponent("models"))
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(OpenCodeAPI.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw OpenCodeErrorMapper.error(status: status, data: data, gateway: gateway) }
        return try parseIDs(data)
    }

    private static func metadata(gateway: OpenCodeGateway, session: URLSession) async throws -> [String: Entry] {
        var req = URLRequest(url: OpenCodeAPI.metadataURL)
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.http(status: status, message: "models.dev") }
        let parsed = parseMetadata(data, gateway: gateway)
        if parsed.isEmpty { throw APIError.server("models.dev") }
        return parsed
    }

    private static func positive(_ value: Any?) -> Int? {
        if let n = value as? Int, n > 0 { return min(n, ContextLimits.maxTokens) }
        if let d = value as? Double, d > 0 { return Int(exactly: d.rounded(.down)).map { min($0, ContextLimits.maxTokens) } }
        return nil
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
