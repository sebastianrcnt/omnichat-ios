import Foundation

/// How one assistant message is laid out, live and finished, from the same inputs.
///
/// The work in stream order: each round's thinking as a "Thought for Ns" line, the activity feed (a card per search, pages
/// read attached to their rows) broken wherever the model thought or wrote to the person between tool rounds, and that
/// text in between. While working, the sentence being thought sits at the end, where the work is happening. Then the
/// answer. The live text keeps the same identity when the answer is final, so it never jumps.
enum MessageLayout {
    enum Item: Equatable, Identifiable {
        /// The whole message's thinking, for a message without per-round thinking segments.
        case thought
        /// One round's thinking, by its segment index.
        case reasoning(Int)
        /// The live line at the end while the model works: the sentence being thought, or what it is doing.
        case working
        /// The `n`th run of tool calls (counted from 0).
        case feed(Int)
        /// Text written between tool rounds, by its segment index.
        case note(Int)
        /// The text being written, then (same identity, so it stays in place) the finished answer.
        case text

        var id: String {
            switch self {
            case .thought: "thought"
            case .reasoning(let n): "reasoning\(n)"
            case .working: "working"
            case .feed(let n): n == 0 ? "feed" : "feed\(n)"
            case .note(let n): "note\(n)"
            case .text: "text"
            }
        }
    }

    /// Space above `item`: one even gap between every part of the work and the answer, so a thought line sits as far
    /// from the card above it as from the one below. The live line takes the same gap, so it doesn't move when it
    /// finishes.
    static func gap(above item: Item, after previous: Item?) -> Double {
        previous == nil ? 0 : 16
    }

    /// The work before the answer, in stream order.
    enum Part: Equatable {
        /// Calls of consecutive rounds, shown as one feed.
        case calls([ToolCallRecord])
        /// What the model wrote before the next round's calls.
        case note(segment: Int, text: String)
        /// A round's thinking, shown by its last line.
        case thought(segment: Int, seconds: Double?, line: String)
    }

    /// Rounds run together into one feed until the model writes something; that text sits between the feeds.
    /// - Parameter hasLiveCalls: the running round has calls, which join the last feed (or start one after a note).
    static func parts(segments: [ProcessSegment], hasLiveCalls: Bool) -> [Part] {
        var out: [Part] = []
        for segment in segments {
            switch segment.kind {
            case .thinking:
                if let line = lastLine(of: segment.text) {
                    out.append(.thought(segment: segment.index, seconds: segment.seconds, line: line))
                }
            case .text:
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append(.note(segment: segment.index, text: text)) }
            case .toolRound:
                guard !segment.calls.isEmpty else { continue }
                if case .calls(let earlier)? = out.last { out[out.count - 1] = .calls(earlier + segment.calls) }
                else { out.append(.calls(segment.calls)) }
            }
        }
        if hasLiveCalls {
            if case .calls? = out.last {} else { out.append(.calls([])) }
        }
        return out
    }

    /// The last sentence of some reasoning, as plain text: the sentence the live line ended on, so a round's line
    /// keeps its words when it finishes. Falls back to the last line with words in it. Nil when there is nothing to show.
    static func lastLine(of text: String) -> String? {
        if let sentence = ThoughtSentences.latest(in: text) {
            let line = plain(sentence.text)
            if line.contains(where: { $0.isLetter || $0.isNumber }) { return line }
        }
        for raw in text.split(whereSeparator: \.isNewline).reversed() {
            let line = plain(String(raw))
            if line.contains(where: { $0.isLetter || $0.isNumber }) { return line }
        }
        return nil
    }

    /// A thought as the line shows it, live or finished: markdown marks (headings, list bullets, emphasis, code ticks)
    /// removed, so both draw the same characters at the same width.
    static func plain(_ text: String) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = line.first, "#>".contains(first) { line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces) }
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) { line.removeFirst(2) }
        for mark in ["**", "__", "`"] { line = line.replacingOccurrences(of: mark, with: "") }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything the model wrote to the person in this message: the notes between rounds, then the answer.
    static func fullText(segments: [ProcessSegment], answer: String) -> String {
        let notes = parts(segments: segments, hasLiveCalls: false).compactMap { part -> String? in
            if case .note(_, let text) = part { return text } else { return nil }
        }
        return (notes + [answer]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The answer is being written: no call is running and this round has text. (Text written before a tool call is a
    /// note; it moves between the feeds when the call is requested.)
    static func answerStarted(isStreaming: Bool, pendingCount: Int, hasRoundText: Bool) -> Bool {
        isStreaming && pendingCount == 0 && hasRoundText
    }

    /// - Parameters:
    ///   - hasThought: the message has reasoning. Without per-round thinking in `parts` (a message saved before rounds
    ///     kept their thinking), a finished one shows it as one line at the top.
    ///   - parts: the work before the answer, from `parts(segments:hasLiveCalls:)`.
    ///   - isWorking: the turn runs and its answer hasn't started: the live line closes the work.
    static func items(hasThought: Bool, parts: [Part], isStreaming: Bool, isWorking: Bool, hasAnswer: Bool) -> [Item] {
        var out: [Item] = []
        let roundThoughts = parts.contains { if case .thought = $0 { true } else { false } }
        if hasThought && !roundThoughts && !isStreaming { out.append(.thought) }
        var feeds = 0
        for part in parts {
            switch part {
            case .calls:
                out.append(.feed(feeds))
                feeds += 1
            case .note(let segment, _):
                out.append(.note(segment))
            case .thought(let segment, _, _):
                out.append(.reasoning(segment))
            }
        }
        if isStreaming && isWorking { out.append(.working) }
        if hasAnswer { out.append(.text) }
        return out
    }
}

/// Totals shown in the summary row.
struct ProcessSummary: Equatable {
    var seconds: Double?
    var searches: Int
    var pages: Int

    init(segments: [ProcessSegment], fallbackSeconds: Double? = nil) {
        let thinking = segments.filter { $0.kind == .thinking }
        let known = thinking.compactMap(\.seconds)
        if !known.isEmpty { seconds = known.reduce(0, +) }
        else { seconds = thinking.isEmpty ? nil : fallbackSeconds }
        let calls = segments.flatMap(\.calls)
        searches = calls.filter { $0.name == ToolNames.webSearch }.count
        pages = calls.filter { ToolNames.readsPage($0.name) && $0.fetchOffset == 0 }.count
    }

    /// "4s", "1m 22s".
    static func duration(_ seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        guard total >= 60 else { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
    }

    var title: String {
        var parts: [String] = []
        if let seconds { parts.append(String(localized: "Thought for \(Self.duration(seconds))")) }
        if searches > 0 { parts.append(searches == 1 ? String(localized: "1 search") : String(localized: "\(searches) searches")) }
        if pages > 0 { parts.append(pages == 1 ? String(localized: "1 page") : String(localized: "\(pages) pages")) }
        return parts.isEmpty ? String(localized: "Worked on it") : parts.joined(separator: " · ")
    }
}
