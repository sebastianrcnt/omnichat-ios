import Foundation

/// A block quote's source line: citation markers at the end of the quote (`> … [1]`, `[1][2]`), or a paragraph right
/// after it made of markers only, are taken out of the text and shown under the quote instead. Nothing is matched
/// against page contents; a quote without such markers gets no source line.
enum QuoteCitations {
    /// What happens to a block.
    enum Plan: Equatable, Sendable {
        /// A quote with a source line: `text` is its source without the trailing markers (nil when they came from the
        /// paragraph after it, so the quote's own text is unchanged).
        case quote(ids: [Int], text: String?)
        /// A markers-only paragraph shown as its quote's source line instead.
        case absorbed
    }

    /// Plans for a run of closed blocks. Callers pass closed blocks only, so a paragraph still being written is never
    /// absorbed early (its quote gets the source line once it closes).
    static func plan(_ blocks: [MarkdownBlock]) -> [Int: Plan] {
        var out: [Int: Plan] = [:]
        for (i, block) in blocks.enumerated() where block.kind == .blockquote && block.isClosed {
            if let trailing = trailingMarkers(in: block.text) {
                out[block.id] = .quote(ids: trailing.ids, text: trailing.text)
            } else if i + 1 < blocks.count, blocks[i + 1].kind == .paragraph, let ids = markersOnly(blocks[i + 1].text) {
                out[block.id] = .quote(ids: ids, text: nil)
                out[blocks[i + 1].id] = .absorbed
            }
        }
        return out
    }

    /// Citation markers ending `text` (spaces between them allowed; a final `.` or `。` after them is kept), outside
    /// code spans. Returns the text without them, or nil when it does not end in a marker.
    static func trailingMarkers(in text: String) -> (text: String, ids: [Int])? {
        var chars = Array(text)
        while let last = chars.last, last.isWhitespace { chars.removeLast() }
        var punctuation: [Character] = []
        if let last = chars.last, last == "." || last == "。" {
            // Only "… [1]." counts; a sentence that just ends in a period has no marker before it.
            punctuation = [last]
            chars.removeLast()
        }
        var ids: [Int] = []
        var end = chars.count
        while end > 0, chars[end - 1] == "]" {
            var j = end - 2
            while j >= 0, chars[j].isASCII, chars[j].isNumber { j -= 1 }
            guard j >= 0, j < end - 2, chars[j] == "[", let id = Int(String(chars[(j + 1)..<(end - 1)])) else { break }
            if j > 0, chars[j - 1] == "\\" { break } // escaped bracket
            ids.insert(id, at: 0)
            end = j
            while end > 0, chars[end - 1] == " " || chars[end - 1] == "\t" { end -= 1 }
        }
        guard !ids.isEmpty else { return nil }
        let before = Array(chars[0..<end])
        // Inside an open code span the brackets are literal code.
        guard before.filter({ $0 == "`" }).count % 2 == 0 else { return nil }
        var rest = String(before)
        while let last = rest.last, last == " " || last == "\t" { rest.removeLast() }
        // A quote made of markers only keeps them (nothing would be left to quote).
        let bare = rest.drop { $0 == ">" || $0.isWhitespace }
        guard !bare.isEmpty else { return nil }
        rest.append(contentsOf: punctuation)
        return (rest, ids)
    }

    /// The ids of a paragraph made of citation markers only (`[1]`, `[1][2]`, `[1] [2]`), else nil.
    static func markersOnly(_ paragraph: String) -> [Int]? {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), let result = trailingMarkersAllowingEmpty(trimmed), result.rest.isEmpty else { return nil }
        return result.ids
    }

    private static func trailingMarkersAllowingEmpty(_ text: String) -> (rest: String, ids: [Int])? {
        // Reuse the scan with a placeholder in front, so an all-marker text is not rejected as empty.
        guard let found = trailingMarkers(in: "x " + text) else { return nil }
        return (String(found.text.dropFirst(1)).trimmingCharacters(in: .whitespaces), found.ids)
    }
}
