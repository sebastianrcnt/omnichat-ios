import Foundation

/// Lets an action through at most once per `interval`. Pure: the caller supplies the time.
struct RateLimiter: Sendable {
    let interval: Duration
    private var last: ContinuousClock.Instant?

    init(interval: Duration) { self.interval = interval }

    /// True when enough time has passed since the last allowed call (the first call is always allowed).
    mutating func allow(at now: ContinuousClock.Instant = .now) -> Bool {
        if let last, now - last < interval { return false }
        last = now
        return true
    }

    mutating func reset() { last = nil }
}
