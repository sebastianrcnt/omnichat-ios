import AppIntents
import CoreSpotlight
import Foundation
import SwiftData

/// A chat, for Shortcuts, Siri and Spotlight: "Open Chat", and the chat Ask OmniChat continues.
struct ConversationEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chat", numericFormat: "\(placeholder: .int) chats")
    static let defaultQuery = ConversationQuery()

    let id: UUID
    @Property(title: "Title")
    var title: String
    @Property(title: "Last Updated")
    var updatedAt: Date

    init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }

    @MainActor
    init(_ conversation: Conversation) {
        self.init(id: conversation.id, title: conversation.displayTitle, updatedAt: conversation.updatedAt)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(updatedAt.formatted(date: .abbreviated, time: .shortened))",
                              image: .init(systemName: "bubble.left.and.bubble.right"))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.contentModificationDate = updatedAt
        attributes.lastUsedDate = updatedAt
        return attributes
    }
}

/// Chats by id, by title, and the recent ones Shortcuts and Siri suggest.
struct ConversationQuery: EntityStringQuery {
    @Dependency private var container: ModelContainer

    /// How many chats the pickers suggest and Spotlight lists.
    static let recentLimit = 30

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ConversationEntity] {
        Self.entities(for: identifiers, in: container.mainContext)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ConversationEntity] {
        Self.entities(matching: string, in: container.mainContext)
    }

    @MainActor
    func suggestedEntities() async throws -> [ConversationEntity] {
        Self.recent(in: container.mainContext)
    }

    @MainActor
    static func entities(for identifiers: [UUID], in context: ModelContext) -> [ConversationEntity] {
        let ids = Set(identifiers)
        let found = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        // In the order asked for.
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return identifiers.compactMap { byID[$0].map(ConversationEntity.init) }
    }

    /// Newest first. Chats with no messages yet (an empty title and nothing sent) are left out.
    @MainActor
    static func recent(in context: ModelContext, limit: Int = recentLimit) -> [ConversationEntity] {
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { !$0.title.isEmpty },
                                                       sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).map(ConversationEntity.init)
    }

    /// Titles containing `string`, newest first.
    @MainActor
    static func entities(matching string: String, in context: ModelContext, limit: Int = recentLimit) -> [ConversationEntity] {
        let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return recent(in: context, limit: limit) }
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title.localizedStandardContains(q) },
                                                       sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).map(ConversationEntity.init)
    }
}

/// A model on one of the connections, as the composer's model menu lists it.
struct ChatModelEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Model", numericFormat: "\(placeholder: .int) models")
    static let defaultQuery = ChatModelQuery()

    /// `<connection id>:<model id>`. A model id may contain colons ("llama3:8b"); a UUID never does.
    let id: String
    let connectionID: UUID
    let modelID: String
    @Property(title: "Name")
    var name: String
    @Property(title: "Connection")
    var connectionName: String

    init(connectionID: UUID, modelID: String, name: String, connectionName: String) {
        self.id = Self.id(connectionID: connectionID, modelID: modelID)
        self.connectionID = connectionID
        self.modelID = modelID
        self.name = name
        self.connectionName = connectionName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(connectionName)")
    }

    var choice: ModelSelection.Choice { .init(connectionID: connectionID, modelID: modelID) }

    static func id(connectionID: UUID, modelID: String) -> String { "\(connectionID.uuidString):\(modelID)" }

    static func parse(_ id: String) -> (connectionID: UUID, modelID: String)? {
        guard let colon = id.firstIndex(of: ":"), let connection = UUID(uuidString: String(id[..<colon])) else { return nil }
        let model = String(id[id.index(after: colon)...])
        return model.isEmpty ? nil : (connection, model)
    }
}

struct ChatModelQuery: EntityStringQuery {
    @Dependency private var connections: ConnectionStore

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ChatModelEntity] {
        Self.entities(for: identifiers, in: connections)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ChatModelEntity] {
        Self.entities(matching: string, in: connections)
    }

    @MainActor
    func suggestedEntities() async throws -> [ChatModelEntity] {
        Self.listed(in: connections)
    }

    /// The models the composer's menu lists, in its order. A model hidden there is still found by id or name.
    @MainActor
    static func listed(in connections: ConnectionStore) -> [ChatModelEntity] {
        all(in: connections).filter { m in connections.connection(m.connectionID)?.showsInPicker(m.modelID) ?? false }
    }

    @MainActor
    static func all(in connections: ConnectionStore) -> [ChatModelEntity] {
        connections.allModels.map { c, model in
            ChatModelEntity(connectionID: c.id, modelID: model.id, name: c.displayName(forModel: model.id), connectionName: c.name)
        }
    }

    @MainActor
    static func entities(for identifiers: [String], in connections: ConnectionStore) -> [ChatModelEntity] {
        identifiers.compactMap { id in
            guard let (connectionID, modelID) = ChatModelEntity.parse(id), let c = connections.connection(connectionID) else { return nil }
            // A model typed by hand that the list no longer has still names the connection's model.
            return ChatModelEntity(connectionID: connectionID, modelID: modelID, name: c.displayName(forModel: modelID), connectionName: c.name)
        }
    }

    @MainActor
    static func entities(matching string: String, in connections: ConnectionStore) -> [ChatModelEntity] {
        let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return listed(in: connections) }
        return all(in: connections).filter {
            $0.name.localizedStandardContains(q) || $0.modelID.localizedStandardContains(q) || $0.connectionName.localizedStandardContains(q)
        }
    }
}
