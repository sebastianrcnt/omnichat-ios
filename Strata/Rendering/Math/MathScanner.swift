import Foundation

/// One formula found in inline text.
struct MathSpan: Hashable, Sendable {
    /// The LaTeX between the delimiters.
    var latex: String
    /// Display style (`$$…$$`, `\[…\]`) or text style (`$…$`, `\(…\)`).
    var display: Bool
    /// Position among the formulas of one string, so two equal formulas next to each other stay two.
    var index = 0
}

/// Marks the characters of an attributed string that are the source of a formula (delimiters included).
/// `InlineMarkdownText.composed` draws the formula in their place once it is typeset.
enum MathAttribute: AttributedStringKey {
    typealias Value = MathSpan
    static let name = "omnichat.math"
}

/// Finds LaTeX in Markdown text: `$…$` and `\(…\)` in text style, `$$…$$` and `\[…\]` in display style.
///
/// Code spans, backslash escapes (`\$`), link destinations and bare URLs are skipped. A single dollar is only math
/// when it looks like it: the opener is followed by a non-space and does not follow a letter or digit, the closer
/// follows a non-space and is not followed by a digit. "$5 and $10", "US$" and "$5-$10" stay text.
enum MathScanner {
    struct Found: Equatable {
        /// UTF-8 offsets of the whole span, delimiters included.
        var range: Range<Int>
        /// Nil for a span still open at the end of streaming text: it is kept as typed, not typeset.
        var latex: String?
        var display: Bool
    }

    /// Longest formula taken as math. Anything longer stays text.
    static let maxLength = 6000

    static func spans(in text: String, isOpen: Bool = false) -> [Found] {
        let b = Array(text.utf8)
        let n = b.count
        guard b.contains(UInt8(ascii: "$")) || b.contains(UInt8(ascii: "\\")) else { return [] }
        var out: [Found] = []
        var i = 0

        func latex(_ range: Range<Int>) -> String? {
            guard range.count <= maxLength else { return nil }
            let s = String(decoding: b[range], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        /// First position at or after `from` where `closer` starts, skipping backslash escapes.
        func find(_ closer: [UInt8], from: Int, escapes: Bool) -> Int? {
            var k = from
            while k + closer.count <= n {
                if b[k...].starts(with: closer) { return k }
                k += (escapes && b[k] == UInt8(ascii: "\\")) ? 2 : 1
            }
            return nil
        }
        /// A delimited span with an unambiguous opener. Unclosed: text, or the whole rest while streaming.
        func delimited(open: Int, closer: [UInt8], display: Bool, escapes: Bool) -> Bool {
            if let close = find(closer, from: open + 2, escapes: escapes) {
                guard let body = latex(open + 2..<close) else { return false }
                out.append(Found(range: open..<close + closer.count, latex: body, display: display))
                i = close + closer.count
                return true
            }
            if isOpen {
                out.append(Found(range: open..<n, latex: nil, display: display))
                i = n
                return true
            }
            return false
        }

        while i < n {
            let c = b[i]
            switch c {
            case UInt8(ascii: "\\"):
                guard i + 1 < n else { i += 1; break }
                if b[i + 1] == UInt8(ascii: "("), delimited(open: i, closer: Array(#"\)"#.utf8), display: false, escapes: false) { break }
                if b[i + 1] == UInt8(ascii: "["), delimited(open: i, closer: Array(#"\]"#.utf8), display: true, escapes: false) { break }
                i += 2
            case UInt8(ascii: "`"):
                var run = 0
                while i + run < n, b[i + run] == c { run += 1 }
                // A code span ends at a run of exactly as many backticks.
                var k = i + run
                var end: Int?
                while k < n {
                    guard b[k] == c else { k += 1; continue }
                    var r = 0
                    while k + r < n, b[k + r] == c { r += 1 }
                    if r == run { end = k + r; break }
                    k += r
                }
                i = end ?? i + run
            case UInt8(ascii: "]") where i + 1 < n && b[i + 1] == UInt8(ascii: "("):
                // A link destination.
                var k = i + 2
                while k < n, b[k] != UInt8(ascii: ")"), b[k] != UInt8(ascii: "\n") { k += 1 }
                i = k
            case UInt8(ascii: "h") where b[i...].starts(with: http) || b[i...].starts(with: https):
                while i < n, !isSpace(b[i]) { i += 1 }
            case UInt8(ascii: "$"):
                if i + 1 < n, b[i + 1] == c {
                    if delimited(open: i, closer: [c, c], display: true, escapes: true) { break }
                    i += 2
                    break
                }
                if let close = singleDollarCloser(b, open: i), let body = latex(i + 1..<close) {
                    out.append(Found(range: i..<close + 1, latex: body, display: false))
                    i = close + 1
                } else {
                    i += 1
                }
            default:
                i += 1
            }
        }
        return out
    }

    private static let http = Array("http://".utf8)
    private static let https = Array("https://".utf8)
    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
    private static func isAlnum(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }

    /// The closing `$` of a text-style formula opened at `open`, or nil when this dollar is not math.
    private static func singleDollarCloser(_ b: [UInt8], open: Int) -> Int? {
        let n = b.count
        guard open + 1 < n, !isSpace(b[open + 1]) else { return nil }
        if open > 0, isAlnum(b[open - 1]) { return nil }
        var k = open + 1
        while k < n {
            let c = b[k]
            if c == UInt8(ascii: "\\") { k += 2; continue }
            if c == UInt8(ascii: "\n") || c == UInt8(ascii: "`") { return nil }
            if c == UInt8(ascii: "$") {
                if isSpace(b[k - 1]) { return nil }
                if k + 1 < n, b[k + 1] >= 0x30, b[k + 1] <= 0x39 { return nil }
                return k
            }
            k += 1
        }
        return nil
    }

    // MARK: Extraction for the inline renderer

    /// Private-use scalars that stand for a formula while the rest of the text goes through the Markdown parser.
    private static let placeholderBase: UInt32 = 0xF0000
    private static let placeholderLimit = 2048

    struct Extraction {
        /// The text with each formula replaced by one placeholder character.
        var text: String
        /// Source (delimiters included) and formula of each placeholder, by its index.
        var spans: [(source: String, math: MathSpan?)]
    }

    /// Takes the formulas out of `text`, so Markdown never reads `_`, `*` or `\(` inside them.
    static func extract(_ text: String, isOpen: Bool) -> Extraction? {
        let found = spans(in: text, isOpen: isOpen)
        guard !found.isEmpty, found.count <= placeholderLimit else { return nil }
        // Text that already uses these scalars is left alone.
        guard !text.unicodeScalars.contains(where: { isPlaceholder($0) }) else { return nil }
        let b = Array(text.utf8)
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var spans: [(source: String, math: MathSpan?)] = []
        var cursor = 0
        for (index, f) in found.enumerated() {
            out.append(contentsOf: b[cursor..<f.range.lowerBound])
            out.append(contentsOf: String(Character(Unicode.Scalar(placeholderBase + UInt32(index))!)).utf8)
            spans.append((String(decoding: b[f.range], as: UTF8.self),
                          f.latex.map { MathSpan(latex: $0, display: f.display, index: index) }))
            cursor = f.range.upperBound
        }
        out.append(contentsOf: b[cursor...])
        return Extraction(text: String(decoding: out, as: UTF8.self), spans: spans)
    }

    private static func isPlaceholder(_ s: Unicode.Scalar) -> Bool {
        s.value >= placeholderBase && s.value < placeholderBase + UInt32(placeholderLimit)
    }

    /// Puts each formula's source back in place of its placeholder, tagged with `MathAttribute`.
    static func restore(_ spans: [(source: String, math: MathSpan?)], in text: inout AttributedString) {
        var hits: [(range: Range<AttributedString.Index>, index: Int)] = []
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let next = scalars.index(after: i)
            if isPlaceholder(scalars[i]) { hits.append((i..<next, Int(scalars[i].value - placeholderBase))) }
            i = next
        }
        for hit in hits.reversed() where hit.index < spans.count {
            let span = spans[hit.index]
            var piece = AttributedString(span.source, attributes: text.runs[hit.range.lowerBound].attributes)
            if let math = span.math { piece[MathAttribute.self] = math }
            text.replaceSubrange(hit.range, with: piece)
        }
    }

    // MARK: Display blocks

    enum BlockDelimiter: Equatable {
        case dollars, brackets
        var opener: String { self == .dollars ? "$$" : #"\["# }
        var closer: String { self == .dollars ? "$$" : #"\]"# }
    }

    /// The LaTeX of a display block (`$$ … $$` or `\[ … \]` over whole lines), or nil if `text` is not a closed one.
    static func blockLatex(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for d in [BlockDelimiter.dollars, .brackets] where t.hasPrefix(d.opener) && t.hasSuffix(d.closer) && t.count >= 4 {
            let body = t.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty || body.utf8.count > maxLength ? nil : body
        }
        return nil
    }
}
