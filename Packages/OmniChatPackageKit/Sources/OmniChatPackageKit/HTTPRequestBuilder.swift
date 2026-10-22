import Foundation

/// Builds the request of a declarative HTTP tool from its template and a call's validated arguments. Pure: no network,
/// no Keychain (secrets come from a closure), so the app and `omnichat-pkg run` build the same bytes.
public enum HTTPRequestBuilder {
    public struct Built: Sendable, Equatable {
        public var method: String
        public var url: URL
        public var headers: [String: String]
        public var body: Data?
        /// What the request does, without credentials: method, URL and body, for the approval card and the audit log.
        public var preview: String
        /// The host the request goes to.
        public var host: String { url.host(percentEncoded: false) ?? "" }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The secret has no value on this device yet.
        case missingSecret(PackageManifest.SecretDeclaration)
        case bad(String)
    }

    /// - Parameters:
    ///   - arguments: already checked against the schema (`JSONSchemaSubset.validateArguments`).
    ///   - secret: the value of a declared secret, or nil when the user hasn't entered it.
    public static func build(tool: PackageTool, manifest: PackageManifest, arguments: [String: JSONValue],
                             secret: (String) -> String?) throws(Failure) -> Built {
        guard let template = tool.request else { throw .bad("the tool has no request.") }
        func value(_ placeholder: String) -> String? {
            let (name, fallback) = URLTemplate.split(placeholder: placeholder)
            return arguments[name]?.templateText ?? fallback
        }
        // Path: every placeholder needs a non-empty value; values are percent-encoded so they stay one segment.
        let path: String
        do {
            path = try URLTemplate.fill(template.url) { p in
                guard let v = value(p), !v.isEmpty else { return nil }
                return v
            }
        } catch {
            if case .missing(let p) = error { throw .bad("\"\(URLTemplate.split(placeholder: p).name)\" is required and can't be empty.") }
            throw .bad("the arguments don't make a valid URL.")
        }
        var query: [(String, String)] = []
        for (name, raw) in (template.query ?? [:]).sorted(by: { JSONValue.byteOrder($0.key, $1.key) }) {
            if let filled = fillOptional(raw, value: value) { query.append((name, filled)) }
        }
        var headers: [String: String] = [:]
        for (name, raw) in template.headers ?? [:] {
            guard let filled = fillOptional(raw, value: value) else { continue }
            guard !filled.contains("\n"), !filled.contains("\r") else { throw .bad("the header \(name) can't hold a line break.") }
            headers[name] = filled
        }
        var body: Data?
        var bodyPreview = ""
        if let json = template.body?.json {
            let filled = substitute(json, arguments: arguments) ?? .null
            body = filled.canonicalData
            bodyPreview = filled.canonical
            if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) { headers["Content-Type"] = "application/json" }
        } else if let form = template.body?.form {
            let pairs = form.sorted(by: { JSONValue.byteOrder($0.key, $1.key) }).compactMap { name, raw in
                fillOptional(raw, value: value).map { (name, $0) }
            }
            let encoded = encodeQuery(pairs)
            body = Data(encoded.utf8)
            bodyPreview = encoded
            if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            }
        }
        func makeURL(_ items: [(String, String)]) throws(Failure) -> URL {
            let text = items.isEmpty ? path : path + (path.contains("?") ? "&" : "?") + encodeQuery(items)
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host(percentEncoded: false)?.isEmpty == false else { throw .bad("the arguments don't make a valid URL.") }
            return url
        }
        let previewURL = try makeURL(query)
        var finalQuery = query
        if let auth = template.auth {
            guard let declaration = manifest.secret(named: auth.secret) else { throw .bad("the secret \(auth.secret) isn't declared.") }
            guard let v = secret(auth.secret), !v.isEmpty else { throw .missingSecret(declaration) }
            switch declaration.inject {
            case "bearer": headers["Authorization"] = "Bearer " + v
            case "basic": headers["Authorization"] = "Basic " + Data(v.utf8).base64EncodedString()
            case let inject where inject.hasPrefix("header:"): headers[String(inject.dropFirst(7))] = v
            case let inject where inject.hasPrefix("query:"): finalQuery.append((String(inject.dropFirst(6)), v))
            default: throw .bad("the secret \(auth.secret) has an unknown injection.")
            }
        }
        let preview = "\(template.httpMethod) \(previewURL.absoluteString)" + (bodyPreview.isEmpty ? "" : "\n\(bodyPreview)")
        return Built(method: template.httpMethod, url: try makeURL(finalQuery), headers: headers, body: body, preview: preview)
    }

    /// A template filled as text. A template that is only one placeholder whose argument is missing (and has no
    /// default) is dropped: an optional argument leaves its query item, header or form field out.
    static func fillOptional(_ template: String, value: (String) -> String?) -> String? {
        let placeholders = URLTemplate.placeholders(in: template)
        if placeholders.count == 1, template == "{\(placeholders[0])}", value(placeholders[0]) == nil { return nil }
        return try? URLTemplate.fill(template, encode: false) { value($0) ?? "" }
    }

    /// A JSON body template: a string that is exactly `{arg}` becomes the argument's typed value (dropped from its
    /// object when missing); any other string is filled as text.
    static func substitute(_ template: JSONValue, arguments: [String: JSONValue]) -> JSONValue? {
        switch template {
        case .string(let s):
            let placeholders = URLTemplate.placeholders(in: s)
            if placeholders.count == 1, s == "{\(placeholders[0])}" {
                let (name, fallback) = URLTemplate.split(placeholder: placeholders[0])
                return arguments[name] ?? fallback.map(JSONValue.string)
            }
            return .string((try? URLTemplate.fill(s, encode: false) { p in
                let (name, fallback) = URLTemplate.split(placeholder: p)
                return arguments[name]?.templateText ?? fallback ?? ""
            }) ?? s)
        case .array(let a): return .array(a.compactMap { substitute($0, arguments: arguments) })
        case .object(let o): return .object(o.compactMapValues { substitute($0, arguments: arguments) })
        default: return template
        }
    }

    /// `a=1&b=x%20y`, every name and value percent-encoded but for unreserved characters.
    public static func encodeQuery(_ items: [(String, String)]) -> String {
        items.map { name, value in
            (name.addingPercentEncoding(withAllowedCharacters: URLTemplate.unreserved) ?? "") + "="
                + (value.addingPercentEncoding(withAllowedCharacters: URLTemplate.unreserved) ?? "")
        }.joined(separator: "&")
    }
}
