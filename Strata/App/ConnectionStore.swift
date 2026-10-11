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

    init(defaults: UserDefaults = .standard, keys: any KeyStoring = KeychainKeyStore(), session: URLSession = .shared) {
        self.defaults = defaults
        self.keys = keys
        self.session = session
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Connection].self, from: data) {
            connections = decoded
        }
        if !connections.contains(where: { $0.isStrata }) {
            connections.insert(.strataPreset(), at: 0)
            save()
        }
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
        save()
    }

    func apiKey(for id: UUID) -> String? { keys.key(for: id) }

    func setAPIKey(_ key: String?, for id: UUID) throws { try keys.setKey(key, for: id) }

    func endpoint(connectionID: UUID?, modelID: String?) -> Endpoint? {
        guard let conn = connection(connectionID), let modelID,
              let base = conn.normalizedBaseURL else { return nil }
        let model = conn.models.first { $0.id == modelID } ?? conn.defaultModel(id: modelID, fetchedContextLength: nil)
        var headers: [String: String] = [:]
        for h in conn.parsedHeaders { headers[h.name] = h.value }
        return Endpoint(connectionID: conn.id, connectionName: conn.name, baseURL: base,
                        apiKey: keys.key(for: conn.id), headers: headers, model: model,
                        systemPrompt: conn.systemPrompt, supportsResumable: conn.supportsResumable)
    }

    /// Every model across all connections, in connection order.
    var allModels: [(connection: Connection, model: ModelInfo)] {
        connections.flatMap { c in c.models.map { (c, $0) } }
    }

    /// Fetches `/models` and merges the result, keeping user-set flags for known ids.
    @discardableResult
    func refreshModels(for id: UUID) async throws -> Int {
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
}
