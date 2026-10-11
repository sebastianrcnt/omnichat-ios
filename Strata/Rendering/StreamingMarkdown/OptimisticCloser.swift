import Foundation

/// Temporarily closes unmatched inline syntax at the end of an open block, so raw markers
/// (`**`, `*`, `` ` ``, `~~`, `[`) do not flicker while a block is still streaming.
enum OptimisticCloser {
    /// Returns `text` plus whatever closers are needed. Nothing changes for balanced input.
    static func closeInline(_ text: String) -> String {
        let chars = Array(text)
        var stack: [String] = []       // "**", "*", "~~"
        var codeTicks = 0               // length of the open code span, 0 if none
        var brackets = 0
        var inURL = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if codeTicks > 0 {
                if c == "`" {
                    var j = i
                    while j < chars.count, chars[j] == "`" { j += 1 }
                    if j - i == codeTicks { codeTicks = 0 }
                    i = j
                } else { i += 1 }
                continue
            }
            switch c {
            case "\\":
                i += 2
            case "`":
                var j = i
                while j < chars.count, chars[j] == "`" { j += 1 }
                codeTicks = j - i
                i = j
            case "*":
                var j = i
                while j < chars.count, chars[j] == "*" { j += 1 }
                var len = j - i
                let prev: Character? = i > 0 ? chars[i - 1] : nil
                let next: Character? = j < chars.count ? chars[j] : nil
                let canOpen = next.map { !$0.isWhitespace } ?? false
                let canClose = prev.map { !$0.isWhitespace } ?? false
                while len > 0 {
                    let token = len >= 2 ? "**" : "*"
                    if canClose, let idx = stack.lastIndex(of: token) {
                        stack.removeSubrange(idx...)
                    } else if canOpen {
                        stack.append(token)
                    }
                    len -= token.count
                }
                i = j
            case "~":
                if i + 1 < chars.count, chars[i + 1] == "~" {
                    if let idx = stack.lastIndex(of: "~~") { stack.removeSubrange(idx...) } else { stack.append("~~") }
                    i += 2
                } else { i += 1 }
            case "[":
                if !inURL { brackets += 1 }
                i += 1
            case "]":
                if !inURL, brackets > 0 {
                    brackets -= 1
                    if i + 1 < chars.count, chars[i + 1] == "(" {
                        inURL = true
                        i += 2
                        continue
                    }
                }
                i += 1
            case ")":
                if inURL { inURL = false }
                i += 1
            default:
                i += 1
            }
        }
        var result = text
        if codeTicks > 0 { result += String(repeating: "`", count: codeTicks) }
        for token in stack.reversed() { result += token }
        if inURL { result += ")" } else if brackets > 0 { result += "](#)" }
        return result
    }

    /// Closes an open fenced code block by appending a closing fence.
    static func closeFence(_ text: String) -> String {
        let lines = BlockScanner.lines(of: text)
        guard let first = lines.first, let f = BlockScanner.Line(first).fence else { return text }
        if lines.count > 1, BlockScanner.Line(lines[lines.count - 1]).closesFence(char: f.char, count: f.count) { return text }
        return text + "\n" + String(repeating: f.char, count: f.count)
    }
}
