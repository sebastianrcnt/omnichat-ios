import Foundation

/// What a piece of code is, as far as colour goes. highlight.js has dozens of scopes; they fold into these.
enum SyntaxToken: String, CaseIterable, Sendable {
    case plain, keyword, string, number, comment, type, function, builtin, attribute, variable, meta, tag, addition, deletion
}

/// A stretch of the code (UTF-16 offsets) with one token. Runs are sorted and do not overlap; code between them is plain.
struct HighlightRun: Equatable, Sendable {
    var start: Int
    var length: Int
    var token: SyntaxToken
    var end: Int { start + length }
}

/// highlight.js output, as runs over the original code.
struct HighlightResult: Equatable, Sendable {
    var runs: [HighlightRun]
    /// The language that was used or detected.
    var language: String?
}

// MARK: - Languages

/// How a fence's language word is treated.
enum LanguageChoice: Equatable, Sendable {
    /// A language highlight.js knows (already normalized).
    case explicit(String)
    /// No language given: guess, for short blocks only.
    case auto
    /// Plain text, or a language there is no grammar for: leave the code alone.
    case plain
}

enum LanguageAliases {
    /// The languages in the bundled highlight.js (44).
    static let known: Set<String> = [
        "bash", "c", "cpp", "csharp", "css", "diff", "go", "graphql", "ini", "java", "javascript", "json", "kotlin", "less", "lua",
        "makefile", "markdown", "objectivec", "perl", "php", "php-template", "plaintext", "python", "python-repl", "r", "ruby",
        "rust", "scss", "shell", "sql", "swift", "typescript", "vbnet", "wasm", "xml", "yaml", "dockerfile", "scala", "haskell",
        "elixir", "dart", "powershell", "nginx", "protobuf",
    ]

    static let aliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript", "node": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python", "python3": "python", "py3": "python", "ipython": "python",
        "sh": "bash", "zsh": "bash", "shell": "bash", "console": "bash", "terminal": "bash", "fish": "bash",
        "yml": "yaml", "rb": "ruby", "rs": "rust", "golang": "go",
        "c++": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "h": "c", "h++": "cpp",
        "c#": "csharp", "cs": "csharp", "dotnet": "csharp",
        "objc": "objectivec", "obj-c": "objectivec", "objective-c": "objectivec", "mm": "objectivec",
        "kt": "kotlin", "kts": "kotlin",
        "md": "markdown", "mdx": "markdown",
        "html": "xml", "xhtml": "xml", "svg": "xml", "plist": "xml", "xsl": "xml", "rss": "xml", "htm": "xml",
        "jsonc": "json", "json5": "json", "jsonl": "json",
        "docker": "dockerfile", "ps1": "powershell", "pwsh": "powershell", "proto": "protobuf",
        "hs": "haskell", "ex": "elixir", "exs": "elixir", "vb": "vbnet", "vb.net": "vbnet",
        "toml": "ini", "conf": "ini", "cfg": "ini", "properties": "ini",
        "pgsql": "sql", "mysql": "sql", "postgres": "sql", "postgresql": "sql", "sqlite": "sql",
        "gql": "graphql", "make": "makefile", "mk": "makefile", "patch": "diff",
        "pl": "perl", "text-diff": "diff", "wat": "wasm",
    ]

    /// Tags that mean "no highlighting".
    static let plainTags: Set<String> = ["", "text", "txt", "plain", "plaintext", "none", "nohighlight", "output", "log", "raw"]

    /// The grammar for a fence's language word.
    static func choose(_ tag: String) -> LanguageChoice {
        var t = tag.lowercased().trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("language-") { t.removeFirst("language-".count) }
        if t.hasPrefix("lang-") { t.removeFirst("lang-".count) }
        if t.isEmpty { return .auto }
        if plainTags.contains(t) { return .plain }
        let name = aliases[t] ?? t
        return known.contains(name) && name != "plaintext" ? .explicit(name) : .plain
    }

    /// What auto-detection chooses between: the languages that turn up in chat, without the ones (css, yaml, markdown)
    /// that highlight.js mistakes for code in other languages.
    static let autoSubset = ["swift", "python", "javascript", "typescript", "json", "bash", "java", "kotlin", "c", "cpp", "csharp",
                             "go", "rust", "ruby", "php", "sql", "xml"]
    /// A guess below this relevance is not trusted: the block stays plain.
    static let autoMinimumRelevance = 5.0
}

/// How much code is highlighted.
enum HighlightLimits {
    /// Guessing the language costs more than a named grammar: only for blocks shorter than this many lines.
    static let autoDetectLines = 200
    /// Above these the block stays plain.
    static let maxLines = 3000
    static let maxBytes = 200 * 1024

    static func allowsHighlighting(lines: Int, bytes: Int) -> Bool { lines <= maxLines && bytes <= maxBytes }
    static func allowsAutoDetect(lines: Int) -> Bool { lines < autoDetectLines }
}

// MARK: - Scopes

enum SyntaxScopes {
    /// The token for the classes of a highlight.js span (`hljs-title function_`), or nil when the span has no colour of
    /// its own and the one around it applies.
    static func token(classes: [String]) -> SyntaxToken? {
        let names = classes.map { $0.hasPrefix("hljs-") ? String($0.dropFirst(5)) : $0 }
        guard let base = names.first else { return nil }
        let rest = Set(names.dropFirst().map { $0.hasSuffix("_") ? String($0.dropLast()) : $0 })
        switch base {
        case "keyword", "literal", "doctag", "selector-tag": return .keyword
        case "built_in", "builtin-name": return .builtin
        case "string", "regexp", "char", "link": return .string
        case "subst": return .plain
        case "number", "symbol", "bullet": return .number
        case "comment", "quote": return .comment
        case "title":
            if rest.contains("class") { return .type }
            return .function
        case "type", "class": return .type
        case "section": return .function
        case "attr", "attribute", "property", "selector-attr", "selector-class", "selector-id", "selector-pseudo": return .attribute
        case "variable", "template-variable": return .variable
        case "params": return .plain
        case "name", "tag": return .tag
        case "meta", "meta-keyword", "meta-string": return .meta
        case "addition": return .addition
        case "deletion": return .deletion
        default: return nil
        }
    }
}

// MARK: - highlight.js output

/// Turns highlight.js's HTML (`<span class="hljs-keyword">let</span>`, entities escaped) into the plain text and runs.
enum HighlightHTML {
    static func parse(_ html: String) -> (text: String, runs: [HighlightRun]) {
        var text = String.UnicodeScalarView()
        var runs: [HighlightRun] = []
        var stack: [SyntaxToken?] = []
        var offset = 0
        var current: SyntaxToken?

        func emit(_ scalar: Unicode.Scalar) {
            text.append(scalar)
            let n = scalar.utf16.count
            if let token = current, token != .plain {
                if var last = runs.last, last.token == token, last.end == offset {
                    last.length += n
                    runs[runs.count - 1] = last
                } else {
                    runs.append(HighlightRun(start: offset, length: n, token: token))
                }
            }
            offset += n
        }

        var it = html.unicodeScalars.makeIterator()
        while let s = it.next() {
            switch s {
            case "<":
                var tag = ""
                while let c = it.next(), c != ">" { tag.unicodeScalars.append(c) }
                if tag.hasPrefix("span") {
                    stack.append(spanToken(tag))
                    current = stack.last(where: { $0 != nil }) ?? nil
                } else if tag.hasPrefix("/span") {
                    if !stack.isEmpty { stack.removeLast() }
                    current = stack.last(where: { $0 != nil }) ?? nil
                }
            case "&":
                var entity = ""
                var closed = false
                while entity.count < 10, let c = it.next() {
                    if c == ";" { closed = true; break }
                    entity.unicodeScalars.append(c)
                }
                if closed, let decoded = decode(entity) {
                    emit(decoded)
                } else {
                    emit("&")
                    for c in entity.unicodeScalars { emit(c) }
                    if closed { emit(";") }
                }
            default:
                emit(s)
            }
        }
        return (String(text), runs)
    }

    private static func spanToken(_ tag: String) -> SyntaxToken? {
        guard let r = tag.range(of: "class=\"") else { return nil }
        let value = tag[r.upperBound...].prefix { $0 != "\"" }
        return SyntaxScopes.token(classes: value.split(separator: " ").map(String.init))
    }

    private static func decode(_ entity: String) -> Unicode.Scalar? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let v = UInt32(entity.dropFirst(2), radix: 16) { return Unicode.Scalar(v) }
            if entity.hasPrefix("#"), let v = UInt32(entity.dropFirst()) { return Unicode.Scalar(v) }
            return nil
        }
    }
}

// MARK: - Palette

/// Colours per token, as 0xRRGGBB for light and dark. The code surface is 0xF3F3F5 (light) and 0x1E1E1E (dark).
enum SyntaxPalette {
    static let light: [SyntaxToken: UInt32] = [
        .keyword: 0xCF222E, .string: 0x0A3069, .number: 0x0550AE, .comment: 0x636C76, .type: 0x953800, .function: 0x8250DF,
        .builtin: 0x0550AE, .attribute: 0x116329, .variable: 0x953800, .meta: 0x6639BA, .tag: 0x116329,
        .addition: 0x116329, .deletion: 0x82071E,
    ]
    static let dark: [SyntaxToken: UInt32] = [
        .keyword: 0xFF7B72, .string: 0xA5D6FF, .number: 0x79C0FF, .comment: 0x8B949E, .type: 0xFFA657, .function: 0xD2A8FF,
        .builtin: 0x79C0FF, .attribute: 0x7EE787, .variable: 0xFFA657, .meta: 0xD2A8FF, .tag: 0x7EE787,
        .addition: 0x7EE787, .deletion: 0xFFA198,
    ]
    static let lightSurface: UInt32 = 0xF3F3F5
    static let darkSurface: UInt32 = 0x1E1E1E

    /// WCAG contrast ratio of two colours.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ v: UInt32) -> Double {
            func channel(_ c: UInt32) -> Double {
                let x = Double(c) / 255
                return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel((v >> 16) & 0xFF) + 0.7152 * channel((v >> 8) & 0xFF) + 0.0722 * channel(v & 0xFF)
        }
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
