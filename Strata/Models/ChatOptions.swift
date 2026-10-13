import Foundation

/// Where an effort level sits on the composer's gauge.
enum EffortScale {
    /// The gauge fill for level `index` of `count` levels: the lowest level shows a sliver (1/count), the highest a full
    /// dial. Works for any number of levels; out-of-range input is clamped, and no levels means an empty dial.
    static func fraction(index: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        let i = min(max(index, 0), count - 1)
        return Double(i + 1) / Double(count)
    }

    /// The gauge fill for `effort` among `levels`; a level the model does not offer reads as the default's position.
    static func fraction(of effort: Effort, in levels: [Effort]) -> Double {
        guard !levels.isEmpty else { return 0 }
        let index = levels.firstIndex(of: effort) ?? levels.firstIndex(of: .default) ?? 0
        return fraction(index: index, count: levels.count)
    }
}

/// The models the "Select model" sheet lists, grouped by connection.
enum ModelPickerCatalog {
    struct Item: Hashable, Identifiable {
        var connectionID: UUID
        var modelID: String
        /// The alias when set, else the id.
        var title: String
        /// The real id under an alias; nil when the title already is the id.
        var subtitle: String?
        /// "Images · Effort · Web tools".
        var capabilities: String?
        var id: String { "\(connectionID.uuidString)/\(modelID)" }
    }

    struct Group: Identifiable {
        var connectionID: UUID
        var name: String
        var items: [Item]
        var id: UUID { connectionID }
    }

    /// Visible models per connection, in connection order; connections with nothing to show are left out. The current
    /// model is always listed, even when hidden, so the menu can show what the chat is using.
    static func groups(connections: [Connection], currentConnectionID: UUID?, currentModelID: String?) -> [Group] {
        connections.compactMap { c in
            let items = c.models
                .filter { c.showsInPicker($0.id) || (c.id == currentConnectionID && $0.id == currentModelID) }
                .map { m in
                    let alias = c.alias(forModel: m.id)
                    return Item(connectionID: c.id, modelID: m.id, title: alias ?? m.id, subtitle: alias == nil ? nil : m.id,
                                capabilities: m.capabilitiesSummary)
                }
            return items.isEmpty ? nil : Group(connectionID: c.id, name: c.name, items: items)
        }
    }
}
