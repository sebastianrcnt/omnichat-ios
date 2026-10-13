import Foundation

/// How one assistant message is laid out, live and finished, from the same inputs.
///
/// One thought line (the sentence being thought while working, "Thought for Ns" once the answer starts), then the
/// activity feed (a card per search, pages read attached to their rows), then the answer. The live text keeps the same
/// identity when the answer is final, so it never jumps.
enum MessageLayout {
    enum Item: Equatable, Identifiable {
        case thought
        case feed
        /// The text being written, then (same identity, so it stays in place) the finished answer.
        case text

        var id: String {
            switch self {
            case .thought: "thought"
            case .feed: "feed"
            case .text: "text"
            }
        }
    }

    /// The answer is being written: no call is running and this round has text. (Text written before a tool call is a
    /// preamble; it moves into the timeline when the call is requested.)
    static func answerStarted(isStreaming: Bool, pendingCount: Int, hasRoundText: Bool) -> Bool {
        isStreaming && pendingCount == 0 && hasRoundText
    }

    /// - Parameters:
    ///   - hasThought: the message has reasoning (a running turn always shows the line: it says what is happening).
    ///   - hasActivity: any tool call, finished or running.
    static func items(hasThought: Bool, hasActivity: Bool, isStreaming: Bool, hasAnswer: Bool) -> [Item] {
        var out: [Item] = []
        if isStreaming || hasThought { out.append(.thought) }
        if hasActivity { out.append(.feed) }
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
        pages = calls.filter { $0.name == ToolNames.webFetch && $0.fetchOffset == 0 }.count
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
