import Foundation

/// Turns `[N]` citation markers in model output into tappable chip links.
///
/// - `[N]` (digits only) where N is a known source id becomes a link `strata-cite://N`.
/// - Consecutive markers (`[1][2]`, `[1] [2]`) merge into one chip labelled "domain +K".
/// - Unknown ids are hidden.
/// - A partially streamed marker at the very end (`[`, `[12`) is held back until its `]` arrives.
/// - Code spans, escaped brackets, and `[N](url)` / `[N]: ref` forms are left alone.
enum CitationParser {
    static let scheme = "strata-cite"

    /// Thin space around the label gives the chip background some padding.
    private static let pad = "\u{2002}" // en space: about 6pt at the chip font size

    static func citeURL(ids: [Int]) -> String {
        "\(scheme)://" + ids.map(String.init).joined(separator: ",")
    }

    static func ids(from url: URL) -> [Int] {
        guard url.scheme == scheme else { return [] }
        let raw = url.absoluteString.dropFirst(scheme.count + 3)
        return raw.split(separator: ",").compactMap { Int($0) }
    }

    private struct Marker {
        var ids: [Int]
        var end: Int // index after the closing bracket
    }

    /// Parse one `[digits]` marker at `i`. Returns nil if it is not a marker, `.partial` at end of text.
    private enum Parsed { case marker(Marker), partial, none }

    private static func parseMarker(_ chars: [Character], at i: Int) -> Parsed {
        guard chars[i] == "[" else { return .none }
        var j = i + 1
        while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
        if j == chars.count { return .partial }          // "[" or "[12" at the end
        guard j > i + 1, chars[j] == "]" else { return .none }
        // `[1](url)` and `[1]: ref` are real Markdown, not citations.
        if j + 1 < chars.count, chars[j + 1] == "(" || chars[j + 1] == ":" { return .none }
        guard let id = Int(String(chars[(i + 1)..<j])) else { return .none }
        return .marker(Marker(ids: [id], end: j + 1))
    }

    /// Rewrite markers in `text`. `holdBack` drops a trailing partial marker (use while streaming).
    static func transform(_ text: String, sources: [Int: SourceInfo], holdBack: Bool) -> String {
        guard text.contains("[") else { return text }
        let chars = Array(text)
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
                out.append(contentsOf: String(chars[i..<end]))
                i = end
                continue
            }
            if c == "[" {
                switch parseMarker(chars, at: i) {
                case .partial:
                    if holdBack { return out.trimmingTrailingSpace() }
                    out.append(c)
                    i += 1
                case .none:
                    out.append(c)
                    i += 1
                case .marker(let first):
                    // Collect the run of consecutive markers.
                    var ids = first.ids
                    var end = first.end
                    var heldPartial = false
                    while true {
                        var k = end
                        if k < chars.count, chars[k] == " " { k += 1 }
                        guard k < chars.count else { break }
                        let next = parseMarker(chars, at: k)
                        if case .marker(let m) = next { ids += m.ids; end = m.end; continue }
                        if case .partial = next, holdBack, chars[k] == "[" { heldPartial = true; end = k }
                        break
                    }
                    var seen = Set<Int>()
                    let known = ids.filter { sources[$0] != nil && seen.insert($0).inserted }
                    if known.isEmpty {
                        out = out.trimmingTrailingSpace() // hidden entirely
                    } else {
                        out += chip(known, sources: sources)
                    }
                    i = end
                    if heldPartial { return out }
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private static func chip(_ ids: [Int], sources: [Int: SourceInfo]) -> String {
        let first = sources[ids[0]]?.shortHost ?? "source"
        // Never wrap inside a chip: non-breaking hyphen and space.
        var label = escape(first).replacingOccurrences(of: "-", with: "\u{2011}")
        if ids.count > 1 { label += "\u{00A0}+\(ids.count - 1)" }
        return "[\(pad)\(label)\(pad)](\(citeURL(ids: ids)))"
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\`*_[]()<>#!|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Known source ids cited in `text`, in first-appearance order.
    static func citedIDs(in text: String, known: Set<Int>) -> [Int] {
        let chars = Array(text)
        var out: [Int] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "[", case .marker(let m) = parseMarker(chars, at: i) {
                if let id = m.ids.first, known.contains(id), !out.contains(id) { out.append(id) }
                i = m.end
            } else { i += 1 }
        }
        return out
    }
}

private extension String {
    func trimmingTrailingSpace() -> String {
        hasSuffix(" ") ? String(dropLast()) : self
    }
}
