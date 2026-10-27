import Foundation

/// The model picker's "Can't find a model?" row: which connections it can refresh or add a model id to, and when a list
/// is old enough to refresh by itself as the picker opens.
enum ModelListRefresh {
    /// A list older than this is refreshed quietly when the picker opens.
    static let maxAge: TimeInterval = 24 * 60 * 60
    /// A quiet refresh that just ran (and failed) isn't tried again on every opening: a server that's off stays quiet.
    static let retryAfter: TimeInterval = 10 * 60

    /// Whether a list fetched at `fetchedAt` (nil: never) wants a quiet refresh, given the last attempt of any outcome.
    static func isStale(fetchedAt: Date?, lastAttempt: Date? = nil, now: Date = .now) -> Bool {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryAfter { return false }
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= maxAge
    }

    /// Whether the connection has a model list to fetch: an address for an OpenAI-compatible server (a key is optional),
    /// a key for Anthropic, a sign-in for ChatGPT and OpenCode. Apple's on-device model has nothing to fetch.
    static func canRefresh(_ c: Connection, hasKey: Bool, signedIn: Bool) -> Bool {
        switch c.kind {
        case .openAICompatible: c.normalizedBaseURL != nil
        case .anthropic: hasKey && c.normalizedBaseURL != nil
        case .chatGPT, .openCode: signedIn
        case .appleOnDevice: false
        }
    }

    /// Whether a model id typed by hand can join the list: only where a refresh keeps it (`ModelInfo.isManual`). ChatGPT
    /// and OpenCode lists are the account's catalog and replace what was there.
    static func canAddModelID(_ c: Connection) -> Bool {
        c.kind == .openAICompatible || c.kind == .anthropic
    }

    /// "Updated 3 days ago"; "Updated just now" within the minute.
    static func updatedText(_ date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "Updated just now") }
        return String(localized: "Updated \(date.formatted(.relative(presentation: .named)))")
    }
}

extension ConnectionStore {
    func canRefreshModels(_ c: Connection) -> Bool {
        ModelListRefresh.canRefresh(c, hasKey: apiKey(for: c.id) != nil,
                                    signedIn: (c.isChatGPT && isChatGPTSignedIn(c.id)) || (c.isOpenCode && isOpenCodeSignedIn(c.id)))
    }

    /// Whether a model id can be typed in for the connection (it has to be usable, too).
    func canAddModelID(_ c: Connection) -> Bool { ModelListRefresh.canAddModelID(c) && canRefreshModels(c) }

    /// Refreshes the lists of `ids` at once (each merged like the editor's Fetch models). The errors, by connection;
    /// a list dropped because the connection was edited meanwhile isn't one.
    @discardableResult
    func refreshModels(of ids: [UUID]) async -> [UUID: String] {
        // Started together; on the main actor they run side by side while their requests are out.
        let fetches = ids.map { id in (id, Task { await refreshError(id) }) }
        var errors: [UUID: String] = [:]
        for (id, fetch) in fetches { errors[id] = await fetch.value }
        return errors
    }

    private func refreshError(_ id: UUID) async -> String? {
        do {
            try await refreshModels(for: id)
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The picker's quiet refresh: connections whose list is a day old or was never fetched, unless one is running.
    func refreshStaleModels(now: Date = .now) async {
        let stale = connections.filter { c in
            canRefreshModels(c) && modelFetches[c.id]?.running != true
                && ModelListRefresh.isStale(fetchedAt: modelsFetchedAt[c.id], lastAttempt: modelFetches[c.id]?.finished, now: now)
        }
        guard !stale.isEmpty else { return }
        await refreshModels(of: stale.map(\.id))
    }

    /// Adds a model by id, as typed, for a server that doesn't list it. It stays through refreshes (`isManual`) and
    /// syncs like the rest of the list. False when the id is blank or already listed.
    @discardableResult
    func addManualModel(_ id: String, connectionID: UUID) -> Bool {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = connection(connectionID), !id.isEmpty, !c.models.contains(where: { $0.id == id }) else { return false }
        var m = c.defaultModel(id: id, fetchedContextLength: nil)
        m.isManual = true
        c.models.append(m)
        upsert(c)
        return true
    }
}
