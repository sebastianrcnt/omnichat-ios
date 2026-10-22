import Foundation
import SwiftData

/// The SwiftData store: chats, saved skills and the files synced chats show. With chat sync on (the default) it is
/// mirrored to the private database of the iCloud container both apps share; off, it stays on this device.
///
/// Every model in `models` syncs, so each stored property must follow CloudKit's rules (see the top of
/// `Conversation.swift`). A new model joins `models`; a new property needs a default or must be optional.
enum StrataStore {
    static let cloudKitContainer = "iCloud.cc.coolservices.strata"
    /// The Settings switch "Sync chats and skills" (this device only, on by default). Read at launch.
    static let syncEnabledKey = "sync.chats"
    /// Set once the store from before sync was migrated and stamped (`prepare`).
    static let preparedKey = "sync.storePrepared.v1"

    static let models: [any PersistentModel.Type] = [
        Conversation.self, Message.self, Attachment.self, CompactionRecord.self, SyncedSkill.self, SyncedFile.self,
    ]

    static var schema: Schema { Schema(models) }

    static func syncEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: syncEnabledKey) as? Bool ?? true
    }

    /// Unit tests never sync, whatever the switch says.
    static var isRunningTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    /// The store at `url`, or at SwiftData's default location (where the store from before sync already is).
    static func configuration(url: URL? = nil, cloudKit: Bool) -> ModelConfiguration {
        let database: ModelConfiguration.CloudKitDatabase = cloudKit ? .private(cloudKitContainer) : .none
        if let url { return ModelConfiguration(schema: schema, url: url, cloudKitDatabase: database) }
        return ModelConfiguration(schema: schema, cloudKitDatabase: database)
    }

    /// The app's container. Opening it migrates an older store in place (lightweight: nothing is dropped).
    static func makeContainer(defaults: UserDefaults = .standard) throws -> ModelContainer {
        let sync = syncEnabled(defaults) && !isRunningTests
        try prepare(url: nil, defaults: defaults)
        return try ModelContainer(for: schema, configurations: configuration(cloudKit: sync))
    }

    /// Once, before the store first syncs: opens it with CloudKit off, which migrates it to this schema, and stamps this
    /// device on the conversations made before sync existed. Nothing has come from iCloud yet, so every one of them is
    /// this device's own; that is what lets `SyncDedupe` tell two uploads of one restored store apart.
    static func prepare(url: URL?, defaults: UserDefaults, device: String = DeviceIdentity.current) throws {
        guard !defaults.bool(forKey: preparedKey) else { return }
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations: configuration(url: url, cloudKit: false))
            try stampOrigins(ModelContext(container), device: device)
        }
        defaults.set(true, forKey: preparedKey)
    }

    static func stampOrigins(_ context: ModelContext, device: String) throws {
        let unstamped = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.syncOrigin == nil }))
        for conversation in unstamped { conversation.syncOrigin = device }
        if context.hasChanges { try context.save() }
    }
}
