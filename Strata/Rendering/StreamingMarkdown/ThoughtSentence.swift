import Foundation

/// The sentence a model is currently writing in its reasoning, identified by where it starts.
/// Growing text keeps the same `start`; a new sentence has a larger one.
struct ThoughtSentence: Equatable, Sendable {
    /// UTF-8 offset of the sentence start in the full reasoning text.
    var start: Int
    var text: String
}

enum ThoughtSentences {
    /// The latest sentence of `text`: from its first character, up to everything written so far.
    ///
    /// Boundaries are `.`, `?` or `!` followed by whitespace, a newline, and CJK `。`. A finished sentence
    /// stays the latest one until the first character of the next sentence arrives, so the result only
    /// changes identity when a new sentence actually begins.
    static func latest(in text: String) -> ThoughtSentence? {
        // Ignore trailing whitespace: "Done. " is still the sentence "Done."
        var end = text.endIndex
        while end > text.startIndex {
            let before = text.index(before: end)
            if text[before].isWhitespace { end = before } else { break }
        }
        guard end > text.startIndex else { return nil }
        let body = text[text.startIndex..<end]

        // Walk back from the character before the last one (a boundary at the very end starts nothing).
        var start = text.startIndex
        var i = body.index(before: body.endIndex)
        while i > body.startIndex {
            i = body.index(before: i)
            if isBoundary(body, at: i) { start = body.index(after: i); break }
        }
        // Skip the whitespace that follows the boundary.
        while start < body.endIndex, body[start].isWhitespace { start = body.index(after: start) }
        guard start < body.endIndex else { return nil }
        return ThoughtSentence(start: text.utf8.distance(from: text.startIndex, to: start), text: String(body[start...]))
    }

    private static func isBoundary(_ s: Substring, at i: Substring.Index) -> Bool {
        let c = s[i]
        switch c {
        case "\n", "\r\n", "。": return true
        case ".", "?", "!":
            let next = s.index(after: i)
            return next < s.endIndex && s[next].isWhitespace
        default: return false
        }
    }
}

/// Decides which sentence the one-line preview shows. Pure and clock-free: the caller passes `now`
/// (any monotonic seconds), so tests drive time explicitly.
///
/// - The first sentence shows immediately.
/// - The displayed sentence keeps updating in place while it grows (same `start`).
/// - A new sentence replaces it only if `minInterval` has passed since the last switch; otherwise the
///   switch is held, and `nextSwitchAt` says when to call `update` again. When the window ends, the
///   preview jumps straight to the latest sentence, skipping any in between.
struct ThoughtPreviewGate: Equatable {
    var minInterval: Double = 1.2
    private(set) var displayed: ThoughtSentence?
    private var switchedAt: Double?

    init(minInterval: Double = 1.2) { self.minInterval = minInterval }

    /// The time at which a held-back switch becomes allowed (nil when nothing is pending).
    private(set) var nextSwitchAt: Double?

    @discardableResult
    mutating func update(latest: ThoughtSentence?, now: Double) -> ThoughtSentence? {
        guard let latest else { return displayed }
        guard let current = displayed, let switchedAt else {
            displayed = latest; switchedAt = now; nextSwitchAt = nil
            return displayed
        }
        if latest.start == current.start {
            displayed = latest; nextSwitchAt = nil // same sentence, still growing
        } else if now >= switchedAt + minInterval { // same expression as nextSwitchAt, so waking exactly then switches
            displayed = latest; self.switchedAt = now; nextSwitchAt = nil
        } else {
            nextSwitchAt = switchedAt + minInterval
        }
        return displayed
    }
}
