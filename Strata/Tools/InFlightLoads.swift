import Foundation

/// Page loads under way, by URL. Two `web_fetch` calls for the same page in one round share one load: the second
/// joins the first, and the page is fetched and extracted once. Progress goes to every call waiting on the load, and
/// the load is cancelled when the last of them is.
@MainActor
final class InFlightLoads {
    static let shared = InFlightLoads()

    @MainActor
    private final class Entry {
        var task: Task<FetchedPage, Error>?
        var waiters = 0
        var callIDs: Set<String> = []
        var latest = 0.0
    }

    private var entries: [String: Entry] = [:]
    /// Loads under way (tests).
    var count: Int { entries.count }

    /// - Parameter perform: does the load; reports its progress (0...1) through the closure it is given.
    func load(key: String, callID: String?,
              perform: @escaping @MainActor @Sendable (_ progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> FetchedPage) async throws -> FetchedPage {
        let entry: Entry
        if let existing = entries[key] {
            entry = existing
        } else {
            let created = Entry()
            entries[key] = created
            created.task = Task { @MainActor [weak self, weak created] in
                let sink: @MainActor @Sendable (Double) -> Void = { value in
                    guard let created else { return }
                    created.latest = max(created.latest, value)
                    for id in created.callIDs { ToolProgress.shared.report(id, value) }
                }
                defer {
                    if let self, let created, self.entries[key] === created { self.entries[key] = nil }
                }
                return try await perform(sink)
            }
            entry = created
        }
        entry.waiters += 1
        if let callID {
            entry.callIDs.insert(callID)
            if entry.latest > 0 { ToolProgress.shared.report(callID, entry.latest) }
        }
        guard let task = entry.task else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor in
                entry.waiters -= 1
                if entry.waiters <= 0 {
                    if self.entries[key] === entry { self.entries[key] = nil }
                    task.cancel()
                }
            }
        }
    }
}
