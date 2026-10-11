import SwiftUI

extension DSTheme {
    /// The colour of a token on the code surface (light and dark palettes).
    func syntax(_ token: SyntaxToken) -> Color {
        guard token != .plain, let light = SyntaxPalette.light[token], let dark = SyntaxPalette.dark[token] else { return textPrimary }
        return Color(light: light, dark: dark)
    }
}

/// Highlighted code as text: one string per line (for the viewer), and the whole block and its collapsed preview.
struct HighlightedCode: Sendable, Equatable {
    var lines: [AttributedString]
    var full: AttributedString
    var preview: AttributedString
    var language: String?
}

enum SyntaxText {
    /// Builds the attributed text of `code` from `runs`. Plain stretches carry no colour (the view's own applies).
    static func build(code: String, runs: [HighlightRun], theme: DSTheme = DSTheme(), previewLines: Int = CodeBlockContent.previewLines,
                      language: String? = nil) -> HighlightedCode {
        let ns = code as NSString
        var lines: [AttributedString] = []
        var line = AttributedString()
        var previewEnd: AttributedString?

        func piece(_ range: NSRange, token: SyntaxToken?) {
            // A stretch may span line breaks: split it there.
            var start = range.location
            let end = range.location + range.length
            while start < end {
                let nl = ns.range(of: "\n", options: [], range: NSRange(location: start, length: end - start))
                let stop = nl.location == NSNotFound ? end : nl.location
                if stop > start {
                    var a = AttributedString(ns.substring(with: NSRange(location: start, length: stop - start)))
                    if let token, token != .plain { a.foregroundColor = theme.syntax(token) }
                    line.append(a)
                }
                if nl.location == NSNotFound { break }
                lines.append(line)
                line = AttributedString()
                start = nl.location + 1
            }
        }

        var cursor = 0
        for run in runs where run.start >= cursor && run.end <= ns.length {
            if run.start > cursor { piece(NSRange(location: cursor, length: run.start - cursor), token: nil) }
            piece(NSRange(location: run.start, length: run.length), token: run.token)
            cursor = run.end
        }
        if cursor < ns.length { piece(NSRange(location: cursor, length: ns.length - cursor), token: nil) }
        lines.append(line)
        if code.isEmpty { lines = [] }

        func joined(_ slice: ArraySlice<AttributedString>) -> AttributedString {
            var out = AttributedString()
            for (i, l) in slice.enumerated() {
                if i > 0 { out.append(AttributedString("\n")) }
                out.append(l)
            }
            return out
        }
        previewEnd = joined(lines.prefix(previewLines))
        return HighlightedCode(lines: lines, full: joined(lines[...]), preview: previewEnd ?? AttributedString(), language: language)
    }
}

/// Finds highlights for code blocks: from the cache, or by asking the highlighter (off the main thread).
enum HighlightService {
    static let cache = HighlightCache<HighlightedCode?>(capacity: 60)

    /// What the cache already holds for a block, without any work. Nil when it is not cached (or cannot be highlighted).
    static func cachedValue(language tag: String, code: String) -> HighlightedCode? {
        guard let language = resolvedLanguage(tag: tag, code: code) else { return nil }
        return cache.value(for: HighlightCache<HighlightedCode?>.key(language: language.name ?? "", code: code)) ?? nil
    }

    /// The grammar to use (nil name: guess), or nil when the block stays plain.
    private static func resolvedLanguage(tag: String, code: String) -> (name: String?, Void)? {
        let lines = CodeBlockContent.countLines(code)
        guard HighlightLimits.allowsHighlighting(lines: lines, bytes: code.utf8.count) else { return nil }
        switch LanguageAliases.choose(tag) {
        case .plain: return nil
        case .explicit(let name): return (name, ())
        case .auto: return HighlightLimits.allowsAutoDetect(lines: lines) ? (nil, ()) : nil
        }
    }

    /// nil when the block stays plain: no language to use, too big, or the highlighter has nothing to say.
    static func highlighted(language tag: String, code: String) async -> HighlightedCode? {
        guard let resolved = resolvedLanguage(tag: tag, code: code) else { return nil }
        let language = resolved.name
        let key = HighlightCache<HighlightedCode?>.key(language: language ?? "", code: code)
        if let hit = cache.value(for: key) { return hit }
        let built = await Task.detached(priority: .utility) { () -> HighlightedCode? in
            guard let result = await SyntaxHighlighter.shared.highlight(code: code, language: language) else { return nil }
            return SyntaxText.build(code: code, runs: result.runs, language: result.language)
        }.value
        cache.store(built, for: key) // a block that cannot be highlighted is remembered too
        return built
    }

    @MainActor static func registerForPurge() { MemoryPurge.register { cache.removeAll() } }
}
