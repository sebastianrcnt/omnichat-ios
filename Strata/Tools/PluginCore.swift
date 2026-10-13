import Foundation

// Site plugins: a manifest plus one script defining `window.strataPlugin(args)`, run in a hidden web view through the
// one fixed `run_plugin` tool. Everything here is plain Foundation (no app types), so `Tools/plugin-check` compiles this
// file as is and runs a plugin on the Mac exactly as the app would.

/// One argument a plugin takes, as its manifest lists it.
struct PluginArgument: Codable, Sendable, Equatable {
    var name: String
    var description: String
    var required: Bool?
    /// Used when the model leaves the argument out.
    var `default`: String?

    var isRequired: Bool { required ?? false }
}

/// `<name>.plugin.json`.
struct PluginManifest: Codable, Sendable, Equatable {
    var name: String
    /// One line, shown to the model.
    var description: String
    var args: [PluginArgument]
    /// The page the plugin runs on: `https://{lang}.wikipedia.org/wiki/{title}`. Each `{arg}` is percent-encoded.
    var url: String
    /// Hosts the page URL may have (a host or any subdomain of it). Nil allows any public host.
    var hosts: [String]?
    /// Seconds to wait after the page is ready, for client-side rendering. Nil uses the fetch settle delay.
    var settle: Double?
    /// CSS selector the page must show before the plugin runs (for content a script renders after the document is
    /// parsed). The document being parsed is always waited for.
    var waitFor: String?
}

struct WebPlugin: Sendable, Equatable, Identifiable {
    var manifest: PluginManifest
    /// The plugin's JavaScript (defines `window.strataPlugin`).
    var script: String

    var id: String { manifest.name }
    var name: String { manifest.name }
}

enum PluginError: Error, LocalizedError, Equatable {
    case invalidManifest(String)
    case unknown(String, available: [String])
    case badArguments(String)
    case hostNotAllowed(String, plugin: String)
    /// The plugin's script threw, or returned nothing usable.
    case script(String)

    // Read by the model, so each says what to do next.
    var errorDescription: String? {
        switch self {
        case .invalidManifest(let m): "Invalid plugin manifest: \(m)"
        case .unknown(let name, let available):
            available.isEmpty
                ? "There is no plugin named \"\(name)\", and no plugins are enabled. Use web_search and web_fetch instead."
                : "There is no plugin named \"\(name)\". Available plugins: \(available.joined(separator: ", "))."
        case .badArguments(let m): "Bad plugin arguments: \(m)"
        case .hostNotAllowed(let host, let plugin): "Blocked: \(host) is not a site the \(plugin) plugin may open."
        case .script(let m): "Plugin script failed: \(m)"
        }
    }
}

// MARK: - Manifest

extension PluginManifest {
    static let nameLimit = 40
    static let maxSettle = 10.0

    /// The `{arg}` names in the URL template, in order.
    static func placeholders(in template: String) -> [String] {
        var out: [String] = []
        var rest = template[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    private static func isIdentifier(_ s: String, lowercase: Bool) -> Bool {
        guard let first = s.unicodeScalars.first, s.count <= nameLimit else { return false }
        let letters = lowercase ? CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz") : CharacterSet.letters
        guard letters.contains(first), first.isASCII else { return false }
        let rest = (lowercase ? letters : CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"))
            .union(CharacterSet(charactersIn: "0123456789_"))
        return s.unicodeScalars.allSatisfy { $0.isASCII && rest.contains($0) }
    }

    /// Throws `PluginError.invalidManifest` naming the first problem.
    func validate() throws {
        func fail(_ m: String) -> PluginError { .invalidManifest("\(name.isEmpty ? "(unnamed)" : name): \(m)") }
        guard Self.isIdentifier(name, lowercase: true) else { throw fail("the name must be lowercase letters, digits and _ (at most \(Self.nameLimit)).") }
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty, !desc.contains("\n") else { throw fail("the description must be one non-empty line.") }
        var seen = Set<String>()
        for arg in args {
            guard Self.isIdentifier(arg.name, lowercase: false) else { throw fail("bad argument name \"\(arg.name)\".") }
            guard seen.insert(arg.name).inserted else { throw fail("argument \"\(arg.name)\" is listed twice.") }
            guard !arg.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !arg.description.contains("\n") else {
                throw fail("argument \"\(arg.name)\" needs a one-line description.")
            }
            if arg.isRequired, arg.default != nil { throw fail("argument \"\(arg.name)\" is required and has a default.") }
        }
        let lower = url.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { throw fail("the url must start with http:// or https://.") }
        for p in Self.placeholders(in: url) {
            guard let arg = args.first(where: { $0.name == p }) else { throw fail("the url uses {\(p)}, which is not an argument.") }
            guard arg.isRequired || arg.default != nil else { throw fail("the url uses {\(p)}, which is optional with no default.") }
        }
        let sample = args.reduce(into: [String: String]()) { $0[$1.name] = $1.default ?? "x" }
        guard let built = try? Self.build(template: url, values: sample), built.host(percentEncoded: false)?.isEmpty == false else {
            throw fail("the url template does not make a valid URL.")
        }
        if let hosts {
            guard !hosts.isEmpty, hosts.allSatisfy({ !Self.normalizedHost($0).isEmpty }) else { throw fail("hosts must be a non-empty list of host names.") }
        }
        if let settle, !(0...Self.maxSettle).contains(settle) { throw fail("settle must be between 0 and \(Int(Self.maxSettle)) seconds.") }
        if let waitFor, waitFor.trimmingCharacters(in: .whitespaces).isEmpty { throw fail("waitFor must not be empty.") }
    }

    /// Characters an argument value keeps in the URL; everything else is percent-encoded (so a value can never add a
    /// path, a query, a port or a user to the URL).
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The template with each `{arg}` replaced by its percent-encoded value.
    static func build(template: String, values: [String: String]) throws -> URL {
        var out = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let key = String(rest[rest.index(after: open)..<close])
            guard let value = values[key] else { throw PluginError.badArguments("missing required argument \"\(key)\".") }
            out += value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        guard let url = URL(string: out), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host(percentEncoded: false)?.isEmpty == false else {
            throw PluginError.badArguments("the arguments do not make a valid URL.")
        }
        return url
    }

    static func normalizedHost(_ host: String) -> String {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("*.") { h.removeFirst(2) }
        return h.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// True when `host` is one of `hosts` or a subdomain of one; any host when there is no list.
    static func hostAllowed(_ host: String, hosts: [String]?) -> Bool {
        guard let hosts else { return true }
        let h = normalizedHost(host)
        guard !h.isEmpty else { return false }
        return hosts.map(normalizedHost).contains { !$0.isEmpty && (h == $0 || h.hasSuffix("." + $0)) }
    }

    /// The arguments the script gets: the model's, checked against the manifest, with defaults filled in.
    /// - Parameter raw: a JSON object, or a string holding one (or nil / "" for none).
    func resolveArguments(_ raw: Any?) throws -> [String: Any] {
        var given: [String: Any] = [:]
        switch raw {
        case nil, is NSNull: break
        case let dict as [String: Any]: given = dict
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
                    throw PluginError.badArguments("args must be a JSON object, like {\"\(args.first?.name ?? "key")\": \"...\"}.")
                }
                given = obj
            }
        default: throw PluginError.badArguments("args must be a JSON object.")
        }
        let known = Set(args.map(\.name))
        if let extra = given.keys.sorted().first(where: { !known.contains($0) }) {
            let list = args.isEmpty ? "none" : args.map(\.name).joined(separator: ", ")
            throw PluginError.badArguments("\(name) has no argument \"\(extra)\" (it takes: \(list)).")
        }
        var out = given.filter { !($0.value is NSNull) }
        for arg in args where out[arg.name] == nil {
            if let d = arg.default { out[arg.name] = d }
            else if arg.isRequired { throw PluginError.badArguments("missing required argument \"\(arg.name)\".") }
        }
        return out
    }

    /// Resolved arguments as the JSON object the script gets (keys sorted).
    static func json(_ arguments: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The page URL for resolved arguments. URL placeholders take strings, numbers or booleans.
    func pageURL(arguments: [String: Any]) throws -> URL {
        var values: [String: String] = [:]
        for key in Self.placeholders(in: url) {
            switch arguments[key] {
            case let s as String:
                guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PluginError.badArguments("\"\(key)\" is empty.") }
                values[key] = s
            case let n as NSNumber: values[key] = n.stringValue // also booleans
            case nil: throw PluginError.badArguments("missing required argument \"\(key)\".")
            default: throw PluginError.badArguments("\"\(key)\" must be a string or a number.")
            }
        }
        return try Self.build(template: url, values: values)
    }

    /// "title (required): Article title; lang (default "en"): Language code".
    var argumentSummary: String {
        args.map { arg in
            let tag = arg.isRequired ? " (required)" : arg.default.map { " (default \"\($0)\")" } ?? " (optional)"
            return arg.name + tag + ": " + arg.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "; ")
    }
}

// MARK: - Registry

/// The plugins that loaded, by name. Broken ones are skipped and listed in `problems`.
struct PluginRegistry: Sendable {
    private(set) var plugins: [WebPlugin]
    private(set) var problems: [String] = []

    init(plugins: [WebPlugin], problems: [String] = []) {
        self.plugins = plugins.sorted { $0.name < $1.name }
        self.problems = problems
    }

    static let manifestSuffix = ".plugin.json"

    /// The plugins bundled with the app: each `<name>.plugin.json` next to its `<name>.plugin.js`.
    static let bundled: PluginRegistry = {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(manifestSuffix) }
        return load(manifestURLs: urls)
    }()

    /// Every `*.plugin.json` in a folder (the Mac helper reads the checkout's `Strata/Resources/Plugins`).
    static func load(directory: URL) -> PluginRegistry {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return load(manifestURLs: files.filter { $0.lastPathComponent.hasSuffix(manifestSuffix) })
    }

    static func load(manifestURLs: [URL]) -> PluginRegistry {
        var plugins: [WebPlugin] = []
        var problems: [String] = []
        for url in manifestURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let file = url.lastPathComponent
            let scriptURL = url.deletingLastPathComponent()
                .appendingPathComponent(String(file.dropLast(manifestSuffix.count)) + ".plugin.js")
            let script = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
            do {
                let plugin = try load(manifest: try Data(contentsOf: url), script: script)
                guard String(file.dropLast(manifestSuffix.count)) == plugin.name else {
                    throw PluginError.invalidManifest("\(file): the file name must be \(plugin.name)\(manifestSuffix).")
                }
                guard !plugins.contains(where: { $0.name == plugin.name }) else {
                    throw PluginError.invalidManifest("\(file): another plugin is already named \(plugin.name).")
                }
                plugins.append(plugin)
            } catch {
                problems.append("\(file): \(error.localizedDescription)")
            }
        }
        return PluginRegistry(plugins: plugins, problems: problems)
    }

    /// Decodes and validates one plugin.
    static func load(manifest data: Data, script: String) throws -> WebPlugin {
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) }
        catch { throw PluginError.invalidManifest("the manifest is not valid JSON of the expected shape.") }
        try manifest.validate()
        guard script.contains("strataPlugin") else {
            throw PluginError.invalidManifest("\(manifest.name): the script must define window.strataPlugin.")
        }
        return WebPlugin(manifest: manifest, script: script)
    }

    func plugin(named name: String) -> WebPlugin? { plugins.first { $0.name == name } }

    func enabled(_ names: Set<String>) -> [WebPlugin] { plugins.filter { names.contains($0.name) } }

    /// The system prompt's plugin list for the enabled plugins, or "" when none is. Sorted and free of anything that
    /// changes between requests, so the cached prefix stays the same.
    func promptSection(enabled names: Set<String>) -> String {
        let list = enabled(names)
        guard !list.isEmpty else { return "" }
        var lines = ["Site plugins (call run_plugin with the plugin name and its args as a JSON object string):"]
        for p in list {
            let args = p.manifest.args.isEmpty ? "No args." : "Args: \(p.manifest.argumentSummary)."
            lines.append("- \(p.name): \(p.manifest.description.trimmingCharacters(in: .whitespacesAndNewlines)) \(args)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Running

enum PluginScript {
    /// Polled while the page loads: where the document is, how far it has parsed, and whether `waitFor` matches.
    static func probe(waitFor: String?) -> String {
        let selector = waitFor.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) } ?? "null"
        return """
        (function() {
          var w = \(selector), found = false;
          if (w) { try { found = !!document.querySelector(w); } catch (e) {} }
          return JSON.stringify({ href: String(location.href), ready: document.readyState, found: found });
        })()
        """
    }

    struct Probe: Decodable, Equatable, Sendable {
        var href: String
        var ready: String
        var found: Bool

        /// The page being waited for has replaced the blank one.
        var committed: Bool { !href.isEmpty && !href.lowercased().hasPrefix("about:") }

        /// Ready to run: the document has been parsed and, when there is a `waitFor`, it matches (an element seen while
        /// the document is still parsing may be only half there).
        func isReady(waitFor: String?) -> Bool { committed && ready != "loading" && (waitFor == nil || found) }

        static func decode(_ json: String) -> Probe? { try? JSONDecoder().decode(Probe.self, from: Data(json.utf8)) }
    }

    /// A function body for `callAsyncJavaScript`: defines the plugin, awaits it, and returns one JSON string. The result
    /// is cut to `maxCharacters` in the page, so nothing larger is ever sent back.
    /// - Parameter arguments: the resolved arguments as a JSON object (`PluginManifest.json(_:)`).
    static func invocation(_ plugin: WebPlugin, arguments: String, maxCharacters: Int) -> String {
        let args = arguments.isEmpty ? "{}" : arguments
        return """
        const __strataArgs = \(args);
        const __strataCap = \(maxCharacters);
        \(plugin.script)
        ;
        try {
          if (typeof window.strataPlugin !== "function") return JSON.stringify({ error: "the plugin does not define window.strataPlugin." });
          let r = await window.strataPlugin(__strataArgs);
          if (r === undefined) r = null;
          const isText = typeof r === "string";
          const body = isText ? r : (JSON.stringify(r, null, 2) || "null");
          const title = (r && typeof r === "object" && typeof r.title === "string") ? r.title : document.title;
          return JSON.stringify({ kind: isText ? "text" : "json", body: body.slice(0, __strataCap), total: body.length,
                                  title: String(title || ""), url: String(location.href) });
        } catch (e) {
          return JSON.stringify({ error: String((e && e.message) || e) });
        }
        """
    }

    struct Result: Decodable, Sendable {
        var kind: String?
        var body: String?
        var total: Int?
        var title: String?
        var url: String?
        var error: String?
    }

    /// What the model reads (header and result) and the part that becomes the source's content.
    struct Output: Sendable, Equatable {
        var text: String
        var title: String
        var url: String
        var content: String
    }

    /// Turns the invocation's JSON into the model's text, with fetch's truncation note when the result was cut.
    static func format(json: String, plugin: WebPlugin, limit: Int) throws -> Output {
        guard let r = try? JSONDecoder().decode(Result.self, from: Data(json.utf8)) else {
            throw PluginError.script("the plugin returned something that is not JSON.")
        }
        if let error = r.error { throw PluginError.script(error) }
        guard var body = r.body else { throw PluginError.script("the plugin returned no result.") }
        let total = r.total ?? body.count
        if body.count > limit { body = String(body.prefix(limit)) }
        if total > body.count { body += "\n\n[Truncated: the plugin result exceeded \(body.count) characters.]" }
        let url = r.url ?? ""
        let title = (r.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let header = "Plugin: \(plugin.name)\n" + (title.isEmpty ? "" : "Title: \(title)\n") + "URL: \(url)\n\n"
        return Output(text: header + body, title: title.isEmpty ? plugin.name : title, url: url, content: body)
    }
}
