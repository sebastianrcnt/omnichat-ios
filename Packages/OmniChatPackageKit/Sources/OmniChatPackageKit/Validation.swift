import Foundation

// The rules of format 1, checked in order; the first broken one throws, worded so whoever fixes it knows what to do
// (the model drafting a package reads these too).

public enum PackageLimits {
    public static let idLength = 3...80
    public static let nameLength = 40
    public static let descriptionLength = 200
    public static let toolDescriptionLength = 1024
    public static let toolsPerPackage = 24
    public static let toolsPerChat = 64
    public static let promptCharacters = 4_000
    public static let fullToolNameLength = 64
    public static let timeout = 1...120
    /// Namespaces packages can't take: they read as the app's own tools (`openchat` was its name before OmniChat).
    public static let reservedNamespaces: Set<String> = ["web", "browser", "run", "view", "load", "save", "show", "current", "video",
                                                         "ssh", "python", "omnichat", "openchat", "app", "test", "pkg"]
    /// Built-in tool groups a package may require or exclude.
    public static let groups: Set<String> = ["web", "browser", "python", "location", "video", "ssh", "views", "health"]
}

/// A skill file in a package: `---` front matter with `name` and `description`, then the body (the app's skill format).
public struct PackageSkill: Sendable, Equatable {
    public var name: String
    public var description: String
    public var body: String

    public static func parse(_ text: String) -> PackageSkill? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil) else {
            return nil
        }
        var fields: [String: String] = [:]
        for line in rest[..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let name = fields["name"], let description = fields["description"], !name.isEmpty, !description.isEmpty else { return nil }
        return PackageSkill(name: name, description: description, body: String(rest[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A skill name on its own: lowercase letters, digits and hyphens, starting with a letter, at most 40.
    public static func isValidLocalName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 40, ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}

extension PackageManifest {
    public static func isValidID(_ id: String) -> Bool {
        guard PackageLimits.idLength.contains(id.count), id.contains("."), !id.hasPrefix("."), !id.hasSuffix("."), !id.contains("..") else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" }
    }

    /// `[a-z][a-z0-9]{1,15}`: no underscores, so `<namespace>__<tool>` splits one way only.
    public static func isValidNamespace(_ ns: String) -> Bool {
        guard (2...16).contains(ns.count), let first = ns.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return ns.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// `[a-z][a-z0-9_]{0,39}`, without a double underscore.
    public static func isValidToolName(_ name: String) -> Bool {
        guard (1...40).contains(name.count), let first = name.unicodeScalars.first, ("a"..."z").contains(first), !name.contains("__") else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    public static func isValidSecretInjection(_ inject: String) -> Bool {
        if inject == "bearer" || inject == "basic" { return true }
        for prefix in ["header:", "query:"] where inject.hasPrefix(prefix) {
            let rest = inject.dropFirst(prefix.count)
            return !rest.isEmpty && rest.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
        }
        return false
    }

    /// Checks every rule of format 1 against the manifest and the package's files (paths → text). Throws
    /// `PackageError.invalid` for the first broken one.
    public func validate(files: [String: Data]) throws {
        func fail(_ m: String) -> PackageError { .invalid(m) }
        guard format >= 1 else { throw fail("format must be 1.") }
        guard format <= PackageFormat.newest else { throw PackageError.newerFormat(format) }
        guard Self.isValidID(id) else {
            throw fail("id \"\(id)\" must be reverse-DNS: lowercase letters, digits, . and -, 3 to 80 characters, like com.acme.jira.")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= PackageLimits.nameLength, !trimmedName.contains("\n") else {
            throw fail("name must be one line of at most \(PackageLimits.nameLength) characters.")
        }
        guard Self.isValidNamespace(namespace) else {
            throw fail("namespace \"\(namespace)\" must be 2 to 16 lowercase letters and digits, starting with a letter (no _), like jira.")
        }
        guard !PackageLimits.reservedNamespaces.contains(namespace) else {
            throw fail("namespace \"\(namespace)\" is reserved for the app's own tools. Pick another, like \(namespace)x or the service's name.")
        }
        // No trimming here: the exact string names the installed folder.
        guard SemVer(version) != nil, !version.contains(where: \.isWhitespace) else { throw fail("version \"\(version)\" must be a SemVer version, like 1.4.0.") }
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty, !desc.contains("\n"), desc.count <= PackageLimits.descriptionLength else {
            throw fail("description must be one line of at most \(PackageLimits.descriptionLength) characters.")
        }
        if let key = publisher?.key { _ = try PackageKey(key) }
        if let app = requires?.app, SemVer("0.0.0")?.satisfies(app) == nil {
            throw fail("requires.app \"\(app)\" is not a version range: use >=1.3.0, <2, ^1.2 or ~1.2.3.")
        }
        for group in requiredGroups + exclusiveGroups where !PackageLimits.groups.contains(group) {
            throw fail("\"\(group)\" is not a tool group. Use: \(PackageLimits.groups.sorted().joined(separator: ", ")).")
        }
        if let both = Set(requiredGroups).intersection(exclusiveGroups).sorted().first {
            throw fail("\(both) is both required and exclusive.")
        }
        // Permissions
        for entry in network where !URLTemplate.isValidNetworkEntry(entry) {
            throw fail("permissions.network entry \"\(entry)\" must be a host name or *.domain, without scheme, port or path.")
        }
        if !(permissions?.data ?? []).isEmpty {
            throw fail("permissions.data must be empty: packages can't receive health, location or other app data.")
        }
        if let storage = permissions?.storage, storage < 0 { throw fail("permissions.storage must be 0 or more bytes.") }
        var secretNames = Set<String>()
        for s in secrets {
            guard JSONSchemaSubset.isPropertyName(s.name), secretNames.insert(s.name).inserted else {
                throw fail("secret name \"\(s.name)\" must be unique, letters, digits and _.")
            }
            guard !s.label.trimmingCharacters(in: .whitespaces).isEmpty else { throw fail("secret \(s.name) needs a label.") }
            guard Self.isValidSecretInjection(s.inject) else {
                throw fail("secret \(s.name): inject must be bearer, basic, header:<Name> or query:<param>.")
            }
        }
        // Contents
        if let prompt = contents?.prompt {
            guard let data = files[prompt], let text = String(data: data, encoding: .utf8) else { throw fail("contents.prompt names \(prompt), which isn't in the package.") }
            let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
            guard count <= PackageLimits.promptCharacters else {
                throw fail("\(prompt) is \(count) characters; a prompt fragment may have at most \(PackageLimits.promptCharacters).")
            }
        }
        var skillNames = Set<String>()
        for path in skillFiles {
            guard let data = files[path], let text = String(data: data, encoding: .utf8) else { throw fail("contents.skills names \(path), which isn't in the package.") }
            guard let skill = PackageSkill.parse(text) else {
                throw fail("\(path) needs front matter: ---, name: <name>, description: <one line>, ---, then the body.")
            }
            guard PackageSkill.isValidLocalName(skill.name) else {
                throw fail("\(path): the skill name \"\(skill.name)\" must be lowercase letters, digits and -, starting with a letter. It becomes \(namespace):\(skill.name).")
            }
            guard skillNames.insert(skill.name).inserted else { throw fail("two skills are named \(skill.name).") }
            guard !skill.body.isEmpty, skill.body.count <= 40_000 else { throw fail("\(path): the skill body must have 1 to 40,000 characters.") }
        }
        if contents?.policy != nil || !(contents?.hooks ?? []).isEmpty {
            throw fail("policy and hooks are only honored from company packages, which this version can't install yet. Remove them.")
        }
        try validateTools()
        for tool in tools where tool.kind == "page" {
            guard let path = tool.script, let data = files[path], let text = String(data: data, encoding: .utf8), text.contains("strataPlugin") else {
                throw fail("tool \(tool.name): script must name a file of the package that defines window.strataPlugin.")
            }
        }
        var commandNames = Set<String>()
        for c in commands {
            guard Self.isValidToolName(c.name), commandNames.insert(c.name).inserted else {
                throw fail("command name \"\(c.name)\" must be unique, lowercase letters, digits and _.")
            }
            guard !c.title.trimmingCharacters(in: .whitespaces).isEmpty, !c.template.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw fail("command \(c.name) needs a title and a template.")
            }
        }
        for preset in connections {
            guard !preset.name.trimmingCharacters(in: .whitespaces).isEmpty, let url = URL(string: preset.url),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil, url.user == nil else {
                throw fail("connection \"\(preset.name)\" needs a name and an http(s) url without a user name.")
            }
            guard ["openai", "responses", nil].contains(preset.api) else { throw fail("connection \(preset.name): api must be openai or responses.") }
            if preset.managed == true { throw fail("connection \(preset.name): managed connections need a company package.") }
        }
    }

    func validateTools() throws {
        func fail(_ m: String) -> PackageError { .invalid(m) }
        let usable = tools.filter { PackageTool.kinds.contains($0.kind) }
        guard usable.count <= PackageLimits.toolsPerPackage else {
            throw fail("the package has \(usable.count) tools; at most \(PackageLimits.toolsPerPackage) are allowed.")
        }
        var names = Set<String>()
        for tool in tools {
            let place = "tool \(tool.name)"
            guard Self.isValidToolName(tool.name) else {
                throw fail("tool name \"\(tool.name)\" must be lowercase letters, digits and single _, starting with a letter, at most 40.")
            }
            guard names.insert(tool.name).inserted else { throw fail("two tools are named \(tool.name).") }
            guard PackageTool.kinds.contains(tool.kind) || tool.optional == true else {
                throw fail("\(place): kind \"\(tool.kind)\" isn't supported by this version (only http and page). Mark it \"optional\": true to skip it here.")
            }
            guard PackageTool.kinds.contains(tool.kind) else { continue }
            let full = PackageRender.toolName(namespace: namespace, tool: tool.name)
            guard full.count <= PackageLimits.fullToolNameLength else { throw fail("\(place): \(full) is longer than 64 characters.") }
            let desc = tool.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !desc.isEmpty, desc.count <= PackageLimits.toolDescriptionLength else {
                throw fail("\(place): the description must have 1 to \(PackageLimits.toolDescriptionLength) characters, written for the model.")
            }
            if let title = tool.title, title.trimmingCharacters(in: .whitespaces).isEmpty || title.count > 60 {
                throw fail("\(place): the title must be 1 to 60 characters.")
            }
            let schema = tool.parameters ?? .object(["type": .string("object"), "properties": .object([:])])
            try JSONSchemaSubset.validateSchema(schema, where: place)
            let params = schema["properties"]?.objectValue ?? [:]
            if let confirm = tool.confirm, !PackageTool.confirmLevels.contains(confirm) { throw fail("\(place): confirm must be never, first or always.") }
            if let t = tool.timeout, !PackageLimits.timeout.contains(t) { throw fail("\(place): timeout must be 1 to 120 seconds.") }
            if let sv = tool.schemaVersion, sv < 1 { throw fail("\(place): schemaVersion must be 1 or more.") }
            if let arg = tool.display?.argument, params[arg] == nil { throw fail("\(place): display.argument names \(arg), which isn't a parameter.") }
            if let od = tool.onDevice {
                guard !od.description.isEmpty, od.description.count <= 120 else { throw fail("\(place): onDevice.description must be 1 to 120 characters.") }
                let list = od.parameters ?? []
                guard list.count <= 3, list.allSatisfy({ params[$0]?["type"]?.stringValue == "string" }) else {
                    throw fail("\(place): onDevice.parameters may list at most 3 string parameters.")
                }
            }
            if tool.kind == "page" {
                try validatePage(tool, place: place, params: params)
            } else {
                try validateRequest(tool, place: place, params: params)
            }
        }
    }

    func validatePage(_ tool: PackageTool, place: String, params: [String: JSONValue]) throws {
        func fail(_ m: String) -> PackageError { .invalid("\(place): \(m)") }
        guard let page = tool.page else { throw fail("a page tool needs a page.") }
        guard tool.request == nil else { throw fail("a page tool has a page, not a request.") }
        let sample = try? URLTemplate.fill(page.url) { _ in "x" }
        guard let sample, let url = URL(string: sample), url.scheme?.lowercased() == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty, url.user == nil else {
            throw fail("page.url must be an absolute https URL, like https://{lang}.wikipedia.org/wiki/{title}.")
        }
        guard URLTemplate.packageHostAllowed(host, network: network) else {
            throw fail("the page's host \(host) is not in permissions.network. Add it there.")
        }
        for name in URLTemplate.placeholders(in: page.url).map({ URLTemplate.split(placeholder: $0).name }) where params[name] == nil {
            throw fail("page.url uses {\(name)}, which isn't a parameter.")
        }
        if let settle = page.settle, !(0...10).contains(settle) { throw fail("page.settle must be 0 to 10 seconds.") }
        if tool.readOnly == false { throw fail("a page tool only reads.") }
    }

    func validateRequest(_ tool: PackageTool, place: String, params: [String: JSONValue]) throws {
        func fail(_ m: String) -> PackageError { .invalid("\(place): \(m)") }
        guard let request = tool.request else { throw fail("an http tool needs a request.") }
        guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(request.httpMethod) else { throw fail("method must be GET, POST, PUT, PATCH or DELETE.") }
        guard URLTemplate.placeholdersOnlyInPath(request.url) else {
            throw fail("the url may use {arguments} only in its path, never in the scheme, host, port or query (use request.query).")
        }
        let sample = try? URLTemplate.fill(request.url) { _ in "x" }
        guard let sample, let url = URL(string: sample), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(percentEncoded: false), !host.isEmpty, url.user == nil else {
            throw fail("the url must be an absolute http(s) URL, like https://api.example.com/items/{id}.")
        }
        guard URLTemplate.packageHostAllowed(host, network: network) else {
            throw fail("the url's host \(host) is not in permissions.network. Add it there.")
        }
        var used: [String] = URLTemplate.placeholders(in: request.url)
        for value in (request.query ?? [:]).values { used += URLTemplate.placeholders(in: value) }
        for (name, value) in request.headers ?? [:] {
            let lower = name.lowercased()
            guard !["authorization", "cookie", "proxy-authorization", "host", "content-length"].contains(lower) else {
                throw fail("the header \(name) can't be set here. Declare a secret and use request.auth for credentials.")
            }
            used += URLTemplate.placeholders(in: value)
        }
        for value in request.body?.form?.values ?? [:].values { used += URLTemplate.placeholders(in: value) }
        if let json = request.body?.json { used += Self.placeholders(inJSON: json) }
        if request.body?.json != nil && request.body?.form != nil { throw fail("the body is either json or form, not both.") }
        if request.body != nil, request.httpMethod == "GET" { throw fail("a GET request can't have a body.") }
        for p in used {
            let (name, _) = URLTemplate.split(placeholder: p)
            guard params[name] != nil else { throw fail("{\(name)} isn't a parameter.") }
        }
        for p in URLTemplate.placeholders(in: request.url) {
            let (name, fallback) = URLTemplate.split(placeholder: p)
            let required = tool.parameters?["required"]?.arrayValue?.contains(.string(name)) ?? false
            guard required || fallback != nil || params[name]?["default"] != nil else {
                throw fail("the url uses {\(name)}, which is optional with no default.")
            }
        }
        if let auth = request.auth, secret(named: auth.secret) == nil {
            throw fail("request.auth uses the secret \(auth.secret), which isn't in permissions.secrets.")
        }
        if let r = tool.response {
            for pointer in [r.each].compactMap({ $0 }) + Array((r.fields ?? [:]).values) where !JSONValue.isValidPointer(pointer) {
                throw fail("\"\(pointer)\" is not a JSON Pointer: start it with /, like /issues/0/key.")
            }
            if let m = r.maxCharacters, !(1...ResponseProjection.maxCharacters).contains(m) {
                throw fail("response.maxCharacters must be 1 to \(ResponseProjection.maxCharacters).")
            }
        }
    }

    static func placeholders(inJSON value: JSONValue) -> [String] {
        switch value {
        case .string(let s): URLTemplate.placeholders(in: s)
        case .array(let a): a.flatMap(placeholders(inJSON:))
        case .object(let o): o.values.flatMap(placeholders(inJSON:))
        default: []
        }
    }
}
