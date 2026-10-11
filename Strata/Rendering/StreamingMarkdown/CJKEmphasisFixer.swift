import Foundation

/// Relaxes the CommonMark flanking rule for CJK text.
///
/// CommonMark treats `**"강조"**는` as plain text, because the closing `**` is preceded by punctuation and
/// followed by a letter (a Hangul particle). CJK text has no spaces, so that case is common. This pass
/// inserts a hair space (U+200A, Unicode whitespace) on the CJK side of such delimiter runs, which makes
/// every CommonMark parser accept them, at the cost of an almost invisible gap.
enum CJKEmphasisFixer {
    static let hairSpace: Character = "\u{200A}"

    static func isCJK(_ c: Character?) -> Bool {
        guard let v = c?.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF, // Hangul
             0x3040...0x30FF,                                    // Kana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:  // Han
            return true
        default:
            return false
        }
    }

    private static func isSpace(_ c: Character?) -> Bool { c == nil || c!.isWhitespace }
    private static func isPunct(_ c: Character?) -> Bool { c.map { $0.isPunctuation || $0.isSymbol } ?? false }

    static func fix(_ text: String) -> String {
        // Fast exit: nothing to do without both an asterisk run and CJK text.
        guard text.contains("*"), text.unicodeScalars.contains(where: { isCJK(Character($0)) }) else { return text }
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count + 8)
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
                // Skip a code span (or an unmatched backtick run) untouched.
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
                out.append(contentsOf: chars[i..<end])
                i = end
                continue
            }
            if c == "*" {
                var j = i
                while j < chars.count, chars[j] == "*" { j += 1 }
                let prev: Character? = i > 0 ? chars[i - 1] : nil
                let next: Character? = j < chars.count ? chars[j] : nil
                let stdLeft = !isSpace(next) && (!isPunct(next) || isSpace(prev) || isPunct(prev))
                let stdRight = !isSpace(prev) && (!isPunct(prev) || isSpace(next) || isPunct(next))
                let relLeft = !isSpace(next) && (!isPunct(next) || isSpace(prev) || isPunct(prev) || isCJK(prev))
                let relRight = !isSpace(prev) && (!isPunct(prev) || isSpace(next) || isPunct(next) || isCJK(next))
                if relLeft && !stdLeft && isCJK(prev) { out.append(hairSpace) }
                out.append(contentsOf: chars[i..<j])
                if relRight && !stdRight && isCJK(next) { out.append(hairSpace) }
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }
}
