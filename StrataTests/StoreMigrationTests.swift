import Testing
import Foundation
import SwiftData
@testable import Strata

/// The models exactly as the store had them before iCloud sync (main at 86fd522): unique ids, attributes without
/// defaults. A store written with them must open with today's models, nothing lost.
enum LegacySchema {
    static var models: [any PersistentModel.Type] { [Conversation.self, Message.self, Attachment.self, CompactionRecord.self] }

    @Model
    final class Conversation {
        @Attribute(.unique) var id: UUID
        var title: String
        var createdAt: Date
        var updatedAt: Date
        var isPinned: Bool
        var titleIsUserSet: Bool = false
        var autoRenameDone: Bool = false
        var createdDay: String = ""
        var leafID: UUID?
        var treeLinked: Bool = false
        var connectionID: UUID?
        var modelID: String?
        var effortRaw: String
        var lastPromptTokens: Int?
        var lastCompletionTokens: Int?
        var lastCachedTokens: Int?
        var lastReasoningTokens: Int?
        var lastUsageMessageID: UUID?
        @Attribute(.externalStorage) var sourcesData: Data?
        @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
        var messages: [Message] = []
        @Relationship(deleteRule: .cascade, inverse: \CompactionRecord.conversation)
        var compactions: [CompactionRecord] = []
        var preferencesSnapshot: String?
        var skillIndexSnapshot: String?
        var pluginSectionSnapshot: String?
        var toolSwitchesRaw: String?
        var offeredToolsRaw: String?
        var announcedToolsRaw: String?

        init(id: UUID, title: String, createdAt: Date) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.isPinned = true
            self.effortRaw = "high"
        }
    }

    @Model
    final class Message {
        @Attribute(.unique) var id: UUID
        var roleRaw: String
        var text: String
        var reasoning: String
        var thinkingSeconds: Double?
        var createdAt: Date
        var sortIndex: Int
        var errorText: String?
        var errorNeedsSettings: Bool = false
        @Attribute(.externalStorage) var resumeData: Data?
        var resumeDynamicData: Data?
        var hasResume: Bool = false
        var cancelPending: Bool = false
        var parentID: UUID?
        var lastActiveChildID: UUID?
        var stoppedByUser: Bool
        var translatedText: String?
        var translationTarget: String?
        var showingTranslation: Bool = false
        var hiddenInstruction: Bool = false
        var skillRequest: Bool = false
        var cutForEarlyAnswer: Bool = false
        var answeredEarly: Bool = false
        var apiNote: String?
        @Attribute(.externalStorage) var stepsData: Data?
        @Attribute(.externalStorage) var segmentsData: Data?
        var openUIStateData: Data?
        var conversation: Conversation?
        @Relationship(deleteRule: .cascade, inverse: \Attachment.message)
        var attachments: [Attachment] = []

        init(id: UUID, role: String, text: String, sortIndex: Int) {
            self.id = id
            self.roleRaw = role
            self.text = text
            self.reasoning = ""
            self.createdAt = .now
            self.sortIndex = sortIndex
            self.stoppedByUser = false
        }
    }

    @Model
    final class Attachment {
        @Attribute(.unique) var id: UUID
        @Attribute(.externalStorage) var jpegData: Data
        var thumbnailData: Data?
        var sortIndex: Int
        var message: Message?

        init(id: UUID, jpegData: Data) {
            self.id = id
            self.jpegData = jpegData
            self.sortIndex = 0
        }
    }

    @Model
    final class CompactionRecord {
        @Attribute(.unique) var id: UUID
        var anchorMessageID: UUID
        var anchorSteps: Int = -1
        var notes: String
        @Attribute(.externalStorage) var replacementData: Data
        var tokensBefore: Int
        var tokensAfter: Int
        var createdAt: Date
        var isAutomatic: Bool = true
        var conversation: Conversation?

        init(id: UUID, anchor: UUID, notes: String, replacement: Data) {
            self.id = id
            self.anchorMessageID = anchor
            self.notes = notes
            self.replacementData = replacement
            self.tokensBefore = 1000
            self.tokensAfter = 100
            self.createdAt = .now
        }
    }
}

@Suite(.serialized)
struct StoreMigrationTests {
    private func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("default.store")
    }

    @Test func theStoreStaysWhereItWas() {
        // Existing users' chats are in SwiftData's default store; the synced store must open that same file.
        #expect(StrataStore.configuration(cloudKit: false).url == ModelConfiguration().url)
        #expect(StrataStore.configuration(cloudKit: true).url == ModelConfiguration().url)
    }

    /// CloudKit's rules, checked on the schema without opening a CloudKit store (tests never touch iCloud). A store
    /// that breaks them fails to load once sync is on ("CloudKit integration requires that all relationships be optional").
    static func cloudKitProblems(_ schema: Schema) -> [String] {
        var out: [String] = []
        for entity in schema.entities {
            if !entity.uniquenessConstraints.isEmpty { out.append("\(entity.name): uniqueness constraint") }
            for attribute in entity.attributes {
                if attribute.isUnique { out.append("\(entity.name).\(attribute.name): unique") }
                if !attribute.isOptional && attribute.defaultValue == nil { out.append("\(entity.name).\(attribute.name): required, no default") }
            }
            for relationship in entity.relationships {
                if !relationship.isOptional { out.append("\(entity.name).\(relationship.name): relationship not optional") }
                if relationship.inverseName == nil && relationship.inverseKeyPath == nil {
                    out.append("\(entity.name).\(relationship.name): no inverse")
                }
            }
        }
        return out.sorted()
    }

    @Test func theSchemaMeetsCloudKitsRules() {
        #expect(Self.cloudKitProblems(StrataStore.schema) == [])
        // The check catches what the old models broke.
        let legacy = Self.cloudKitProblems(Schema(LegacySchema.models))
        #expect(legacy.contains("Conversation.id: unique"))
        #expect(legacy.contains("Conversation.title: required, no default"))
        #expect(legacy.contains("Conversation.messages: relationship not optional"))
    }

    @Test func aStoreFromBeforeSyncOpensWithEverythingInIt() throws {
        let url = try tempStoreURL()
        let ids = (conversation: UUID(), user: UUID(), answer: UUID(), attachment: UUID(), compaction: UUID())
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let jpeg = Data((0..<300_000).map { UInt8($0 % 251) }) // big enough for external storage
        let sources = Data(#"[{"n":1}]"#.utf8)
        try autoreleasepool {
            let schema = Schema(LegacySchema.models)
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
            let context = ModelContext(old)
            let c = LegacySchema.Conversation(id: ids.conversation, title: "Trip plans", createdAt: created)
            c.createdDay = "2026-09-21"
            c.preferencesSnapshot = "Be brief."
            c.skillIndexSnapshot = "Skills: …"
            c.offeredToolsRaw = "web,python"
            c.sourcesData = sources
            c.leafID = ids.answer
            context.insert(c)
            let user = LegacySchema.Message(id: ids.user, role: "user", text: "Where to?", sortIndex: 0)
            let answer = LegacySchema.Message(id: ids.answer, role: "assistant", text: "Jeju.", sortIndex: 1)
            answer.parentID = ids.user
            answer.stepsData = Data("steps".utf8)
            answer.resumeData = Data("checkpoint".utf8)
            answer.hasResume = true
            context.insert(user)
            context.insert(answer)
            user.conversation = c
            answer.conversation = c
            let attachment = LegacySchema.Attachment(id: ids.attachment, jpegData: jpeg)
            attachment.thumbnailData = Data("thumb".utf8)
            context.insert(attachment)
            attachment.message = user
            let record = LegacySchema.CompactionRecord(id: ids.compaction, anchor: ids.user, notes: "Notes", replacement: Data("[]".utf8))
            context.insert(record)
            record.conversation = c
            try context.save()
        }

        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        try StrataStore.prepare(url: url, defaults: defaults, device: "device-A")
        #expect(defaults.bool(forKey: StrataStore.preparedKey))
        let container = try ModelContainer(for: StrataStore.schema, configurations: StrataStore.configuration(url: url, cloudKit: false))
        let context = ModelContext(container)
        let c = try #require(try context.fetch(FetchDescriptor<Conversation>()).first)
        #expect(c.id == ids.conversation)
        #expect(c.title == "Trip plans")
        #expect(c.createdAt == created)
        #expect(c.isPinned)
        #expect(c.effortRaw == "high")
        #expect(c.createdDay == "2026-09-21")
        #expect(c.preferencesSnapshot == "Be brief.")
        #expect(c.skillIndexSnapshot == "Skills: …")
        #expect(c.offeredToolsRaw == "web,python")
        #expect(c.sourcesData == sources)
        #expect(c.leafID == ids.answer)
        #expect(c.syncOrigin == "device-A") // stamped before the first sync
        let messages = c.sortedMessages
        #expect(messages.map(\.id) == [ids.user, ids.answer])
        #expect(messages.map(\.text) == ["Where to?", "Jeju."])
        #expect(messages[1].parentID == ids.user)
        #expect(messages[1].stepsData == Data("steps".utf8))
        #expect(messages[1].resumeData == Data("checkpoint".utf8))
        #expect(messages[1].hasResume)
        #expect(messages[1].resumeDeviceID == nil) // a checkpoint from before sync is this device's own
        let attachment = try #require(messages[0].attachments.first)
        #expect(attachment.id == ids.attachment)
        #expect(attachment.jpegData == jpeg)
        #expect(attachment.thumbnailData == Data("thumb".utf8))
        let record = try #require(c.compactions.first)
        #expect(record.id == ids.compaction)
        #expect(record.anchorMessageID == ids.user)
        #expect(record.notes == "Notes")
        #expect(record.replacementData == Data("[]".utf8))
        #expect(record.tokensBefore == 1000)
        #expect(try context.fetchCount(FetchDescriptor<Message>()) == 2)

        // Prepared once: a second launch doesn't stamp again.
        try StrataStore.prepare(url: url, defaults: defaults, device: "device-B")
        #expect(try ModelContext(container).fetch(FetchDescriptor<Conversation>()).first?.syncOrigin == "device-A")
    }

    @Test func newConversationsCarryThisDevice() {
        #expect(Conversation(title: "x").syncOrigin == DeviceIdentity.current)
    }

    @MainActor
    @Test func onlyThisDevicesUnfinishedTurnsAreResumed() throws {
        let container = try ModelContainer(for: StrataStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        defaults.set(true, forKey: "strata.resumeFlagMigrated.v1")
        func pending(_ device: String?) -> Message {
            let m = Message(role: .assistant, sortIndex: 0)
            m.resumeData = Data("x".utf8)
            m.hasResume = true
            m.resumeDeviceID = device
            context.insert(m)
            return m
        }
        let mine = pending("me"), legacy = pending(nil), theirs = pending("other")
        try context.save()
        let found = Set(ChatController.pendingMessages(context: context, defaults: defaults, device: "me").map(\.id))
        #expect(found == [mine.id, legacy.id])
        #expect(!found.contains(theirs.id))
    }
}
