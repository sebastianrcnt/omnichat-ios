import Foundation

// OpenUI Lang (openui.com, MIT): the language only. Lexer, statement splitter, expression parser and the streaming
// parser that keeps completed statements. Spec 1.0, language.md sections 1 and 4. Rendering is ours (`OpenUIViews`).

// MARK: - Tokens

enum OUIToken: Equatable, Sendable {
    /// A name: a reference (lowercase) or a component (uppercase). `true`, `false` and `null` too.
    case ident(String)
    /// `$name`, with the `$`.
    case state(String)
    /// `@Name`, without the `@`.
    case function(String)
    case string(String)
    case number(Double)
    /// Operators and punctuation: `==`, `(`, `,` ...
    case op(String)
    case newline

    /// A token after which `-` is subtraction, not the sign of a number.
    var isValue: Bool {
        switch self {
        case .ident, .state, .string, .number: true
        case .op(let o): o == ")" || o == "]"
        default: false
        }
    }
}

/// Lexing never fails: unknown characters are skipped, an unterminated string is closed.
enum OUILexer {
    struct Result: Equatable, Sendable {
        var tokens: [OUIToken]
        /// The text ended inside a string.
        var incomplete: Bool
    }

    static func lex(_ text: String) -> Result {
        let s = Array(text.unicodeScalars)
        var i = 0
        var tokens: [OUIToken] = []
        var incomplete = false

        func isIdentStart(_ c: Unicode.Scalar) -> Bool { c == "_" || (c.isASCII && c.properties.isAlphabetic) }
        func isIdent(_ c: Unicode.Scalar) -> Bool { isIdentStart(c) || isDigit(c) }
        func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
        func peek(_ k: Int) -> Unicode.Scalar? { i + k < s.count ? s[i + k] : nil }

        while i < s.count {
            let c = s[i]
            if c == " " || c == "\t" || c == "\r" { i += 1; continue }
            if c == "\n" { tokens.append(.newline); i += 1; continue }
            // Comments run to the end of the line.
            if c == "#" || (c == "/" && peek(1) == "/") {
                while i < s.count, s[i] != "\n" { i += 1 }
                continue
            }
            if c == "\"" || c == "'" {
                let (value, end, closed) = readString(s, from: i)
                tokens.append(.string(value))
                if !closed { incomplete = true }
                i = end
                continue
            }
            if isDigit(c) || (c == "-" && peek(1).map(isDigit) == true && !(tokens.last?.isValue ?? false)) {
                var j = i
                if s[j] == "-" { j += 1 }
                while j < s.count, isDigit(s[j]) { j += 1 }
                if j + 1 < s.count, s[j] == ".", isDigit(s[j + 1]) {
                    j += 1
                    while j < s.count, isDigit(s[j]) { j += 1 }
                }
                if j < s.count, s[j] == "e" || s[j] == "E" {
                    j += 1
                    if j < s.count, s[j] == "+" || s[j] == "-" { j += 1 }
                    while j < s.count, isDigit(s[j]) { j += 1 }
                }
                let raw = String(String.UnicodeScalarView(s[i..<j]))
                tokens.append(.number(Double(raw) ?? Double(raw.prefix { $0 != "e" && $0 != "E" }) ?? 0))
                i = j
                continue
            }
            if isIdentStart(c) {
                var j = i
                while j < s.count, isIdent(s[j]) { j += 1 }
                tokens.append(.ident(String(String.UnicodeScalarView(s[i..<j]))))
                i = j
                continue
            }
            if (c == "$" || c == "@"), let n = peek(1), isIdentStart(n) {
                var j = i + 1
                while j < s.count, isIdent(s[j]) { j += 1 }
                let name = String(String.UnicodeScalarView(s[(i + 1)..<j]))
                tokens.append(c == "$" ? .state("$" + name) : .function(name))
                i = j
                continue
            }
            let two = peek(1).map { String(c) + String($0) }
            if let two, ["==", "!=", ">=", "<=", "&&", "||"].contains(two) {
                tokens.append(.op(two))
                i += 2
                continue
            }
            switch c {
            case "&": tokens.append(.op("&&"))
            case "|": tokens.append(.op("||"))
            case "=", ">", "<", "+", "-", "*", "/", "%", "!", "?", ":", ".", ",", "(", ")", "[", "]", "{", "}":
                tokens.append(.op(String(c)))
            default: break // skipped: `a;b` lexes as `a` and `b`
            }
            i += 1
        }
        return Result(tokens: tokens, incomplete: incomplete)
    }

    /// A string literal starting at `start` (its quote). Double quotes take JSON escapes; single quotes `\'`, `\\`,
    /// `\n` and `\t`. Unterminated: closed at the end, a dangling `\` kept as a backslash.
    private static func readString(_ s: [Unicode.Scalar], from start: Int) -> (String, Int, Bool) {
        let quote = s[start]
        var out = String.UnicodeScalarView()
        var i = start + 1
        while i < s.count {
            let c = s[i]
            if c == quote { return (String(out), i + 1, true) }
            if c == "\\" {
                guard i + 1 < s.count else { out.append("\\"); return (String(out), s.count, false) }
                let e = s[i + 1]
                i += 2
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                case "'": out.append("'")
                case "\"": out.append("\"")
                case "r" where quote == "\"": out.append("\r")
                case "b" where quote == "\"": out.append("\u{8}")
                case "f" where quote == "\"": out.append("\u{C}")
                case "/" where quote == "\"": out.append("/")
                case "u" where quote == "\"":
                    let hex = String(String.UnicodeScalarView(s[i..<min(i + 4, s.count)]))
                    if hex.count == 4, let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) {
                        out.append(scalar)
                        i += 4
                    } else {
                        out.append("u")
                    }
                default:
                    if quote == "'" { out.append("\\") }
                    out.append(e)
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return (String(out), s.count, false)
    }
}

// MARK: - Syntax tree

/// An object literal's entries, in source order.
struct OUIEntry: Equatable, Sendable {
    var key: String
    var value: OUIExpr
}

/// A call argument: positional, or `name: value` (not OpenUI Lang, but models write it; mapped by prop name).
struct OUIArgument: Equatable, Sendable {
    var label: String?
    var value: OUIExpr
}

indirect enum OUIExpr: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([OUIExpr])
    case object([OUIEntry])
    /// A statement name (any case; a bare identifier is always a reference).
    case ref(String)
    /// `$name`.
    case state(String)
    /// `Name(args)`: a component, or the reserved `Query`, `Mutation`, `Action`.
    case call(String, [OUIArgument])
    /// `@Name(args)`: a built-in, an action, or an unknown function.
    case function(String, [OUIArgument])
    case binary(String, OUIExpr, OUIExpr)
    case unary(String, OUIExpr)
    case ternary(OUIExpr, OUIExpr, OUIExpr)
    case member(OUIExpr, String)
    case index(OUIExpr, OUIExpr)
    /// `$name = value` inside an expression (two-way binding). Parsed; evaluates to the value.
    case assign(String, OUIExpr)
}

struct OUIStatement: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case value, state, query, mutation }

    var name: String
    var expr: OUIExpr
    var kind: Kind
    /// The statement's source, for error reports.
    var source: String
}

// MARK: - Expression parser

/// Pratt-style parser over one statement's tokens. Lenient: EOF closes whatever is open, a mismatched closing bracket
/// is skipped, and an unexpected token is recorded and skipped.
struct OUIParser {
    /// Built-ins that need `@`: `Count(x)` is the reference `Count` and its arguments are dropped (spec 1.5).
    static let builtins: Set<String> = ["Count", "First", "Last", "Sum", "Avg", "Min", "Max", "Filter", "Sort",
                                        "Round", "Abs", "Floor", "Ceil", "Each"]

    private let tokens: [OUIToken]
    private var pos = 0
    private(set) var problems: [String] = []

    init(tokens: [OUIToken]) { self.tokens = tokens.filter { $0 != .newline } }

    /// `name = expression`, or nil when the tokens don't have that shape (such a line is skipped without an error).
    static func statement(_ source: String) -> (statement: OUIStatement?, problems: [String]) {
        let lexed = OUILexer.lex(source)
        var parser = OUIParser(tokens: lexed.tokens)
        guard let head = parser.peek, parser.peek(1) == .op("=") else { return (nil, []) }
        let name: String
        switch head {
        case .ident(let n) where !["true", "false", "null"].contains(n): name = n
        case .state(let n): name = n
        default: return (nil, [])
        }
        parser.pos = 2
        guard parser.peek != nil else { return (nil, ["\(name): no value"]) }
        let expr = parser.expression()
        let kind: OUIStatement.Kind
        switch expr {
        case .call("Query", _): kind = .query
        case .call("Mutation", _): kind = .mutation
        default: kind = name.hasPrefix("$") ? .state : .value
        }
        return (OUIStatement(name: name, expr: expr, kind: kind, source: source), parser.problems)
    }

    /// Parses a whole expression (tests and `@Each` templates use this directly).
    static func expression(_ source: String) -> OUIExpr {
        var parser = OUIParser(tokens: OUILexer.lex(source).tokens)
        return parser.expression()
    }

    private var peek: OUIToken? { pos < tokens.count ? tokens[pos] : nil }
    private func peek(_ k: Int) -> OUIToken? { pos + k < tokens.count ? tokens[pos + k] : nil }
    private mutating func advance() { pos += 1 }
    private mutating func eat(_ op: String) -> Bool {
        if peek == .op(op) { advance(); return true }
        return false
    }

    mutating func expression() -> OUIExpr { ternary() }

    private mutating func ternary() -> OUIExpr {
        let condition = binary(level: 0)
        guard eat("?") else { return condition }
        let yes = peek == nil ? OUIExpr.null : ternary()
        let no = eat(":") && peek != nil ? ternary() : .null
        return .ternary(condition, yes, no)
    }

    private static let levels: [[String]] = [["||"], ["&&"], ["==", "!="], [">", "<", ">=", "<="], ["+", "-"], ["*", "/", "%"]]

    private mutating func binary(level: Int) -> OUIExpr {
        guard level < Self.levels.count else { return unary() }
        var left = binary(level: level + 1)
        while case .op(let o)? = peek, Self.levels[level].contains(o) {
            advance()
            guard peek != nil else { break }
            left = .binary(o, left, binary(level: level + 1))
        }
        return left
    }

    private mutating func unary() -> OUIExpr {
        if case .op(let o)? = peek, o == "!" || o == "-" {
            advance()
            return .unary(o, unary())
        }
        return postfix(primary())
    }

    private mutating func postfix(_ base: OUIExpr) -> OUIExpr {
        var e = base
        while true {
            if peek == .op("."), let field = fieldName(peek(1)) {
                pos += 2
                e = .member(e, field)
            } else if peek == .op("[") {
                advance()
                let index = expression()
                _ = eat("]")
                e = .index(e, index)
            } else {
                return e
            }
        }
    }

    /// Field and object-key tokens: names, strings, numbers, component names, `$` names (the `$` dropped).
    private func fieldName(_ token: OUIToken?) -> String? {
        switch token {
        case .ident(let n): n
        case .string(let s): s
        case .number(let d): Self.numberKey(d)
        case .state(let n): String(n.dropFirst())
        default: nil
        }
    }

    static func numberKey(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
    }

    private mutating func primary() -> OUIExpr {
        guard let token = peek else { return .null }
        advance()
        switch token {
        case .string(let s): return .string(s)
        case .number(let d): return .number(d)
        case .state(let name):
            // `$x = value` inside an expression: a binding assignment.
            if peek == .op("=") {
                advance()
                return .assign(name, expression())
            }
            return .state(name)
        case .function(let name):
            guard eat("(") else { return .function(name, []) }
            return .function(name, arguments(close: ")"))
        case .ident(let name):
            switch name {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: break
            }
            guard peek == .op("(") else { return .ref(name) }
            let isComponent = name.first.map { $0.isUppercase } ?? false
            if !isComponent || Self.builtins.contains(name) {
                // `count(x)` / `Count(x)`: a reference; the arguments are lost.
                advance()
                _ = arguments(close: ")")
                return .ref(name)
            }
            advance()
            return .call(name, arguments(close: ")"))
        case .op("["):
            return .array(arguments(close: "]").map(\.value))
        case .op("{"):
            return object()
        case .op("("):
            let inner = expression()
            _ = eat(")")
            return inner
        case .op(let o):
            problems.append("Unexpected \(o)")
            return .null
        case .newline:
            return .null
        }
    }

    /// Elements up to `close`; commas optional, trailing commas ignored, EOF closes. `label:` before an element of a
    /// call makes it a named argument.
    private mutating func arguments(close: String) -> [OUIArgument] {
        var out: [OUIArgument] = []
        while let token = peek {
            if token == .op(close) { advance(); return out }
            if token == .op(",") { advance(); continue }
            if case .op(let o) = token, [")", "]", "}"].contains(o) {
                advance() // a closing bracket that doesn't match: skipped
                continue
            }
            if case .op(let o) = token, [":", "=", "?"].contains(o) {
                problems.append("Unexpected \(o)")
                advance()
                continue
            }
            var label: String?
            if close == ")", case .ident(let n) = token, peek(1) == .op(":") {
                label = n
                pos += 2
            }
            let start = pos
            let value = expression()
            out.append(OUIArgument(label: label, value: value))
            if pos == start { advance() } // never stall
        }
        return out
    }

    private mutating func object() -> OUIExpr {
        var entries: [OUIEntry] = []
        while let token = peek {
            if token == .op("}") { advance(); break }
            if token == .op(",") { advance(); continue }
            if case .op(let o) = token, o == ")" || o == "]" { advance(); continue }
            let key = fieldName(token) ?? "?"
            advance()
            if !eat(":") {
                // `{a}` or a stray token: no value.
                entries.append(OUIEntry(key: key, value: .null))
                continue
            }
            let start = pos
            entries.append(OUIEntry(key: key, value: expression()))
            if pos == start { advance() }
        }
        return .object(entries)
    }
}

// MARK: - Statement boundaries

/// Finds where statements end in source text (spec 1.4): a newline at bracket depth zero, outside a string, while no
/// ternary is open and the next line doesn't start with `?`.
enum OUISplitter {
    struct Piece: Equatable, Sendable {
        /// UTF-8 offsets into the scanned text.
        var start: Int
        var end: Int
        /// Ended by a newline whose next non-blank character has arrived and is not `?`.
        var complete: Bool
    }

    /// Splits `bytes[from...]`. All but the last piece are complete; the last is complete only when its end is
    /// confirmed by later text.
    static func split(_ bytes: [UInt8], from: Int = 0) -> [Piece] {
        var pieces: [Piece] = []
        var start = from
        var i = from
        var depth = 0
        var quote: UInt8 = 0
        var questions = 0
        var colons = 0
        var lastSignificant: UInt8 = 0
        let n = bytes.count

        func reset() { depth = 0; questions = 0; colons = 0; lastSignificant = 0 }

        while i < n {
            let c = bytes[i]
            if quote != 0 {
                if c == UInt8(ascii: "\\") { i += 2; continue }
                if c == quote { quote = 0; lastSignificant = c }
                i += 1
                continue
            }
            switch c {
            case UInt8(ascii: "\""), UInt8(ascii: "'"):
                quote = c
            case UInt8(ascii: "#"):
                while i < n, bytes[i] != UInt8(ascii: "\n") { i += 1 }
                continue
            case UInt8(ascii: "/") where i + 1 < n && bytes[i + 1] == UInt8(ascii: "/"):
                while i < n, bytes[i] != UInt8(ascii: "\n") { i += 1 }
                continue
            case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                lastSignificant = c
            case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth = max(0, depth - 1)
                lastSignificant = c
            case UInt8(ascii: "?") where depth == 0:
                questions += 1
                lastSignificant = c
            case UInt8(ascii: ":") where depth == 0:
                colons += 1
                lastSignificant = c
            case UInt8(ascii: "\n"):
                if depth == 0 {
                    let ternaryOpen = questions > colons || lastSignificant == UInt8(ascii: "?") || lastSignificant == UInt8(ascii: ":")
                    if !ternaryOpen {
                        // The next line decides: a leading `?` continues the statement.
                        var j = i + 1
                        while j < n, [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n")].contains(bytes[j]) { j += 1 }
                        if j < n {
                            if bytes[j] != UInt8(ascii: "?") {
                                pieces.append(Piece(start: start, end: i, complete: true))
                                start = i + 1
                                reset()
                            }
                        } else {
                            // Nothing after it yet: provisionally ended.
                            pieces.append(Piece(start: start, end: i, complete: false))
                            return pieces
                        }
                    }
                }
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"):
                break
            default:
                lastSignificant = c
            }
            i += 1
        }
        if start < n { pieces.append(Piece(start: start, end: n, complete: false)) }
        return pieces
    }
}

// MARK: - Streaming parser

/// Parses a program as it streams in. Completed statements are parsed once and never change; the pending tail is
/// parsed again on each update (spec section 4). If the text no longer starts with what was completed, it starts over.
struct OUIStreamParser: Sendable {
    private(set) var completed: [OUIStatement] = []
    /// Statements dropped because they didn't parse, with the reason.
    private(set) var completedProblems: [String] = []
    private var consumed: [UInt8] = []
    private(set) var pendingSource = ""

    init() {}

    /// Feeds the whole program text so far (not a delta).
    mutating func update(_ text: String) {
        let bytes = Array(text.utf8)
        if bytes.count < consumed.count || !bytes.starts(with: consumed) { self = OUIStreamParser() }
        let pieces = OUISplitter.split(bytes, from: consumed.count)
        var cut = consumed.count
        for piece in pieces where piece.complete {
            add(String(decoding: bytes[piece.start..<piece.end], as: UTF8.self))
            cut = min(bytes.count, piece.end + 1)
        }
        consumed = Array(bytes[..<cut])
        pendingSource = String(decoding: bytes[cut...], as: UTF8.self)
    }

    private mutating func add(_ source: String) {
        guard !source.allSatisfy({ $0.isWhitespace }) else { return }
        let (statement, problems) = OUIParser.statement(source)
        if let statement {
            completed.append(statement)
            completedProblems.append(contentsOf: problems.map { "\(statement.name): \($0)" })
        } else if Self.looksLikeCode(source) {
            completedProblems.append("Skipped: \(source.prefix(60))")
        }
    }

    /// The pending tail, closed implicitly (unterminated strings and brackets end with the text), and its problems.
    var pending: (statements: [OUIStatement], problems: [String]) {
        let bytes = Array(pendingSource.utf8)
        var statements: [OUIStatement] = []
        var problems: [String] = []
        for piece in OUISplitter.split(bytes) {
            let source = String(decoding: bytes[piece.start..<piece.end], as: UTF8.self)
            guard !source.allSatisfy({ $0.isWhitespace }) else { continue }
            let (statement, found) = OUIParser.statement(source)
            if let statement {
                statements.append(statement)
                problems.append(contentsOf: found.map { "\(statement.name): \($0)" })
            } else if Self.looksLikeCode(source) {
                problems.append("Skipped: \(source.prefix(60))")
            }
        }
        return (statements, problems)
    }

    /// Completed statements, plus the tail when the stream has ended (`final`).
    func statements(final: Bool) -> [OUIStatement] {
        final ? completed + pending.statements : completed
    }

    func problems(final: Bool) -> [String] {
        final ? completedProblems + pending.problems : completedProblems
    }

    /// A non-blank line that isn't a statement only counts as a problem when it looks like code, not prose.
    private static func looksLikeCode(_ source: String) -> Bool {
        source.contains("(") || source.contains("=")
    }

    /// One-shot parse of a finished program.
    static func parse(_ text: String) -> [OUIStatement] {
        var parser = OUIStreamParser()
        parser.update(text)
        return parser.statements(final: true)
    }
}
