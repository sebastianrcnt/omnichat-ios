import Foundation

/// What a package adds to a request, rendered to fixed bytes: the prompt section and the tool definitions. Nothing here
/// depends on the time, the locale or the order packages were installed, so a chat's frozen copy matches what a new
/// chat would render for the same package version.
public enum PackageRender {
    /// `<namespace>__<tool>`.
    public static func toolName(namespace: String, tool: String) -> String { namespace + "__" + tool }

    /// The namespace and tool of a full name, nil for names without the double underscore.
    public static func split(toolName: String) -> (namespace: String, tool: String)? {
        guard let range = toolName.range(of: "__") else { return nil }
        let ns = String(toolName[..<range.lowerBound]), tool = String(toolName[range.upperBound...])
        guard !ns.isEmpty, !tool.isEmpty else { return nil }
        return (ns, tool)
    }

    /// The OpenAI function definition, as a JSON value: `{"type":"function","function":{name, description, parameters}}`.
    public static func toolDefinition(namespace: String, tool: PackageTool) -> JSONValue {
        let parameters = JSONSchemaSubset.modelSchema(tool.parameters ?? .object(["type": .string("object"), "properties": .object([:])]))
        return .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(toolName(namespace: namespace, tool: tool.name)),
                "description": .string(normalize(tool.description.trimmingCharacters(in: .whitespacesAndNewlines))),
                "parameters": normalizeStrings(parameters),
            ]),
        ])
    }

    /// The system prompt section:
    ///
    ///     Package "Acme Jira" (tools jira__*):
    ///     <prompt.md, trimmed>
    ///     Skills (load one with load_skill before a task it covers):
    ///     - jira:triage: ...
    ///
    /// "" when the package has no prompt and no skills: its tools describe themselves.
    public static func promptSection(name: String, namespace: String, hasTools: Bool, prompt: String?,
                                     skills: [(name: String, description: String)]) -> String {
        let text = escapeFragment(normalize(prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty || !skills.isEmpty else { return "" }
        let label = escapeFragment(normalize(name)).replacingOccurrences(of: "\"", with: "'")
        var lines = ["Package \"\(label)\"" + (hasTools ? " (tools \(namespace)__*):" : ":")]
        if !text.isEmpty { lines.append(text) }
        if !skills.isEmpty {
            lines.append("Skills (load one with load_skill before a task it covers):")
            for s in skills.sorted(by: { JSONValue.byteOrder($0.name, $1.name) }) {
                let d = escapeFragment(normalize(s.description)).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                lines.append("- \(namespace):\(s.name): \(d)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Keeps a fragment from forging the app's structure: the user's preferences tags, source blocks and the date line.
    public static func escapeFragment(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "<userPreferences>", with: "&lt;userPreferences>", options: .caseInsensitive)
            .replacingOccurrences(of: "</userPreferences>", with: "&lt;/userPreferences>", options: .caseInsensitive)
            .replacingOccurrences(of: "</source", with: "<\\/source")
        out = out.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasPrefix("Current date:") ? "(" + line + ")" : String(line)
        }.joined(separator: "\n")
        return out
    }

    /// LF line ends and NFC, as packages are stored.
    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").precomposedStringWithCanonicalMapping
    }

    static func normalizeStrings(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): .string(normalize(s))
        case .array(let a): .array(a.map(normalizeStrings))
        case .object(let o): .object(Dictionary(uniqueKeysWithValues: o.map { (normalize($0.key), normalizeStrings($0.value)) }))
        default: value
        }
    }
}
