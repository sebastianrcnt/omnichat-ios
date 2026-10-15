import Foundation

/// How one assistant message is laid out, live and finished, from the same inputs.
///
/// One thought line (the sentence being thought while working, "Thought for Ns" once the answer starts), then the work
/// in stream order: the activity feed (a card per search, pages read attached to their rows), broken wherever the model
/// wrote to the person between tool rounds, with that text in between. Then the answer. The live text keeps the same
/// identity when the answer is final, so it never jumps.
enum MessageLayout {
    enum Item: Equatable, Identifiable {
        case thought
        /// The `n`th run of tool calls (counted from 0).
        case feed(Int)
        /// Text written between tool rounds, by its segment index.
        case note(Int)
        /// The text being written, then (same identity, so it stays in place) the finished answer.
        case text

        var id: String {
            switch self {
            case .thought: "thought"
            case .feed(let n): n == 0 ? "feed" : "feed\(n)"
            case .note(let n): "note\(n)"
            case .text: "text"
            }
        }
    }

    /// The work before the answer, in stream order.
    enum Part: Equatable {
        /// Calls of consecutive rounds, shown as one feed.
        case calls([ToolCallRecord])
        /// What the model wrote before the next round's calls.
        case note(segment: Int, text: String)
    }

    /// Rounds run together into one feed until the model writes something; that text sits between the feeds.
    /// - Parameter hasLiveCalls: the running round has calls, which join the last feed (or start one after a note).
    static func parts(segments: [ProcessSegment], hasLiveCalls: Bool) -> [Part] {
        var out: [Part] = []
        for segment in segments {
            switch segment.kind {
            case .thinking:
                continue
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
    ///   - hasThought: the message has reasoning (a running turn always shows the line: it says what is happening).
    ///   - parts: the work before the answer, from `parts(segments:hasLiveCalls:)`.
    static func items(hasThought: Bool, parts: [Part], isStreaming: Bool, hasAnswer: Bool) -> [Item] {
        var out: [Item] = []
        if isStreaming || hasThought { out.append(.thought) }
        var feeds = 0
        for part in parts {
            switch part {
            case .calls:
                out.append(.feed(feeds))
                feeds += 1
            case .note(let segment, _):
                out.append(.note(segment))
            }
        }
        if hasAnswer { out.append(.text) }
        return out
    }

    /// One feed of all the calls (`hasActivity`), as before notes split it.
    static func items(hasThought: Bool, hasActivity: Bool, isStreaming: Bool, hasAnswer: Bool) -> [Item] {
        items(hasThought: hasThought, parts: hasActivity ? [.calls([])] : [], isStreaming: isStreaming, hasAnswer: hasAnswer)
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
