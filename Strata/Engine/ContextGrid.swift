import Foundation

/// What fills the context window, in the order the Context sheet's grid groups it.
enum ContextCategory: Int, CaseIterable, Sendable {
    case system, tools, messages, web, reasoning, images

    var title: String {
        switch self {
        case .system: String(localized: "System prompt")
        case .tools: String(localized: "Tool definitions")
        case .messages: String(localized: "Messages")
        case .web: String(localized: "Web results & pages")
        case .reasoning: String(localized: "Reasoning kept")
        case .images: String(localized: "Images")
        }
    }
}

/// The Context sheet's numbers: the zoom range, the cells and the summarize point. Pure, display only.
enum ContextGrid {
    static let columns = 20
    static let rows = 10
    static let cells = columns * rows

    /// Zoom ranges, powers of two.
    static let zoomSteps = [32_768, 65_536, 131_072, 262_144, 524_288, 1_048_576, 2_097_152]

    /// The tokens the grid spans: below a quarter of the window, the smallest zoom step that holds about twice what is
    /// used (and fits the window); otherwise the whole window.
    static func range(used: Int, window: Int) -> Int {
        guard window > 0 else { return 0 }
        if Double(used) >= Double(window) * 0.25 { return window }
        return zoomSteps.first { $0 >= used * 2 && $0 <= window } ?? window
    }

    /// The category of each filled cell, in category order: whole cells per category, at least one for each present
    /// category, the rest by largest remainder, so the count is exactly `used` in cells (but never less than the
    /// number of present categories, nor more than the grid).
    static func allocate(_ tokens: [Int], range: Int) -> [Int] {
        guard range > 0 else { return [] }
        let per = Double(range) / Double(cells)
        let exact = tokens.map { Double(max($0, 0)) / per }
        let present = tokens.indices.filter { tokens[$0] > 0 }
        let used = tokens.reduce(0) { $0 + max($1, 0) }
        let target = min(cells, max(present.count, Int((Double(used) / per).rounded())))
        var n = exact.map { $0 > 0 ? max(1, Int($0.rounded(.down))) : 0 }
        let remainders = present.map { ($0, exact[$0] - exact[$0].rounded(.down)) }
        var sum = n.reduce(0, +)
        // Largest remainder first; ties go to the earlier category.
        let byLargest = remainders.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.0)
        var j = 0
        while sum < target, !byLargest.isEmpty {
            n[byLargest[j % byLargest.count]] += 1
            sum += 1
            j += 1
        }
        // The minimum of one cell can overshoot: take back from the smallest remainders, never below one cell.
        var k = 0
        let bySmallest = byLargest.reversed().map { $0 }
        while sum > target, bySmallest.contains(where: { n[$0] > 1 }) {
            let i = bySmallest[k % bySmallest.count]
            if n[i] > 1 { n[i] -= 1; sum -= 1 }
            k += 1
        }
        var owner: [Int] = []
        for (i, m) in n.enumerated() { owner += Array(repeating: i, count: m) }
        return Array(owner.prefix(cells))
    }

    /// The first cell at or past the summarize point, or nil when that point lies outside the shown range.
    static func summarizeCell(limit: Int, range: Int) -> Int? {
        guard limit > 0, range > 0 else { return nil }
        let i = Int((Double(limit) / (Double(range) / Double(cells))).rounded(.down))
        return i < cells ? i : nil
    }

    /// Tokens per cell.
    static func tokensPerCell(range: Int) -> Int { Int((Double(range) / Double(cells)).rounded()) }

    /// A window or zoom range: powers of two read as "256k" and "1M"; anything else as a rounded count.
    static func sizeLabel(_ n: Int) -> String {
        if n > 0, n % 1_048_576 == 0 { return "\(n / 1_048_576)M" }
        if n > 0, n % 1024 == 0 { return "\(n / 1024)k" }
        return TokenFormat.short(n)
    }
}

/// Splits a request's real size into categories: each category's characters are estimated the way compaction
/// estimates them, then scaled so the categories add up to the reported total.
enum ContextEstimator {
    /// Estimated characters of each category, indexed by `ContextCategory.rawValue`.
    ///
    /// - System prompt: system messages.
    /// - Tool definitions: the encoded tool JSON, when tools are sent.
    /// - Messages: user text and assistant text (handoff notes from a compaction included).
    /// - Web results & pages: tool results and the calls that asked for them.
    /// - Reasoning kept: always 0. The request builder (`MessageAssembler`) never sends reasoning back in history.
    /// - Images: `Compaction.imageChars` per attached image (765 tokens, `ContextEstimate.tokensPerImage`).
    static func chars(messages: [APIMessage], toolsJSON: String?) -> [Int] {
        var c = Array(repeating: 0, count: ContextCategory.allCases.count)
        func add(_ cat: ContextCategory, _ n: Int) { c[cat.rawValue] += n }
        if let toolsJSON { add(.tools, Compaction.estimateChars(toolsJSON)) }
        for m in messages {
            let category: ContextCategory
            switch m.role {
            case "system": category = .system
            case "tool": category = .web
            default: category = .messages
            }
            switch m.content {
            case .text(let s): add(category, Compaction.estimateChars(s))
            case .parts(let parts):
                for p in parts {
                    switch p {
                    case .text(let s): add(category, Compaction.estimateChars(s))
                    case .imageURL: add(.images, Compaction.imageChars)
                    }
                }
            }
            for call in m.toolCalls { add(.web, call.name.utf8.count + Compaction.estimateChars(call.arguments)) }
        }
        return c
    }

    /// The encoded tool definitions as sent, or nil when tools are off.
    static func toolsJSON(_ tools: [ToolDefinition]?) -> String? {
        guard let tools, !tools.isEmpty, let data = try? ChatRequest.encoder.encode(tools) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `chars` scaled to `total` tokens, by largest remainder so the parts add up exactly. With no estimate at all,
    /// everything counts as messages.
    static func scale(_ chars: [Int], to total: Int) -> [Int] {
        var out = Array(repeating: 0, count: chars.count)
        guard total > 0 else { return out }
        let sum = chars.reduce(0) { $0 + max($1, 0) }
        guard sum > 0 else {
            if out.indices.contains(ContextCategory.messages.rawValue) { out[ContextCategory.messages.rawValue] = total }
            return out
        }
        let exact = chars.map { Double(max($0, 0)) * Double(total) / Double(sum) }
        out = exact.map { Int($0.rounded(.down)) }
        var left = total - out.reduce(0, +)
        for i in exact.indices.sorted(by: { (exact[$0] - exact[$0].rounded(.down)) > (exact[$1] - exact[$1].rounded(.down)) }) {
            guard left > 0 else { break }
            if chars[i] > 0 { out[i] += 1; left -= 1 }
        }
        return out
    }

    static func split(messages: [APIMessage], tools: [ToolDefinition]?, total: Int) -> [Int] {
        scale(chars(messages: messages, toolsJSON: toolsJSON(tools)), to: total)
    }
}
