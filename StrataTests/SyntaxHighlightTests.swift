import Testing
import Foundation
import SwiftUI
@testable import Strata

struct LanguageAliasTests {
    @Test func commonAliasesMapToTheirGrammar() {
        let expected: [String: String] = [
            "js": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript", "py": "python", "sh": "bash",
            "zsh": "bash", "shell": "bash", "console": "bash", "yml": "yaml", "rb": "ruby", "rs": "rust", "c++": "cpp",
            "c#": "csharp", "objc": "objectivec", "kt": "kotlin", "golang": "go", "md": "markdown", "html": "xml",
            "jsonc": "json", "toml": "ini", "docker": "dockerfile", "ps1": "powershell", "hs": "haskell", "proto": "protobuf",
        ]
        for (tag, name) in expected { #expect(LanguageAliases.choose(tag) == .explicit(name), "\(tag)") }
    }

    @Test func namesAreCaseInsensitiveAndMayCarryAPrefix() {
        #expect(LanguageAliases.choose("Swift") == .explicit("swift"))
        #expect(LanguageAliases.choose("PYTHON") == .explicit("python"))
        #expect(LanguageAliases.choose("language-js") == .explicit("javascript"))
        #expect(LanguageAliases.choose(" go ") == .explicit("go"))
    }

    @Test func noLanguageMeansGuessAndPlainTagsMeanPlain() {
        #expect(LanguageAliases.choose("") == .auto)
        for tag in ["text", "txt", "plaintext", "plain", "none", "output", "log"] { #expect(LanguageAliases.choose(tag) == .plain, "\(tag)") }
    }

    @Test func aLanguageWithoutAGrammarStaysPlain() {
        for tag in ["mermaid", "brainfuck", "unknownlang", "vue"] { #expect(LanguageAliases.choose(tag) == .plain, "\(tag)") }
    }

    @Test func everyAliasTargetHasAGrammar() {
        for (alias, name) in LanguageAliases.aliases { #expect(LanguageAliases.known.contains(name), "\(alias) -> \(name)") }
        #expect(LanguageAliases.autoSubset.allSatisfy { LanguageAliases.known.contains($0) })
    }
}

struct HighlightHTMLTests {
    @Test func spansBecomeRunsOverThePlainText() {
        let html = #"<span class="hljs-keyword">let</span> x <span class="hljs-operator">=</span> <span class="hljs-number">1</span> <span class="hljs-comment">// done</span>"#
        let (text, runs) = HighlightHTML.parse(html)
        #expect(text == "let x = 1 // done")
        #expect(runs == [
            HighlightRun(start: 0, length: 3, token: .keyword),
            HighlightRun(start: 8, length: 1, token: .number),
            HighlightRun(start: 10, length: 7, token: .comment),
        ]) // the operator span has no colour of its own
    }

    @Test func entitiesAreDecoded() {
        let html = #"<span class="hljs-string">&quot;a &lt; b &amp;&amp; c&quot;</span> &#x27;x&#x27; &#39;y&#39; &gt;"#
        let (text, runs) = HighlightHTML.parse(html)
        #expect(text == "\"a < b && c\" 'x' 'y' >")
        #expect(runs == [HighlightRun(start: 0, length: 12, token: .string)])
    }

    @Test func theInnermostScopeWinsAndTheOuterOneFillsTheGaps() {
        let html = #"<span class="hljs-meta"><span class="hljs-keyword">#include</span> <span class="hljs-string">&lt;stdio.h&gt;</span></span>"#
        let (text, runs) = HighlightHTML.parse(html)
        #expect(text == "#include <stdio.h>")
        #expect(runs == [
            HighlightRun(start: 0, length: 8, token: .keyword),
            HighlightRun(start: 8, length: 1, token: .meta),
            HighlightRun(start: 9, length: 9, token: .string),
        ])
    }

    @Test func compoundTitlesBecomeFunctionsAndTypes() {
        let html = #"<span class="hljs-title function_">run</span>() <span class="hljs-title class_">Foo</span> <span class="hljs-title class_ inherited__">Bar</span>"#
        let (_, runs) = HighlightHTML.parse(html)
        #expect(runs.map(\.token) == [.function, .type, .type])
    }

    @Test func interpolationInsideAStringIsPlainAgain() {
        let html = #"<span class="hljs-string">"a<span class="hljs-subst">${x}</span>b"</span>"#
        let (text, runs) = HighlightHTML.parse(html)
        #expect(text == "\"a${x}b\"")
        #expect(runs == [HighlightRun(start: 0, length: 2, token: .string), HighlightRun(start: 6, length: 2, token: .string)])
    }

    @Test func offsetsCountUTF16UnitsSoEmojiAndKoreanLineUp() {
        let html = #"<span class="hljs-comment">// 😀한</span> <span class="hljs-keyword">let</span>"#
        let (text, runs) = HighlightHTML.parse(html)
        #expect(text == "// 😀한 let")
        let ns = text as NSString
        for r in runs { #expect(ns.substring(with: NSRange(location: r.start, length: r.length)) == (r.token == .keyword ? "let" : "// 😀한")) }
    }

    @Test func adjacentSpansOfOneTokenMerge() {
        let (_, runs) = HighlightHTML.parse(#"<span class="hljs-keyword">a</span><span class="hljs-keyword">b</span>"#)
        #expect(runs == [HighlightRun(start: 0, length: 2, token: .keyword)])
    }

    @Test func aStrayAmpersandSurvives() {
        let (text, _) = HighlightHTML.parse("a & b &unknown; c")
        #expect(text == "a & b &unknown; c")
    }

    @Test func scopesMapToTokens() {
        #expect(SyntaxScopes.token(classes: ["hljs-keyword"]) == .keyword)
        #expect(SyntaxScopes.token(classes: ["hljs-literal"]) == .keyword)
        #expect(SyntaxScopes.token(classes: ["hljs-built_in"]) == .builtin)
        #expect(SyntaxScopes.token(classes: ["hljs-attr"]) == .attribute)
        #expect(SyntaxScopes.token(classes: ["hljs-name"]) == .tag)
        #expect(SyntaxScopes.token(classes: ["hljs-addition"]) == .addition)
        #expect(SyntaxScopes.token(classes: ["hljs-operator"]) == nil)
        #expect(SyntaxScopes.token(classes: []) == nil)
    }
}

struct HighlightLimitTests {
    @Test func limits() {
        #expect(HighlightLimits.allowsAutoDetect(lines: 199))
        #expect(!HighlightLimits.allowsAutoDetect(lines: 200))
        #expect(HighlightLimits.allowsHighlighting(lines: 3000, bytes: 1000))
        #expect(!HighlightLimits.allowsHighlighting(lines: 3001, bytes: 1000))
        #expect(HighlightLimits.allowsHighlighting(lines: 10, bytes: 200 * 1024))
        #expect(!HighlightLimits.allowsHighlighting(lines: 10, bytes: 200 * 1024 + 1))
    }
}

struct SyntaxPaletteTests {
    @Test func everyColourReadsOnTheCodeSurface() {
        for token in SyntaxToken.allCases where token != .plain {
            let light = SyntaxPalette.light[token], dark = SyntaxPalette.dark[token]
            #expect(light != nil && dark != nil, "\(token)")
            if let light { #expect(SyntaxPalette.contrast(light, SyntaxPalette.lightSurface) >= 4.5, "light \(token)") }
            if let dark { #expect(SyntaxPalette.contrast(dark, SyntaxPalette.darkSurface) >= 4.5, "dark \(token)") }
        }
    }

    @Test func plainHasNoColourOfItsOwn() {
        #expect(SyntaxPalette.light[.plain] == nil && SyntaxPalette.dark[.plain] == nil) // the view's text colour applies
    }
}

struct SyntaxTextTests {
    @Test func linesMatchTheCodeAndKeepItsText() {
        let code = "let a = 1\n\nprint(a) // hi\n"
        let runs = [HighlightRun(start: 0, length: 3, token: .keyword), HighlightRun(start: 12, length: 5, token: .builtin)]
        let h = SyntaxText.build(code: code, runs: runs)
        #expect(h.lines.map { String($0.characters) } == code.components(separatedBy: "\n"))
        #expect(String(h.full.characters) == code)
    }

    @Test func aRunThatSpansLinesIsSplitAtTheBreaks() {
        let code = "/* one\ntwo */ x"
        let h = SyntaxText.build(code: code, runs: [HighlightRun(start: 0, length: 13, token: .comment)])
        #expect(h.lines.map { String($0.characters) } == ["/* one", "two */ x"])
        let colours = h.lines.map { line in line.runs.compactMap(\.foregroundColor) }
        #expect(colours[0].count == 1 && colours[1].count == 1) // each line has its coloured stretch
    }

    @Test func thePreviewIsTheFirstLines() {
        let code = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let h = SyntaxText.build(code: code, runs: [])
        #expect(String(h.preview.characters) == (1...12).map { "line \($0)" }.joined(separator: "\n"))
    }

    @Test func emptyCodeHasNoLines() {
        #expect(SyntaxText.build(code: "", runs: []).lines.isEmpty)
    }
}

struct HighlightCacheTests {
    @Test func keysDependOnLanguageAndCode() {
        let a = HighlightCache<Int>.key(language: "swift", code: "let a = 1")
        #expect(a == HighlightCache<Int>.key(language: "swift", code: "let a = 1"))
        #expect(a != HighlightCache<Int>.key(language: "python", code: "let a = 1"))
        #expect(a != HighlightCache<Int>.key(language: "swift", code: "let a = 2"))
        #expect(a != HighlightCache<Int>.key(language: "swif", code: "tlet a = 1")) // the boundary matters
    }

    @Test func itRemembersAndEvictsTheLeastRecentlyUsed() {
        let cache = HighlightCache<Int>(capacity: 2)
        cache.store(1, for: "a"); cache.store(2, for: "b")
        #expect(cache.value(for: "a") == 1) // a is now the most recent
        cache.store(3, for: "c")
        #expect(cache.value(for: "b") == nil && cache.value(for: "a") == 1 && cache.value(for: "c") == 3)
        #expect(cache.count == 2)
        cache.removeAll()
        #expect(cache.count == 0)
    }
}

/// highlight.js itself, from the app bundle.
@MainActor
@Suite(.serialized)
struct SyntaxHighlighterTests {
    private func highlighted(_ language: String, _ code: String) async -> HighlightedCode? {
        await HighlightService.highlighted(language: language, code: code)
    }

    @Test func theLibraryIsBundled() {
        let source = SyntaxHighlighter.librarySource()
        #expect(source?.contains("Highlight.js v11.") == true)
    }

    @Test func swiftGetsKeywordsAndNumbers() async throws {
        let code = "let answer = 42 // the answer\nfunc f() {}"
        let result = try #require(await SyntaxHighlighter.shared.highlight(code: code, language: "swift"))
        let ns = code as NSString
        func tokens(_ t: SyntaxToken) -> [String] {
            result.runs.filter { $0.token == t }.map { ns.substring(with: NSRange(location: $0.start, length: $0.length)) }
        }
        #expect(tokens(.keyword).contains("let") && tokens(.keyword).contains("func"))
        #expect(tokens(.number) == ["42"])
        #expect(tokens(.comment) == ["// the answer"])
        #expect(result.language == "swift")
    }

    @Test func theTextIsAlwaysTheOriginalCode() async throws {
        let samples: [(String, String)] = [
            ("python", "def f(x):\n    return \"a<b\" + '&'\n"),
            ("json", #"{"a": [1, 2, {"b": null}], "c": "x"}"#),
            ("bash", "echo \"$HOME\" | grep -v '#'"),
            ("xml", "<a href=\"x\">t &amp; u</a>"),
            ("swift", "let s = \"한국어 😀\""),
        ]
        for (language, code) in samples {
            let h = try #require(await highlighted(language, code), "\(language)")
            #expect(String(h.full.characters) == code, "\(language)")
            #expect(h.lines.count == code.components(separatedBy: "\n").count, "\(language)")
        }
    }

    @Test func aliasesReachTheRightGrammar() async throws {
        let h = try #require(await highlighted("py", "def f():\n    return 1"))
        #expect(h.language == "python")
        let js = try #require(await highlighted("tsx", "const x: number = 1"))
        #expect(js.language == "typescript")
    }

    @Test func aSecondRequestForTheSameCodeIsACacheHit() async throws {
        let code = "let unique\(UUID().uuidString.prefix(6).filter(\.isLetter)) = 1"
        let before = await SyntaxHighlighter.shared.runCount
        let first = try #require(await highlighted("swift", code))
        let mid = await SyntaxHighlighter.shared.runCount
        let second = try #require(await highlighted("swift", code))
        let after = await SyntaxHighlighter.shared.runCount
        #expect(mid == before + 1 && after == mid) // not highlighted again
        #expect(first == second)
        #expect(HighlightService.cachedValue(language: "swift", code: code) == first) // the viewer finds it too
        // The same code under another language is its own entry.
        _ = await highlighted("python", code)
        #expect(await SyntaxHighlighter.shared.runCount == after + 1)
    }

    @Test func unknownAndPlainLanguagesAreLeftAlone() async {
        let before = await SyntaxHighlighter.shared.runCount
        #expect(await highlighted("mermaid", "graph TD; A-->B;") == nil)
        #expect(await highlighted("text", "just some words") == nil)
        #expect(await highlighted("unknownlang", "x = 1") == nil)
        #expect(await SyntaxHighlighter.shared.runCount == before) // the highlighter was never asked
    }

    @Test func aShortBlockWithNoLanguageIsGuessed() async throws {
        let code = "fn main() {\n    let v: Vec<i32> = vec![1, 2, 3];\n    println!(\"{:?}\", v);\n}"
        let h = try #require(await highlighted("", code))
        #expect(h.language == "rust")
        #expect(!h.full.runs.compactMap(\.foregroundColor).isEmpty)
    }

    @Test func proseWithNoLanguageIsNotColoured() async {
        #expect(await highlighted("", "This is just a plain sentence, with a comma or two, and nothing else to see here.") == nil)
    }

    @Test func aLongBlockWithNoLanguageIsNotGuessedButANamedOneIsHighlighted() async throws {
        let code = (1...250).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        #expect(await highlighted("", code) == nil) // 250 lines: too long to guess
        let named = try #require(await highlighted("swift", code))
        #expect(named.lines.count == 250)
    }

    @Test func hugeBlocksStayPlain() async {
        let tooManyLines = (1...3001).map { "x\($0)" }.joined(separator: "\n")
        #expect(await highlighted("swift", tooManyLines) == nil)
        let tooManyBytes = String(repeating: "let a = 1 // padding to make this long\n", count: 6000) // over 200 KB
        #expect(tooManyBytes.utf8.count > 200 * 1024)
        #expect(await highlighted("swift", tooManyBytes) == nil)
        // Just inside the limits it is highlighted.
        let big = (1...3000).map { "let v\($0) = \($0)" }.joined(separator: "\n")
        #expect(await highlighted("swift", big) != nil)
    }

    @Test func aLargeBlockIsHighlightedOffTheMainThread() async throws {
        let code = (1...3000).map { "let value\($0) = compute(\($0), \"two\") // note" }.joined(separator: "\n")
        let start = ContinuousClock.now
        // The main actor stays free while it runs: this ticker keeps going.
        var ticks = 0
        let ticker = Task { @MainActor in while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(5)) } }
        let h = await highlighted("swift", code)
        ticker.cancel()
        #expect(h != nil)
        #expect(ticks > 0 || ContinuousClock.now - start < .milliseconds(50))
    }

    @Test func theCacheIsRegisteredForMemoryWarnings() async {
        HighlightService.registerForPurge()
        _ = await highlighted("swift", "let purged = 1")
        #expect(HighlightService.cache.count > 0)
        MemoryPurge.purgeNow()
        #expect(HighlightService.cache.count == 0)
    }
}
