import Foundation

/// Even pacing for a live answer: text is shown at a steady rate a little under the rate it arrives at, sped up
/// whenever the backlog would take longer than `maxLag` to show, so the display is never far behind.
struct RevealPacing: Sendable, Equatable {
    /// Shown rate as a share of the measured incoming rate.
    var rateFactor = 0.85
    /// The longest the display may trail what has arrived, in seconds.
    var maxLag = 0.35
    /// How far back arrivals count toward the incoming rate, in seconds.
    var window = 1.0

    /// Characters per second to show: `rateFactor` x the incoming rate, but at least `backlog / maxLag`.
    func charsPerSecond(incomingRate: Double, backlog: Int) -> Double {
        max(rateFactor * max(0, incomingRate), Double(max(0, backlog)) / maxLag)
    }

    /// Characters per second that arrived in the last `window`. `arrivals` starts with the stream's oldest kept arrival,
    /// so a young stream is measured over its age (at least 0.25 s, so one burst does not read as an enormous rate).
    func incomingRate(arrivals: [(time: Double, count: Int)], now: Double) -> Double {
        let recent = arrivals.filter { $0.time > now - window }
        guard !recent.isEmpty, let first = arrivals.first else { return 0 }
        let span = min(window, max(0.25, now - first.time)) // a stream younger than the window is measured over its age
        return Double(recent.reduce(0) { $0 + $1.count }) / span
    }
}

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
    /// When set, `tick` paces evenly (`RevealPacing`) instead of the backlog-proportional step.
    var pacing: RevealPacing?
    /// Recent arrivals, for the incoming rate (paced mode only).
    private var arrivals: [(time: Double, count: Int)] = []
    /// Characters owed to the display but not shown yet (a cut at a word boundary shows fewer; they are made up next).
    private(set) var budget: Double = 0

    init(targetLag: Double = 0.2, minStep: Int = 3, pacing: RevealPacing? = nil) {
        self.targetLag = targetLag
        self.minStep = minStep
        self.pacing = pacing
    }

    var hasBacklog: Bool { backlogCount > 0 }

    mutating func receive(_ text: String, at now: Double = ProcessInfo.processInfo.systemUptime) {
        guard !text.isEmpty else { return }
        let before = backlogCount
        backlog += text
        backlogCount = backlog.count
        let added = max(0, backlogCount - before)
        receivedCount += added
        if let pacing {
            arrivals.append((now, added))
            if let first = arrivals.first, first.time < now - pacing.window * 2 { arrivals.removeAll { $0.time < now - pacing.window } }
        }
    }

    /// The incoming rate right now, in characters per second (paced mode).
    func incomingRate(now: Double) -> Double { pacing?.incomingRate(arrivals: arrivals, now: now) ?? 0 }

    /// Drop everything queued (the buffer is being replaced, e.g. a new attempt or regenerate).
    mutating func reset() {
        backlog = ""
        backlogCount = 0
        revealedCount = 0
        receivedCount = 0
        drainTicksLeft = nil
        arrivals = []
        budget = 0
    }

    /// The stream ended: drain the remaining backlog within `targetLag` (instead of the decaying rate).
    mutating func markEnded(tick: Double) {
        drainTicksLeft = max(1, Int((targetLag / max(tick, 0.001)).rounded(.down)))
    }

    /// Reveal a slice for this tick. Returns the newly revealed text (possibly empty).
    mutating func tick(dt: Double, now: Double = ProcessInfo.processInfo.systemUptime) -> String {
        guard !backlog.isEmpty else { budget = min(budget, 2); return "" }
        backlogCount = backlog.count
        if let pacing, drainTicksLeft == nil {
            budget += pacing.charsPerSecond(incomingRate: incomingRate(now: now), backlog: backlogCount) * dt
            let step = Self.wordCut(backlog, upTo: min(backlogCount, Int(budget)), maxWord: wordLookback * 2)
            guard step > 0 else { return "" }
            let out = take(step, preferWordBoundary: false)
            budget -= Double(out.count)
            if backlog.isEmpty { budget = min(budget, 2) }
            return out
        }
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

    /// How many characters of `text` to show when `limit` are allowed: whole words only (the cut falls after a space,
    /// or where the next character is one). A run with no space in reach (CJK text, a long URL) is cut at `limit` once
    /// that reaches `maxWord`; shorter waits for the rest of its word. Counts are graphemes, so nothing is split.
    static func wordCut(_ text: String, upTo limit: Int, maxWord: Int) -> Int {
        guard limit > 0 else { return 0 }
        var i = text.startIndex
        var count = 0
        var lastBoundary = 0
        while count < limit, i < text.endIndex {
            let ch = text[i]
            count += 1
            i = text.index(after: i)
            if ch.isWhitespace { lastBoundary = count }
        }
        if i == text.endIndex || text[i].isWhitespace { return count } // the whole text, or a word ends right here
        if lastBoundary > 0 { return lastBoundary }
        return count >= maxWord ? count : 0
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
