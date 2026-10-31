import Foundation

/// Fetching each connection's model list and merging it into the connection.
extension ConnectionStore {
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

    /// A model list as the server sent it, with how many came and how many were left out (OpenCode), ready to merge
    /// into the connection as it is once the list is in.
    struct ModelList {
        var count: Int
        var unsupported = 0
        /// OpenCode's free models, left out (`OpenCodeModelsAPI.isFree`).
        var free = 0
        /// The connection with this list as its models: user-set flags, aliases and models added by hand stay.
        let merged: (Connection) -> Connection
    }

    /// Runs a model-list fetch of `id` and records how it went in `modelFetches`.
    private func tracked(_ id: UUID, _ fetch: () async throws -> ModelList) async throws -> ModelList {
        modelFetches[id, default: ModelFetch()].running = true
        do {
            let result = try await fetch()
            modelFetches[id] = ModelFetch(finished: .now, count: result.count, unsupported: result.unsupported, free: result.free)
            modelsFetchedAt[id] = .now
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
        if connection(id)?.isAppleOnDevice == true { refreshOnDeviceModels(); return 1 }
        return try await refreshSaved(id).count
    }

    /// The same for an OpenCode account, with the models it left out.
    @discardableResult
    func refreshOpenCodeModels(for id: UUID) async throws -> (count: Int, unsupported: Int, free: Int) {
        let list = try await refreshSaved(id)
        return (list.count, list.unsupported, list.free)
    }

    /// A saved connection's fetch: sent with what it has now, merged into it as it is when the list comes in.
    private func refreshSaved(_ id: UUID) async throws -> ModelList {
        guard let sent = connection(id) else { throw APIError.invalidBaseURL }
        return try await fetchModels(of: sent, apiKey: requestKey(sent),
                                     current: { connection(id).map { ($0, requestKey($0)) } },
                                     apply: { upsert($0) })
    }

    /// The key a saved connection's requests carry: its API key, or an OpenCode account's service-account key.
    func requestKey(_ c: Connection) -> String? { c.isOpenCode ? openCode.store.apiKey(c.id) : keys.key(for: c.id) }

    /// Fetches the model list of `connection` with `apiKey` (a saved connection's, or one still being added: see
    /// `ConnectionDraft`) and records the fetch under its id. `current` is the connection and its key as they are once
    /// the list is in, and `apply` takes it with the list merged: it may have been deleted or edited while the request
    /// ran, and a list from another address, headers, key or plan (edited meanwhile, or a fetch that a newer one
    /// overtook) isn't this one's.
    func fetchModels(of connection: Connection, apiKey: String?,
                     current: () -> (connection: Connection, apiKey: String?)?,
                     apply: (Connection) -> Void) async throws -> ModelList {
        try await tracked(connection.id) {
            let list = try await fetchModelList(connection, apiKey: apiKey)
            guard let now = current() else { return list }
            guard Self.fetchTarget(now.connection, apiKey: now.apiKey) == Self.fetchTarget(connection, apiKey: apiKey) else {
                throw CancellationError()
            }
            apply(list.merged(now.connection))
            return list
        }
    }

    /// What a model-list request goes to and with: its answer is merged only while the connection still has all of it.
    private static func fetchTarget(_ c: Connection, apiKey: String?) -> [String?] {
        [c.normalizedBaseURL?.absoluteString, c.customHeaders, apiKey, c.openCodeGateway?.rawValue]
    }

    private func fetchModelList(_ connection: Connection, apiKey: String?) async throws -> ModelList {
        switch connection.kind {
        case .openAICompatible: try await compatibleModels(connection, apiKey: apiKey)
        case .chatGPT: try await chatGPTModels(connection)
        case .anthropic: try await anthropicModels(connection, apiKey: apiKey)
        case .openCode: try await openCodeModels(connection, apiKey: apiKey)
        case .appleOnDevice:
            // Nothing to fetch: what the system's model can do now (`refreshOnDeviceModels`).
            ModelList(count: 1) { c in
                var updated = c
                updated.models = [OnDevice.modelInfo(OnDevice.system, keeping: c.models.first { $0.id == OnDevice.modelID })]
                return updated
            }
        }
    }

    /// The headers a connection's model-list request carries.
    private static func headers(_ c: Connection) -> [String: String] {
        var headers: [String: String] = [:]
        for h in c.parsedHeaders { headers[h.name] = h.value }
        return headers
    }

    /// `/models` of an OpenAI-compatible server, chat models only. Server-reported limits and capabilities replace
    /// what the server said before, never what the user set; a model added by hand stays.
    private func compatibleModels(_ conn: Connection, apiKey: String?) async throws -> ModelList {
        guard let base = conn.normalizedBaseURL else { throw APIError.invalidBaseURL }
        let probe = Endpoint(connectionID: conn.id, connectionName: conn.name, baseURL: base, apiKey: apiKey,
                             headers: Self.headers(conn), model: ModelInfo(id: ""))
        let entries = try await ModelsAPI.fetch(endpoint: probe, session: session).filter { OpenAIPlatform.isChatModel($0.id, baseURL: base) }
        return ModelList(count: entries.count) { conn in
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
            return updated
        }
    }

    /// The signed-in account's catalog (`GET /v1/models`, `visibility: "list"` entries, in the server's order),
    /// merged like `/models` of other connections: user-set flags stay, models that dropped out go.
    private func chatGPTModels(_ conn: Connection) async throws -> ModelList {
        let entries = try await ChatGPTModelsAPI.fetch(connectionID: conn.id, auth: chatGPT, session: session)
        return ModelList(count: entries.count) { conn in
            var updated = conn
            updated.models = entries.map { entry in
                var model = updated.models.first { $0.id == entry.slug }
                    ?? updated.defaultModel(id: entry.slug, fetchedContextLength: entry.contextLength, fetchedImages: entry.supportsImages)
                model.fetchedDisplayName = entry.displayName
                model.fetchedContextLength = entry.contextLength ?? model.fetchedContextLength
                if !model.supportsImagesUserSet, let images = entry.supportsImages { model.supportsImages = images }
                return model
            }
            return updated
        }
    }

    /// The key's models from `GET /v1/models` (every page), merged like `/models` of other connections: user-set flags,
    /// aliases and hidden models stay, a model added by hand stays, models that dropped out of the list go.
    private func anthropicModels(_ conn: Connection, apiKey: String?) async throws -> ModelList {
        guard let base = conn.normalizedBaseURL else { throw APIError.invalidBaseURL }
        let probe = Endpoint(connectionID: conn.id, connectionName: conn.name, baseURL: base, apiKey: apiKey,
                             headers: Self.headers(conn), model: ModelInfo(id: ""), kind: .anthropic)
        let entries = try await AnthropicModelsAPI.fetch(endpoint: probe, session: session)
        return ModelList(count: entries.count) { conn in
            var updated = conn
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
            return updated
        }
    }

    /// The gateway's models with their catalog metadata, merged like ChatGPT's: user-set flags stay, models that dropped
    /// out go. Free models (they only work in OpenCode's own apps) and models of an API the app can't talk yet are left
    /// out and counted. A chat still set to a free model keeps it and gets the gateway's refusal, worded by
    /// `OpenCodeErrorMapper`. A service-account key that isn't saved yet (`apiKey`) is sent as it is; otherwise the
    /// token comes from the sign-in.
    private func openCodeModels(_ conn: Connection, apiKey: String?) async throws -> ModelList {
        guard let gateway = conn.openCodeGateway else { return ModelList(count: 0) { $0 } }
        let auth: any OpenCodeTokenProviding = apiKey.map(OpenCodeKeyToken.init) ?? openCode
        let fetched = try await OpenCodeModelsAPI.fetch(connectionID: conn.id, gateway: gateway, auth: auth, session: session)
        return ModelList(count: fetched.supported.count, unsupported: fetched.unsupported.count, free: fetched.free.count) { conn in
            var updated = conn
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
            return updated
        }
    }
}
