import Foundation

/// Makes `**bold**` work the way CJK-friendly renderers do, instead of CommonMark's strict flanking rules.
///
/// Strict CommonMark leaves `**신체 **:`, `** 앞공백**` or `**"인용"**을` as raw asterisks. Here every pair of
/// `**` on a line that has real content between them is rewritten into a form every CommonMark parser
/// accepts: whitespace at the edges moves outside the markers, and a zero-width space is placed just inside
/// each marker. A zero-width space is neither whitespace nor punctuation, so the opener is always
/// left-flanking and the closer always right-flanking. `stripZeroWidth` removes them again afterwards.
enum LenientEmphasis {
    static let zeroWidth: Character = "\u{200B}"

    static func normalize(_ text: String) -> String {
        guard text.contains("**") else { return text }
        let chars = Array(text)
        let delimiters = findDelimiters(chars)
        guard delimiters.count >= 2 else { return text }

        // Pair delimiters left to right when there is non-space content between them on the same line.
        var pairs: [(open: Int, close: Int)] = []
        var i = 0
        while i + 1 < delimiters.count {
            let a = delimiters[i], b = delimiters[i + 1]
            let inner = chars[(a + 2)..<b]
            if inner.contains(where: { !$0.isWhitespace }) && !inner.contains("\n") {
                pairs.append((a, b))
                i += 2
            } else {
                i += 1
            }
        }
        guard !pairs.isEmpty else { return text }

        var out = ""
        var cursor = 0
        for (open, close) in pairs {
            var innerStart = open + 2
            var innerEnd = close
            while innerStart < innerEnd, chars[innerStart].isWhitespace { innerStart += 1 }
            while innerEnd > innerStart, chars[innerEnd - 1].isWhitespace { innerEnd -= 1 }
            out += String(chars[cursor..<open])
            out += String(chars[(open + 2)..<innerStart])           // leading space moves outside
            out += "**" + String(zeroWidth) + String(chars[innerStart..<innerEnd]) + String(zeroWidth) + "**"
            out += String(chars[innerEnd..<close])                   // trailing space moves outside
            cursor = close + 2
        }
        out += String(chars[cursor...])
        return out
    }

    /// Positions of `**` runs that are exactly two asterisks, outside code spans and not escaped.
    private static func findDelimiters(_ chars: [Character]) -> [Int] {
        var found: [Int] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "`" {
                var j = i
                while j < chars.count, chars[j] == "`" { j += 1 }
                let len = j - i
                var k = j
                var close: Int?
                while k < chars.count {
                    if chars[k] == "`" {
                        var m = k
                        while m < chars.count, chars[m] == "`" { m += 1 }
                        if m - k == len { close = m; break }
                        k = m
                    } else { k += 1 }
                }
                i = close ?? j
                continue
            }
            if c == "*" {
                var j = i
                while j < chars.count, chars[j] == "*" { j += 1 }
                if j - i == 2 { found.append(i) }
                i = j
                continue
            }
            i += 1
        }
        return found
    }

    static func stripZeroWidth(_ text: AttributedString) -> AttributedString {
        // One pass: copy the stretches between zero-width characters (attributes travel with the slices).
        var cuts: [Range<AttributedString.Index>] = []
        var i = text.characters.startIndex
        while i < text.characters.endIndex {
            let next = text.characters.index(after: i)
            if text.characters[i] == zeroWidth { cuts.append(i..<next) }
            i = next
        }
        guard !cuts.isEmpty else { return text }
        var out = AttributedString()
        var start = text.startIndex
        for cut in cuts {
            if start < cut.lowerBound { out.append(text[start..<cut.lowerBound]) }
            start = cut.upperBound
        }
        if start < text.endIndex { out.append(text[start..<text.endIndex]) }
        return out
    }
}

/// GFM strikethrough is turned off: `~` and `~~` are always literal text (`2~3천` is a range, not a strike).
enum TildeEscaper {
    /// Backslash-escapes tildes outside code spans and fenced code. Already escaped tildes are kept.
    static func escape(_ text: String) -> String {
        guard text.contains("~") else { return text }
        var out = ""
        var fence: (char: Character, count: Int)?
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index > 0 { out += "\n" }
            let l = BlockScanner.Line(line)
            if let f = fence {
                if l.closesFence(char: f.char, count: f.count) { fence = nil }
                out += line
                continue
            }
            if let f = l.fence { fence = (f.char, f.count); out += line; continue }
            out += escapeInline(String(line))
        }
        return out
    }

    private static func escapeInline(_ line: String) -> String {
        guard line.contains("~") else { return line }
        let chars = Array(line)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                out.append(c)
                if i + 1 < chars.count { out.append(chars[i + 1]) }
                i += 2
                continue
            }
            if c == "`" {
                var j = i
                while j < chars.count, chars[j] == "`" { j += 1 }
                let len = j - i
                var k = j
                var close: Int?
                while k < chars.count {
                    if chars[k] == "`" {
                        var m = k
                        while m < chars.count, chars[m] == "`" { m += 1 }
                        if m - k == len { close = m; break }
                        k = m
                    } else { k += 1 }
                }
                let end = close ?? j
                out += String(chars[i..<end])
                i = end
                continue
            }
            if c == "~" { out += "\\~" } else { out.append(c) }
            i += 1
        }
        return out
    }
}

/// Plain text for the "Copy" action: Markdown markers removed, line structure kept.
enum MarkdownPlain {
    static func text(from markdown: String) -> String {
        // Interactive views copy as what they show, not as their program (`OUIPlainText`).
        let markdown = OpenUIFence.replacingBlocks(in: markdown) { OUIPlainText.text(source: $0) }
        let prepared = LenientEmphasis.normalize(TildeEscaper.escape(markdown))
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: prepared, options: options) else { return markdown }
        return String(LenientEmphasis.stripZeroWidth(attributed).characters)
    }
}
