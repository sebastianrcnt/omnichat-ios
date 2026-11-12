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
        let suite = "strata.tests.\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let found = try await Task.detached {
            #expect(!Self.isMainThread())
            return try PendingRecoveryQuery.identifiers(container: container, device: "me", defaults: UserDefaults(suiteName: suite)!)
        }.value
        #expect(found.isEmpty)
        #expect(main.hasChanges)
        #expect(unsaved.cancelPending)
    }

    @Test func legacyFlagMigrationAndDeviceFilteringWorkInBackground() async throws {
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
        let found = try await Task.detached {
            #expect(!Self.isMainThread())
            let defaults = UserDefaults(suiteName: suite)!
            let ids = try PendingRecoveryQuery.identifiers(container: container, device: "me", defaults: defaults)
            #expect(defaults.bool(forKey: "strata.resumeFlagMigrated.v1"))
            return Set(ids)
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

    @Test func overlappingFlushesCannotOverwriteANewerCheckpoint() async throws {
        let container = try store()
        let message = Message(role: .assistant, sortIndex: 0)
        container.mainContext.insert(message)
        try container.mainContext.save()
        let writer = CheckpointStore(container: container, id: message.persistentModelID)
        var writes: [Int] = []
        var release: CheckedContinuation<Void, Never>?
        let persister = CheckpointPersister(minInterval: 0, center: NotificationCenter(), autoTrailing: false) { snapshot in
            if writes.isEmpty {
                writes.append(snapshot.checkpoint.lastSequence)
                await withCheckedContinuation { release = $0 }
            } else {
                writes.append(snapshot.checkpoint.lastSequence)
            }
            try await writer.write(snapshot, device: "me", sources: nil)
        }
        var first = try TurnCheckpoint(messages: [.user("hi")])
        first.requestData = try ChatRequest(model: "m", messages: [.user("hi")]).encoded()
        first.submissionStarted = true
        _ = try first.apply(ChatDelta(content: "a", requestID: "request", sequence: 1))
        let earlier = first
        let one = Task { try await persister.update(earlier) }
        for _ in 0..<1000 where release == nil { await Task.yield() }
        #expect(release != nil)
        var second = first
        _ = try second.apply(ChatDelta(content: "b", sequence: 2))
        let later = second
        let two = Task { try await persister.update(later) }
        for _ in 0..<1000 where persister.latest?.lastSequence != 2 { await Task.yield() }
        #expect(persister.latest?.lastSequence == 2)
        #expect(writes == [1], "the newer flush waits until the earlier write completes")
        release?.resume()
        try await one.value
        try await two.value
        try await persister.flush()
        #expect(writes == [1, 2])
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<Message>()).first?.resumeCheckpoint)
        #expect(saved.lastSequence == 2 && saved.accumulator.content == "ab")
        persister.close()
        writer.close()
        await #expect(throws: CancellationError.self) {
            try await writer.write(.init(checkpoint: earlier, staticData: nil,
                                         dynamicData: JSONEncoder().encode(earlier.dynamicPart)), device: "me", sources: nil)
        }
        #expect(try ModelContext(container).fetch(FetchDescriptor<Message>()).first?.resumeCheckpoint?.lastSequence == 2)
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
