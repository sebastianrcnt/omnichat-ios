import Foundation

/// Context compaction, after atto (agent/compact.go): when the conversation nears the model's window, the model writes
/// handoff notes, and the history becomes the recent user messages plus those notes. This file is the pure part: the
/// trigger, the request, the trimming and the replacement. `Compactor` runs it against a model.
enum Compaction {
    /// Handoff notes stay under this many words.
    static let noteWords = 700
    /// Recent user text that survives compaction, in tokens (chars / 4).
    static let keepUserTokens = 20_000
    /// The least room a compaction request keeps for its answer: the notes and the thinking before them.
    static let room = 8192
    /// Token estimates are rough, and servers add a few of their own.
    static let margin = 256
    static let imagePlaceholder = "[image omitted by compaction]"
    static let truncationNote = "\n[truncated]"
    /// An image counts as this many characters when estimating (765 tokens).
    static let imageChars = ContextEstimate.tokensPerImage * 4

    /// The user message appended to the existing request.
    static var instruction: String {
        """
        Context checkpoint: the conversation is about to be compacted. Write handoff notes so that you can continue this work with no other context.

        If earlier handoff notes appear above, fold them into one updated set: keep what is still relevant, drop what is stale.

        Include:
        - The user's goal and any constraints or preferences they stated
        - Progress so far and what was learned: key findings, decisions and why, pages read and what they said
        - Current state: what has been answered, what is still open or uncertain
        - Remaining steps
        - Sources: the id [N], title and URL of each web source the answer relies on or may cite again, so later answers can keep citing them

        The full transcript stays visible to the user, so long quotations and finished exploration need not be copied; but everything needed to continue must be in the notes. Be specific: names, numbers, URLs, exact wording where it matters. Stay under \(noteWords) words. Output only the notes, no preamble. Do not call tools.
        """
    }

    /// Introduces the notes in the compacted history.
    static let summaryPrefix = "[Strata handoff notes] The conversation was compacted. Earlier messages were replaced by these notes, written by you from the full history. Build on them and avoid redoing finished work; source ids [N] named in the notes can still be cited. If you need a detail the notes leave out, say so or look it up again with the tools.\n\n"

    // MARK: Estimating

    /// Four bytes per token for prose. Text with little whitespace and many digits or punctuation, or long unbroken runs
    /// (base64, minified code), gets the more conservative three.
    static func estimateChars(_ s: String) -> Int {
        var spaces = 0, dense = 0, run = 0, longest = 0
        var count = 0
        for c in s.utf8 {
            count += 1
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 {
                spaces += 1
                run = 0
            } else {
                run += 1
                if run > longest { longest = run }
                if (c >= 0x30 && c <= 0x39) || Self.denseBytes.contains(c) { dense += 1 }
            }
        }
        if count >= 64, longest >= 64 || (spaces * 8 < count && dense * 8 >= count) { return (count * 4 + 2) / 3 }
        return count
    }

    private static let denseBytes: Set<UInt8> = Set(#"{}[]:,_=+/\""#.utf8)

    static func messageChars(_ m: APIMessage) -> Int {
        var n = 0
        switch m.content {
        case .text(let s): n += estimateChars(s)
        case .parts(let parts):
            for p in parts {
                switch p {
                case .text(let s): n += estimateChars(s)
                case .imageURL: n += imageChars
                }
            }
        }
        for c in m.toolCalls { n += c.name.utf8.count + estimateChars(c.arguments) }
        return n
    }

    static func chars(_ messages: some Sequence<APIMessage>) -> Int { messages.reduce(0) { $0 + messageChars($1) } }

    static func text(of m: APIMessage) -> String {
        switch m.content {
        case .text(let s): return s
        case .parts(let parts):
            return parts.compactMap { if case .text(let s) = $0 { s } else { nil } }.joined(separator: "\n")
        }
    }

    // MARK: Trigger

    /// Tokens kept free under the window for the reply: 10% of it, at least `reserveFloor` once the window is twice that.
    static let reserveFloor = 16_000

    /// The size at which a conversation is compacted: the window minus the room kept for the reply, which is 10% of the
    /// window or `reserveFloor`, whichever is more, and never more than the model's output limit. A full-size answer is
    /// not reserved: a 1M window with a 384k output limit would compact at 616k when 900k still leaves 100k for the
    /// answer (OpenCode's `calculateCeiling` keeps the same room).
    static func limit(window: Int, maxOutput: Int?) -> Int {
        guard window > 0 else { return 0 }
        let window = min(window, ContextLimits.maxTokens)
        var reserve = max(window / 10, window >= 2 * reserveFloor ? reserveFloor : 0)
        if let maxOutput, maxOutput > 0 { reserve = min(reserve, maxOutput) }
        return max(window - reserve, 0)
    }

    /// True when `meter` (plus `extraChars` about to be appended) has reached `limit`.
    static func needsCompaction(_ meter: ContextMeter, limit: Int, extraChars: Int = 0, hasMessages: Bool = true) -> Bool {
        limit > 0 && hasMessages && meter.tokens + min(extraChars, ContextMeter.maxTokens) / 4 >= limit
    }

    // MARK: Request

    /// The compaction request: the existing request unchanged, one instruction appended, no tool calls allowed. The
    /// messages are an extension of the previous request's, so the prefix is byte-for-byte the same.
    static func request(from base: ChatRequest) -> ChatRequest {
        var r = base
        r.messages.append(.user(instruction))
        r.toolChoice = "none"
        return r
    }

    /// Whether `error` says the request did not fit the model's window.
    static func isContextOverflow(_ error: Error) -> Bool {
        let text: String
        switch error as? APIError {
        case .http(let status, let message)?: text = status == 400 || status == 413 || status == 422 ? message : ""
        case .server(let message)?: text = message
        default: return false
        }
        let t = text.lowercased()
        return ["context length", "context_length", "context window", "maximum context", "too many tokens", "token limit",
                "reduce the length", "prompt is too long", "input is too long", "exceeds the model"].contains { t.contains($0) }
    }

    /// How notes were cut off, or nil when they are whole: the answer ended at its token limit or in a tool call, or its
    /// last line is a heading with nothing under it.
    static func cutReason(finishReason: String?, content: String) -> String? {
        switch finishReason {
        case "length": return "the answer reached its token limit"
        case "tool_calls": return "the model made a tool call"
        default: break
        }
        let notes = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = notes.split(separator: "\n", omittingEmptySubsequences: false).last,
           last.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil {
            return "it ends with a heading"
        }
        return nil
    }

    // MARK: Fitting

    struct Fit: Equatable {
        /// Messages dropped from the oldest turns of the request.
        var dropped = 0
        /// The latest turn's trailing tool-call and results group, kept out of the summary request (and after the notes).
        var kept: [APIMessage] = []
        /// Estimated tokens of the request that remains.
        var estimate = 0
    }

    /// Makes `request` (whose prompt is about `estimate` tokens, the instruction included as its last message) fit
    /// `window` with `need` tokens left to answer. It drops the oldest turns, whole, so a tool call keeps its result,
    /// never the system message or the instruction; if the last turn alone is too large it cuts at its latest
    /// assistant tool call and returns that group to keep after the notes instead of summarizing it. It lowers
    /// `maxTokens` to the room left only when that is less than `need`, so a request that fits is left as it was.
    static func fit(_ request: inout ChatRequest, window: Int, estimate: Int, need: Int) -> Fit {
        guard window > 0 else { return Fit(estimate: estimate) }
        var est = estimate
        var msgs = request.messages // [system?, conversation..., instruction]
        let s = msgs.first?.role == "system" ? 1 : 0
        var fit = Fit()
        func tokens(_ slice: ArraySlice<APIMessage>) -> Int { slice.reduce(0) { $0 + messageChars($1) / 4 } }
        func fits(_ tokens: Int, _ output: Int) -> Bool { window - tokens - margin >= output }
        func dropOldest() -> Bool {
            var end = s + 1
            while end < msgs.count - 1 && msgs[end].role != "user" { end += 1 }
            if end >= msgs.count - 1 { return false } // one turn left: keep it
            est -= tokens(msgs[s..<end])
            fit.dropped += end - s
            msgs.removeSubrange(s..<end)
            return true
        }
        if !fits(est, need) {
            var last = s
            var i = s + 1
            while i < msgs.count - 1 { if msgs[i].role == "user" { last = i }; i += 1 }
            let lastEst = est - tokens(msgs[s..<last])
            if !fits(lastEst, need) {
                // Dropping older turns cannot help. Summarize their history and the current turn's prefix, keeping the
                // latest call with all its results. Never cut at a tool result itself.
                var j = msgs.count - 2
                while j > last {
                    if msgs[j].role == "assistant", !msgs[j].toolCalls.isEmpty {
                        let tail = Array(msgs[j..<(msgs.count - 1)])
                        let t = tokens(tail[...])
                        // The cut must leave room for at least the minimum answer.
                        if fits(lastEst - t, 1024) {
                            fit.kept = tail
                            est -= t
                            let instruction = msgs[msgs.count - 1]
                            msgs.removeSubrange(j...)
                            msgs.append(instruction)
                            break
                        }
                    }
                    j -= 1
                }
            }
        }
        while !fits(est, need), msgs.count > s + 2 {
            if !dropOldest() { break }
        }
        request.messages = msgs
        let roomLeft = window - est - margin
        if roomLeft < need { request.maxTokens = max(roomLeft, 1024) }
        fit.estimate = est
        return fit
    }

    // MARK: Replacement

    /// The history after compaction: the most recent user messages (newest first within `keepUserTokens`, in
    /// chronological order, text only, earlier notes dropped since the new ones fold them in), then the notes, then
    /// whatever the latest turn kept.
    static func replacement(history: [APIMessage], notes: String, retained: [APIMessage]) -> [APIMessage] {
        var kept: [APIMessage] = []
        var budget = keepUserTokens * 4
        for m in history.reversed() {
            guard budget > 0 else { break }
            guard m.role == "user" else { continue }
            var text = Self.text(of: m)
            if text.hasPrefix(summaryPrefix) { continue }
            if case .parts(let parts) = m.content {
                // Kept messages carry text only; each image becomes a note.
                let images = parts.filter { if case .imageURL = $0 { true } else { false } }.count
                if images > 0 {
                    if !text.isEmpty { text += "\n" }
                    text += Array(repeating: imagePlaceholder, count: images).joined(separator: "\n")
                }
            }
            if text.count > budget { text = String(text.suffix(budget)) + truncationNote }
            budget -= text.count
            kept.insert(.user(text), at: 0)
        }
        return kept + [.user(summaryPrefix + notes)] + retained
    }

    /// Notes as stored in a replacement's summary message.
    static func notes(in replacement: [APIMessage]) -> String? {
        for m in replacement.reversed() where m.role == "user" {
            let t = text(of: m)
            if t.hasPrefix(summaryPrefix) { return String(t.dropFirst(summaryPrefix.count)) }
        }
        return nil
    }
}

/// How big the context is: the last reported usage (prompt + completion) plus characters / 4 for what was appended since.
struct ContextMeter: Equatable, Sendable {
    private(set) var usageTokens = 0
    private(set) var sinceChars = 0

    init(usageTokens: Int = 0, sinceChars: Int = 0) {
        self.usageTokens = min(max(usageTokens, 0), Self.maxTokens)
        self.sinceChars = sinceChars
    }

    init(usage: Usage?, sinceChars: Int = 0) { self.init(usageTokens: usage?.totalTokens ?? 0, sinceChars: sinceChars) }

    /// No usage known: everything is an estimate.
    static func estimate(_ messages: some Sequence<APIMessage>) -> ContextMeter {
        ContextMeter(sinceChars: Compaction.chars(messages))
    }

    /// The most a server's usage counts for: far past any context window, and small enough that the sums here can't
    /// overflow when a server reports nonsense like Int.max.
    static let maxTokens = 1 << 40

    var tokens: Int { min(usageTokens, Self.maxTokens) + min(sinceChars, Self.maxTokens) / 4 }

    mutating func record(_ usage: Usage) {
        guard usage.promptTokens > 0 || usage.completionTokens > 0 else { return }
        usageTokens = min(usage.totalTokens, Self.maxTokens)
        sinceChars = 0
    }

    mutating func append(_ message: APIMessage) { sinceChars += Compaction.messageChars(message) }
    mutating func append(chars: Int) { sinceChars += chars }
}

/// Bounds for token counts that come from servers, catalogs and Settings: none of them may crash arithmetic.
enum ContextLimits {
    /// Far above any real context window (100M tokens), small enough that sums and percentages never overflow.
    static let maxTokens = 100_000_000

    /// Adds counters a server reported, saturating instead of trapping on overflow; negatives count as 0.
    static func add(_ values: Int...) -> Int {
        var total = 0
        for v in values {
            let (sum, overflow) = total.addingReportingOverflow(max(0, v))
            total = overflow ? Int.max : sum
        }
        return total
    }
}
