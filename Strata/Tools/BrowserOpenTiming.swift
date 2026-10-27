import Foundation

/// Where the time of one `browser_open` went, for the diagnostics panel: each phase's milliseconds, and what let the
/// page count as rendered.
struct BrowserOpenTiming: Codable, Equatable, Sendable {
    enum Settle: String, Codable, Sendable {
        /// The DOM and the network went quiet.
        case quiet
        /// The network never rested; read a moment after the load event.
        case afterLoad
        /// Read when the time limit ran out.
        case limit
    }

    var host = ""
    var date = Date()
    /// Checking the address (DNS).
    var resolve = 0
    /// Waiting for the conversation's browser (another call, the person watching or holding the page).
    var queue = 0
    /// Loading until the page counted as rendered.
    var load = 0
    var check = 0
    var read = 0
    /// The element list for the model.
    var state = 0
    var total = 0
    var settle: Settle?

    /// One line: "sec.gov 3.1 s · load 2.6 s (after load) · state 0.2 s".
    var summary: String {
        func s(_ ms: Int) -> String { (Double(ms) / 1000).formatted(.number.precision(.fractionLength(1))) + " s" }
        let how = settle.map { " (\($0 == .afterLoad ? "after load" : $0.rawValue))" } ?? ""
        var parts = ["\(host) \(s(total))", "load \(s(load))\(how)"]
        for (name, ms) in [("dns", resolve), ("queue", queue), ("check", check), ("read", read), ("state", state)] where ms >= 100 {
            parts.append("\(name) \(s(ms))")
        }
        return parts.joined(separator: " · ")
    }

    /// Marks each phase's end on the clock it started on.
    @MainActor
    final class Recorder {
        private var timing: BrowserOpenTiming
        private let started: ContinuousClock.Instant
        private var last: ContinuousClock.Instant

        init(host: String, started: ContinuousClock.Instant = .now) {
            timing = BrowserOpenTiming(host: host)
            self.started = started
            last = started
        }

        func mark(_ phase: WritableKeyPath<BrowserOpenTiming, Int>) {
            let now = ContinuousClock.now
            timing[keyPath: phase] = Self.ms(now - last)
            last = now
        }

        func settled(_ how: Settle) { timing.settle = how }

        func finish() -> BrowserOpenTiming {
            var out = timing
            out.total = Self.ms(.now - started)
            return out
        }

        private static func ms(_ d: Duration) -> Int {
            let (seconds, attoseconds) = d.components
            return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
        }
    }
}
