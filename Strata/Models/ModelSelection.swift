import Foundation

/// Picks which model a new chat should use.
enum ModelSelection {
    struct Choice: Equatable {
        var connectionID: UUID
        var modelID: String
    }

    /// The preferred choice if it still exists; otherwise the first model of the Strata connection;
    /// otherwise the first model of any connection. `nil` when no connection has models.
    static func resolve(connections: [Connection], preferredConnectionID: UUID?, preferredModelID: String?) -> Choice? {
        if let cid = preferredConnectionID, let mid = preferredModelID,
           connections.first(where: { $0.id == cid })?.models.contains(where: { $0.id == mid }) == true {
            return Choice(connectionID: cid, modelID: mid)
        }
        if let strata = connections.first(where: { $0.isStrata }), let first = strata.models.first {
            return Choice(connectionID: strata.id, modelID: first.id)
        }
        for c in connections { if let first = c.models.first { return Choice(connectionID: c.id, modelID: first.id) } }
        return nil
    }
}
