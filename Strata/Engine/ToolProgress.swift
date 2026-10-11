import Foundation
import Observation

/// Who is running a tool call: the id of the model's call, for the code that reports progress for it.
enum ToolContext {
    @TaskLocal static var callID: String?
    /// Where a page load reports its progress: it fans out to every call waiting on the load.
    @TaskLocal static var progressSink: (@MainActor @Sendable (Double) -> Void)?
}

/// Progress of running tool calls (0...1), keyed by call id, for the fill in a running fetch's chip. Only calls that
/// report progress appear here. Values never go backwards, and a finished call fades out instead of vanishing.
@MainActor
@Observable
final class ToolProgress {
    static let shared = ToolProgress()
    /// How long a completed fill stays before it is removed (the view fades it meanwhile).
    static let fadeDelay: Duration = .milliseconds(450)

    private(set) var values: [String: Double] = [:]
    @ObservationIgnored private var removals: [String: Task<Void, Never>] = [:]

    func value(for id: String) -> Double? { values[id] }

    /// Raises the value; a lower one is ignored.
    func report(_ id: String, _ value: Double) {
        let v = min(1, max(0, value))
        removals[id]?.cancel()
        removals[id] = nil
        if let current = values[id], current >= v { return }
        values[id] = v
    }

    /// The call is done. Success fills to 1 and fades; failure removes the fill at once (the row shows its error tint).
    func finish(_ id: String, success: Bool) {
        guard values[id] != nil else { return }
        guard success else { clear(id); return }
        values[id] = 1
        removals[id]?.cancel()
        removals[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.fadeDelay)
            guard !Task.isCancelled else { return }
            self?.values[id] = nil
            self?.removals[id] = nil
        }
    }

    func clear(_ id: String) {
        removals[id]?.cancel()
        removals[id] = nil
        values[id] = nil
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
