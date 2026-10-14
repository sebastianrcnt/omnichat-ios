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

    init(defaults: UserDefaults = .standard, keys: any KeyStoring = KeychainKeyStore(), session: URLSession = .shared,
         chatGPT: ChatGPTAuth = .shared) {
        self.defaults = defaults
        self.keys = keys
        self.session = session
        self.chatGPT = chatGPT
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Connection].self, from: data) {
            connections = decoded
            migrateSystemPrompts(data)
        }
        if !connections.contains(where: { $0.isStrata }) {
            connections.insert(.strataPreset(), at: 0)
            save()
        }
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
    }

    func connection(_ id: UUID?) -> Connection? { connections.first { $0.id == id } }

    func upsert(_ connection: Connection) {
        if let i = connections.firstIndex(where: { $0.id == connection.id }) { connections[i] = connection }
        else { connections.append(connection) }
        save()
    }

    func delete(_ id: UUID) {
        guard id != Connection.strataID else { return }
        connections.removeAll { $0.id == id }
        try? keys.setKey(nil, for: id)
        chatGPT.store.removeAll(id)
        save()
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

    func endpoint(connectionID: UUID?, modelID: String?) -> Endpoint? {
        guard let conn = connection(connectionID), let modelID else { return nil }
        let model = conn.models.first { $0.id == modelID } ?? conn.defaultModel(id: modelID, fetchedContextLength: nil)
        if conn.isChatGPT {
            // The token comes from `ChatGPTAuth` per request (it refreshes); custom headers and resuming don't apply.
            return Endpoint(connectionID: conn.id, connectionName: conn.name, baseURL: URL(string: ChatGPTOAuth.resource)!,
                            apiKey: nil, headers: [:], model: model, supportsResumable: false, kind: .chatGPT)
        }
        guard let base = conn.normalizedBaseURL else { return nil }
        var headers: [String: String] = [:]
        for h in conn.parsedHeaders { headers[h.name] = h.value }
        return Endpoint(connectionID: conn.id, connectionName: conn.name, baseURL: base,
                        apiKey: keys.key(for: conn.id), headers: headers, model: model,
                        supportsResumable: conn.supportsResumable)
    }

    // MARK: ChatGPT

    func isChatGPTSignedIn(_ id: UUID) -> Bool { chatGPT.store.hasTokens(id) }

    /// The account a ChatGPT connection is registered to (kept after sign-out).
    func chatGPTRegistration(_ id: UUID) -> ChatGPTRegistration? { chatGPT.store.registration(id) }

    /// Whether the signed-in account granted plan usage (nil when signed out).
    func chatGPTAllowsPlanUsage(_ id: UUID) -> Bool? { chatGPT.store.tokens(id)?.allowsPlanUsage }

    /// Every model across all connections, in connection order.
    var allModels: [(connection: Connection, model: ModelInfo)] {
        connections.flatMap { c in c.models.map { (c, $0) } }
    }

    /// Fetches `/models` and merges the result, keeping user-set flags for known ids.
    @discardableResult
    func refreshModels(for id: UUID) async throws -> Int {
        if connection(id)?.isChatGPT == true { return try await refreshChatGPTModels(for: id) }
        guard let conn = connection(id), let base = conn.normalizedBaseURL else { throw APIError.invalidBaseURL }
        var headers: [String: String] = [:]
        for h in conn.parsedHeaders { headers[h.name] = h.value }
        let probe = Endpoint(connectionID: id, connectionName: conn.name, baseURL: base, apiKey: keys.key(for: id),
                             headers: headers, model: ModelInfo(id: ""))
        let entries = try await ModelsAPI.fetch(endpoint: probe, session: session)
        var updated = conn
        let manual = conn.models.filter { m in !entries.contains { $0.id == m.id } && m.isManual }
        var merged: [ModelInfo] = entries.map { entry in
            if var existing = conn.models.first(where: { $0.id == entry.id }) {
                existing.fetchedContextLength = entry.contextLength ?? existing.fetchedContextLength
                existing.maxOutputTokens = entry.maxOutputTokens ?? existing.maxOutputTokens
                if !existing.supportsImagesUserSet, let images = entry.supportsImages ?? (conn.isStrata ? true : nil) {
                    existing.supportsImages = images
                }
                return existing
            }
            return conn.defaultModel(id: entry.id, fetchedContextLength: entry.contextLength, fetchedImages: entry.supportsImages)
        }
        merged.append(contentsOf: manual)
        updated.models = merged
        upsert(updated)
        return entries.count
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
}
