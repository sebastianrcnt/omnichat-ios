import Foundation

/// One step of the work that happened before the final answer, in stream order.
/// The final answer itself is `Message.text`, not a segment.
struct ProcessSegment: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case thinking, text, toolRound }

    var index: Int
    var kind: Kind
    /// Raw reasoning (`thinking`) or the preamble the model wrote between tool rounds (`text`).
    var text: String = ""
    /// Time spent thinking in this segment, when known.
    var seconds: Double?
    /// The tool calls of one round (`toolRound`).
    var calls: [ToolCallRecord] = []

    var id: Int { index }

    /// "Searched 5 sites", "Read 2 pages", or both joined with a dot.
    static func toolTitle(calls: [ToolCallRecord]) -> String {
        let searches = calls.filter { $0.name == ToolNames.webSearch }
        var sites = Set<Int>()
        for call in searches { sites.formUnion(call.sourceIDs) }
        let pages = calls.filter { ToolNames.readsPage($0.name) && $0.fetchOffset == 0 }.count
        let continued = calls.contains { $0.name == ToolNames.webFetch && $0.fetchOffset > 0 }
        var parts: [String] = []
        if !searches.isEmpty {
            parts.append(sites.isEmpty ? String(localized: "Searched the web")
                         : sites.count == 1 ? String(localized: "Searched 1 site")
                         : String(localized: "Searched \(sites.count) sites"))
        }
        if pages > 0 {
            parts.append(pages == 1 ? String(localized: "Read 1 page") : String(localized: "Read \(pages) pages"))
        } else if continued {
            parts.append(String(localized: "Read more"))
        }
        if calls.contains(where: { $0.name == ToolNames.runPython }) { parts.append(String(localized: "Ran Python")) }
        if calls.contains(where: { $0.name == ToolNames.viewImage }) { parts.append(String(localized: "Viewed an image")) }
        return parts.isEmpty ? String(localized: "Used tools") : parts.joined(separator: " · ")
    }
}

enum ProcessSegments {
    /// Reasoning paragraphs as the timeline counts them (split on blank lines, empty ones dropped).
    static func paragraphs(_ reasoning: String) -> [String] {
        reasoning.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Rebuild the ordered segments of a message saved before segments were persisted.
    /// Each step carries the number of reasoning paragraphs before it, which places its thinking.
    static func derive(steps: [ToolStep], reasoning: String, thinkingSeconds: Double? = nil) -> [ProcessSegment] {
        let chunks = paragraphs(reasoning)
        var out: [ProcessSegment] = []
        var used = 0
        func add(_ kind: ProcessSegment.Kind, text: String = "", seconds: Double? = nil, calls: [ToolCallRecord] = []) {
            out.append(ProcessSegment(index: out.count, kind: kind, text: text, seconds: seconds, calls: calls))
        }
        func thinking(upTo limit: Int) {
            let end = min(max(limit, used), chunks.count)
            guard end > used else { return }
            add(.thinking, text: chunks[used..<end].joined(separator: "\n\n"))
            used = end
        }
        for step in steps {
            thinking(upTo: step.reasoningParagraphs)
            let preamble = step.assistantContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preamble.isEmpty { add(.text, text: preamble) }
            if !step.calls.isEmpty { add(.toolRound, calls: step.calls.map(\.displayOnly)) }
        }
        thinking(upTo: chunks.count)
        // Only one thinking segment: its time is the whole message's thinking time.
        let thinkingIndices = out.indices.filter { out[$0].kind == .thinking }
        if thinkingIndices.count == 1, let thinkingSeconds { out[thinkingIndices[0]].seconds = thinkingSeconds }
        return out
    }
}
