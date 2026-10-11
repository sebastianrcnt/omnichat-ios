import Foundation

/// How one assistant message is laid out, live and finished, from the same inputs.
///
/// Everything that happened before the final answer is folded into ONE summary row ("Thought for 1m 22s · 8 searches ·
/// 4 pages"). While the turn streams, only the live tail (the current thought, the running tool round, or the text being
/// written) shows below it. When the turn ends, the divider and the answer follow the summary.
enum MessageLayout {
    enum Tail: Equatable { case none, thinking, tools, text }

    enum Item: Equatable, Identifiable {
        case summary
        case liveThinking
        case liveTools
        /// The text being written, then (same identity, so it stays in place) the finished answer.
        case text
        case divider

        var id: String {
            switch self {
            case .summary: "summary"
            case .liveThinking: "tail-thinking"
            case .liveTools: "tail-tools"
            case .text: "text"
            case .divider: "divider"
            }
        }
    }

    /// What the live tail shows. Running tool calls win; then text already written this round; otherwise thinking.
    static func tail(isStreaming: Bool, pendingCount: Int, hasRoundText: Bool) -> Tail {
        guard isStreaming else { return .none }
        if pendingCount > 0 { return .tools }
        if hasRoundText { return .text }
        return .thinking
    }

    static func items(segmentCount: Int, tail: Tail, isStreaming: Bool, hasAnswer: Bool) -> [Item] {
        var out: [Item] = []
        if segmentCount > 0 { out.append(.summary) }
        if isStreaming {
            switch tail {
            case .none: break
            case .thinking: out.append(.liveThinking)
            case .tools: out.append(.liveTools)
            case .text: out.append(.text)
            }
        } else if hasAnswer {
            if segmentCount > 0 { out.append(.divider) }
            out.append(.text)
        }
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
