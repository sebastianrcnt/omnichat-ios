import Foundation

/// Makes request bodies and reports safe to hand to someone else. It works on the text, so every other byte of a
/// request (key order, spacing) is kept exactly as it was sent.
enum DebugRedaction {
    struct Options: Equatable, Sendable {
        /// Replace inline image data URLs with `<image N bytes>`.
        var stripImages = true
        init(stripImages: Bool = true) { self.stripImages = stripImages }
    }

    // `\/` is accepted inside the payload because some encoders escape slashes.
    private static let imageURL = try! NSRegularExpression(
        pattern: #"data:image(?:\\?/)[A-Za-z0-9.+-]+;base64,((?:[A-Za-z0-9+=]|\\?/)+)"#)
    private static let secretField = try! NSRegularExpression(
        pattern: #"("[^"]*(?:authorization|api[_-]?key|apikey|token|secret|password|cookie|verifier)[^"]*"\s*:\s*")(?:[^"\\]|\\.)*(")"#,
        options: [.caseInsensitive])
    /// Form-encoded and query secrets (OAuth token requests): `refresh_token=…&client_secret=…`.
    private static let formSecret = try! NSRegularExpression(
        pattern: #"(?i)\b((?:[a-z_]*token|client_secret|code_verifier|code|password|api_?key|key)=)[^&\s"]+"#)
    private static let bearer = try! NSRegularExpression(pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#)
    private static let skKey = try! NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9_-]{16,}"#)
    /// SSH secrets: private keys anywhere, the secret arguments of `ssh_` calls (JSON inside a JSON string), and the
    /// lines of an `ssh_credential_get` result.
    private static let privateKey = try! NSRegularExpression(
        pattern: #"-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, options: [.dotMatchesLineSeparators])
    private static let sshArgument = try! NSRegularExpression(
        pattern: #"(\\"(?:password|passphrase|private_key|stdin|answers|certificate)\\"\s*:\s*\\")(?:[^"\\]|\\[^"])*(\\")"#)
    private static let sshResultLine = try! NSRegularExpression(
        pattern: #"((?:\\n|^)(?:password|passphrase): )(?:[^"\\]|\\[^n"])*"#, options: [.anchorsMatchLines])

    static func redact(_ text: String, options: Options = Options()) -> String {
        var out = text
        if options.stripImages { out = stripImages(out) }
        out = replace(secretField, in: out) { _, groups in groups[1] + "<redacted>" + groups[2] }
        out = replace(formSecret, in: out) { _, groups in groups[1] + "<redacted>" }
        out = replace(bearer, in: out) { _, _ in "Bearer <redacted>" }
        out = replace(skKey, in: out) { _, _ in "sk-<redacted>" }
        out = replace(privateKey, in: out) { _, groups in "-----BEGIN \(groups[1])PRIVATE KEY----- <redacted>" }
        out = replace(sshArgument, in: out) { _, groups in groups[1] + "<redacted>" + groups[2] }
        out = replace(sshResultLine, in: out) { _, groups in groups[1] + "<redacted>" }
        return out
    }

    static func redact(_ data: Data, options: Options = Options()) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        return Data(redact(text, options: options).utf8)
    }

    static func stripImages(_ text: String) -> String {
        replace(imageURL, in: text) { _, groups in
            let payload = groups[1].replacingOccurrences(of: "\\/", with: "/")
            let padding = payload.reversed().prefix(while: { $0 == "=" }).count
            let bytes = max(0, payload.utf8.count * 3 / 4 - padding)
            return "<image \(bytes) bytes>"
        }
    }

    /// Replaces every match; `groups[0]` is the whole match, the rest are capture groups.
    private static func replace(_ regex: NSRegularExpression, in text: String,
                                _ make: (String, [String]) -> String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += make(groups[0], groups)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
