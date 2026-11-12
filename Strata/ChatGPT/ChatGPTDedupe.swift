import Foundation
import SwiftData

/// The ChatGPT account a connection is signed in to, kept with the connection so it syncs with the list: every device can
/// then tell two connections of one account (each device that signed in on its own made one) from two accounts. None of
/// it is a credential: the ID token's subject, the workspace, the email.
struct ChatGPTAccount: Codable, Hashable, Sendable {
    var subject: String?
    /// One login can have several workspaces (a personal plan and a Team), each its own account here.
    var workspace: String?
    /// Lowercased.
    var email: String?

    init?(subject: String?, workspace: String? = nil, email: String?) {
        let email = email?.trimmingCharacters(in: .whitespaces).lowercased()
        guard !(subject ?? "").isEmpty || !(email ?? "").isEmpty else { return nil }
        self.subject = (subject ?? "").isEmpty ? nil : subject
        self.workspace = (workspace ?? "").isEmpty ? nil : workspace
        self.email = (email ?? "").isEmpty ? nil : email
    }

    /// From a verified sign-in: the registration, and the workspace of this device's ID token when the registration is
    /// older than the field (the token was verified when it was saved).
    init?(_ registration: ChatGPTRegistration, tokens: ChatGPTTokens? = nil) {
        let workspace = registration.workspace ?? tokens?.idToken.flatMap { try? JWT($0).claims() }?.workspace
        self.init(subject: registration.subject, workspace: workspace, email: registration.email)
    }

    /// One account: the same workspace (or none named on either), and the same subject or, failing that, the same email.
    /// A workspace known on one side only is not a match yet: the device signed in to it fills it in.
    func isSame(as other: ChatGPTAccount) -> Bool {
        guard workspace == other.workspace else { return false }
        if let subject, subject == other.subject { return true }
        if let email, let theirs = other.email { return email == theirs }
        return false
    }

    /// What this lacks, taken from `other` (the same sign-in seen again). What it has never changes, so two devices that
    /// fill in the same connection agree.
    func filled(from other: ChatGPTAccount?) -> ChatGPTAccount {
        guard let other else { return self }
        var out = self
        out.subject = subject ?? other.subject
        out.workspace = workspace ?? other.workspace
        out.email = email ?? other.email
        return out
    }
}

/// One connection per ChatGPT account. Two devices that each signed in to the same account each made a connection, and
/// sync brings both everywhere. Every device collapses them on its own, so the one that stays must be the same
/// everywhere, chosen from what syncs: the smallest id. The others merge into it (`ConnectionStore`), and their chats and
/// settings follow.
enum ChatGPTDedupe {
    /// For each ChatGPT connection whose account another already has, the connection it merges into: the smallest id of
    /// that account. `dropped` are connections sync just removed here (merged on another device): they map to the one of
    /// `connections` with their account, and are never kept.
    static func plan(_ connections: [Connection], dropped: [Connection] = []) -> [UUID: UUID] {
        var heads: [(id: UUID, account: ChatGPTAccount)] = []
        var out: [UUID: UUID] = [:]
        for c in ordered(connections) {
            guard let account = c.chatGPTAccount else { continue }
            if let head = heads.first(where: { $0.account.isSame(as: account) }) { out[c.id] = head.id }
            else { heads.append((c.id, account)) }
        }
        for c in ordered(dropped) {
            guard let account = c.chatGPTAccount, let head = heads.first(where: { $0.account.isSame(as: account) }),
                  head.id != c.id else { continue }
            out[c.id] = head.id
        }
        return out
    }

    /// The connection of `account` that another one of it would merge into (the smallest id), if there is one.
    static func survivor(for account: ChatGPTAccount, among connections: [Connection]) -> UUID? {
        ordered(connections).first { $0.chatGPTAccount?.isSame(as: account) == true }?.id
    }

    private static func ordered(_ connections: [Connection]) -> [Connection] {
        connections.filter { $0.isChatGPT && $0.chatGPTAccount != nil }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// The survivor with what only the loser had: model aliases it has none for, the model list when it has none yet
    /// (fetched only where it is signed in), and the account details it lacks. Its name and everything else stay.
    static func merged(_ survivor: Connection, absorbing loser: Connection) -> Connection {
        var out = survivor
        out.modelAliases = loser.modelAliases.merging(survivor.modelAliases) { _, kept in kept }
        if out.models.isEmpty {
            out.models = loser.models
            out.hiddenModelIDs = loser.hiddenModelIDs
        }
        out.chatGPTAccount = survivor.chatGPTAccount?.filled(from: loser.chatGPTAccount) ?? loser.chatGPTAccount
        return out
    }

    // MARK: References

    static func remap(_ id: UUID?, _ merged: [UUID: UUID]) -> UUID? { id.map { merged[$0] ?? $0 } }

    /// `RecentModels` keys (`<connection id>/<model id>`) pointed at the survivors, each model once, newest first.
    static func remap(recentModels: [String], _ merged: [UUID: UUID]) -> [String] {
        var seen = Set<String>()
        return recentModels.compactMap { key in
            var key = key
            if let slash = key.firstIndex(of: "/"), let id = UUID(uuidString: String(key[..<slash])), let to = merged[id] {
                key = RecentModels.key(to, String(key[key.index(after: slash)...]))
            }
            return seen.insert(key).inserted ? key : nil
        }
    }

    /// Chats, the model last picked, dictation's connection and the recent models, pointed at the survivors.
    @MainActor
    static func remapReferences(_ merged: [UUID: UUID], settings: AppSettings, context: ModelContext?) {
        guard !merged.isEmpty else { return }
        if let context { _ = try? remapConversations(context, merged) }
        if let id = settings.lastConnectionID, let to = merged[id] { settings.lastConnectionID = to }
        if let id = settings.dictationConnectionID, let to = merged[id] { settings.dictationConnectionID = to }
        let recent = remap(recentModels: settings.recentModels, merged)
        if recent != settings.recentModels { settings.recentModels = recent }
    }

    /// Points chats at the connection theirs merged into. Returns how many changed.
    @MainActor
    static func remapConversations(_ context: ModelContext, _ merged: [UUID: UUID]) throws -> Int {
        guard !merged.isEmpty else { return 0 }
        let losers: [UUID?] = merged.keys.map { $0 }
        let chats = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { losers.contains($0.connectionID) }))
        for chat in chats { chat.connectionID = remap(chat.connectionID, merged) }
        if context.hasChanges { try context.save() }
        return chats.count
    }
}
