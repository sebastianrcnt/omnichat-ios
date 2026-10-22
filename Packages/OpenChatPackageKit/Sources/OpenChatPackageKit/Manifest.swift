import Foundation

// `manifest.json`, format 1 (docs/PACKAGES.md section 3). Decoding is lenient about unknown keys (they become warnings
// in the review sheet, `PackageManifest.warnings`); `validate` is strict about everything it knows.

/// What went wrong with a package, worded for whoever fixes it: the author, or the model drafting one.
public enum PackageError: Error, LocalizedError, Equatable, Sendable {
    /// The manifest or a content file breaks a rule.
    case invalid(String)
    /// The zip or folder can't be read safely.
    case archive(String)
    /// CHECKSUMS or SIGNATURE don't hold.
    case signature(String)
    /// The package needs a newer OpenChat.
    case newerFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .invalid(let m): m
        case .archive(let m): m
        case .signature(let m): m
        case .newerFormat(let f): "This package uses format \(f). Update OpenChat to install this package."
        }
    }
}

public struct PackageManifest: Codable, Sendable, Equatable {
    public var format: Int
    /// Reverse-DNS, lowercase: `com.acme.jira`.
    public var id: String
    public var name: String
    /// The tool-name prefix: `jira` makes `jira__search`.
    public var namespace: String
    /// SemVer 2.0.
    public var version: String
    /// One line for the UI, never sent to the model.
    public var description: String
    public var publisher: Publisher?
    public var license: String?
    public var homepage: String?
    public var requires: Requirements?
    public var permissions: Permissions?
    public var contents: Contents?
    public var update: Update?

    public init(format: Int = 1, id: String, name: String, namespace: String, version: String, description: String,
                publisher: Publisher? = nil, license: String? = nil, homepage: String? = nil, requires: Requirements? = nil,
                permissions: Permissions? = nil, contents: Contents? = nil, update: Update? = nil) {
        self.format = format
        self.id = id
        self.name = name
        self.namespace = namespace
        self.version = version
        self.description = description
        self.publisher = publisher
        self.license = license
        self.homepage = homepage
        self.requires = requires
        self.permissions = permissions
        self.contents = contents
        self.update = update
    }

    public struct Publisher: Codable, Sendable, Equatable {
        public var name: String
        /// `ed25519:<base64url>`; nil for an unsigned package.
        public var key: String?
        public init(name: String, key: String? = nil) { self.name = name; self.key = key }
    }

    public struct Requirements: Codable, Sendable, Equatable {
        /// An OpenChat version range: `>=1.3.0`, `<2`, `^1.2`, `~1.2.3`, several separated by spaces.
        public var app: String?
        public var hostAPI: Int?
        /// Built-in tool groups the package needs on (`browser` for skills with scripts).
        public var groups: [String]?
        public init(app: String? = nil, hostAPI: Int? = nil, groups: [String]? = nil) {
            self.app = app; self.hostAPI = hostAPI; self.groups = groups
        }
    }

    public struct Permissions: Codable, Sendable, Equatable {
        /// Hosts the tools may reach: an exact host, or `*.suffix`.
        public var network: [String]?
        public var privateNetwork: Bool?
        public var secrets: [SecretDeclaration]?
        public var storage: Int?
        /// Built-in groups that may not be on in the same chat.
        public var exclusive: [String]?
        /// Reserved; must be empty in format 1 (no health, location or other app data reaches packages).
        public var data: [String]?

        public init(network: [String]? = nil, privateNetwork: Bool? = nil, secrets: [SecretDeclaration]? = nil,
                    storage: Int? = nil, exclusive: [String]? = nil, data: [String]? = nil) {
            self.network = network; self.privateNetwork = privateNetwork; self.secrets = secrets
            self.storage = storage; self.exclusive = exclusive; self.data = data
        }
    }

    public struct SecretDeclaration: Codable, Sendable, Equatable {
        public var name: String
        public var label: String
        public var help: String?
        /// `bearer`, `basic`, `header:<Name>` or `query:<param>`.
        public var inject: String
        public init(name: String, label: String, help: String? = nil, inject: String) {
            self.name = name; self.label = label; self.help = help; self.inject = inject
        }
    }

    public struct Contents: Codable, Sendable, Equatable {
        public var prompt: String?
        public var skills: [String]?
        public var tools: [PackageTool]?
        public var views: [View]?
        public var commands: [PackageCommand]?
        public var connections: [PackageConnectionPreset]?
        public var policy: String?
        public var hooks: [JSONValue]?

        public init(prompt: String? = nil, skills: [String]? = nil, tools: [PackageTool]? = nil, views: [View]? = nil,
                    commands: [PackageCommand]? = nil, connections: [PackageConnectionPreset]? = nil, policy: String? = nil, hooks: [JSONValue]? = nil) {
            self.prompt = prompt; self.skills = skills; self.tools = tools; self.views = views; self.commands = commands
            self.connections = connections; self.policy = policy; self.hooks = hooks
        }
    }

    public struct View: Codable, Sendable, Equatable {
        public var name: String
        public var file: String
    }

    public struct Update: Codable, Sendable, Equatable {
        public var url: String
    }

    // Convenience views with the defaults applied.
    public var tools: [PackageTool] { contents?.tools ?? [] }
    public var commands: [PackageCommand] { contents?.commands ?? [] }
    public var connections: [PackageConnectionPreset] { contents?.connections ?? [] }
    public var skillFiles: [String] { contents?.skills ?? [] }
    public var network: [String] { permissions?.network ?? [] }
    public var secrets: [SecretDeclaration] { permissions?.secrets ?? [] }
    public var privateNetwork: Bool { permissions?.privateNetwork ?? false }
    public var requiredGroups: [String] { requires?.groups ?? [] }
    public var exclusiveGroups: [String] { permissions?.exclusive ?? [] }

    public func secret(named name: String) -> SecretDeclaration? { secrets.first { $0.name == name } }
    public func tool(named name: String) -> PackageTool? { tools.first { $0.name == name } }
}

/// One tool. Format 1 knows `http` (declarative) and `page` (a site plugin: a script run in a hidden web page, for
/// built-in packages only; the app refuses it from any other); `js` comes in a later format and is refused unless the
/// entry says `"optional": true`, in which case it is skipped.
public struct PackageTool: Codable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var title: String?
    public var description: String
    /// A JSON Schema subset (`JSONSchemaSubset`).
    public var parameters: JSONValue?
    public var request: HTTPRequestTemplate?
    public var response: ResponseSpec?
    public var readOnly: Bool?
    /// `never`, `first` or `always`.
    public var confirm: String?
    /// Seconds, 1–120.
    public var timeout: Int?
    public var display: Display?
    public var onDevice: OnDevice?
    public var schemaVersion: Int?
    public var optional: Bool?
    /// For `page` tools: the package file with the page script (defines `window.strataPlugin`).
    public var script: String?
    /// For `page` tools: the page the script runs on.
    public var page: Page?

    public init(name: String, kind: String = "http", title: String? = nil, description: String, parameters: JSONValue? = nil,
                request: HTTPRequestTemplate? = nil, response: ResponseSpec? = nil, readOnly: Bool? = nil, confirm: String? = nil,
                timeout: Int? = nil, display: Display? = nil, onDevice: OnDevice? = nil, schemaVersion: Int? = nil) {
        self.name = name; self.kind = kind; self.title = title; self.description = description; self.parameters = parameters
        self.request = request; self.response = response; self.readOnly = readOnly; self.confirm = confirm
        self.timeout = timeout; self.display = display; self.onDevice = onDevice; self.schemaVersion = schemaVersion
    }

    public struct HTTPRequestTemplate: Codable, Sendable, Equatable {
        public var method: String?
        /// Scheme, host and port fixed; `{arg}` only in path segments.
        public var url: String
        public var query: [String: String]?
        public var headers: [String: String]?
        public var auth: Auth?
        public var body: Body?

        public init(method: String? = nil, url: String, query: [String: String]? = nil, headers: [String: String]? = nil,
                    auth: Auth? = nil, body: Body? = nil) {
            self.method = method; self.url = url; self.query = query; self.headers = headers; self.auth = auth; self.body = body
        }

        public var httpMethod: String { (method ?? "GET").uppercased() }
    }

    public struct Auth: Codable, Sendable, Equatable {
        public var secret: String
        public init(secret: String) { self.secret = secret }
    }

    /// `{ "json": <template> }` or `{ "form": { "key": "{arg}" } }`.
    public struct Body: Codable, Sendable, Equatable {
        public var json: JSONValue?
        public var form: [String: String]?
        public init(json: JSONValue? = nil, form: [String: String]? = nil) { self.json = json; self.form = form }
    }

    public struct ResponseSpec: Codable, Sendable, Equatable {
        /// A JSON Pointer to an array; each element becomes one item.
        public var each: String?
        /// Output field name → JSON Pointer inside an item.
        public var fields: [String: String]?
        public var sources: SourceSpec?
        public var maxCharacters: Int?
        public init(each: String? = nil, fields: [String: String]? = nil, sources: SourceSpec? = nil, maxCharacters: Int? = nil) {
            self.each = each; self.fields = fields; self.sources = sources; self.maxCharacters = maxCharacters
        }
    }

    /// Templates over an item's fields (`{summary}`) that make it a citable source.
    public struct SourceSpec: Codable, Sendable, Equatable {
        public var title: String
        public var url: String
        public var content: String?
        public init(title: String, url: String, content: String? = nil) { self.title = title; self.url = url; self.content = content }
    }

    public struct Display: Codable, Sendable, Equatable {
        /// The argument the feed shows.
        public var argument: String?
        /// Keep the whole result in the chat's feed (capped), not only its first line.
        public var keepResult: Bool?
        public init(argument: String? = nil, keepResult: Bool? = nil) { self.argument = argument; self.keepResult = keepResult }
    }

    /// Offer the tool to the on-device model, with a short description and at most 3 string parameters. `false` (or
    /// leaving it out) keeps it off the device.
    public struct OnDevice: Codable, Sendable, Equatable {
        public var description: String
        public var parameters: [String]?
        public init(description: String, parameters: [String]? = nil) { self.description = description; self.parameters = parameters }
    }

    /// The page a `page` tool opens, as in a site plugin: `{arg}` anywhere in the URL (percent-encoded), the host
    /// within `permissions.network`.
    public struct Page: Codable, Sendable, Equatable {
        public var url: String
        /// Seconds to wait after the page is ready, for client-side rendering.
        public var settle: Double?
        /// A CSS selector the page must show before the script runs.
        public var waitFor: String?
        public init(url: String, settle: Double? = nil, waitFor: String? = nil) { self.url = url; self.settle = settle; self.waitFor = waitFor }
    }

    private enum CodingKeys: String, CodingKey {
        case name, kind, title, description, parameters, request, response, readOnly, confirm, timeout, display, onDevice
        case schemaVersion, optional, script, page
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "http"
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decode(String.self, forKey: .description)
        parameters = try c.decodeIfPresent(JSONValue.self, forKey: .parameters)
        request = try c.decodeIfPresent(HTTPRequestTemplate.self, forKey: .request)
        response = try c.decodeIfPresent(ResponseSpec.self, forKey: .response)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly)
        confirm = try c.decodeIfPresent(String.self, forKey: .confirm)
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
        display = try c.decodeIfPresent(Display.self, forKey: .display)
        // `"onDevice": false` is the same as leaving it out.
        if (try? c.decodeIfPresent(Bool.self, forKey: .onDevice)) != nil { onDevice = nil }
        else { onDevice = try c.decodeIfPresent(OnDevice.self, forKey: .onDevice) }
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        optional = try c.decodeIfPresent(Bool.self, forKey: .optional)
        script = try c.decodeIfPresent(String.self, forKey: .script)
        page = try c.decodeIfPresent(Page.self, forKey: .page)
    }

    public static let kinds: Set<String> = ["http", "page"]
    public static let confirmLevels = ["never", "first", "always"]

    /// GET tools only read unless they say otherwise; readOnly tools are safe to retry.
    public var isReadOnly: Bool { readOnly ?? ((request?.httpMethod ?? "GET") == "GET") }
    /// The manifest's level, or the default: never for readOnly tools, always otherwise.
    public var confirmLevel: String { confirm ?? (isReadOnly ? "never" : "always") }
    public var timeoutSeconds: Int { timeout ?? 30 }
    public var effectiveSchemaVersion: Int { schemaVersion ?? 1 }
    public var displayTitle: String { title ?? name }
    public var keepsResult: Bool { display?.keepResult ?? false }
}

/// A composer prompt template (`/triage`).
public struct PackageCommand: Codable, Sendable, Equatable {
    public var name: String
    public var title: String
    /// `{{arg}}` placeholders.
    public var template: String
    public var args: [Arg]?

    public init(name: String, title: String, template: String, args: [Arg]? = nil) {
        self.name = name; self.title = title; self.template = template; self.args = args
    }

    public struct Arg: Codable, Sendable, Equatable {
        public var name: String
        public var label: String?
        public var placeholder: String?
        public init(name: String, label: String? = nil, placeholder: String? = nil) {
            self.name = name; self.label = label; self.placeholder = placeholder
        }
    }

    /// The template with each `{{arg}}` filled; an argument without a value keeps its placeholder text, so the user sees
    /// what to type.
    public func expanded(_ values: [String: String] = [:]) -> String {
        var out = template
        for arg in args ?? [] {
            let value = values[arg.name].flatMap { $0.isEmpty ? nil : $0 } ?? arg.placeholder ?? arg.label ?? arg.name
            out = out.replacingOccurrences(of: "{{\(arg.name)}}", with: value)
        }
        return out
    }
}

/// A connection preset: shown in the add-connection screen under the package's name. Never a key.
public struct PackageConnectionPreset: Codable, Sendable, Equatable {
    public var name: String
    public var url: String
    /// `openai` (Chat Completions, Automatic) or `responses`.
    public var api: String?
    public var images: Bool?
    public var effort: Bool?
    public var resumable: Bool?
    /// One line under the name in the list.
    public var subtitle: String?
    /// Where to get a key, shown in the editor.
    public var keyHelp: String?
    public var managed: Bool?

    public init(name: String, url: String, api: String? = nil, images: Bool? = nil, effort: Bool? = nil, resumable: Bool? = nil,
                subtitle: String? = nil, keyHelp: String? = nil) {
        self.name = name; self.url = url; self.api = api; self.images = images; self.effort = effort
        self.resumable = resumable; self.subtitle = subtitle; self.keyHelp = keyHelp
    }
}

// MARK: - Decoding

extension PackageManifest {
    /// Decodes `manifest.json`, with an error that names the field at fault.
    public static func decode(_ data: Data) throws -> PackageManifest {
        let raw: JSONValue
        do { raw = try JSONValue.parse(data) } catch {
            throw PackageError.invalid("manifest.json is not valid JSON. Check for trailing commas, comments or unquoted keys.")
        }
        guard raw.objectValue != nil else { throw PackageError.invalid("manifest.json must be a JSON object.") }
        if let format = raw["format"]?.intValue, format > Int64(PackageFormat.newest) {
            throw PackageError.newerFormat(Int(format))
        }
        do {
            return try JSONDecoder().decode(PackageManifest.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw PackageError.invalid("manifest.json: \(Self.path(context.codingPath + [key])) is missing.")
        } catch let DecodingError.typeMismatch(type, context) {
            throw PackageError.invalid("manifest.json: \(Self.path(context.codingPath)) must be \(Self.typeName(type)).")
        } catch let DecodingError.valueNotFound(type, context) {
            throw PackageError.invalid("manifest.json: \(Self.path(context.codingPath)) must be \(Self.typeName(type)), not null.")
        } catch {
            throw PackageError.invalid("manifest.json doesn't have the expected shape: \(error.localizedDescription)")
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func typeName(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: "a string"
        case is Int.Type, is Int64.Type: "an integer"
        case is Bool.Type: "true or false"
        case is [Any].Type: "an array"
        default: "an object of the expected shape"
        }
    }

    /// Keys the format doesn't know, as "contents.tools[0].foo": ignored, and listed in the review sheet.
    public static func warnings(_ data: Data) -> [String] {
        guard let raw = try? JSONValue.parse(data) else { return [] }
        var out: [String] = []
        func check(_ value: JSONValue?, _ known: Set<String>, _ path: String) {
            guard let o = value?.objectValue else { return }
            for key in o.keys.sorted() where !known.contains(key) { out.append(path.isEmpty ? key : "\(path).\(key)") }
        }
        check(raw, ["format", "id", "name", "namespace", "version", "description", "publisher", "license", "homepage",
                    "requires", "permissions", "contents", "update"], "")
        check(raw["requires"], ["app", "hostAPI", "groups"], "requires")
        check(raw["permissions"], ["network", "privateNetwork", "secrets", "storage", "exclusive", "data"], "permissions")
        check(raw["contents"], ["prompt", "skills", "tools", "views", "commands", "connections", "policy", "hooks"], "contents")
        for (i, tool) in (raw["contents"]?["tools"]?.arrayValue ?? []).enumerated() {
            let path = "contents.tools[\(i)]"
            check(tool, ["name", "kind", "title", "description", "parameters", "request", "response", "readOnly", "confirm",
                         "timeout", "display", "onDevice", "schemaVersion", "optional", "script", "page"], path)
            check(tool["page"], ["url", "settle", "waitFor"], path + ".page")
            check(tool["request"], ["method", "url", "query", "headers", "auth", "body"], path + ".request")
            check(tool["response"], ["each", "fields", "sources", "maxCharacters"], path + ".response")
        }
        return out
    }
}

public enum PackageFormat {
    /// The newest manifest format this kit understands.
    public static let newest = 1
}
