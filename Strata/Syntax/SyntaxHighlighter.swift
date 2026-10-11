import Foundation
import JavaScriptCore
import CryptoKit

/// highlight.js in a JavaScriptCore context, on its own actor so no highlighting ever runs on the main thread.
actor SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    private var context: JSContext?
    private var loadFailed = false
    /// Highlights run so far (tests).
    private(set) var runCount = 0

    private static let glue = """
    function __highlight(code, lang, subset, minRelevance) {
      var r;
      if (lang) { r = hljs.highlight(code, { language: lang, ignoreIllegals: true }); }
      else {
        r = hljs.highlightAuto(code, subset);
        if (!r.language || r.relevance < minRelevance) { return null; }
      }
      return JSON.stringify({ html: r.value, language: r.language || lang || null });
    }
    """

    /// The bundled library's source (nil in a test host without it).
    static func librarySource(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "highlight", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func loadedContext() -> JSContext? {
        if let context { return context }
        guard !loadFailed, let source = Self.librarySource(), let ctx = JSContext() else { loadFailed = true; return nil }
        ctx.exceptionHandler = { _, _ in }
        ctx.evaluateScript(source)
        ctx.evaluateScript(Self.glue)
        guard ctx.objectForKeyedSubscript("hljs")?.isObject == true else { loadFailed = true; return nil }
        context = ctx
        return ctx
    }

    /// The runs for `code`. `language` is a normalized highlight.js name, or nil to guess. Nil when there is nothing to
    /// colour (no library, a guess that is not trusted, an error).
    func highlight(code: String, language: String?) -> HighlightResult? {
        guard let ctx = loadedContext(), let fn = ctx.objectForKeyedSubscript("__highlight") else { return nil }
        runCount += 1
        let args: [Any] = [code, language ?? NSNull(), LanguageAliases.autoSubset, LanguageAliases.autoMinimumRelevance]
        guard let value = fn.call(withArguments: args), value.isString, let json = value.toString(),
              let data = json.data(using: .utf8),
              let out = try? JSONDecoder().decode(Output.self, from: data) else { return nil }
        let parsed = HighlightHTML.parse(out.html)
        guard parsed.text == code else { return nil } // the output must be the code, only coloured
        return HighlightResult(runs: parsed.runs, language: out.language)
    }

    private struct Output: Decodable { var html: String; var language: String? }
}

/// Finished highlights by hash of language and code, shared by the inline block and the full-screen viewer.
final class HighlightCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Value] = [:]
    private var order: [String] = []
    let capacity: Int

    init(capacity: Int = 60) { self.capacity = capacity }

    static func key(language: String, code: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(language.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(code.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func value(for key: String) -> Value? {
        lock.withLock {
            guard let v = entries[key] else { return nil }
            if let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) } // most recently used last
            return v
        }
    }

    func store(_ value: Value, for key: String) {
        lock.withLock {
            if entries[key] == nil { order.append(key) }
            entries[key] = value
            while order.count > capacity { entries[order.removeFirst()] = nil }
        }
    }

    var count: Int { lock.withLock { entries.count } }
    func removeAll() { lock.withLock { entries.removeAll(); order.removeAll() } }
}
