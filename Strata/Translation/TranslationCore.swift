import Foundation
import NaturalLanguage

// The parts of translation that do not touch the system framework, so they can be tested: when to offer it, how an
// answer is cut into blocks, which spans must never reach the translator, and how the result is put back together.

/// Which language an answer is in, and whether that differs from the reader's.
enum TranslationLanguage {
    /// Fewer letters than this is too little to name a language reliably.
    static let minimumLetters = 12
    static let minimumConfidence = 0.5

    /// The reader's language: the first entry of `Locale.preferredLanguages`.
    static var preferred: String? { Locale.preferredLanguages.first }

    /// The language the prose of `markdown` is written in, ignoring code, links and citation markers. Nil when there
    /// is too little prose or the recognizer is unsure.
    static func dominant(of markdown: String) -> String? {
        let prose = proseOnly(markdown)
        guard prose.unicodeScalars.lazy.filter({ CharacterSet.letters.contains($0) }).count >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(prose.prefix(4000)))
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first, top.value >= minimumConfidence else { return nil }
        return top.key.rawValue
    }

    /// The text a person reads as language: fenced code, inline code, URLs and citation markers removed.
    static func proseOnly(_ markdown: String) -> String {
        let plan = TranslationPlan(markdown: markdown)
        return plan.sources.map(\.visibleText).joined(separator: "\n")
    }

    /// True when `a` and `b` are different languages. Regions do not count (en-US and en-GB match); Chinese scripts do.
    static func differs(_ a: String, _ b: String) -> Bool {
        let x = Locale.Language(identifier: a), y = Locale.Language(identifier: b)
        guard let cx = x.languageCode?.identifier, let cy = y.languageCode?.identifier else { return a != b }
        let (nx, ny) = (normalized(cx), normalized(cy))
        if nx != ny { return true }
        if nx == "zh", let sx = script(of: x), let sy = script(of: y) { return sx != sy }
        return false
    }

    private static func normalized(_ code: String) -> String {
        switch code {
        case "nb", "nn": "no"
        case "iw": "he"
        case "in": "id"
        default: code
        }
    }

    /// Han script of a Chinese identifier, filling in the usual script for a region (zh-TW is traditional).
    private static func script(of language: Locale.Language) -> String? {
        if let s = language.script?.identifier { return s }
        switch language.region?.identifier {
        case "TW", "HK", "MO": return "Hant"
        case "CN", "SG": return "Hans"
        default: return nil
        }
    }

    /// Whether to show the translate action for an answer.
    static func shouldOffer(text: String, preferred: String?) -> Bool {
        guard let preferred, let dominant = dominant(of: text) else { return false }
        return differs(dominant, preferred)
    }
}

/// Who may be translated: a finished answer with text.
enum TranslationEligibility {
    static func isEligible(role: MessageRole, text: String, isStreaming: Bool, hasError: Bool, hasUnfinishedTurn: Bool) -> Bool {
        role == .assistant && !isStreaming && !hasError && !hasUnfinishedTurn
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What the stored translation means right now.
enum TranslationState: Equatable {
    case none
    /// A translation for the reader's current language exists. `showing` is which side is displayed.
    case translated(showing: Bool)

    static func resolve(translatedText: String?, storedTarget: String?, showing: Bool, currentTarget: String?) -> TranslationState {
        guard let translatedText, !translatedText.isEmpty, let storedTarget, let currentTarget,
              !TranslationLanguage.differs(storedTarget, currentTarget) else { return .none }
        return .translated(showing: showing)
    }
}

// MARK: - Protecting spans

/// Spans swapped for numbered placeholders before translation and put back after.
enum TranslationProtector {
    static let open = "\u{27E6}", close = "\u{27E7}" // ⟦ ⟧

    static func token(_ i: Int) -> String { "\(open)\(i)\(close)" }

    /// Matches code spans, link targets, bare URLs, autolinks, inline HTML, and citation or footnote markers.
    private static let patterns: [NSRegularExpression] = [
        #"(?<!`)(`+)(?!`).+?(?<!`)\1(?!`)"#,        // inline code (a run of backticks, closed by the same run)
        #"(?<=\])\((?:[^()\s]|\([^()\s]*\))*(?:\s+"[^"]*")?\)"#, // the (target "title") of a link or image
        #"<(?:https?|mailto):[^>\s]+>"#,            // autolink
        #"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>"#, // inline HTML tag
        #"\bhttps?://[^\s<>()\[\]]+(?:\([^\s<>()]*\)[^\s<>()\[\]]*)*"#, // bare URL
        #"\[\^[^\]\s]+\]"#,                         // footnote marker
        #"\[\d{1,3}\](?!\()"#,                      // citation marker [1] (a link text of digits has a "(" next)
    ].map { try! NSRegularExpression(pattern: $0, options: [.dotMatchesLineSeparators]) }

    /// Replaces every protected span with a placeholder. `tokens[i]` is the text behind placeholder i.
    static func protect(_ text: String) -> (text: String, tokens: [String]) {
        let ns = text as NSString
        var ranges: [NSRange] = []
        for regex in patterns {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var r = m.range
                if regex === patterns[4] { r = trimmedURL(r, in: ns) }
                if r.length > 0, !ranges.contains(where: { NSIntersectionRange($0, r).length > 0 }) { ranges.append(r) }
            }
        }
        ranges.sort { $0.location < $1.location }
        var out = "", tokens: [String] = [], cursor = 0
        for r in ranges {
            out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            out += token(tokens.count)
            tokens.append(ns.substring(with: r))
            cursor = r.location + r.length
        }
        out += ns.substring(from: cursor)
        return (out, tokens)
    }

    /// A URL does not end in the punctuation of the sentence around it.
    private static func trimmedURL(_ r: NSRange, in ns: NSString) -> NSRange {
        var length = r.length
        while length > 0, let c = ns.substring(with: NSRange(location: r.location + length - 1, length: 1)).first, ".,;:!?'\"".contains(c) { length -= 1 }
        return NSRange(location: r.location, length: length)
    }

    /// Puts the spans back. Placeholders may come back with stray spaces inside. Returns nil when one is missing or
    /// repeated, because then the translation cannot be trusted to keep the spans where they belong.
    static func restore(_ translated: String, tokens: [String]) -> String? {
        guard !tokens.isEmpty else { return translated }
        let regex = try! NSRegularExpression(pattern: "\(open)\\s*(\\d+)\\s*\(close)")
        let ns = translated as NSString
        var seen = Set<Int>()
        var out = "", cursor = 0
        for m in regex.matches(in: translated, range: NSRange(location: 0, length: ns.length)) {
            guard let i = Int(ns.substring(with: m.range(at: 1))), tokens.indices.contains(i), seen.insert(i).inserted else { return nil }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            // A link target must follow its "]" directly, whatever spacing the translator added.
            if tokens[i].hasPrefix("("), out.last?.isWhitespace == true {
                let trimmed = String(out.reversed().drop { $0.isWhitespace }.reversed())
                if trimmed.hasSuffix("]") { out = trimmed }
            }
            out += tokens[i]
            cursor = m.range.location + m.range.length
        }
        guard seen.count == tokens.count else { return nil }
        out += ns.substring(from: cursor)
        return out
    }
}

// MARK: - Cutting an answer into blocks

/// An answer cut into pieces: the structure that is kept as it is (fences, rules, list markers, table pipes) and the
/// blocks of prose that go to the translator.
struct TranslationPlan: Equatable {
    struct Source: Equatable {
        /// The block as written (without its line prefixes).
        var original: String
        /// What is sent: the block with its protected spans replaced.
        var protected: String
        var tokens: [String]
        /// The prefix repeated on each line of a block ("> ", "  ").
        var linePrefix: String

        /// Readable text: protected spans removed.
        var visibleText: String {
            var s = protected
            for i in tokens.indices { s = s.replacingOccurrences(of: TranslationProtector.token(i), with: " ") }
            return s
        }

        /// A block with no letters in it (only code, links, numbers, symbols) has nothing to translate.
        var needsTranslation: Bool { visibleText.contains { $0.isLetter } }
    }

    enum Piece: Equatable {
        case literal(String)
        /// The first line's prefix (quote, indent, heading hashes, bullet or number), then the translated block.
        case block(marker: String, source: Int)
    }

    var pieces: [Piece] = []
    var sources: [Source] = []

    private enum Line {
        case literal(String)               // fence, fence content, blank line, rule, table separator
        case table(String)
        case text(prefix: String, marker: String, rest: String)
    }

    init(markdown: String) {
        var lines = markdown.components(separatedBy: "\n")
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }
        func newline(after i: Int) -> String { i < lines.count - 1 || endsWithNewline ? "\n" : "" }

        var classified: [Line] = []
        var fence: (char: Character, length: Int)?
        for line in lines {
            if let open = fence {
                classified.append(.literal(line))
                if let f = Self.fenceMarker(line), f.char == open.char, f.length >= open.length,
                   line.trimmingCharacters(in: .whitespaces).dropFirst(f.length).allSatisfy(\.isWhitespace) { fence = nil }
            } else if let f = Self.fenceMarker(line) {
                fence = f
                classified.append(.literal(line))
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || Self.isRule(trimmed) {
                    classified.append(.literal(line))
                } else if trimmed.hasPrefix("|") {
                    classified.append(.table(line))
                } else {
                    let (prefix, marker, rest) = Self.split(line)
                    classified.append(.text(prefix: prefix, marker: marker, rest: rest))
                }
            }
        }

        var i = 0
        while i < classified.count {
            switch classified[i] {
            case .literal(let s):
                pieces.append(.literal(s + newline(after: i)))
                i += 1
            case .table(let row):
                addTableRow(row, newline: newline(after: i))
                i += 1
            case .text(let prefix, let marker, let rest):
                var block = [rest]
                var end = i
                if marker.isEmpty { // plain lines with the same prefix are one paragraph
                    while end + 1 < classified.count, case .text(let p2, let m2, let r2) = classified[end + 1], m2.isEmpty, p2 == prefix {
                        block.append(r2)
                        end += 1
                    }
                }
                add(block: block.joined(separator: "\n"), marker: prefix + marker, continuation: marker.isEmpty ? prefix : "",
                    newline: newline(after: end))
                i = end + 1
            }
        }
    }

    /// Adds a block of prose. Whitespace at its ends is kept as it was and not translated.
    private mutating func add(block: String, marker: String, continuation: String, newline: String) {
        let lead = String(block.prefix { $0 == " " || $0 == "\t" })
        let body = block.dropFirst(lead.count)
        let trail = String(body.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        let core = String(body.dropLast(trail.count))
        let (text, tokens) = TranslationProtector.protect(core)
        let source = Source(original: core, protected: text, tokens: tokens, linePrefix: continuation)
        if source.needsTranslation {
            sources.append(source)
            pieces.append(.literal(lead))
            pieces.append(.block(marker: marker, source: sources.count - 1))
        } else {
            pieces.append(.literal(marker + lead + core.replacingOccurrences(of: "\n", with: "\n" + continuation)))
        }
        pieces.append(.literal(trail + newline))
    }

    private mutating func addTableRow(_ line: String, newline: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.allSatisfy({ "|-: \t".contains($0) }) { pieces.append(.literal(line + newline)); return }
        // Cells are blocks of their own; the pipes and padding stay.
        var cells: [String] = [], current = "", escaped = false
        for ch in line {
            if ch == "|" && !escaped { cells.append(current); current = "" } else { current.append(ch) }
            escaped = ch == "\\" && !escaped
        }
        cells.append(current)
        for (n, cell) in cells.enumerated() {
            if n > 0 { pieces.append(.literal("|")) }
            if cell.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(.literal(cell)); continue }
            add(block: cell, marker: "", continuation: "", newline: "")
        }
        pieces.append(.literal(newline))
    }

    // MARK: Line shapes

    static func fenceMarker(_ line: String) -> (char: Character, length: Int)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let c = rest.first, c == "`" || c == "~" else { return nil }
        let run = rest.prefix { $0 == c }.count
        guard run >= 3 else { return nil }
        if c == "`", rest.dropFirst(run).contains("`") { return nil } // `` ```x``` `` on one line is inline code
        return (c, run)
    }

    static func isRule(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { $0 != " " }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    private static let markerRegex = try! NSRegularExpression(
        pattern: #"^((?:[ \t]*>)*[ \t]*)((?:#{1,6}[ \t]+)|(?:[-*+][ \t]+(?:\[[ xX]\][ \t]+)?)|(?:\d{1,9}[.)][ \t]+))?"#)

    /// Splits a line into its quote/indent prefix, its list or heading marker, and the text after both.
    static func split(_ line: String) -> (prefix: String, marker: String, rest: String) {
        let ns = line as NSString
        guard let m = markerRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return ("", "", line) }
        let prefix = ns.substring(with: m.range(at: 1))
        let marker = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
        return (prefix, marker, ns.substring(from: m.range.location + m.range.length))
    }

    // MARK: Putting it back

    /// The requests, in order. One per block.
    var requests: [String] { sources.map(\.protected) }

    /// Joins the translated blocks into Markdown. A block whose translation lost or repeated a placeholder (or came
    /// back empty) keeps its original text.
    func assemble(_ translations: [String]) -> String {
        precondition(translations.count == sources.count, "one translation per source block")
        var out = ""
        for piece in pieces {
            switch piece {
            case .literal(let s): out += s
            case .block(let marker, let i):
                let source = sources[i]
                let restored = TranslationProtector.restore(translations[i], tokens: source.tokens)
                let body = restored.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? source.original
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                out += marker + trimmed.replacingOccurrences(of: "\n", with: "\n" + source.linePrefix)
            }
        }
        return out
    }

    /// How many blocks were kept as written because their translation could not be trusted.
    func untrusted(_ translations: [String]) -> Int {
        zip(sources, translations).filter { TranslationProtector.restore($1, tokens: $0.tokens) == nil }.count
    }
}

// MARK: - Running

protocol TextTranslating: Sendable {
    /// One translation per text, in order.
    func translate(_ texts: [String]) async throws -> [String]
}

enum TranslationRunner {
    /// Translates `markdown` block by block. Code, links and citation markers never reach the translator.
    static func translate(_ markdown: String, with translator: any TextTranslating) async throws -> String {
        let plan = TranslationPlan(markdown: markdown)
        if plan.sources.isEmpty { return markdown }
        let results = try await translator.translate(plan.requests)
        guard results.count == plan.sources.count else { throw TranslationFailure.countMismatch }
        try Task.checkCancellation()
        return plan.assemble(results)
    }
}

enum TranslationFailure: LocalizedError, Equatable {
    case countMismatch
    case unavailable
    case unsupportedPair

    var errorDescription: String? {
        switch self {
        case .countMismatch: String(localized: "The translation came back incomplete.")
        case .unavailable: String(localized: "Translation isn't available on this device.")
        case .unsupportedPair: String(localized: "This language can't be translated to your language.")
        }
    }
}
