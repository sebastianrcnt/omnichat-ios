import Foundation

/// How much of the work before the answer a message shows. While the reply works, the newest few rows, with the older
/// ones behind "8 earlier steps"; once the answer is being written, and in a finished message, all of it behind one
/// summary line ("Thought for 31s · 6 searches · 3 pages"). A tap opens either in place. Results (a map, a long note to
/// the person) and calls waiting for the person never fold. Pure, built on every render; the Timeline shows everything.
nonisolated enum ProcessFold {
    enum Kind: Equatable, Sendable {
        /// A "✦" line: one round's thinking.
        case thought
        /// A short note the model wrote to the person between rounds ("Let me look more closely").
        case note
        /// A tool line: one card, or a run of browser calls.
        case step
        /// Something to look at rather than process: a map, a long note. Always shown.
        case result
        /// A call waiting for the person (an approval). Always shown.
        case attention

        var isProcess: Bool { self == .thought || self == .note || self == .step }
        var isNarration: Bool { self == .thought || self == .note }
    }

    /// One line of the work: a message item, or one item of a feed.
    struct Row: Identifiable, Equatable, Sendable {
        var id: String
        var item: MessageLayout.Item
        /// The feed item's id (`BrowserRun.Item.id`) for a row inside a feed.
        var feedItem: String?
        var kind: Kind
    }

    enum Mode: Equatable, Sendable {
        /// Everything shows.
        case open
        /// Working: the older rows behind "N earlier steps".
        case earlier
        /// The answer is there: the work behind one summary line.
        case summary
    }

    struct Plan: Equatable, Sendable {
        var mode: Mode
        /// The rows hidden while folded, in order.
        var hidden: [String] = []
        /// Of those, tool lines (and results), and thoughts or notes.
        var hiddenSteps = 0
        var hiddenNarration = 0

        static let open = Plan(mode: .open)
    }

    /// Rows shown while working, counting the newest thought or note.
    static let liveRows = 3
    /// Fewer process rows than this and a finished message shows them as they are.
    static let summaryThreshold = 3
    /// Hiding fewer rows than this saves nothing: the "earlier" line would take their place.
    static let minimumHidden = 2
    /// A note longer than this (or of several paragraphs) is something the person reads, not narration.
    static let noteLimit = 280

    static func isNarrationNote(_ text: String) -> Bool {
        text.count <= noteLimit && !text.contains("\n\n")
    }

    /// A feed item that is a result in itself: the map of `show_places`.
    static func isResult(_ item: BrowserRun.Item) -> Bool {
        if case .card(let card) = item, case .places = card.kind { return true }
        return false
    }

    /// The message's rows in order. `attention` holds the feed items (by id) waiting for the person.
    static func rows(items: [MessageLayout.Item], feedItems: [Int: [BrowserRun.Item]], notes: [Int: String],
                     attention: Set<String> = []) -> [Row] {
        var out: [Row] = []
        for item in items {
            switch item {
            case .thought, .reasoning:
                out.append(Row(id: item.id, item: item, kind: .thought))
            case .note(let segment):
                let short = notes[segment].map(isNarrationNote) ?? true
                out.append(Row(id: item.id, item: item, kind: short ? .note : .result))
            case .feed(let n):
                for feedItem in feedItems[n] ?? [] {
                    let kind: Kind = attention.contains(feedItem.id) ? .attention : isResult(feedItem) ? .result : .step
                    out.append(Row(id: item.id + "/" + feedItem.id, item: item, feedItem: feedItem.id, kind: kind))
                }
            case .working, .text, .fold:
                break
            }
        }
        return out
    }

    /// The fold treats the reply as still working until its answer is clearly more than a note: a model that narrates
    /// writes "Let me check this." before each call, and that text looks like the answer's start until the call comes.
    /// Folding everything for it, then unfolding a moment later, made the work jump at every round.
    static func isWorking(isStreaming: Bool, answerStarted: Bool, answerText: String) -> Bool {
        guard isStreaming else { return false }
        return !answerStarted || isNarrationNote(answerText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// - Parameters:
    ///   - working: the reply runs and its answer hasn't started.
    ///   - hasAnswer: the answer (or its start) is on screen. A finished message without one (an error, a stop) shows
    ///     its work as it is: there is nothing else to read.
    static func plan(rows: [Row], working: Bool, hasAnswer: Bool) -> Plan {
        if working { return live(rows) }
        guard hasAnswer else { return .open }
        let process = rows.filter(\.kind.isProcess)
        guard process.count >= summaryThreshold else { return .open }
        return plan(.summary, hiding: process)
    }

    /// The newest `liveRows` of the tool lines and the newest thought or note; older thoughts and notes fold with the
    /// older lines.
    private static func live(_ rows: [Row]) -> Plan {
        let lastNarration = rows.lastIndex { $0.kind.isNarration }
        let candidates = rows.indices.filter { rows[$0].kind == .step || $0 == lastNarration }
        let kept = Set(candidates.suffix(liveRows))
        let hidden = rows.indices.filter { rows[$0].kind.isProcess && !kept.contains($0) }.map { rows[$0] }
        guard hidden.count >= minimumHidden else { return .open }
        return plan(.earlier, hiding: hidden)
    }

    private static func plan(_ mode: Mode, hiding rows: [Row]) -> Plan {
        let narration = rows.filter(\.kind.isNarration).count
        return Plan(mode: mode, hidden: rows.map(\.id), hiddenSteps: rows.count - narration, hiddenNarration: narration)
    }

    /// The message's items as shown: the fold line first, then every item with a row left to show (an item without
    /// rows, like the answer or the live line, always shows).
    static func displayed(items: [MessageLayout.Item], rows: [Row], plan: Plan, expanded: Bool) -> [MessageLayout.Item] {
        guard plan.mode != .open else { return items }
        let hidden = expanded ? [] : Set(plan.hidden)
        var out: [MessageLayout.Item] = [.fold]
        for item in items {
            let own = rows.filter { $0.item == item }
            if own.isEmpty || own.contains(where: { !hidden.contains($0.id) }) { out.append(item) }
        }
        return out
    }

    /// The items of feed `n` (`BrowserRun.Item.id`) hidden while folded.
    static func hiddenFeedItems(feed n: Int, rows: [Row], plan: Plan, expanded: Bool) -> Set<String> {
        guard plan.mode != .open, !expanded else { return [] }
        let hidden = Set(plan.hidden)
        return Set(rows.filter { $0.item == .feed(n) && hidden.contains($0.id) }.compactMap(\.feedItem))
    }

    /// "8 earlier steps"; "2 earlier thoughts" when only thoughts and notes are folded.
    static func earlierTitle(_ plan: Plan) -> String {
        let steps = plan.hiddenSteps
        if steps > 0 { return steps == 1 ? String(localized: "1 earlier step") : String(localized: "\(steps) earlier steps") }
        let n = plan.hiddenNarration
        return n == 1 ? String(localized: "1 earlier thought") : String(localized: "\(n) earlier thoughts")
    }

    /// The thinking time of the whole reply: its rounds' times added up, else the message's own.
    static func thinkingSeconds(segments: [ProcessSegment], whole: Double?) -> Double? {
        let rounds = segments.filter { $0.kind == .thinking }.compactMap(\.seconds)
        return rounds.isEmpty ? whole : rounds.reduce(0, +)
    }

    /// The summary line's totals, counted from the feed's cards.
    struct Summary: Equatable, Sendable {
        var seconds: Double?
        var searches = 0
        var pages = 0
        var videos = 0
        var pythonRuns = 0
        var browserSteps = 0
        var otherSteps = 0

        init(cards: [FeedCard], thinkingSeconds: Double?) {
            seconds = thinkingSeconds
            for card in cards {
                switch card.kind {
                case .search: searches += 1
                case .pages: pages += card.extras.count
                case .transcripts: videos += card.extras.count
                case .python: pythonRuns += 1
                case .browser, .script, .browserAction: browserSteps += 1
                case .image, .note, .places, .artifact, .ssh, .health: otherSteps += 1
                }
            }
        }

        /// "Thought for 31s · 6 searches · 3 pages · 2 Python runs"; counts of zero are left out.
        var title: String {
            var parts: [String] = []
            if let seconds { parts.append(String(localized: "Thought for \(ProcessSummary.duration(seconds))")) }
            if searches > 0 { parts.append(searches == 1 ? String(localized: "1 search") : String(localized: "\(searches) searches")) }
            if pages > 0 { parts.append(pages == 1 ? String(localized: "1 page") : String(localized: "\(pages) pages")) }
            if videos > 0 { parts.append(videos == 1 ? String(localized: "1 video") : String(localized: "\(videos) videos")) }
            if pythonRuns > 0 {
                parts.append(pythonRuns == 1 ? String(localized: "1 Python run") : String(localized: "\(pythonRuns) Python runs"))
            }
            if browserSteps > 0 {
                parts.append(browserSteps == 1 ? String(localized: "1 browser step") : String(localized: "\(browserSteps) browser steps"))
            }
            if otherSteps > 0 {
                let alone = parts.isEmpty
                parts.append(otherSteps == 1
                             ? (alone ? String(localized: "1 step") : String(localized: "1 other step"))
                             : (alone ? String(localized: "\(otherSteps) steps") : String(localized: "\(otherSteps) other steps")))
            }
            return parts.isEmpty ? String(localized: "Worked on it") : parts.joined(separator: " · ")
        }
    }
}
