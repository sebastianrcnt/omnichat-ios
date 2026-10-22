import Foundation
import SwiftData

/// A skill the user saved, in the synced store. `SkillStore` keeps the files the tools read; this is what travels.
/// CloudKit rules apply (see `Conversation.swift`): every property optional or defaulted, nothing unique (`SyncDedupe`
/// keeps one skill per name).
@Model
final class SyncedSkill {
    var name: String = ""
    var summary: String = ""
    var body: String = ""
    var updatedAt: Date = Date.now
    /// The device that first saved it (`DeviceIdentity`): two devices that saved the same name are told apart by it.
    var origin: String?

    init(_ skill: Skill, origin: String = DeviceIdentity.current) {
        name = skill.name
        summary = skill.description
        body = skill.body
        self.origin = origin
    }

    var skill: Skill { Skill(name: name, description: summary, body: body) }

    func update(from skill: Skill) {
        guard summary != skill.description || body != skill.body else { return }
        summary = skill.description
        body = skill.body
        updatedAt = .now
    }
}

/// Keeps `SkillStore` and the synced store in step: the skill files from before sync move in once, local saves and
/// deletes are written to the store, and what other devices saved comes back out as files.
@MainActor
final class SkillSync {
    static let migratedKey = "sync.skillsMigrated.v1"

    let container: ModelContainer
    let store: SkillStore
    let defaults: UserDefaults

    init(container: ModelContainer, store: SkillStore = .shared, defaults: UserDefaults = .standard) {
        self.container = container
        self.store = store
        self.defaults = defaults
    }

    private var context: ModelContext { container.mainContext }

    func start() {
        migrateFiles()
        store.onChange { [weak self] change in
            Task { @MainActor in self?.record(change) }
        }
        apply()
    }

    /// The saved skill files become records, once. A name already in the store (another device moved it in first) is
    /// left to `SyncDedupe`, which keeps one.
    func migrateFiles() {
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        for skill in store.savedSkills { context.insert(SyncedSkill(skill)) }
        guard (try? context.save()) != nil else { return }
        defaults.set(true, forKey: Self.migratedKey)
    }

    /// The store's skills (after dedupe) replace the saved ones on this device.
    func apply() {
        _ = try? SyncDedupe.skills(context)
        let records = (try? context.fetch(FetchDescriptor<SyncedSkill>())) ?? []
        store.replaceSaved(records.map(\.skill))
    }

    func record(_ change: SkillStore.Change) {
        let name = change.name
        let existing = (try? context.fetch(FetchDescriptor<SyncedSkill>(predicate: #Predicate { $0.name == name }))) ?? []
        switch change {
        case .saved(let skill):
            // Copies of one name that dedupe has not settled yet all take the new text, so whichever stays has it.
            for record in existing { record.update(from: skill) }
            if existing.isEmpty { context.insert(SyncedSkill(skill)) }
        case .deleted:
            for record in existing { context.delete(record) }
        }
        if (try? context.save()) != nil { store.acknowledge(name) }
    }
}
