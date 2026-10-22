import Testing
import Foundation
import SwiftData
@testable import Strata

/// A local-only store with every synced model (CloudKit is never on in tests).
@MainActor
private func syncedStore() throws -> ModelContainer {
    try ModelContainer(for: StrataStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
}

private func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Dedupe

@MainActor
struct SyncDedupeTests {
    /// One conversation as two devices uploaded it: the same id, each copy with its own messages.
    private func twoCopies(_ context: ModelContext, firstOrigin: String = "A", secondOrigin: String = "B")
        -> (id: UUID, shared: UUID, onlyFirst: UUID, onlySecond: UUID) {
        let id = UUID(), shared = UUID(), onlyFirst = UUID(), onlySecond = UUID()
        func copy(origin: String, messages: [UUID], title: String, updated: Date) {
            let c = Conversation(title: title)
            c.id = id
            c.syncOrigin = origin
            c.updatedAt = updated
            context.insert(c)
            for (i, mid) in messages.enumerated() {
                let m = Message(role: i == 0 ? .user : .assistant, text: "m\(i)", sortIndex: i)
                m.id = mid
                context.insert(m)
                m.conversation = c
            }
        }
        copy(origin: firstOrigin, messages: [shared, onlyFirst], title: "Old", updated: Date(timeIntervalSince1970: 100))
        copy(origin: secondOrigin, messages: [shared, onlySecond], title: "Renamed", updated: Date(timeIntervalSince1970: 200))
        return (id, shared, onlyFirst, onlySecond)
    }

    @Test func copiesOfAConversationBecomeOneWithEverythingEitherHad() throws {
        let container = try syncedStore()
        let context = container.mainContext
        let ids = twoCopies(context)
        try context.save()
        #expect(try SyncDedupe.conversations(context) == 1)
        let left = try context.fetch(FetchDescriptor<Conversation>())
        #expect(left.count == 1)
        let kept = try #require(left.first)
        #expect(kept.syncOrigin == "A") // the smallest origin, the same on every device
        #expect(kept.title == "Renamed") // the newer copy's title
        #expect(Set(kept.messages.map(\.id)) == [ids.shared, ids.onlyFirst, ids.onlySecond])
        #expect(try context.fetch(FetchDescriptor<Message>()).filter { $0.id == ids.shared }.count == 1)
        #expect(try SyncDedupe.conversations(context) == 0)
    }

    @Test func everyDeviceKeepsTheSameCopy() throws {
        // Whichever copy a device has locally (inserted first), the one that stays is the same.
        for (first, second) in [("A", "B"), ("B", "A")] {
            let container = try syncedStore()
            let context = container.mainContext
            _ = twoCopies(context, firstOrigin: first, secondOrigin: second)
            try context.save()
            try SyncDedupe.conversations(context)
            #expect(try context.fetch(FetchDescriptor<Conversation>()).map(\.syncOrigin) == ["A"])
        }
    }

    @Test func frozenSnapshotsAreNeverReplaced() throws {
        let container = try syncedStore()
        let context = container.mainContext
        let a = Conversation(title: "a"), b = Conversation(title: "b")
        b.id = a.id
        a.syncOrigin = "A"
        b.syncOrigin = "B"
        a.skillIndexSnapshot = "kept"
        b.skillIndexSnapshot = "other"
        b.preferencesSnapshot = "from b"
        b.updatedAt = a.updatedAt.addingTimeInterval(60)
        context.insert(a)
        context.insert(b)
        try context.save()
        try SyncDedupe.conversations(context)
        let kept = try #require(try context.fetch(FetchDescriptor<Conversation>()).first)
        #expect(kept.skillIndexSnapshot == "kept")
        #expect(kept.preferencesSnapshot == "from b") // filled in, since the kept copy had none
    }

    @Test func copiesThatCantBeToldApartStay() throws {
        let container = try syncedStore()
        let context = container.mainContext
        _ = twoCopies(context, firstOrigin: "A", secondOrigin: "A")
        let other = twoCopies(context)
        try context.save()
        // Same origin: no device could pick the same one, so neither goes. On screen: left for later.
        #expect(try SyncDedupe.conversations(context, skipping: [other.id]) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Conversation>()) == 4)
        #expect(try SyncDedupe.conversations(context) == 1)
    }

    @Test func skillsAndFilesKeepOnePerNameAndPath() throws {
        let container = try syncedStore()
        let context = container.mainContext
        let older = SyncedSkill(Skill(name: "naver-places", description: "Old.", body: "old"), origin: "A")
        let newer = SyncedSkill(Skill(name: "naver-places", description: "New.", body: "new"), origin: "B")
        older.updatedAt = Date(timeIntervalSince1970: 100)
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        context.insert(newer)
        context.insert(older)
        let path = "Artifacts/\(UUID().uuidString)/a1.html"
        let f1 = SyncedFile(path: path, conversationID: nil, data: Data("1".utf8), origin: "B")
        let f2 = SyncedFile(path: path, conversationID: nil, data: Data("2".utf8), origin: "A")
        f1.updatedAt = Date(timeIntervalSince1970: 300)
        f2.updatedAt = Date(timeIntervalSince1970: 100)
        context.insert(f1)
        context.insert(f2)
        try context.save()
        #expect(try SyncDedupe.run(context) == SyncDedupe.Report(conversations: 0, skills: 1, files: 1))
        let skill = try #require(try context.fetch(FetchDescriptor<SyncedSkill>()).first)
        #expect(skill.origin == "A" && skill.body == "new" && skill.summary == "New.")
        let file = try #require(try context.fetch(FetchDescriptor<SyncedFile>()).first)
        #expect(file.origin == "A" && file.data == Data("1".utf8))
    }
}

// MARK: - Skills

@MainActor
struct SkillSyncTests {
    @Test func skillFilesMoveIntoTheStoreOnceAndOtherDevicesSkillsComeOut() throws {
        let container = try syncedStore()
        let dir = try tempDirectory()
        let local = SkillStore(builtIn: [], directory: dir)
        try local.save(Skill(name: "from-files", description: "Saved before sync.", body: "Body."))
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let sync = SkillSync(container: container, store: local, defaults: defaults)
        sync.migrateFiles()
        #expect(defaults.bool(forKey: SkillSync.migratedKey))
        let records = try container.mainContext.fetch(FetchDescriptor<SyncedSkill>())
        #expect(records.map(\.name) == ["from-files"])
        sync.migrateFiles() // once
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SyncedSkill>()) == 1)

        // Another device's skill arrives; one deleted elsewhere goes.
        container.mainContext.insert(SyncedSkill(Skill(name: "from-mac", description: "Saved on the Mac.", body: "Steps."), origin: "mac"))
        try container.mainContext.save()
        sync.apply()
        #expect(local.savedSkills.map(\.name) == ["from-files", "from-mac"])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("from-mac.md").path))
        for record in try container.mainContext.fetch(FetchDescriptor<SyncedSkill>()) where record.name == "from-files" {
            container.mainContext.delete(record)
        }
        try container.mainContext.save()
        sync.apply()
        #expect(local.savedSkills.map(\.name) == ["from-mac"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("from-files.md").path))
        #expect(SkillStore(builtIn: [], directory: dir).savedSkills.map(\.name) == ["from-mac"]) // the files match
    }

    @Test func localSavesAndDeletesReachTheStore() throws {
        let container = try syncedStore()
        let local = SkillStore(builtIn: [], directory: nil)
        let sync = SkillSync(container: container, store: local, defaults: UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!)
        sync.record(.saved(Skill(name: "new-one", description: "D.", body: "B.")))
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedSkill>()).map(\.body) == ["B."])
        sync.record(.saved(Skill(name: "new-one", description: "D.", body: "B2.")))
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncedSkill>()).map(\.body) == ["B2."])
        sync.record(.deleted("new-one"))
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SyncedSkill>()) == 0)
    }

    @Test func aSkillSavedHereIsNotUndoneBeforeTheStoreHasIt() throws {
        let local = SkillStore(builtIn: [Skill(name: "built-in", description: "B.", body: "B.")], directory: nil)
        var reported: [SkillStore.Change] = []
        local.onChange { change in MainActor.assumeIsolated { reported.append(change) } }
        try local.save(Skill(name: "fresh", description: "Just saved.", body: "Body."))
        #expect(reported.map(\.name) == ["fresh"])
        local.replaceSaved([Skill(name: "remote", description: "R.", body: "R."), Skill(name: "built-in", description: "X.", body: "X.")])
        #expect(local.savedSkills.map(\.name) == ["fresh", "remote"]) // a built-in name never comes in
        local.acknowledge("fresh")
        local.replaceSaved([Skill(name: "remote", description: "R.", body: "R.")])
        #expect(local.savedSkills.map(\.name) == ["remote"])
    }
}

// MARK: - Files

struct FileSyncTests {
    @Test func onlyFiguresAndArtifactsSync() {
        let id = UUID()
        #expect(FileSync.path(area: FileSync.toolImages, conversationID: id, name: "figure-1.png") == "ToolImages/\(id.uuidString)/figure-1.png")
        #expect(FileSync.path(area: FileSync.toolImages, conversationID: id, name: "screenshot-1.png") == nil)
        #expect(FileSync.path(area: FileSync.artifacts, conversationID: id, name: "index.json") != nil)
        #expect(FileSync.path(area: FileSync.artifacts, conversationID: id, name: "../x") == nil)
        #expect(FileSync.path(area: "Skills", conversationID: id, name: "x.md") == nil)
    }

    @MainActor
    @Test func writesReachTheStoreAndMissingFilesComeBack() throws {
        let container = try syncedStore()
        let here = try tempDirectory(), there = try tempDirectory()
        let chat = UUID()
        let sync = FileSync(container: container, root: here)
        sync.wrote(Data("png".utf8), area: FileSync.toolImages, conversationID: chat, name: "figure-1.png")
        sync.wrote(Data("<p>1</p>".utf8), area: FileSync.artifacts, conversationID: chat, name: "a1.html")
        sync.wrote(Data("shot".utf8), area: FileSync.toolImages, conversationID: chat, name: "screenshot-1.png")
        sync.waitForPendingWork()
        let paths = try ModelContext(container).fetch(FetchDescriptor<SyncedFile>()).map(\.path).sorted()
        #expect(paths == ["Artifacts/\(chat.uuidString)/a1.html", "ToolImages/\(chat.uuidString)/figure-1.png"])

        // Another device writes what it lacks into the same folders.
        let other = FileSync(container: container, root: there)
        #expect(other.materializeNow() == 2)
        #expect(try Data(contentsOf: there.appendingPathComponent("ToolImages/\(chat.uuidString)/figure-1.png")) == Data("png".utf8))
        #expect(other.materializeNow() == 0)
        #expect(ToolImageStore(root: there.appendingPathComponent(FileSync.toolImages)).image(id: "figure-1", conversationID: chat) != nil)

        // Deleting the chat removes its files from the store.
        sync.removedAll(area: FileSync.toolImages, conversationID: chat)
        sync.waitForPendingWork()
        #expect(try ModelContext(container).fetch(FetchDescriptor<SyncedFile>()).map(\.path) == ["Artifacts/\(chat.uuidString)/a1.html"])
    }
}

// MARK: - Settings and connections

@MainActor
struct SettingsSyncTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")! }

    @Test func preferencesGoUpAndDeviceSettingsStay() {
        let d = defaults(), cloud = InMemoryKeyValueStore()
        d.set("#3B82F6", forKey: "accentHex")
        d.set("Be brief.", forKey: AppSettings.userPreferencesKey)
        d.set(false, forKey: AppSettings.webSearchEnabledKey)
        d.set(["naver"], forKey: AppSettings.enabledPluginsKey)
        d.set(5, forKey: "textSizeStep")
        d.set(true, forKey: "developerMode")
        d.set(true, forKey: AppSettings.healthEnabledKey)
        d.set(false, forKey: "notifyReplies")
        let written = SettingsSync.push(from: d, to: cloud)
        #expect(Set(written) == ["accentHex", AppSettings.userPreferencesKey, AppSettings.webSearchEnabledKey, AppSettings.enabledPluginsKey])
        #expect(cloud.object(forKey: "settings.userPreferences") as? String == "Be brief.")
        #expect(cloud.object(forKey: "settings.textSizeStep") == nil)
        #expect(cloud.object(forKey: "settings.developerMode") == nil)
        #expect(cloud.object(forKey: "settings.healthTool") == nil)
        #expect(SettingsSync.push(from: d, to: cloud).isEmpty) // nothing changed
        for key in ["textSizeStep", "useSystemTextSize", "developerMode", "notifyReplies", AppSettings.liveActivitiesKey,
                    AppSettings.healthEnabledKey, BackgroundLoadingSound.enabledKey, DictationSettings.engineKey, "lastModelID",
                    StrataStore.syncEnabledKey, KeychainSync.enabledKey, SettingsSync.enabledKey] {
            #expect(!SettingsSync.keys.contains(key), "\(key) belongs to one device")
        }
    }

    @Test func anotherDevicesChangesComeDownAndShowAtOnce() {
        let d = defaults(), cloud = InMemoryKeyValueStore()
        let settings = AppSettings(defaults: d)
        let sync = SettingsSync(defaults: d, cloud: cloud, settings: settings)
        sync.start()
        cloud.set("Answer in Korean.", forKey: "settings.userPreferences")
        cloud.set(48_000, forKey: "settings.fetchLength")
        cloud.set(7, forKey: "settings.textSizeStep") // not a synced key: ignored
        sync.remoteChanged(["settings.userPreferences", "settings.fetchLength", "settings.textSizeStep"])
        #expect(settings.userPreferences == "Answer in Korean.")
        #expect(settings.fetchLength == 48_000)
        #expect(d.string(forKey: AppSettings.userPreferencesKey) == "Answer in Korean.")
        #expect(d.object(forKey: "textSizeStep") == nil)
        // A change here goes up.
        settings.accentHex = "#EF4444"
        sync.localChanged()
        #expect(cloud.object(forKey: "settings.accentHex") as? String == "#EF4444")
        sync.stop()
    }

    @Test func turningSyncOnSendsThisDevicesValuesFirst() {
        let d = defaults(), cloud = InMemoryKeyValueStore()
        d.set("Mine.", forKey: AppSettings.userPreferencesKey)
        cloud.set("Theirs.", forKey: "settings.userPreferences")
        SettingsSync(defaults: d, cloud: cloud, settings: AppSettings(defaults: d)).start(localWins: true)
        #expect(cloud.object(forKey: "settings.userPreferences") as? String == "Mine.")
        let launch = defaults()
        launch.set("Old.", forKey: AppSettings.userPreferencesKey)
        SettingsSync(defaults: launch, cloud: cloud, settings: AppSettings(defaults: launch)).start()
        #expect(launch.string(forKey: AppSettings.userPreferencesKey) == "Mine.") // at launch the cloud's come down
    }
}

@MainActor
struct ConnectionSyncTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")! }
    private func connection(_ name: String, headers: String = "") -> Connection {
        Connection(name: name, baseURL: "https://\(name).example/v1", customHeaders: headers, models: [ModelInfo(id: "m")])
    }

    @Test func theMergeKeepsNewConnectionsAndDropsThoseDeletedElsewhere() {
        let mine = connection("mine"), shared = connection("shared"), deleted = connection("deleted")
        var sharedThere = shared
        sharedThere.name = "Renamed there"
        let theirs = connection("theirs")
        let onDevice = Connection.appleOnDevice(model: FakeOnDeviceModel())
        let merged = ConnectionSync.merge(local: [shared, mine, deleted, onDevice], cloud: [shared.id: sharedThere, theirs.id: theirs],
                                          order: [theirs.id, shared.id], seen: [shared.id, deleted.id, theirs.id],
                                          headers: { $0 == shared.id ? "X-Org: acme" : nil })
        #expect(merged.map(\.name) == ["Renamed there", "mine", onDevice.name, "theirs"])
        #expect(merged.first?.customHeaders == "X-Org: acme")
        #expect(!ConnectionSync.syncs(onDevice))
        #expect(!ConnectionSync.syncs(Connection(name: "New connection", baseURL: "https://")))
    }

    @Test func customHeadersTravelInTheKeychainNotTheKeyValueStore() throws {
        let c = connection("org", headers: "Authorization: Bearer secret")
        let data = try #require(ConnectionSync.encode(c))
        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
        let store = ConnectionStore(defaults: defaults(), keys: InMemoryKeyStore())
        store.upsert(c)
        let cloud = InMemoryKeyValueStore(), headers = InMemoryKeyStore()
        let sync = ConnectionSync(store: store, cloud: cloud, defaults: defaults(), headers: headers)
        sync.start()
        #expect(headers.key(for: c.id) == "Authorization: Bearer secret")
        #expect(ConnectionSync.cloudConnections(cloud)[c.id]?.customHeaders == "")
        #expect(store.connection(c.id)?.customHeaders == "Authorization: Bearer secret") // still here
        sync.stop()
    }

    @Test func pushAndPullBetweenTwoDevices() throws {
        let cloud = InMemoryKeyValueStore()
        let headers = InMemoryKeyStore() // iCloud Keychain, shared by both
        let phone = ConnectionStore(defaults: defaults(), keys: InMemoryKeyStore())
        let mac = ConnectionStore(defaults: defaults(), keys: InMemoryKeyStore())
        let a = connection("phone-only"), b = connection("mac-only")
        phone.upsert(a)
        mac.upsert(b)
        let phoneSync = ConnectionSync(store: phone, cloud: cloud, defaults: defaults(), headers: headers)
        let macSync = ConnectionSync(store: mac, cloud: cloud, defaults: defaults(), headers: headers)
        phoneSync.start()
        macSync.start()
        phoneSync.pull()
        #expect(Set(phone.connections.map(\.name)) == ["phone-only", "mac-only"])
        #expect(Set(mac.connections.map(\.name)) == ["phone-only", "mac-only"])

        // A delete on the Mac reaches the phone; a connection the phone adds meanwhile is not removed by the Mac.
        mac.delete(a.id)
        let c = connection("added-on-phone")
        phone.upsert(c)
        macSync.push(mac.connections)
        phoneSync.pull()
        #expect(Set(phone.connections.map(\.name)) == ["mac-only", "added-on-phone"])
        macSync.pull()
        #expect(Set(mac.connections.map(\.name)) == ["mac-only", "added-on-phone"])

        // A save on the phone doesn't send back its older copy of a connection the Mac just renamed.
        var renamed = try #require(mac.connection(b.id))
        renamed.name = "renamed-on-mac"
        mac.upsert(renamed)
        var touched = try #require(phone.connection(c.id))
        touched.name = "touched-on-phone"
        phone.upsert(touched)
        phoneSync.pull()
        macSync.pull()
        #expect(Set(phone.connections.map(\.name)) == ["renamed-on-mac", "touched-on-phone"])
        #expect(Set(mac.connections.map(\.name)) == ["renamed-on-mac", "touched-on-phone"])
        phoneSync.stop()
        macSync.stop()
    }
}
