import Foundation

/// `![caption](figure-N)` in an answer: a figure `run_python` saved, placed where the model wants it. A paragraph made
/// only of such lines renders as the figures; figures the answer doesn't place this way are shown after it.
enum FigureReference {
    struct Ref: Equatable, Hashable {
        var id: String
        var caption: String
    }

    private static var pattern: Regex<(Substring, Substring, Substring)> { /!\[([^\]\n]*)\]\(\s*([Ff]igure-\d+)\s*\)/ }

    /// The figures a paragraph shows, when every non-blank line of it is one reference; nil otherwise.
    static func block(_ text: String) -> [Ref]? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        var refs: [Ref] = []
        for line in lines {
            guard let m = try? pattern.wholeMatch(in: line) else { return nil }
            refs.append(Ref(id: String(m.2).lowercased(), caption: String(m.1).trimmingCharacters(in: .whitespaces)))
        }
        return refs
    }

    /// Ids of the figures the answer places as figure paragraphs (blank-line separated blocks).
    static func placedIDs(in text: String) -> Set<String> {
        guard text.contains("](figure-") || text.contains("]( figure-") else { return [] }
        var ids = Set<String>()
        for paragraph in text.components(separatedBy: "\n\n") {
            for ref in block(paragraph) ?? [] { ids.insert(ref.id) }
        }
        return ids
    }

    /// The turn's figures the answer did not place, in the order they were made.
    static func unplaced(_ figures: [ToolImage], text: String) -> [ToolImage] {
        let placed = placedIDs(in: text)
        return figures.filter { !placed.contains($0.id) }
    }

    /// A stored figure of the conversation, by id (size unknown until it loads).
    static func image(id: String, conversationID: UUID) -> ToolImage {
        ToolImage(id: id, width: 0, height: 0, file: conversationID.uuidString + "/" + id + ".png")
    }
}
