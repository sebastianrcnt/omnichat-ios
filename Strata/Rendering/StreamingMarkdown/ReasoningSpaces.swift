import Foundation

/// Display-only cleanup of reasoning text: runs of two or more ASCII spaces collapse into one. Newlines, tabs,
/// no-break spaces and figure spaces are left alone. The stored reasoning and anything sent to the API stay raw.
enum ReasoningSpaces {
    /// Collapses `text`. `previous` is the last character already shown, so a delta that starts with a space after
    /// a shown space also collapses (streaming deltas can split a run anywhere).
    static func collapse(_ text: String, after previous: Character? = nil) -> String {
        guard text.contains(" ") else { return text }
        if previous != " ", !text.contains("  ") { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var lastWasSpace = previous == " "
        for ch in text {
            if ch == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            out.append(ch)
        }
        return out
    }
}
