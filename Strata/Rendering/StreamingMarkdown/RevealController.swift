import Foundation

/// Decouples text arrival from display.
///
/// Received text queues up as a backlog; each display tick reveals part of it. The step is
/// `max(minStep, backlog * dt / targetLag)`, so bursty network chunks turn into a steady flow and the
/// display never lags far behind. Cuts prefer word boundaries and never split a grapheme cluster
/// (all counting is in `Character`s, i.e. extended grapheme clusters).
struct RevealController: Sendable {
    var targetLag: Double = 0.2
    /// Minimum characters revealed per tick while there is a backlog.
    var minStep = 3
    /// How far back from the raw cut a word boundary is searched, in characters.
    var wordLookback = 10

    private(set) var backlog = ""
    /// Always `backlog.count`. Recomputed from the string after every mutation: counting each received
    /// chunk separately drifts when a grapheme cluster spans two chunks (combining marks, ZWJ emoji,
    /// CRLF, Hangul jamo), which used to push the cursor past the end of the buffer.
    private(set) var backlogCount = 0
    private(set) var revealedCount = 0
    private(set) var receivedCount = 0
    private var drainTicksLeft: Int?

    init(targetLag: Double = 0.2, minStep: Int = 3) {
        self.targetLag = targetLag
        self.minStep = minStep
    }

    var hasBacklog: Bool { backlogCount > 0 }

    mutating func receive(_ text: String) {
        guard !text.isEmpty else { return }
        let before = backlogCount
        backlog += text
        backlogCount = backlog.count
        receivedCount += max(0, backlogCount - before)
    }

    /// Drop everything queued (the buffer is being replaced, e.g. a new attempt or regenerate).
    mutating func reset() {
        backlog = ""
        backlogCount = 0
        revealedCount = 0
        receivedCount = 0
        drainTicksLeft = nil
    }

    /// The stream ended: drain the remaining backlog within `targetLag` (instead of the decaying rate).
    mutating func markEnded(tick: Double) {
        drainTicksLeft = max(1, Int((targetLag / max(tick, 0.001)).rounded(.down)))
    }

    /// Reveal a slice for this tick. Returns the newly revealed text (possibly empty).
    mutating func tick(dt: Double) -> String {
        guard !backlog.isEmpty else { return "" }
        backlogCount = backlog.count
        var step: Int
        if let left = drainTicksLeft {
            step = Int((Double(backlogCount) / Double(max(left, 1))).rounded(.up))
            drainTicksLeft = max(1, left - 1)
        } else {
            step = Int((Double(backlogCount) * dt / max(targetLag, 0.001)).rounded(.up))
        }
        step = min(backlogCount, max(minStep, step))
        return take(step, preferWordBoundary: step < backlogCount && drainTicksLeft == nil)
    }

    /// Reveal everything immediately (stream finished, user scrolled up, or tapped stop).
    mutating func flushAll() -> String {
        guard !backlog.isEmpty else { return "" }
        return take(backlog.count, preferWordBoundary: false)
    }

    private mutating func take(_ requested: Int, preferWordBoundary: Bool) -> String {
        // Never trust the counters: clamp to what the buffer really holds.
        backlogCount = backlog.count
        var count = min(max(0, requested), backlogCount)
        guard count > 0 else { return "" }
        if preferWordBoundary {
            // Look back from the cut for whitespace; cut right after it so words are not split.
            let prefix = backlog.prefix(count)
            var offset = 0
            var found: Int?
            for ch in prefix.reversed() {
                if offset >= wordLookback { break }
                if ch.isWhitespace { found = count - offset; break }
                offset += 1
            }
            if let found, found > 0 { count = found }
        }
        let end = backlog.index(backlog.startIndex, offsetBy: count, limitedBy: backlog.endIndex) ?? backlog.endIndex
        let out = String(backlog[..<end])
        backlog.removeSubrange(..<end)
        backlogCount = backlog.count
        revealedCount += out.count
        return out
    }
}
