import Foundation

/// What an Anthropic model takes beyond `ModelInfo`: how it thinks and which `output_config.effort` levels it accepts.
/// From the `capabilities` of `GET /v1/models`, or for a model the list doesn't describe (a proxy that leaves them out,
/// a model added by hand) from its family (`AnthropicModels.family`).
struct AnthropicModelInfo: Codable, Hashable, Sendable {
    enum ThinkingMode: String, Codable, Sendable {
        /// `thinking: {type: "adaptive"}`, depth steered by effort (Claude 4.6 and later).
        case adaptive
        /// `thinking: {type: "enabled", budget_tokens: N}` (Claude 3.7 to 4.5): the app's effort picks the budget.
        case budget
        /// No thinking.
        case none
    }

    var thinking: ThinkingMode
    /// The levels `output_config.effort` takes, lowest first. Empty: the parameter is refused (Claude 4.5 and older,
    /// except Opus 4.5).
    var efforts: [Effort] = []

    init(thinking: ThinkingMode, efforts: [Effort] = []) {
        self.thinking = thinking
        self.efforts = efforts
    }

    // Lenient: a value a later version writes (a new thinking mode or level, synced from another device) must not make
    // the connection unreadable here.
    private enum CodingKeys: String, CodingKey { case thinking, efforts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thinking = (try? c.decode(String.self, forKey: .thinking)).flatMap(ThinkingMode.init(rawValue:)) ?? .none
        efforts = ((try? c.decode([String].self, forKey: .efforts)) ?? []).compactMap(Effort.init(rawValue:))
    }

    /// The levels the effort picker offers, lowest first. A budget model takes no `effort`, but the app's level still
    /// picks its thinking budget, so it gets every level.
    var pickerLevels: [Effort] {
        if !efforts.isEmpty { return efforts }
        return thinking == .budget ? Effort.allCases : []
    }
}

enum AnthropicModels {
    static let defaultBaseURL = "https://api.anthropic.com/v1"

    /// What a model's id says about it when the list gives no capabilities: thinking, effort levels, context window and
    /// output cap, as Anthropic's model tables give them for each generation. Nil for an id that isn't a Claude model.
    struct Family: Equatable, Sendable {
        var info: AnthropicModelInfo
        var contextLength: Int
        var maxOutputTokens: Int
    }

    static func family(of modelID: String) -> Family? {
        let id = modelID.lowercased()
        guard id.hasPrefix("claude-") else { return nil }
        // Claude 3 ids put the version first: claude-3-5-sonnet-20241022, claude-3-7-sonnet-latest, claude-3-opus-….
        if id.hasPrefix("claude-3-7") {
            return Family(info: .init(thinking: .budget), contextLength: 200_000, maxOutputTokens: 64_000)
        }
        if id.hasPrefix("claude-3") || id.hasPrefix("claude-2") || id.hasPrefix("claude-instant") {
            return Family(info: .init(thinking: .none), contextLength: 200_000, maxOutputTokens: 8192)
        }
        // Later ids put the line first: claude-opus-4-1-20250805, claude-sonnet-4-20250514, claude-haiku-5-5.
        let parts = id.split(separator: "-").dropFirst()
        let line = parts.first.map(String.init) ?? ""
        let numbers = parts.dropFirst().prefix { $0.count <= 2 && Int($0) != nil }.compactMap { Int($0) }
        let major = numbers.first ?? 99
        let minor = numbers.dropFirst().first ?? 0
        let version = major * 10 + min(minor, 9)
        switch version {
        case ..<45:
            // Claude 4.0 and 4.1: budget thinking, no effort.
            return Family(info: .init(thinking: .budget), contextLength: 200_000, maxOutputTokens: line == "opus" ? 32_000 : 64_000)
        case 45:
            return Family(info: .init(thinking: .budget, efforts: line == "opus" ? [.low, .medium, .high] : []),
                          contextLength: 200_000, maxOutputTokens: 64_000)
        case 46:
            return Family(info: .init(thinking: .adaptive, efforts: [.low, .medium, .high, .max]),
                          contextLength: 1_000_000, maxOutputTokens: line == "opus" ? 128_000 : 64_000)
        case 47, 48:
            return Family(info: .init(thinking: .adaptive, efforts: Effort.allCases), contextLength: 1_000_000, maxOutputTokens: 128_000)
        default:
            // Claude 5 and anything newer than this table: adaptive thinking and every level.
            return Family(info: .init(thinking: .adaptive, efforts: Effort.allCases), contextLength: 1_000_000, maxOutputTokens: 128_000)
        }
    }

    /// A model of an Anthropic connection that `/models` didn't describe (added by hand, or a request for an id no longer
    /// listed): what its family says. Every current Claude model reads images and calls tools.
    static func model(id: String) -> ModelInfo {
        let family = family(of: id)
        var model = ModelInfo(id: id, fetchedContextLength: family?.contextLength, supportsImages: family != nil,
                              supportsEffort: !(family?.info.pickerLevels.isEmpty ?? true), supportsTools: true)
        model.maxOutputTokens = family?.maxOutputTokens
        model.anthropic = family?.info
        return model
    }

    /// How a model thinks and the levels it takes: its own catalog entry, else its family's.
    static func info(for model: ModelInfo) -> AnthropicModelInfo {
        model.anthropic ?? family(of: model.id)?.info ?? AnthropicModelInfo(thinking: .none)
    }

    /// The `thinking` and `output_config.effort` of a request.
    /// - Parameters:
    ///   - requested: the chat's level (`ChatRequest.reasoningEffort`), "none" from the title request, or nil when the
    ///     model's effort is off in its settings.
    ///   - maxTokens: the request's `max_tokens`; a budget must stay below it.
    /// The level is the chat's as one the model offers (`Effort.resolved`). Adaptive models get it as `effort`; budget
    /// models think up to the level's token cap (`Effort.thinkingTokenCap`), at least the API's 1,024. "none" leaves
    /// `thinking` out (off on the models that allow it, adaptive on those that always think) at the lowest level, so a
    /// title costs little.
    static func controls(for model: ModelInfo, requested: String?, maxTokens: Int) -> (thinking: MessagesRequest.Thinking?, effort: String?) {
        let info = info(for: model)
        if requested == "none" {
            return (nil, info.efforts.first?.apiValue)
        }
        let level = requested.flatMap(Effort.init(rawValue:)).map { $0.resolved(in: info.pickerLevels) }
        let effort = level.flatMap { info.efforts.isEmpty ? nil : $0.resolved(in: info.efforts).apiValue }
        switch info.thinking {
        case .adaptive:
            return (.adaptive, effort)
        case .budget:
            // The API wants 1,024 to `max_tokens - 1`; a request too small for that (a capped side request) thinks not at all.
            let ceiling = maxTokens - 1
            guard ceiling >= minimumBudget else { return (nil, effort) }
            let wanted = (level ?? .medium).thinkingTokenCap ?? maxBudget
            return (.budget(min(max(wanted, minimumBudget), ceiling)), effort)
        case .none:
            return (nil, effort)
        }
    }

    static let minimumBudget = 1024
    /// Max effort's budget on a budget model: the most the docs advise outside batch processing.
    static let maxBudget = 32_000
}

/// `GET /v1/models`, paginated: the models the key can use, newest first, with their limits and capabilities.
enum AnthropicModelsAPI {
    struct Entry: Sendable, Equatable {
        var id: String
        var displayName: String?
        var contextLength: Int?
        var maxOutputTokens: Int?
        var supportsImages: Bool?
        var info: AnthropicModelInfo
    }

    struct Page: Sendable, Equatable {
        var entries: [Entry]
        var hasMore: Bool
        var lastID: String?
    }

    /// The page size asked for (the API allows up to 1,000), and how many pages are followed at most.
    static let pageSize = 1000
    static let maxPages = 20

    static func parse(_ data: Data) throws -> Page {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            throw APIError.server(String(localized: "Anthropic returned an unexpected model list. Try again."))
        }
        let entries = list.compactMap { item -> Entry? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let family = AnthropicModels.family(of: id)
            let caps = item["capabilities"] as? [String: Any]
            return Entry(id: id, displayName: item["display_name"] as? String,
                         contextLength: positive(item["max_input_tokens"]) ?? family?.contextLength,
                         maxOutputTokens: positive(item["max_tokens"]) ?? family?.maxOutputTokens,
                         supportsImages: caps.flatMap { supported($0["image_input"]) } ?? (family != nil ? true : nil),
                         info: caps.map(info(capabilities:)) ?? family?.info ?? AnthropicModelInfo(thinking: .none))
        }
        return Page(entries: entries, hasMore: root["has_more"] as? Bool ?? false, lastID: root["last_id"] as? String)
    }

    /// `capabilities.thinking.types` and `capabilities.effort` as the app's model info. Adaptive thinking wins over a
    /// budget where a model takes both.
    static func info(capabilities caps: [String: Any]) -> AnthropicModelInfo {
        let thinking = caps["thinking"] as? [String: Any]
        let types = thinking?["types"] as? [String: Any]
        let mode: AnthropicModelInfo.ThinkingMode
        if supported(types?["adaptive"]) == true { mode = .adaptive }
        else if supported(types?["enabled"]) == true { mode = .budget }
        else { mode = .none }
        var efforts: [Effort] = []
        if let effort = caps["effort"] as? [String: Any], effort["supported"] as? Bool == true {
            efforts = Effort.allCases.filter { supported(effort[$0.rawValue]) == true }
        }
        return AnthropicModelInfo(thinking: mode, efforts: efforts)
    }

    /// `{"supported": true}`.
    private static func supported(_ value: Any?) -> Bool? {
        (value as? [String: Any])?["supported"] as? Bool
    }

    private static func positive(_ value: Any?) -> Int? {
        if let n = value as? Int, n > 0 { return min(n, ContextLimits.maxTokens) }
        if let d = value as? Double, d > 0 { return Int(exactly: d.rounded(.down)).map { min($0, ContextLimits.maxTokens) } }
        return nil
    }

    static func fetch(endpoint: Endpoint, session: URLSession = .shared) async throws -> [Entry] {
        guard let key = endpoint.apiKey, !key.isEmpty else { throw APIError.missingAPIKey(connection: endpoint.connectionName) }
        var entries: [Entry] = []
        var after: String?
        for _ in 0..<maxPages {
            var components = URLComponents(url: endpoint.baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "limit", value: String(pageSize))]
                + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            guard let url = components?.url else { throw APIError.invalidBaseURL }
            var req = AnthropicClient.request(url: url, endpoint: endpoint, key: key)
            req.httpMethod = "GET"
            req.timeoutInterval = 20
            let (data, response) = try await session.data(for: req)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw AnthropicErrorMapper.error(status: status, data: data, retryAfter: http?.value(forHTTPHeaderField: "retry-after"),
                                                 connection: endpoint.connectionName)
            }
            let page = try parse(data)
            entries += page.entries.filter { e in !entries.contains { $0.id == e.id } }
            guard page.hasMore, let last = page.lastID, last != after else { break }
            after = last
        }
        return entries
    }
}
