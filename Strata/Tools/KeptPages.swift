import Foundation

/// A page that can be kept after its tool failed (`HiddenWebView`; a fake in tests).
@MainActor
protocol KeepablePage: AnyObject {
    /// Short and stable for the view's life ("page7"): the model passes it to `browser_show`.
    var pageID: String { get }
    var currentURL: URL? { get }
    /// On screen in a sheet or a card: never torn down from under the user.
    var isOnScreen: Bool { get }
    var isDisposed: Bool { get }
    func dispose()
    /// Out of the window until it is shown or used again (`HiddenWebView.freeze`).
    func freeze()
}

extension KeepablePage {
    func freeze() {}
}

/// Web views whose tool failed or was blocked (a robot check, a pop-up, a timeout), kept alive instead of being torn
/// down, so the same page (its state, scroll, form input, a half-done check) can be handed to the user: by the model
/// with `browser_show(page:)`, or by a tap on the failed row. They live until the reply ends plus `lingering`; at most
/// `maxKept` are kept, the oldest going first. A browser session's page is listed too (`owned` false): it is only
/// found here, never torn down by this list.
@MainActor
@Observable
final class KeptPages {
    static let shared: KeptPages = {
        let kept = KeptPages()
        MemoryPurge.register { kept.removeAll() }
        return kept
    }()

    var maxKept = 3
    var lingering: Duration = .seconds(300)

    struct Entry {
        let page: any KeepablePage
        let owned: Bool
        var callIDs: Set<String>
        /// The chat whose reply kept it (its turn's end starts the clock).
        let conversationID: UUID?
        let keptAt: ContinuousClock.Instant
        /// Set when the reply that kept it ended.
        var expires: ContinuousClock.Instant?
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var sweeper: Task<Void, Never>?

    var count: Int { entries.filter(\.owned).count }

    /// Keeps `page` (failed in the call `callID`). Over `maxKept`, the oldest kept page not on screen is torn down.
    func keep(_ page: any KeepablePage, callID: String?, owned: Bool = true, conversationID: UUID? = ToolContext.conversationID,
              now: ContinuousClock.Instant = .now) {
        prune()
        if let i = entries.firstIndex(where: { $0.page === page }) {
            if let callID { entries[i].callIDs.insert(callID) }
            entries[i].expires = nil
            return
        }
        entries.append(Entry(page: page, owned: owned, callIDs: callID.map { [$0] } ?? [], conversationID: conversationID, keptAt: now))
        evict()
    }

    func page(id: String) -> (any KeepablePage)? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return entries.first { $0.page.pageID == trimmed && !$0.page.isDisposed }?.page
    }

    /// The page kept for a failed call, for the "Open this page" button on its row. Given the call's chat, only a page
    /// that chat's reply kept (call ids repeat across chats).
    func page(forCall callID: String, conversation: UUID? = nil) -> (any KeepablePage)? {
        entries.last { entry in
            entry.callIDs.contains(callID) && !entry.page.isDisposed
                && (conversation == nil || entry.conversationID == nil || entry.conversationID == conversation)
        }?.page
    }

    /// The reply of `conversation` ended: its pages go after `lingering` (one on screen then waits until it is put
    /// away), frozen meanwhile (a browser session's page is its session's to freeze). Pages another chat's running reply
    /// kept stay. Nil: every reply ended.
    func turnEnded(conversation: UUID? = nil, now: ContinuousClock.Instant = .now) {
        for i in entries.indices where entries[i].expires == nil
            && (conversation == nil || entries[i].conversationID == nil || entries[i].conversationID == conversation) {
            entries[i].expires = now + lingering
            if entries[i].owned { entries[i].page.freeze() }
        }
        scheduleSweep()
    }

    /// Tears down the pages whose time is up.
    func sweep(now: ContinuousClock.Instant = .now) {
        let expired = entries.filter { entry in entry.expires.map { now >= $0 } == true && !entry.page.isOnScreen }
        for entry in expired where entry.owned { entry.page.dispose() }
        entries.removeAll { entry in expired.contains { $0.page === entry.page } }
        prune()
    }

    /// Forgets a page without tearing it down (it is used again, or its owner disposes it).
    func release(_ page: any KeepablePage) {
        entries.removeAll { $0.page === page }
    }

    func removeAll() {
        for entry in entries where entry.owned && !entry.page.isOnScreen { entry.page.dispose() }
        entries.removeAll { $0.owned == false || !$0.page.isOnScreen }
        sweeper?.cancel()
        sweeper = nil
    }

    /// What a failed tool's result says about its kept page.
    static func note(pageID: String) -> String {
        "The page is kept open for a few minutes as page \"\(pageID)\": browser_show with page \"\(pageID)\" hands it to the user (to pass a check, sign in or close a pop-up) and returns its text when they tap Done."
    }

    /// The note for the kept page of `callID`, with a leading space; empty when nothing was kept.
    func note(forCall callID: String?, conversation: UUID? = ToolContext.conversationID) -> String {
        guard let callID, let page = page(forCall: callID, conversation: conversation) else { return "" }
        return " " + Self.note(pageID: page.pageID)
    }

    private func prune() {
        entries.removeAll { $0.page.isDisposed }
    }

    private func evict() {
        while count > maxKept, let i = entries.firstIndex(where: { $0.owned && !$0.page.isOnScreen }) {
            entries.remove(at: i).page.dispose()
        }
    }

    private func scheduleSweep() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while let self, !Task.isCancelled, self.entries.contains(where: { $0.expires != nil }) {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self.sweep()
            }
            self?.sweeper = nil
        }
    }

    /// Whether a view whose load failed with `error` is worth keeping for the user: not when the call was cancelled
    /// (the reply stopped), the URL guard refused the address, or the certificate was bad (nothing to show).
    nonisolated static func shouldKeep(after error: Error) -> Bool {
        if error is CancellationError || error is URLGuardError { return false }
        if let e = error as? WebToolError, e == .insecure { return false }
        return true
    }
}
