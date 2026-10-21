import Foundation
import Observation

/// Who is running a tool call: the id of the model's call, for the code that reports progress for it.
enum ToolContext {
    @TaskLocal static var callID: String?
    /// Where a page load reports its progress: it fans out to every call waiting on the load.
    @TaskLocal static var progressSink: (@MainActor @Sendable (Double) -> Void)?
    /// The conversation the turn belongs to (Python keeps one interpreter, and its figures, per conversation).
    @TaskLocal static var conversationID: UUID?
    /// The model reads images, so `view_image` is offered and Python output points to it.
    @TaskLocal static var readsImages = false
}

/// Progress of running tool calls (0...1), keyed by chat and call id, for the fill in a running fetch's chip. Only calls
/// that report progress appear here. Values never go backwards, and a finished call fades out instead of vanishing.
///
/// The chat is part of the key because call ids are only unique within a request: two chats replying at once can both
/// have a `call_0` (a server that sends no ids gets synthetic ones). Writers default to the turn's chat
/// (`ToolContext.conversationID`); readers pass the chat they show.
@MainActor
@Observable
final class ToolProgress {
    static let shared = ToolProgress()
    /// How long a completed fill stays before it is removed (the view fades it meanwhile).
    static let fadeDelay: Duration = .milliseconds(450)

    struct Key: Hashable {
        var conversation: UUID?
        var id: String
    }

    private(set) var values: [Key: Double] = [:]
    @ObservationIgnored private var removals: [Key: Task<Void, Never>] = [:]

    func value(for id: String, conversation: UUID? = nil) -> Double? { values[Key(conversation: conversation, id: id)] }

    /// Raises the value; a lower one is ignored.
    func report(_ id: String, _ value: Double, conversation: UUID? = ToolContext.conversationID) {
        let key = Key(conversation: conversation, id: id)
        let v = min(1, max(0, value))
        removals[key]?.cancel()
        removals[key] = nil
        if let current = values[key], current >= v { return }
        values[key] = v
    }

    /// The call is done. Success fills to 1 and fades; failure removes the fill at once (the row shows its error tint).
    func finish(_ id: String, success: Bool, conversation: UUID? = ToolContext.conversationID) {
        let key = Key(conversation: conversation, id: id)
        guard values[key] != nil else { return }
        guard success else { clear(id, conversation: conversation); return }
        values[key] = 1
        removals[key]?.cancel()
        removals[key] = Task { [weak self] in
            try? await Task.sleep(for: Self.fadeDelay)
            guard !Task.isCancelled else { return }
            self?.values[key] = nil
            self?.removals[key] = nil
        }
    }

    func clear(_ id: String, conversation: UUID? = ToolContext.conversationID) {
        let key = Key(conversation: conversation, id: id)
        removals[key]?.cancel()
        removals[key] = nil
        values[key] = nil
    }
}

/// Turns what a web view reports into one bar. Loading takes 0...0.8 of it (the page's own estimate), the rest is the
/// steps after the load. Values only go up.
struct FetchProgress {
    static let loadShare = 0.8
    static let loaded = 0.8
    static let settled = 0.85
    static let extracting = 0.9
    static let extracted = 0.95
    static let done = 1.0

    /// 0...1 estimate of the page load, as the web view reports it.
    static func loading(_ estimate: Double) -> Double { min(max(estimate, 0), 1) * loadShare }

    private(set) var value = 0.0
    private var limiter = RateLimiter(interval: .milliseconds(100)) // about 10 updates a second

    /// The value to publish now, or nil when it is not higher than the last one or is too soon after the last update.
    /// The final value always gets through.
    mutating func advance(to new: Double, at now: ContinuousClock.Instant = .now) -> Double? {
        let v = min(1, max(0, new))
        guard v > value else { return nil }
        if v < Self.done, !limiter.allow(at: now) { return nil }
        value = v
        if v >= Self.done { limiter.reset() }
        return v
    }
}
