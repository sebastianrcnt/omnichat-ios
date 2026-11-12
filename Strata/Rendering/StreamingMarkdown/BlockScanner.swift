import Foundation

/// Cheap line-based splitter from raw Markdown to top-level blocks.
///
/// It does not build an AST: it only finds block boundaries, which is all the streaming pipeline needs.
/// Block *content* is rendered by a real Markdown renderer once the block is finalized.
enum BlockScanner {
    struct Scanned: Equatable {
        var kind: MarkdownBlock.Kind
        var startLine: Int
        var endLine: Int // inclusive
        var isClosed: Bool
    }

    // MARK: Line classification

    struct Line {
        let raw: Substring
        let indent: Int
        let rest: Substring
        var isBlank: Bool { rest.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" } }

        init(_ raw: Substring) {
            self.raw = raw
            var indent = 0
            var idx = raw.startIndex
            while idx < raw.endIndex {
                if raw[idx] == " " { indent += 1 } else if raw[idx] == "\t" { indent += 4 - indent % 4 } else { break }
                idx = raw.index(after: idx)
            }
            self.indent = indent
            self.rest = raw[idx...]
        }

        var trimmed: Substring {
            var s = rest
            while let l = s.last, l == " " || l == "\t" || l == "\r" { s = s.dropLast() }
            return s
        }

        /// Opening fence (indent <= 3).
        var fence: (char: Character, count: Int)? { indent <= 3 ? fenceAnyIndent : nil }

        /// Opening fence at any indentation (used inside list items).
        var fenceAnyIndent: (char: Character, count: Int)? {
            guard let c = rest.first, c == "`" || c == "~" else { return nil }
            let count = rest.prefix { $0 == c }.count
            guard count >= 3 else { return nil }
            if c == "`" && rest.dropFirst(count).contains("`") { return nil }
            return (c, count)
        }

        func closesFence(char: Character, count: Int, anyIndent: Bool = false) -> Bool {
            guard anyIndent || indent <= 3 else { return false }
            let t = trimmed
            guard let c = t.first, c == char else { return false }
            return t.count >= count && t.allSatisfy { $0 == char }
        }

        var atxLevel: Int? {
            guard indent <= 3, rest.first == "#" else { return nil }
            let hashes = rest.prefix { $0 == "#" }.count
            guard hashes <= 6 else { return nil }
            let after = rest.dropFirst(hashes)
            guard after.isEmpty || after.first == " " || after.first == "\t" || after.first == "\r" else { return nil }
            return hashes
        }

        var isThematicBreak: Bool {
            guard indent <= 3, let c = rest.first, c == "-" || c == "*" || c == "_" else { return false }
            var count = 0
            for ch in trimmed {
                if ch == c { count += 1 } else if ch != " " && ch != "\t" { return false }
            }
            return count >= 3
        }

        /// 1 for `===`, 2 for `---`, nil otherwise.
        var setextLevel: Int? {
            guard indent <= 3, let c = rest.first, c == "=" || c == "-" else { return nil }
            let t = trimmed
            guard t.allSatisfy({ $0 == c }) else { return nil }
            return c == "=" ? 1 : 2
        }

        var isQuote: Bool { indent <= 3 && rest.first == ">" }

        /// List marker info for a line at indent <= 3.
        var listMarker: (ordered: Bool, start: Int, hasContent: Bool)? {
            guard indent <= 3, let c = rest.first else { return nil }
            if c == "-" || c == "+" || c == "*" {
                let after = rest.dropFirst()
                guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
                return (false, 0, !after.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" })
            }
            if c.isASCII, c.isNumber {
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard digits.count <= 9 else { return nil }
                let after = rest.dropFirst(digits.count)
                guard let d = after.first, d == "." || d == ")" else { return nil }
                let tail = after.dropFirst()
                guard tail.isEmpty || tail.first == " " || tail.first == "\t" else { return nil }
                return (true, Int(digits) ?? 1, !tail.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" })
            }
            return nil
        }

        var isTableDelimiter: Bool {
            let t = trimmed
            guard t.contains("-"), t.contains("|") else { return false }
            return t.allSatisfy { "|:- \t".contains($0) }
        }

        var containsPipe: Bool { rest.contains("|") }

        /// The delimiter a display formula opens with, when the line starts with one (indent <= 3).
        var mathOpener: MathScanner.BlockDelimiter? {
            guard indent <= 3 else { return nil }
            if rest.hasPrefix("$$") { return .dollars }
            if rest.hasPrefix(#"\["#) { return .brackets }
            return nil
        }
    }

    /// The display formula that starts at line `i`: its last line and whether it is closed there. Nil when the line
    /// does not open one. A formula ends on the line that ends with its closing delimiter. Text after the delimiter,
    /// or a blank line before it, means this is prose (the inline renderer still finds `$$…$$` inside a paragraph).
    /// Without either, the formula is still being written and runs to the end of the text.
    static func mathBlock(_ lines: [Line], from i: Int) -> (end: Int, closed: Bool)? {
        guard let delimiter = lines[i].mathOpener else { return nil }
        let closer = delimiter.closer
        var j = i
        while j < lines.count {
            let line = lines[j]
            if line.isBlank {
                // An empty last line is only the newline that just arrived, not a blank line yet.
                if j == lines.count - 1 { break }
                return nil
            }
            // On the opening line, look after the opener: "$$" alone is not "$$ … $$".
            let text = j == i ? line.trimmed.dropFirst(2) : line.trimmed
            if let found = text.range(of: closer) {
                return found.upperBound == text.endIndex ? (j, true) : nil
            }
            j += 1
        }
        return (lines.count - 1, false)
    }

    // MARK: Scanning

    /// Split `text` into top-level blocks. Lines are separated by `\n`.
    static func scan(lines: [Substring]) -> [Scanned] {
        let parsed = lines.map(Line.init)
        var blocks: [Scanned] = []
        var i = 0
        let n = parsed.count

        /// Whether line `j` starts a block that interrupts a paragraph.
        func isBlockStart(_ j: Int) -> Bool {
            let l = parsed[j]
            if l.fence != nil || l.atxLevel != nil || l.isThematicBreak || l.isQuote { return true }
            if let m = l.listMarker, m.hasContent, !m.ordered || m.start == 1 { return true }
            return mathBlock(parsed, from: j) != nil
        }

        while i < n {
            let line = parsed[i]
            if line.isBlank { i += 1; continue }

            // Fenced code
            if let f = line.fence {
                var j = i + 1
                var closed = false
                while j < n {
                    if parsed[j].closesFence(char: f.char, count: f.count) { closed = true; break }
                    j += 1
                }
                let end = closed ? j : n - 1
                blocks.append(.init(kind: .code, startLine: i, endLine: end, isClosed: closed))
                i = end + 1
                continue
            }
            // Display formula
            if let math = mathBlock(parsed, from: i) {
                blocks.append(.init(kind: .math, startLine: i, endLine: math.end, isClosed: math.closed))
                i = math.end + 1
                continue
            }
            // ATX heading
            if let level = line.atxLevel {
                blocks.append(.init(kind: .heading(level: level), startLine: i, endLine: i, isClosed: true))
                i += 1
                continue
            }
            // Thematic break
            if line.isThematicBreak {
                blocks.append(.init(kind: .thematicBreak, startLine: i, endLine: i, isClosed: true))
                i += 1
                continue
            }
            // Block quote
            if line.isQuote {
                var j = i + 1
                while j < n {
                    let l = parsed[j]
                    if l.isBlank { break }
                    if l.isQuote { j += 1; continue }
                    if isBlockStart(j) { break } // lazy continuation only for plain text
                    j += 1
                }
                blocks.append(.init(kind: .blockquote, startLine: i, endLine: j - 1, isClosed: true))
                i = j
                continue
            }
            // List
            if line.listMarker != nil {
                var j = i + 1
                var lastIncluded = i
                while j < n {
                    let l = parsed[j]
                    if l.isBlank {
                        var k = j + 1
                        while k < n && parsed[k].isBlank { k += 1 }
                        guard k < n else { break }
                        let nxt = parsed[k]
                        if nxt.indent >= 2 || (nxt.listMarker != nil && !nxt.isThematicBreak) {
                            j = k
                            continue
                        }
                        break
                    }
                    if l.isThematicBreak && l.indent < 2 { break }
                    if l.indent < 2 && (l.atxLevel != nil || l.isQuote || mathBlock(parsed, from: j) != nil) { break }
                    if l.indent >= 2, let f = l.fenceAnyIndent {
                        // Fenced code inside an item: consume through its closing fence.
                        var k = j + 1
                        var closed = false
                        while k < n {
                            if parsed[k].closesFence(char: f.char, count: f.count, anyIndent: true) { closed = true; break }
                            k += 1
                        }
                        lastIncluded = closed ? k : n - 1
                        j = lastIncluded + 1
                        continue
                    }
                    lastIncluded = j
                    j += 1
                }
                blocks.append(.init(kind: .list, startLine: i, endLine: min(lastIncluded, n - 1), isClosed: true))
                i = min(lastIncluded, n - 1) + 1
                continue
            }
            // Table: header row with pipes followed by a delimiter row
            if line.containsPipe, i + 1 < n, parsed[i + 1].isTableDelimiter {
                var j = i + 2
                while j < n, !parsed[j].isBlank, !isBlockStart(j) { j += 1 }
                let terminated = j < n
                blocks.append(.init(kind: .table, startLine: i, endLine: j - 1, isClosed: terminated))
                i = j
                continue
            }
            // Indented code
            if line.indent >= 4 {
                var j = i + 1
                var last = i
                while j < n {
                    if parsed[j].isBlank { j += 1; continue }
                    if parsed[j].indent >= 4 { last = j; j += 1 } else { break }
                }
                blocks.append(.init(kind: .code, startLine: i, endLine: last, isClosed: true))
                i = last + 1
                continue
            }
            // Paragraph (possibly a setext heading)
            var j = i + 1
            var heading: Int?
            while j < n {
                let l = parsed[j]
                if l.isBlank { break }
                if let level = l.setextLevel { heading = level; j += 1; break }
                if isBlockStart(j) { break }
                if l.containsPipe, j + 1 < n, parsed[j + 1].isTableDelimiter { break }
                j += 1
            }
            blocks.append(.init(kind: heading.map { .heading(level: $0) } ?? .paragraph,
                                startLine: i, endLine: j - 1, isClosed: true))
            i = j
        }
        return blocks
    }

    /// Split a string into lines on `\n` (any `\r` stays on the line it ends).
    static func lines(of text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
