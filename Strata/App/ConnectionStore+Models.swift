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

    /// Runs a model-list fetch of `id` and records how it went in `modelFetches`.
    private func tracked(_ id: UUID, _ fetch: () async throws -> (count: Int, unsupported: Int, free: Int)) async throws
        -> (count: Int, unsupported: Int, free: Int) {
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
