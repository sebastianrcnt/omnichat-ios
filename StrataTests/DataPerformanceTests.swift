import CoreData
import Foundation
import SwiftData
import Testing
@testable import Strata

@MainActor
struct DataPerformanceTests {
    nonisolated private static func isMainThread() -> Bool { Thread.isMainThread }
    private func store() throws -> ModelContainer {
        try ModelContainer(for: StrataStore.schema,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    @Test func emptyBackgroundQueryDoesNotReadOrSaveTheViewContext() async throws {
        let container = try store()
        let main = container.mainContext
        main.autosaveEnabled = false
        // This unsaved pending message must not be visible to the background query.
        let unsaved = Message(role: .assistant, sortIndex: 0)
        unsaved.cancelPending = true
        main.insert(unsaved)
        let found = try await Task.detached {
            #expect(!Self.isMainThread())
            return try PendingRecoveryQuery.identifiers(container: container, device: "me")
        }.value
        #expect(found.isEmpty)
        #expect(main.hasChanges)
        #expect(unsaved.cancelPending)
    }

    @Test func legacyFlagMigrationStaysCoherentAndDeviceFilteringWorksInBackground() async throws {
        let container = try store()
        let context = container.mainContext
        let mine = Message(role: .assistant, sortIndex: 0)
        mine.resumeData = Data("legacy".utf8)
        let other = Message(role: .assistant, sortIndex: 1)
        other.hasResume = true
        other.resumeDeviceID = "other"
        let cancel = Message(role: .assistant, sortIndex: 2)
        cancel.cancelPending = true
        cancel.resumeDeviceID = "me"
        for message in [mine, other, cancel] { context.insert(message) }
        try context.save()
        let expected = Set([mine.persistentModelID, cancel.persistentModelID])
        let suite = "strata.tests.\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        try ChatController.migrateResumeFlags(context: context, defaults: defaults)
        #expect(defaults.bool(forKey: "strata.resumeFlagMigrated.v1"))
        #expect(mine.hasResume, "the main model sees the backfill immediately")
        mine.text = "a later main-context edit"
        try context.save()
        let found = try await Task.detached {
            #expect(!Self.isMainThread())
            return Set(try PendingRecoveryQuery.identifiers(container: container, device: "me"))
        }.value
        #expect(found == expected)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Message>()).first { $0.sortIndex == 0 }?.hasResume == true)
    }

    @Test func automaticRetriesBackOffButFirstForegroundIsEligible() throws {
        let container = try store()
        let a = Message(role: .assistant, sortIndex: 0), b = Message(role: .assistant, sortIndex: 1)
        container.mainContext.insert(a); container.mainContext.insert(b)
        try container.mainContext.save()
        let id = a.persistentModelID, untouched = b.persistentModelID
        var attempts = RecoveryAttempts()
        var now = Date(timeIntervalSince1970: 1000)
        #expect(attempts.isEligible(id, now: now))
        for delay in [30.0, 60, 120, 240, 480, 600, 600] {
            attempts.record(id, now: now)
            #expect(!attempts.isEligible(id, now: now))
            #expect(!attempts.isEligible(id, now: now.addingTimeInterval(delay - 1)))
            #expect(attempts.isEligible(untouched, now: now))
            now = now.addingTimeInterval(delay)
            #expect(attempts.isEligible(id, now: now))
        }
    }

    @Test func completedMigrationDoesNotFetchOrSaveMainContext() throws {
        let container = try store()
        let context = container.mainContext
        context.autosaveEnabled = false
        let suite = "strata.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "strata.resumeFlagMigrated.v1")
        let unsaved = Message(role: .assistant, sortIndex: 0)
        unsaved.resumeData = Data("legacy".utf8)
        context.insert(unsaved)
        try ChatController.migrateResumeFlags(context: context, defaults: defaults)
        #expect(context.hasChanges)
        #expect(!unsaved.hasResume, "no backfill scan once the migration flag is set")
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Message>()) == 0)
    }

    @Test func requestEncodingOffMainPreservesExactBytes() async throws {
        let request = ChatRequest(model: "m", messages: [.user(parts: [.imageURL("data:image/jpeg;base64,AA=="), .text("hi")])])
        let expected = try request.encoded()
        #expect(try await request.encodedOffMain() == expected)
    }

    @Test func resumeIndexesAreAnInferredLightweightMigration() throws {
        let current = try #require(NSManagedObjectModel.makeManagedObjectModel(for: StrataStore.models))
        let message = try #require(current.entitiesByName["Message"])
        let indexed = Set(message.indexes.flatMap { $0.elements.compactMap { $0.property?.name } })
        #expect(indexed.contains("hasResume"))
        #expect(indexed.contains("cancelPending"))
        // Exactly the previous, unversioned model, except for these indexes. Core Data must infer the mapping;
        // StoreMigrationTests also opens an actual older on-disk store using StrataStore's unchanged setup.
        let previous = try #require(current.copy() as? NSManagedObjectModel)
        previous.entitiesByName["Message"]?.indexes = []
        _ = try NSMappingModel.inferredMappingModel(forSourceModel: previous, destinationModel: current)
    }
}
