import Foundation

/// `![caption](figure-N)` in an answer: a figure `run_python` saved, placed where the model wants it. A paragraph made
/// only of such lines renders as the figures; figures the answer doesn't place this way are shown after it.
enum FigureReference {
    struct Ref: Equatable, Hashable {
        var id: String
        var caption: String
    }

    private static var pattern: Regex<(Substring, Substring, Substring)> { /!\[([^\]\n]*)\]\(\s*([Ff]igure-\d+(?:-[0-9A-Fa-f]{8})?)\s*\)/ }

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

    /// The turn's figures the answer did not place, in the order they were made. A figure placed by the short form of
    /// its id (`figure-3` for `figure-3-3f9a2c1b`) counts as placed.
    static func unplaced(_ figures: [ToolImage], text: String) -> [ToolImage] {
        let placed = placedIDs(in: text)
        return figures.filter { !placed.contains($0.id) && !placed.contains(shortID($0.id)) }
    }

    /// `figure-3` from `figure-3-3f9a2c1b`; an id without the random part as it is.
    static func shortID(_ id: String) -> String {
        guard let n = ToolImageStore.number(of: id, prefix: ToolImageStore.figurePrefix) else { return id }
        return ToolImageStore.figurePrefix + String(n)
    }

    /// A stored figure of the conversation, by id (size unknown until it loads). A short id whose file isn't there
    /// stands for the conversation's only figure with that number (`ToolImageStore.resolve`).
    static func image(id: String, conversationID: UUID, store: ToolImageStore = .shared) -> ToolImage {
        var stored = id
        if shortID(id) == id, !store.exists(file: conversationID.uuidString + "/" + id + ".png") {
            stored = store.resolve(id: id, conversationID: conversationID) ?? id
        }
        return ToolImage(id: stored, width: 0, height: 0, file: conversationID.uuidString + "/" + stored + ".png")
    }
}
