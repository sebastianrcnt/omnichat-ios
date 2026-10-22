import Foundation
import Observation

/// Connections (JSON in UserDefaults) plus their Keychain-backed API keys.
@MainActor
@Observable
final class ConnectionStore {
    private(set) var connections: [Connection] = []
    private let defaults: UserDefaults
    let keys: any KeyStoring
    private let storageKey = "connections.v1"
    private let session: URLSession
    /// Sign-in and tokens of ChatGPT connections.
    let chatGPT: ChatGPTAuth
    /// Sign-in, tokens and API keys of OpenCode connections.
    let openCode: OpenCodeAuth

    init(defaults: UserDefaults = .standard, keys: any KeyStoring = KeychainKeyStore(), session: URLSession = .shared,
         chatGPT: ChatGPTAuth = .shared, openCode: OpenCodeAuth = .shared) {
        self.defaults = defaults
        self.keys = keys
        self.session = session
        self.chatGPT = chatGPT
        self.openCode = openCode
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: storageKey) {
            if let decoded = try? JSONDecoder().decode([Connection].self, from: data) {
                connections = decoded
            } else {
                // One entry this version can't read must not cost the others: decode them one by one, and keep the
                // original blob aside so nothing is lost for good when the list is saved again.
                defaults.set(data, forKey: storageKey + ".unreadable")
                connections = ((try? JSONDecoder().decode([Lenient<Connection>].self, from: data)) ?? []).compactMap(\.value)
            }
            migrateSystemPrompts(data)
        }
        migrateBuiltInConnection(defaults.data(forKey: storageKey))
    }

    /// Set once the connection that used to ship with the app has become an ordinary one.
    static let builtInMigrationKey = "connections.builtInMigrated"

    /// The app once shipped with a built-in connection (this id), which it re-added when missing and treated specially:
    /// new models read images and took reasoning effort, and replies were resumable unless turned off. It stays as an
    /// ordinary connection the user can edit or delete, with its name, address, key, models and chats, and with what it
    /// did frozen into its own settings, so nothing changes after the update. Runs once; never adds or removes one.
    private func migrateBuiltInConnection(_ data: Data?) {
        guard !defaults.bool(forKey: Self.builtInMigrationKey) else { return }
        defaults.set(true, forKey: Self.builtInMigrationKey)
        guard let i = connections.firstIndex(where: { $0.id == LegacyBuiltInConnection.id }) else { return }
        connections[i].imagesByDefault = true
        connections[i].effortByDefault = true
        // Saved before the toggle existed: it was on for this connection.
        struct Saved: Decodable { var id: UUID; var supportsResumable: Bool? }
        let saved = data.flatMap { try? JSONDecoder().decode([Lenient<Saved>].self, from: $0) }?
            .compactMap(\.value).first { $0.id == LegacyBuiltInConnection.id }
        if let saved, saved.supportsResumable == nil { connections[i].supportsResumable = true }
        save()
    }

    /// Connections once had their own system prompt. The first one a user wrote becomes their preferences (unless
    /// they already have some); the stock prompt is dropped, since the app prompt now covers it. Saving afterwards
    /// writes the connections without the field, so this runs once.
    private func migrateSystemPrompts(_ data: Data) {
        struct Legacy: Decodable { var systemPrompt: String? }
        guard let legacy = try? JSONDecoder().decode([Legacy].self, from: data),
              legacy.contains(where: { $0.systemPrompt != nil }) else { return }
        let stock = AppPrompt.legacyCitation.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = legacy.lazy.compactMap { $0.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != stock }
        if let written, (defaults.string(forKey: AppSettings.userPreferencesKey) ?? "").isEmpty {
            defaults.set(written, forKey: AppSettings.userPreferencesKey)
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(connections) { defaults.set(data, forKey: storageKey) }
        onSave?(connections)
    }

    /// Told of every saved change (`ConnectionSync` sends it to the user's other devices).
    @ObservationIgnored var onSave: (([Connection]) -> Void)?
    /// A connection's custom headers when another device changed them (`ConnectionSync.changedHeaders`): they arrive
    /// through iCloud Keychain alone, so the copy in memory can be stale. Nil: the copy in memory is current.
    @ObservationIgnored var changedHeaders: (@MainActor (UUID) -> String?)?

    /// The list as another device left it (`ConnectionSync`). Connections it drops were deleted there, along with their
    /// Keychain items, so nothing more is removed here.
    func replaceAll(_ list: [Connection]) {
        connections = list
        save()
    }

    func connection(_ id: UUID?) -> Connection? { connections.first { $0.id == id } }

    func upsert(_ connection: Connection) {
        if let i = connections.firstIndex(where: { $0.id == connection.id }) { connections[i] = connection }
        else { connections.append(connection) }
        save()
    }

    func delete(_ id: UUID) {
        connections.removeAll { $0.id == id }
        try? keys.setKey(nil, for: id)
        chatGPT.store.removeAll(id)
        openCode.store.removeAll(id)
        save()
    }

    /// Drops OpenAI-compatible and Anthropic connections that were added but never set up (no address, key or models),
    /// so a tap on "Add" that was backed out of doesn't leave a "New connection" in the list. An Anthropic connection
    /// has its address from the start: no key and no models is enough (it isn't synced before it has models).
    func removeUnconfigured() {
        let empty = connections.filter { c in
            guard c.kind == .openAICompatible || c.kind == .anthropic, c.models.isEmpty, keys.key(for: c.id) == nil else { return false }
            if c.kind == .anthropic { return true }
            let url = c.baseURL.trimmingCharacters(in: .whitespaces).lowercased()
            return url.isEmpty || url == "https://" || url == "http://"
        }
        for c in empty { delete(c.id) }
    }

    /// What the UI shows for a model: the user's alias, else the id. Nil only when there is no model id.
    func displayName(connectionID: UUID?, modelID: String?) -> String? {
        guard let modelID else { return nil }
        return connection(connectionID)?.displayName(forModel: modelID) ?? modelID
    }

    /// Sets or (with nil / blank text) clears a model's alias. Display-only; requests keep the real id.
    func setModelAlias(_ alias: String?, connectionID: UUID, modelID: String) {
        guard var c = connection(connectionID) else { return }
        c.setAlias(alias, forModel: modelID)
        guard c != connection(connectionID) else { return }
        upsert(c)
    }

    /// Shows or hides a model in the composer's model menu. Display-only; requests are unchanged.
    func setModelShownInPicker(_ shown: Bool, connectionID: UUID, modelID: String) {
        guard var c = connection(connectionID) else { return }
        c.setShowsInPicker(shown, forModel: modelID)
        guard c != connection(connectionID) else { return }
        upsert(c)
    }

    func apiKey(for id: UUID) -> String? { keys.key(for: id) }

    func setAPIKey(_ key: String?, for id: UUID) throws { try keys.setKey(key, for: id) }

    /// - Parameter sessionID: the conversation the requests belong to; OpenCode routes and caches by it.
    func endpoint(connectionID: UUID?, modelID: String?, sessionID: String? = nil) -> Endpoint? {
        guard let conn = connection(connectionID), let modelID else { return nil }
        if conn.isAppleOnDevice { return OnDevice.endpoint(conn) }
        let model = conn.models.first { $0.id == modelID } ?? conn.defaultModel(id: modelID, fetchedContextLength: nil)
        if conn.isOpenCode {
            // The token comes from `OpenCodeAuth` per request. Go asks for a named client and a stable session id.
            let gateway = conn.openCodeGateway ?? .go
            let headers = ["User-Agent": OpenCodeAPI.userAgent, "x-opencode-client": OpenCodeAPI.clientName,
                           "x-opencode-session": sessionID ?? conn.id.uuidString]
            return Endpoint(connectionID: conn.id, connectionName: conn.name, baseURL: gateway.baseURL,
                            apiKey: nil, headers: headers, model: model, supportsResumable: false, kind: .openCode)
        }
        if conn.isChatGPT {
            // The token comes from `ChatGPTAuth` per request (it refreshes); custom headers and resuming don't apply.
            return Endpoint(connectionID: conn.id, connectionName: conn.name, baseURL: URL(string: ChatGPTOAuth.resource)!,
                            apiKey: nil, headers: [:], model: model, supportsResumable: false, kind: .chatGPT)
        }
        guard let base = conn.normalizedBaseURL else { return nil }
        var headers: [String: String] = [:]
        var current = conn
        if let changed = changedHeaders?(conn.id) { current.customHeaders = changed }
        for h in current.parsedHeaders { headers[h.name] = h.value }
        if conn.isAnthropic {
            // The Messages API can't replay a stream: never resumable, whatever the connection says.
            return Endpoint(connectionID: conn.id, connectionName: conn.name, baseURL: base, apiKey: keys.key(for: conn.id),
                            headers: headers, model: model, supportsResumable: false, kind: .anthropic)
        }
        // Chat Completions unless the model is known to need the Responses API, which is never resumable (the gateway
        // replays Chat Completions streams only).
        let api = conn.chatAPI(forModel: modelID)
        let connectionID = conn.id
        let route = ChatAPIRoute(api: api, automatic: conn.pickedAPI(forModel: modelID) == nil) { [weak self] detected in
            Task { @MainActor in self?.recordDetectedAPI(detected, connectionID: connectionID, modelID: modelID) }
        }
        return Endpoint(connectionID: conn.id, connectionName: conn.name, baseURL: base,
                        apiKey: keys.key(for: conn.id), headers: headers, model: model,
                        supportsResumable: conn.supportsResumable && api == .chatCompletions, apiRoute: route)
    }

    /// Remembers that a model answered only through `api` (found by `ResponsesFallback`), unless the user picked one.
    func recordDetectedAPI(_ api: ChatAPI, connectionID: UUID, modelID: String) {
        guard var c = connection(connectionID), c.kind == .openAICompatible, c.pickedAPI(forModel: modelID) == nil,
              c.detectedModelAPIs[modelID] != api else { return }
        c.detectedModelAPIs[modelID] = api
        upsert(c)
    }

    /// The API picked for a model in its settings; nil is Automatic (and forgets what was detected).
    func setModelAPIOverride(_ api: ChatAPI?, connectionID: UUID, modelID: String) {
        guard var c = connection(connectionID) else { return }
        c.setAPIOverride(api, forModel: modelID)
        guard c != connection(connectionID) else { return }
        upsert(c)
    }

    // MARK: ChatGPT

    func isChatGPTSignedIn(_ id: UUID) -> Bool { chatGPT.store.hasTokens(id) }

    /// The account a ChatGPT connection is registered to (kept after sign-out).
    func chatGPTRegistration(_ id: UUID) -> ChatGPTRegistration? { chatGPT.store.registration(id) }

    /// Whether the signed-in account granted plan usage (nil when signed out).
    func chatGPTAllowsPlanUsage(_ id: UUID) -> Bool? { chatGPT.store.tokens(id)?.allowsPlanUsage }

    // MARK: OpenCode

    func isOpenCodeSignedIn(_ id: UUID) -> Bool { openCode.store.hasCredential(id) }

    /// Every model across all connections, in connection order.
    var allModels: [(connection: Connection, model: ModelInfo)] {
        connections.flatMap { c in c.models.map { (c, $0) } }
    }

    /// Signed-in ChatGPT and OpenCode accounts that have no models yet fetch them (errors are left to the editor, which
    /// shows them). The fetch right after a sign-in can fail while the browser has the app in the background.
    func fetchMissingAccountModels() async {
        let pending = connections.filter { c in
            c.models.isEmpty && ((c.isChatGPT && isChatGPTSignedIn(c.id)) || (c.isOpenCode && isOpenCodeSignedIn(c.id)))
        }
        for c in pending { _ = try? await refreshModels(for: c.id) }
    }

    /// The last model-list fetch of each connection, from its editor or from launch: what the editor's Models section
    /// says even when the fetch ran in the background. Not saved: every launch fetches again.
    struct ModelFetch: Equatable {
        var running = false
        var finished: Date?
        var count: Int?
        var unsupported = 0
        /// OpenCode's free models, left out (`OpenCodeModelsAPI.isFree`).
        var free = 0
        var error: String?
    }

    private(set) var modelFetches: [UUID: ModelFetch] = [:]

    /// Runs a model-list fetch of `id` and records how it went in `modelFetches`.
    private func tracked(_ id: UUID, _ fetch: () async throws -> (count: Int, unsupported: Int, free: Int)) async throws
        -> (count: Int, unsupported: Int, free: Int) {
        modelFetches[id, default: ModelFetch()].running = true
        do {
            let result = try await fetch()
            modelFetches[id] = ModelFetch(finished: .now, count: result.count, unsupported: result.unsupported, free: result.free)
            return result
        } catch {
            var failed = ModelFetch(finished: .now)
            if !(error is CancellationError) { failed.error = error.localizedDescription }
            modelFetches[id] = failed
            throw error
        }
    }

    /// Fetches `/models` and merges the result, keeping user-set flags for known ids.
    @discardableResult
    func refreshModels(for id: UUID) async throws -> Int {
        if connection(id)?.isOpenCode == true { return try await refreshOpenCodeModels(for: id).count }
        if connection(id)?.isAppleOnDevice == true { refreshOnDeviceModels(); return 1 }
        return try await tracked(id) { (try await fetchModels(for: id), 0, 0) }.count
    }

    private func fetchModels(for id: UUID) async throws -> Int {
        if connection(id)?.isChatGPT == true { return try await refreshChatGPTModels(for: id) }
        if connection(id)?.isAnthropic == true { return try await refreshAnthropicModels(for: id) }
        guard let conn = connection(id), let base = conn.normalizedBaseURL else { throw APIError.invalidBaseURL }
        var headers: [String: String] = [:]
        for h in conn.parsedHeaders { headers[h.name] = h.value }
        let probe = Endpoint(connectionID: id, connectionName: conn.name, baseURL: base, apiKey: keys.key(for: id),
                             headers: headers, model: ModelInfo(id: ""))
        let sent = fetchTarget(id)
        let entries = try await ModelsAPI.fetch(endpoint: probe, session: session).filter { OpenAIPlatform.isChatModel($0.id, baseURL: base) }
        // Merge into the connection as it is now: it may have been deleted or edited while the request ran. A list from
        // another address, headers or key (edited meanwhile, or a fetch that a newer one overtook) isn't this one's.
        guard let conn = connection(id) else { return entries.count }
        guard fetchTarget(id) == sent else { throw CancellationError() }
        var updated = conn
        let manual = conn.models.filter { m in !entries.contains { $0.id == m.id } && m.isManual }
        var merged: [ModelInfo] = entries.map { entry in
            if var existing = conn.models.first(where: { $0.id == entry.id }) {
                existing.fetchedContextLength = entry.contextLength ?? existing.fetchedContextLength
                existing.maxOutputTokens = entry.maxOutputTokens ?? existing.maxOutputTokens
                // What the server says about a model replaces what it said before, never what the user set.
                if !existing.supportsImagesUserSet, let images = entry.supportsImages { existing.supportsImages = images }
                if !existing.supportsEffortUserSet, let effort = entry.supportsEffort { existing.supportsEffort = effort }
                return existing
            }
            return conn.defaultModel(id: entry.id, fetchedContextLength: entry.contextLength, fetchedImages: entry.supportsImages,
                                     fetchedEffort: entry.supportsEffort)
        }
        merged.append(contentsOf: manual)
        updated.models = merged
        upsert(updated)
        return entries.count
    }

    /// What a `/models` request goes to and with: its answer is merged only while the connection still has all of it.
    private func fetchTarget(_ id: UUID) -> [String?] {
        guard let c = connection(id) else { return [] }
        return [c.normalizedBaseURL?.absoluteString, c.customHeaders, keys.key(for: id)]
    }

    /// The signed-in account's catalog (`GET /v1/models`, `visibility: "list"` entries, in the server's order),
    /// merged like `/models` of other connections: user-set flags stay, models that dropped out go.
    private func refreshChatGPTModels(for id: UUID) async throws -> Int {
        let entries = try await ChatGPTModelsAPI.fetch(connectionID: id, auth: chatGPT, session: session)
        guard var updated = connection(id) else { return 0 }
        updated.models = entries.map { entry in
            var model = updated.models.first { $0.id == entry.slug }
                ?? updated.defaultModel(id: entry.slug, fetchedContextLength: entry.contextLength, fetchedImages: entry.supportsImages)
            model.fetchedDisplayName = entry.displayName
            model.fetchedContextLength = entry.contextLength ?? model.fetchedContextLength
            if !model.supportsImagesUserSet, let images = entry.supportsImages { model.supportsImages = images }
            return model
        }
        upsert(updated)
        return entries.count
    }

    /// The key's models from `GET /v1/models` (every page), merged like `/models` of other connections: user-set flags,
    /// aliases and hidden models stay, a model added by hand stays, models that dropped out of the list go.
    private func refreshAnthropicModels(for id: UUID) async throws -> Int {
        guard let conn = connection(id), let base = conn.normalizedBaseURL else { throw APIError.invalidBaseURL }
        var headers: [String: String] = [:]
        for h in conn.parsedHeaders { headers[h.name] = h.value }
        let probe = Endpoint(connectionID: id, connectionName: conn.name, baseURL: base, apiKey: keys.key(for: id),
                             headers: headers, model: ModelInfo(id: ""), kind: .anthropic)
        let sent = fetchTarget(id)
        let entries = try await AnthropicModelsAPI.fetch(endpoint: probe, session: session)
        guard var updated = connection(id) else { return entries.count }
        guard fetchTarget(id) == sent else { throw CancellationError() } // edited while the request ran
        let manual = updated.models.filter { m in m.isManual && !entries.contains { $0.id == m.id } }
        updated.models = entries.map { entry in
            var model = updated.models.first { $0.id == entry.id } ?? AnthropicModels.model(id: entry.id)
            model.fetchedDisplayName = entry.displayName
            model.fetchedContextLength = entry.contextLength ?? model.fetchedContextLength
            model.maxOutputTokens = entry.maxOutputTokens ?? model.maxOutputTokens
            model.anthropic = entry.info
            if !model.supportsImagesUserSet, let images = entry.supportsImages { model.supportsImages = images }
            if !model.supportsEffortUserSet { model.supportsEffort = !entry.info.pickerLevels.isEmpty }
            return model
        } + manual
        upsert(updated)
        return entries.count
    }

    /// The gateway's models with their catalog metadata, merged like ChatGPT's: user-set flags stay, models that dropped
    /// out go. Free models (they only work in OpenCode's own apps) and models of an API the app can't talk yet are left
    /// out and counted. A chat still set to a free model keeps it and gets the gateway's refusal, worded by
    /// `OpenCodeErrorMapper`.
    @discardableResult
    func refreshOpenCodeModels(for id: UUID) async throws -> (count: Int, unsupported: Int, free: Int) {
        try await tracked(id) { try await fetchOpenCodeModels(for: id) }
    }

    private func fetchOpenCodeModels(for id: UUID) async throws -> (count: Int, unsupported: Int, free: Int) {
        guard let gateway = connection(id)?.openCodeGateway else { return (0, 0, 0) }
        let fetched = try await OpenCodeModelsAPI.fetch(connectionID: id, gateway: gateway, auth: openCode, session: session)
        guard var updated = connection(id), updated.openCodeGateway == gateway else { return (0, 0, 0) }
        updated.models = fetched.supported.map { entry in
            var model = updated.models.first { $0.id == entry.id }
                ?? ModelInfo(id: entry.id, supportsImages: entry.supportsImages ?? false,
                             supportsEffort: !entry.info.efforts.isEmpty, supportsTools: entry.supportsTools ?? true)
            model.fetchedDisplayName = entry.name
            model.fetchedContextLength = entry.contextLength ?? model.fetchedContextLength
            model.maxOutputTokens = entry.maxOutputTokens ?? model.maxOutputTokens
            if !model.supportsImagesUserSet, let images = entry.supportsImages { model.supportsImages = images }
            model.openCode = entry.info
            return model
        }
        upsert(updated)
        return (fetched.supported.count, fetched.unsupported.count, fetched.free.count)
    }
}

/// One entry of a saved list that this version may not be able to read: nil instead of failing the whole list.
private struct Lenient<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// The id of the connection that used to be built in (see `ConnectionStore.migrateBuiltInConnection`). Only the
/// migration knows it; nothing else treats that connection differently.
enum LegacyBuiltInConnection {
    static let id = UUID(uuidString: "5712A7A0-0000-4000-8000-000000000001")!
}

extension ConnectionStore.ModelFetch {
    /// The Models section's footer: running, the error, or how many came and when.
    var footer: String? {
        if running { return String(localized: "Fetching models…") }
        if let error { return String(localized: "Couldn't fetch models: \(error)") }
        guard let count, let finished else { return nil }
        let when = finished.formatted(.relative(presentation: .named))
        var text = String(localized: "Fetched \(count) models \(when).")
        if unsupported > 0 { text += " " + String(localized: "\(unsupported) more use an API OmniChat doesn't support yet.") }
        if free > 0 { text += " " + String(localized: "Free models are hidden: OpenCode allows them only in its own apps.") }
        return text
    }
}
