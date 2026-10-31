import Foundation
import Observation

/// A connection being added, held by its editor until Add (`ConnectionStore.add`). Its settings, headers, models and
/// API key stay here, so nothing is in the connection list, the Keychain or iCloud before then, and Cancel (or going
/// back, or closing the sheet) has nothing to undo but a sign-in: a ChatGPT or OpenCode sign-in is kept under the
/// draft's id in its own store from the start, goes with the connection on Add, and is signed out and removed when the
/// draft is discarded (`ConnectionStore.discard`).
@MainActor
@Observable
final class ConnectionDraft: Identifiable {
    /// The connection's id from the start, which a sign-in is kept under. Editors never change `connection.id`.
    let id: UUID
    var connection: Connection
    /// The API key entered (for an OpenCode account, a service-account key), trimmed: into the Keychain on Add.
    private(set) var apiKey: String?
    /// Whether a ChatGPT or OpenCode sign-in is kept under the draft's id, as last checked (`ConnectionStore.checkSignIn`).
    fileprivate(set) var signedIn = false
    /// The connection Add saved it as: its own id, or the connection that already had its ChatGPT account (or the
    /// on-device connection there already is).
    fileprivate(set) var added: UUID?
    fileprivate(set) var discarded = false

    init(_ connection: Connection) {
        id = connection.id
        self.connection = connection
    }

    /// Neither added nor discarded yet.
    var isOpen: Bool { added == nil && !discarded }

    func setAPIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Whether Add can be pressed: the least the connection needs to be of use. An OpenAI-compatible server needs a
    /// real address (it may not take a key: Ollama, LM Studio); Anthropic needs a key; an account needs its sign-in (for
    /// OpenCode, a service-account key does too). The on-device connection needs nothing: the editor says whether the
    /// model can run yet.
    var canAdd: Bool {
        guard isOpen else { return false }
        switch connection.kind {
        case .openAICompatible: return connection.normalizedBaseURL != nil
        case .anthropic: return connection.normalizedBaseURL != nil && apiKey != nil
        case .chatGPT: return signedIn
        case .openCode: return signedIn || apiKey != nil
        case .appleOnDevice: return true
        }
    }
}

extension ConnectionStore {
    /// What a connection's editor shows: the draft while it is one, else the saved connection.
    func connection(_ id: UUID, draft: ConnectionDraft?) -> Connection? { draft?.connection ?? connection(id) }

    /// A change from a connection's editor: into the draft while it is one, else saved at once (the editor of a saved
    /// connection saves as you go).
    func edit(_ id: UUID, draft: ConnectionDraft?, _ change: (inout Connection) -> Void) {
        if let draft {
            change(&draft.connection)
            return
        }
        guard var c = connection(id) else { return }
        change(&c)
        if c != connection(id) { upsert(c) }
    }

    /// Reads whether a sign-in is kept under the draft's id (its editor calls this after signing in or out).
    func checkSignIn(_ draft: ConnectionDraft) {
        draft.signedIn = draft.connection.isChatGPT ? isChatGPTSignedIn(draft.id)
                       : draft.connection.isOpenCode ? isOpenCodeSignedIn(draft.id) : false
    }

    /// The editor's Fetch models: a saved connection's list, or a draft's, fetched with the draft's own address,
    /// headers and key and merged into the draft. A fetch still running when Add is pressed goes to the connection the
    /// draft became.
    @discardableResult
    func refreshModels(for id: UUID, draft: ConnectionDraft?) async throws -> Int {
        guard let draft else { return try await refreshModels(for: id) }
        let list = try await fetchModels(of: draft.connection, apiKey: draft.apiKey, current: {
            if let added = draft.added { return connection(added).map { ($0, requestKey($0)) } }
            return draft.discarded ? nil : (draft.connection, draft.apiKey)
        }, apply: { merged in
            if draft.added != nil { upsert(merged) } else { draft.connection = merged }
        })
        return list.count
    }

    /// Saves a draft (Add): the connection with its headers and models, its API key into the Keychain, and a sign-in
    /// already kept under its id. A ChatGPT account another connection already has goes to that one, as a sign-in there
    /// would (`keepChatGPTSignIn`), and a second on-device connection is never added. Returns the connection it is now;
    /// nil when it can't be added yet (`canAdd`). Throws when the key can't be saved, and then nothing is.
    @discardableResult
    func add(_ draft: ConnectionDraft) throws -> UUID? {
        guard draft.canAdd else { return nil }
        let c = draft.connection
        let fetchedAt = modelsFetchedAt[c.id]
        let id: UUID
        switch c.kind {
        case .chatGPT:
            id = keepChatGPTSignIn(c)
        case .appleOnDevice:
            if let existing = onDeviceConnection {
                id = existing.id
            } else {
                upsert(c)
                id = c.id
            }
        case .openCode:
            if let key = draft.apiKey { try openCode.saveAPIKey(key, connectionID: c.id) }
            upsert(c)
            id = c.id
        case .openAICompatible, .anthropic:
            if let key = draft.apiKey { try setAPIKey(key, for: c.id) }
            upsert(c)
            id = c.id
        }
        draft.added = id
        if id == c.id, let fetchedAt { modelsFetchedAt[id] = fetchedAt } // kept now that the connection is known
        return id
    }

    /// Drops a draft (Cancel, going back, closing the sheet) and leaves nothing of it: its key and headers were never
    /// saved, and a sign-in kept under its id is signed out (a ChatGPT token is revoked, a sign-in still running ends
    /// without saving) and removed with whatever else is under the id.
    func discard(_ draft: ConnectionDraft) async {
        guard draft.isOpen else { return }
        draft.discarded = true
        let id = draft.id
        modelFetches[id] = nil
        guard connection(id) == nil else { return } // never: a draft isn't in the list until Add
        await chatGPT.signOut(connectionID: id)
        await openCode.signOut(connectionID: id)
        forget(id)
    }
}
