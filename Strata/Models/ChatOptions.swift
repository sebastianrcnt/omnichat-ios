import Foundation

/// The models the "Select model" sheet lists, grouped by connection.
enum ModelPickerCatalog {
    struct Item: Hashable, Identifiable {
        var connectionID: UUID
        var modelID: String
        /// The alias when set, else the id.
        var title: String
        /// The real id under an alias; nil when the title already is the id.
        var subtitle: String?
        /// What the model can't do ("No images · No web tools"); nil when it does everything. Rows note only the gaps,
        /// so a list of capable models stays quiet.
        var limits: String?
        var id: String { "\(connectionID.uuidString)/\(modelID)" }
    }

    struct Group: Identifiable {
        var connectionID: UUID
        var name: String
        var items: [Item]
        /// What every model here can do ("Every model here takes images and can use web tools."); nil when nothing is shared.
        var footer: String?
        var id: UUID { connectionID }
    }

    /// A provider list longer than this gets a search field.
    static let searchThreshold = 10

    static func limits(_ m: ModelInfo) -> String? {
        var parts: [String] = []
        if !m.supportsImages { parts.append(String(localized: "No images")) }
        if !m.supportsEffort { parts.append(String(localized: "No effort")) }
        if !m.supportsTools { parts.append(String(localized: "No web tools")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func footer(_ models: [ModelInfo]) -> String? {
        guard !models.isEmpty else { return nil }
        var shared: [String] = []
        if models.allSatisfy(\.supportsImages) { shared.append(String(localized: "takes images")) }
        if models.allSatisfy(\.supportsEffort) { shared.append(String(localized: "has effort levels")) }
        if models.allSatisfy(\.supportsTools) { shared.append(String(localized: "can use web tools")) }
        guard let last = shared.popLast() else { return nil }
        let list = shared.isEmpty ? last : String(localized: "\(shared.joined(separator: ", ")) and \(last)")
        return models.count == 1
            ? String(localized: "This model \(list).")
            : String(localized: "Every model here \(list).")
    }

    /// Recently used models across connections, newest first: the current one leads, then `recentKeys`
    /// (`RecentModels.key`), skipping any no longer listed. At most `limit`.
    static func recent(groups: [Group], recentKeys: [String], currentConnectionID: UUID?, currentModelID: String?,
                       limit: Int = 4) -> [Item] {
        let all = Dictionary(groups.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var keys = recentKeys
        if let c = currentConnectionID, let m = currentModelID { keys.insert(RecentModels.key(c, m), at: 0) }
        var seen = Set<String>()
        return keys.compactMap { k in seen.insert(k).inserted ? all[k] : nil }.prefix(limit).map { $0 }
    }

    /// Items whose title or id contains `query` (case-insensitive); all of them for a blank query.
    static func filter(_ items: [Item], query: String) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.modelID.localizedCaseInsensitiveContains(q) }
    }

    /// Visible models per connection, in connection order; connections with nothing to show are left out. The current
    /// model is always listed, even when hidden, so the menu can show what the chat is using.
    static func groups(connections: [Connection], currentConnectionID: UUID?, currentModelID: String?) -> [Group] {
        connections.compactMap { c in
            let models = c.models
                .filter { c.showsInPicker($0.id) || (c.id == currentConnectionID && $0.id == currentModelID) }
            let items = models.map { m in
                let alias = c.alias(forModel: m.id)
                return Item(connectionID: c.id, modelID: m.id, title: alias ?? m.id, subtitle: alias == nil ? nil : m.id,
                            limits: limits(m))
            }
            return items.isEmpty ? nil : Group(connectionID: c.id, name: c.name, items: items, footer: footer(models))
        }
    }
}

/// The models picked most recently, newest first, as `RecentModels.key` strings in `AppSettings.recentModels`.
enum RecentModels {
    static let limit = 8

    static func key(_ connectionID: UUID, _ modelID: String) -> String { "\(connectionID.uuidString)/\(modelID)" }

    static func noting(_ connectionID: UUID, _ modelID: String, in list: [String]) -> [String] {
        let k = key(connectionID, modelID)
        return Array(([k] + list.filter { $0 != k }).prefix(limit))
    }
}

/// Identity of the chat view. A new chat creates its conversation on the first send; the view stays (so the question
/// it just sent stays pinned) instead of being rebuilt the way it is for any other change of conversation.
struct ChatViewKey: Equatable {
    private(set) var id = UUID()

    /// Keeps the view when `new` is the conversation the empty chat just started answering; otherwise a fresh view.
    static func keepsView(old: UUID?, new: UUID?, active: UUID?) -> Bool {
        old == nil && new != nil && new == active
    }

    mutating func update(old: UUID?, new: UUID?, active: UUID?) {
        if !Self.keepsView(old: old, new: new, active: active) { id = UUID() }
    }
}
