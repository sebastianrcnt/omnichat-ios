import Foundation

/// Picks which model a new chat should use.
enum ModelSelection {
    struct Choice: Equatable {
        var connectionID: UUID
        var modelID: String
    }

    /// The preferred choice (the user's last pick) if it still exists; otherwise the first model of the preferred
    /// connection; otherwise the first model of the first connection that has models. No connection is favored
    /// beyond that. `nil` when no connection has models.
    static func resolve(connections: [Connection], preferredConnectionID: UUID?, preferredModelID: String?) -> Choice? {
        if let cid = preferredConnectionID, let preferred = connections.first(where: { $0.id == cid }) {
            if let mid = preferredModelID, preferred.models.contains(where: { $0.id == mid }) {
                return Choice(connectionID: cid, modelID: mid)
            }
            if let first = preferred.models.first { return Choice(connectionID: cid, modelID: first.id) }
        }
        for c in connections { if let first = c.models.first { return Choice(connectionID: c.id, modelID: first.id) } }
        return nil
    }
}
