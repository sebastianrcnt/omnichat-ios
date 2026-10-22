import Foundation

// URL templates with `{arg}` placeholders, and host lists. Shared by the app's site plugins (`PluginManifest`) and
// package HTTP tools. Plain Foundation, so `Tools/plugin-check` compiles this file as is next to PluginCore.swift.

public enum URLTemplate {
    public enum Failure: Error, Equatable, Sendable {
        /// No value for the placeholder.
        case missing(String)
        /// The filled template isn't an http(s) URL with a host.
        case invalidURL
    }

    /// Characters an argument value keeps in the URL; everything else is percent-encoded (so a value can never add a
    /// path, a query, a port or a user to the URL).
    public static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The `{arg}` names in the template, in order (a `{arg|default}` placeholder's whole text).
    public static func placeholders(in template: String) -> [String] {
        var out: [String] = []
        var rest = template[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    /// A placeholder's argument name and its default: `limit|20` is ("limit", "20").
    public static func split(placeholder: String) -> (name: String, fallback: String?) {
        guard let bar = placeholder.firstIndex(of: "|") else { return (placeholder, nil) }
        return (String(placeholder[..<bar]), String(placeholder[placeholder.index(after: bar)...]))
    }

    /// Fills each placeholder with a value as is (`encode` false) or percent-encoded.
    public static func fill(_ template: String, encode: Bool = true, value: (String) -> String?) throws(Failure) -> String {
        var out = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let key = String(rest[rest.index(after: open)..<close])
            guard let v = value(key) else { throw .missing(key) }
            out += encode ? (v.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "") : v
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    /// The template with each `{arg}` replaced by its percent-encoded value.
    public static func build(template: String, values: [String: String]) throws(Failure) -> URL {
        let filled = try fill(template) { values[$0] }
        guard let url = URL(string: filled), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host(percentEncoded: false)?.isEmpty == false else { throw .invalidURL }
        return url
    }

    /// True when every placeholder sits in the path: after `scheme://host[:port]/` and before any `?` or `#`. Package
    /// tools may only template the path, so the scheme, host and port are fixed by the manifest.
    public static func placeholdersOnlyInPath(_ template: String) -> Bool {
        guard let schemeEnd = template.range(of: "://") else { return !template.contains("{") }
        let afterScheme = template[schemeEnd.upperBound...]
        guard let slash = afterScheme.firstIndex(of: "/") else { return !template.contains("{") }
        let authority = template[..<slash]
        if authority.contains("{") { return false }
        let path = afterScheme[slash...]
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }), path[q...].contains("{") { return false }
        return true
    }

    public static func normalizedHost(_ host: String) -> String {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("*.") { h.removeFirst(2) }
        return h.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// True when `host` is one of `hosts` or a subdomain of one; any host when there is no list.
    public static func hostAllowed(_ host: String, hosts: [String]?) -> Bool {
        guard let hosts else { return true }
        let h = normalizedHost(host)
        guard !h.isEmpty else { return false }
        return hosts.map(normalizedHost).contains { !$0.isEmpty && (h == $0 || h.hasSuffix("." + $0)) }
    }

    /// Package network entries are stricter than plugin host lists: `acme.com` allows only acme.com itself, and
    /// `*.acme.com` allows acme.com and every subdomain.
    public static func packageHostAllowed(_ host: String, network: [String]) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !h.isEmpty else { return false }
        return network.contains { entry in
            let e = entry.lowercased().trimmingCharacters(in: .whitespaces)
            if e.hasPrefix("*.") {
                let suffix = String(e.dropFirst(2))
                return !suffix.isEmpty && (h == suffix || h.hasSuffix("." + suffix))
            }
            return h == e
        }
    }

    /// A network entry: a host name or `*.` and one, letters, digits, `-` and `.` only, no scheme, port or path.
    public static func isValidNetworkEntry(_ entry: String) -> Bool {
        var e = entry.lowercased()
        if e.hasPrefix("*.") { e.removeFirst(2) }
        guard !e.isEmpty, e.count <= 253, !e.hasPrefix("."), !e.hasSuffix("."), !e.contains("..") else { return false }
        return e.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "." }
    }
}
