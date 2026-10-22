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
    /// The user set `supportsEffort` by hand (or it was saved before detection existed); `/models` never overrides it.
    var supportsEffortUserSet: Bool = false
    var supportsTools: Bool
    /// Entered by hand rather than discovered from `/models`.
    var isManual: Bool
    /// The name the server gives the model (ChatGPT's `display_name`), shown when the user set no alias.
    var fetchedDisplayName: String?
    /// An OpenCode model's API family and effort levels; nil on other connections.
    var openCode: OpenCodeModelInfo?

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
        // A model saved before `/models` could say anything about effort keeps the value it had: the user may have
        // set it, and nothing recorded whether they did.
        supportsEffortUserSet = try c.decodeIfPresent(Bool.self, forKey: .supportsEffortUserSet)
            ?? c.contains(.supportsEffort)
        supportsTools = try c.decodeIfPresent(Bool.self, forKey: .supportsTools) ?? true
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        fetchedDisplayName = try c.decodeIfPresent(String.self, forKey: .fetchedDisplayName)
        openCode = try c.decodeIfPresent(OpenCodeModelInfo.self, forKey: .openCode)
    }

    /// The reasoning effort levels this model offers, lowest first (none when it takes no `reasoning_effort`). An
    /// OpenCode model offers the levels its catalog lists.
    func effortLevels(_ style: EffortStyle) -> [Effort] {
        guard supportsEffort else { return [] }
        if let listed = openCode?.efforts, !listed.isEmpty { return listed }
        return Effort.levels(style)
    }

    /// "Images · Effort · Web tools": what the model can do, for a row subtitle.
    var capabilitiesSummary: String? {
        var parts: [String] = []
        if supportsImages { parts.append(String(localized: "Images")) }
        if supportsEffort { parts.append(String(localized: "Effort")) }
        if supportsTools { parts.append(String(localized: "Web tools")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// User override, then the value from `/models`, then the app-wide default.
    func effectiveContextLength(default fallback: Int) -> Int {
        contextLength ?? fetchedContextLength ?? fallback
    }
}

/// An OpenAI-compatible endpoint, a ChatGPT account, or an OpenCode account. The API key (or the sign-in) lives in the
/// Keychain, keyed by `id`.
struct Connection: Codable, Identifiable, Hashable, Sendable {
    /// What the connection talks to, which decides the API the requests use.
    enum Kind: String, Codable, Sendable {
        /// Chat Completions at `baseURL`, with an optional API key.
        case openAICompatible
        /// The user's ChatGPT plan through Sign in with ChatGPT: the Responses API at `api.openai.com`, with OAuth tokens.
        case chatGPT
        /// The user's OpenCode Console account (Go subscription or pay as you go), through the device-code sign-in or a
        /// service-account key: each model's own API family at the gateway of `openCodeGateway`.
        case openCode
        /// Apple's on-device model (Foundation Models): no key, no network (`OnDeviceClient`).
        case appleOnDevice
    }

    var id: UUID
    /// Saved connections from before the field existed are OpenAI-compatible.
    var kind: Kind = .openAICompatible
    var name: String
    var baseURL: String
    /// One header per line, `Name: value`.
    var customHeaders: String
    var models: [ModelInfo]
    var supportsResumable: Bool
    /// User-set display names, keyed by model id. Display-only: requests always send the real id. Kept apart from
    /// `models` so a name survives `/models` refreshes, even when a model briefly drops out of the list.
    var modelAliases: [String: String] = [:]
    /// Models the user hid from the composer's model menu ("Show in picker" off). Display-only, kept apart from
    /// `models` like the aliases so it survives `/models` refreshes.
    var hiddenModelIDs: Set<String> = []
    /// The gateway of an OpenCode connection (nil on other kinds).
    var openCodeGateway: OpenCodeGateway?
    /// OpenAI-compatible only: the API each model turned out to need (see `ResponsesFallback`), keyed by model id.
    /// Kept apart from `models` like the aliases, so it survives `/models` refreshes.
    var detectedModelAPIs: [String: ChatAPI] = [:]
    /// OpenAI-compatible only: the API the user picked for a model. No entry means Automatic.
    var modelAPIOverrides: [String: ChatAPI] = [:]
    /// OpenAI-compatible only: the API the user picked for the whole connection, for models without a pick of their own.
    /// Nil means Automatic (Chat Completions, switching when the server says a model needs the Responses API).
    var defaultChatAPI: ChatAPI?
    /// Whether newly found models take images when `/models` doesn't say. Each model can still be changed.
    var imagesByDefault = false
    /// Whether newly found models get reasoning effort when `/models` doesn't say. Each model can still be changed.
    var effortByDefault = false

    init(id: UUID = UUID(), kind: Kind = .openAICompatible, name: String, baseURL: String, customHeaders: String = "",
         models: [ModelInfo] = [], supportsResumable: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.customHeaders = customHeaders
        self.models = models
        self.supportsResumable = supportsResumable ?? false
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .openAICompatible
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        customHeaders = try c.decodeIfPresent(String.self, forKey: .customHeaders) ?? ""
        models = try c.decodeIfPresent([ModelInfo].self, forKey: .models) ?? []
        supportsResumable = try c.decodeIfPresent(Bool.self, forKey: .supportsResumable) ?? false
        modelAliases = try c.decodeIfPresent([String: String].self, forKey: .modelAliases) ?? [:]
        hiddenModelIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenModelIDs) ?? []
        openCodeGateway = try c.decodeIfPresent(OpenCodeGateway.self, forKey: .openCodeGateway)
        detectedModelAPIs = ChatAPI.decodeMap(c, forKey: .detectedModelAPIs)
        modelAPIOverrides = ChatAPI.decodeMap(c, forKey: .modelAPIOverrides)
        defaultChatAPI = (try? c.decodeIfPresent(String.self, forKey: .defaultChatAPI)).flatMap(ChatAPI.init(rawValue:))
        imagesByDefault = try c.decodeIfPresent(Bool.self, forKey: .imagesByDefault) ?? false
        effortByDefault = try c.decodeIfPresent(Bool.self, forKey: .effortByDefault) ?? false
    }

    /// A new ChatGPT account connection. Its base URL is fixed and never shown; requests go to the Responses API.
    static func chatGPT(name: String = "ChatGPT") -> Connection {
        Connection(kind: .chatGPT, name: name, baseURL: ChatGPTOAuth.resource, supportsResumable: false)
    }

    /// A new OpenCode account connection. Its base URL follows the gateway and is never shown.
    static func openCode(name: String = "OpenCode", gateway: OpenCodeGateway = .go) -> Connection {
        var c = Connection(kind: .openCode, name: name, baseURL: gateway.baseURL.absoluteString, supportsResumable: false)
        c.openCodeGateway = gateway
        return c
    }

    var isChatGPT: Bool { kind == .chatGPT }
    var isOpenCode: Bool { kind == .openCode }
    var isAppleOnDevice: Bool { kind == .appleOnDevice }
    var effortStyle: EffortStyle { isChatGPT || isOpenCode ? .modelDecides : .tokenCaps }

    /// Defaults for newly discovered models on this connection: what `/models` said, else the connection's settings.
    /// ChatGPT models read images, reason and call tools.
    func defaultModel(id modelID: String, fetchedContextLength: Int?, fetchedImages: Bool? = nil,
                      fetchedEffort: Bool? = nil) -> ModelInfo {
        ModelInfo(id: modelID,
                  fetchedContextLength: fetchedContextLength,
                  supportsImages: fetchedImages ?? (imagesByDefault || isChatGPT),
                  supportsEffort: fetchedEffort ?? (effortByDefault || isChatGPT),
                  supportsTools: true)
    }

    /// The user's name for a model, or nil when it has none.
    func alias(forModel modelID: String) -> String? { modelAliases[modelID] }

    /// What the UI shows for a model: its alias when set, else the server's name for it, else its id.
    func displayName(forModel modelID: String) -> String {
        alias(forModel: modelID) ?? models.first { $0.id == modelID }?.fetchedDisplayName ?? modelID
    }

    /// Sets (or, for nil / blank text, removes) a model's alias. The text is trimmed and capped.
    mutating func setAlias(_ alias: String?, forModel modelID: String) {
        modelAliases[modelID] = ModelAlias.normalized(alias)
    }

    /// Whether the model is listed in the composer's model menu (default on).
    func showsInPicker(_ modelID: String) -> Bool { !hiddenModelIDs.contains(modelID) }

    mutating func setShowsInPicker(_ shown: Bool, forModel modelID: String) {
        if shown { hiddenModelIDs.remove(modelID) } else { hiddenModelIDs.insert(modelID) }
    }

    /// The API requests for a model use: the user's pick for the model, else for the connection, else what was
    /// detected, else Chat Completions.
    func chatAPI(forModel modelID: String) -> ChatAPI {
        pickedAPI(forModel: modelID) ?? detectedModelAPIs[modelID] ?? .chatCompletions
    }

    /// The API the user picked for a model, directly or for the whole connection; nil is Automatic.
    func pickedAPI(forModel modelID: String) -> ChatAPI? {
        modelAPIOverrides[modelID] ?? defaultChatAPI
    }

    /// "Responses API" for a model row whose requests go there; nil for the usual Chat Completions.
    func apiLabel(forModel modelID: String) -> String? {
        kind == .openAICompatible && chatAPI(forModel: modelID) == .responses ? ChatAPI.responses.title : nil
    }

    /// A model row's subtitle in the connection editor: "Hidden", what the model can do, and the Responses API when
    /// its requests go there. Nil when there is nothing to say.
    func modelRowSubtitle(_ model: ModelInfo) -> String? {
        let parts = [showsInPicker(model.id) ? nil : String(localized: "Hidden"), model.capabilitiesSummary,
                     apiLabel(forModel: model.id)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Sets the user's pick (nil: Automatic). Going back to Automatic forgets what was detected, so it is found again.
    mutating func setAPIOverride(_ api: ChatAPI?, forModel modelID: String) {
        modelAPIOverrides[modelID] = api
        if api == nil { detectedModelAPIs[modelID] = nil }
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
    var supportsResumable: Bool = false
    /// Chat Completions, or the Responses API for a ChatGPT account (whose token comes from `ChatGPTAuth`, not `apiKey`),
    /// or the model's API for an OpenCode account (token from `OpenCodeAuth`).
    var kind: Connection.Kind = .openAICompatible
    /// For an OpenAI-compatible connection: Chat Completions or the Responses API, and whether a refused Chat
    /// Completions request may switch (see `ResponsesFallback`). Nil means Chat Completions, never switching.
    var apiRoute: ChatAPIRoute?

    /// The API an OpenAI-compatible endpoint's requests use now.
    var chatAPI: ChatAPI { apiRoute?.current ?? .chatCompletions }

    /// The URL requests are sent to, for the diagnostics ring.
    var requestURL: URL {
        switch kind {
        case .chatGPT: baseURL.appendingPathComponent("responses")
        case .openCode: baseURL.appendingPathComponent(openCodeAPI.path(model: model.id))
        case .openAICompatible: baseURL.appendingPathComponent(chatAPI == .responses ? "responses" : "chat/completions")
        case .appleOnDevice: baseURL
        }
    }

    /// The gateway of an OpenCode endpoint, from its base URL.
    var openCodeGateway: OpenCodeGateway {
        baseURL.path.contains("/go/") ? .go : .console
    }

    /// The API an OpenCode model is served by: as fetched, else guessed from its id.
    var openCodeAPI: OpenCodeModelAPI {
        model.openCode?.api ?? .guess(model: model.id, gateway: openCodeGateway)
    }
}
