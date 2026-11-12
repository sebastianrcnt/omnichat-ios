import Foundation
import SwiftData

/// Each run owns one serial writer. Contexts/models never leave its queue. Closing is a terminal fence: all already
/// submitted writes finish before Stop, deletion or the final main-context save, and later submissions cannot write.
final class CheckpointStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cc.coolservices.strata.checkpoint", qos: .utility)
    private let container: ModelContainer
    private let id: PersistentIdentifier
    private var closed = false // queue confined

    init(container: ModelContainer, id: PersistentIdentifier) {
        self.container = container
        self.id = id
    }

    func write(_ snapshot: CheckpointPersister.Snapshot?, device: String, sources: [SourceInfo]?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard !closed else { throw CancellationError() }
                    let context = ModelContext(container)
                    context.autosaveEnabled = false
                    let id = id
                    let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.persistentModelID == id })
                    guard let message = try context.fetch(descriptor).first else { throw CancellationError() }
                    if let snapshot {
                        if let data = snapshot.staticData { message.resumeData = data }
                        message.resumeDynamicData = snapshot.dynamicData
                        message.hasResume = true
                        message.resumeDeviceID = device
                    } else {
                        message.clearResume()
                    }
                    if let sources { message.conversation?.sources = sources }
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Only terminal operations wait synchronously; periodic streaming writes suspend instead of blocking main.
    func close() {
        queue.sync { closed = true }
    }
}
