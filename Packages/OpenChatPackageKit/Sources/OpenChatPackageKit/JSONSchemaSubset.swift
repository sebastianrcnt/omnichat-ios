import Foundation

/// The JSON Schema subset tool parameters use, chosen to work with local models and chat templates: `type`
/// (object, string, integer, number, boolean, array), `description`, `enum`, `properties`, `required`, `items`,
/// `minimum`, `maximum`, `maxLength`, `default`. No `$ref`, `oneOf`, `anyOf` or `patternProperties`; at most 4 levels
/// deep and 4 KB per tool; numbers are integers.
///
/// One extension for HTTP tools: a top-level string parameter may declare `capture`, a regular expression with one
/// group. The host matches it against the value and uses the group, so a tool can take a full link and use the id in
/// it (`https://x.com/a/status/123` gives `123`). It is left out of what the model sees (`modelSchema`).
public enum JSONSchemaSubset {
    public static let maxDepth = 4
    public static let maxBytes = 4096
    static let types: Set<String> = ["object", "string", "integer", "number", "boolean", "array"]
    static let keywords: Set<String> = ["type", "description", "enum", "properties", "required", "items", "minimum", "maximum",
                                        "maxLength", "default", "capture"]

    /// Throws `PackageError.invalid` naming the first problem (`where` says which tool).
    public static func validateSchema(_ schema: JSONValue, where place: String) throws {
        func fail(_ m: String) -> PackageError { .invalid("\(place): \(m)") }
        guard let root = schema.objectValue, root["type"]?.stringValue == "object" else {
            throw fail("parameters must be a JSON Schema object with \"type\": \"object\".")
        }
        if modelSchema(schema).canonical.utf8.count > maxBytes { throw fail("parameters are larger than \(maxBytes) bytes.") }
        try check(schema, depth: 1, path: "parameters", top: true, fail: fail)
    }

    private static func check(_ schema: JSONValue, depth: Int, path: String, top: Bool, fail: (String) -> PackageError) throws {
        guard depth <= maxDepth else { throw fail("\(path) is nested deeper than \(maxDepth) levels.") }
        guard let o = schema.objectValue else { throw fail("\(path) must be an object.") }
        if let bad = o.keys.sorted().first(where: { !keywords.contains($0) }) {
            throw fail("\(path) uses \"\(bad)\", which isn't supported. Use only: \(keywords.subtracting(["capture"]).sorted().joined(separator: ", ")).")
        }
        guard let type = o["type"]?.stringValue, types.contains(type) else {
            throw fail("\(path) needs a \"type\": one of \(types.sorted().joined(separator: ", ")).")
        }
        if let d = o["description"], d.stringValue == nil { throw fail("\(path).description must be a string.") }
        for key in ["minimum", "maximum", "maxLength"] {
            if let v = o[key], case .int = v {} else if o[key] != nil { throw fail("\(path).\(key) must be an integer.") }
        }
        if let values = o["enum"] {
            guard let list = values.arrayValue, !list.isEmpty else { throw fail("\(path).enum must be a non-empty array.") }
            for v in list where !matches(v, type: type) { throw fail("\(path).enum holds \(v.canonical), which isn't a \(type).") }
        }
        if let d = o["default"], !matches(d, type: type) { throw fail("\(path).default must be a \(type).") }
        if let capture = o["capture"] {
            guard top, type == "string", let pattern = capture.stringValue else {
                throw fail("\(path).capture is only for top-level string parameters, as a regular expression.")
            }
            guard let regex = try? NSRegularExpression(pattern: pattern), regex.numberOfCaptureGroups >= 1 else {
                throw fail("\(path).capture must be a regular expression with one capture group, like \"status/(\\\\d+)\".")
            }
        }
        switch type {
        case "object":
            let props = o["properties"]?.objectValue ?? [:]
            if o["properties"] != nil, o["properties"]?.objectValue == nil { throw fail("\(path).properties must be an object.") }
            for (name, sub) in props.sorted(by: { $0.key < $1.key }) {
                guard isPropertyName(name) else {
                    throw fail("\(path) has a property named \"\(name)\": use letters, digits and _ (starting with a letter).")
                }
                try check(sub, depth: depth + 1, path: "\(path).\(name)", top: depth == 1, fail: fail)
            }
            if let req = o["required"] {
                guard let list = req.arrayValue?.compactMap(\.stringValue), list.count == req.arrayValue?.count else {
                    throw fail("\(path).required must be an array of property names.")
                }
                for name in list where props[name] == nil { throw fail("\(path).required names \"\(name)\", which isn't a property.") }
            }
        case "array":
            guard let items = o["items"] else { throw fail("\(path) is an array and needs \"items\".") }
            try check(items, depth: depth + 1, path: "\(path).items", top: false, fail: fail)
        default:
            if o["properties"] != nil || o["items"] != nil { throw fail("\(path) is a \(type) and can't have properties or items.") }
        }
    }

    static func isPropertyName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, s.count <= 64, first.isASCII, CharacterSet.letters.contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }

    static func matches(_ v: JSONValue, type: String) -> Bool {
        switch type {
        case "string": v.stringValue != nil
        case "integer": v.intValue != nil
        case "number": v.doubleValue != nil
        case "boolean": v.boolValue != nil
        case "array": v.arrayValue != nil
        case "object": v.objectValue != nil
        default: false
        }
    }

    /// The schema the model sees: `capture` taken out.
    public static func modelSchema(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case .object(var o):
            o["capture"] = nil
            return .object(o.mapValues(modelSchema))
        case .array(let a):
            return .array(a.map(modelSchema))
        default:
            return schema
        }
    }

    /// "jql (required), limit": what a tool takes, for error messages.
    public static func summary(_ schema: JSONValue?) -> String {
        let props = schema?["properties"]?.objectValue ?? [:]
        guard !props.isEmpty else { return "no arguments" }
        let required = Set(schema?["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        return props.keys.sorted().map { required.contains($0) ? "\($0) (required)" : $0 }.joined(separator: ", ")
    }

    /// Checks a call's arguments against the schema and returns them with defaults filled in and `capture` applied.
    /// Numbers and booleans sent as strings ("20", "true") are converted; anything else wrong throws a message that
    /// tells the model what the tool takes.
    public static func validateArguments(_ arguments: JSONValue, schema: JSONValue?, tool: String) throws -> [String: JSONValue] {
        func fail(_ m: String) -> PackageError { .invalid("Bad arguments for \(tool): \(m) It takes: \(summary(schema)).") }
        let given: [String: JSONValue]
        switch arguments {
        case .object(let o): given = o
        case .null: given = [:]
        default: throw fail("the arguments must be a JSON object.")
        }
        let props = schema?["properties"]?.objectValue ?? [:]
        if let extra = given.keys.sorted().first(where: { props[$0] == nil }) { throw fail("there is no argument \"\(extra)\".") }
        var out: [String: JSONValue] = [:]
        for (name, value) in given where value != .null {
            var v = try coerce(value, schema: props[name]!, path: name, fail: fail)
            if let pattern = props[name]?["capture"]?.stringValue, let text = v.stringValue {
                v = .string(try capture(text, pattern: pattern, name: name, fail: fail))
            }
            out[name] = v
        }
        for (name, sub) in props where out[name] == nil {
            if let d = sub["default"] { out[name] = d }
        }
        for name in schema?["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where out[name] == nil {
            throw fail("\"\(name)\" is required.")
        }
        return out
    }

    private static func capture(_ text: String, pattern: String, name: String, fail: (String) -> PackageError) throws -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            throw fail("\"\(name)\" doesn't have the expected form.")
        }
        for i in 1..<m.numberOfRanges where m.range(at: i).location != NSNotFound {
            return ns.substring(with: m.range(at: i))
        }
        throw fail("\"\(name)\" doesn't have the expected form.")
    }

    private static func coerce(_ value: JSONValue, schema: JSONValue, path: String, fail: (String) -> PackageError) throws -> JSONValue {
        let type = schema["type"]?.stringValue ?? "string"
        var v = value
        switch type {
        case "integer":
            if case .string(let s) = v, let i = Int64(s.trimmingCharacters(in: .whitespaces)) { v = .int(i) }
            guard let i = v.intValue else { throw fail("\"\(path)\" must be an integer.") }
            v = .int(i)
            if let min = schema["minimum"]?.intValue, i < min { throw fail("\"\(path)\" must be at least \(min).") }
            if let max = schema["maximum"]?.intValue, i > max { throw fail("\"\(path)\" must be at most \(max).") }
        case "number":
            if case .string(let s) = v, let d = Double(s.trimmingCharacters(in: .whitespaces)) { v = .double(d) }
            guard let d = v.doubleValue else { throw fail("\"\(path)\" must be a number.") }
            if let min = schema["minimum"]?.doubleValue, d < min { throw fail("\"\(path)\" must be at least \(min.formatted()).") }
            if let max = schema["maximum"]?.doubleValue, d > max { throw fail("\"\(path)\" must be at most \(max.formatted()).") }
        case "boolean":
            if case .string(let s) = v, ["true", "false"].contains(s.lowercased()) { v = .bool(s.lowercased() == "true") }
            guard v.boolValue != nil else { throw fail("\"\(path)\" must be true or false.") }
        case "string":
            switch v {
            case .string: break
            case .int, .double: v = .string(v.templateText) // an id sent as a number
            default: throw fail("\"\(path)\" must be a string.")
            }
            if let max = schema["maxLength"]?.intValue, Int64(v.stringValue!.count) > max {
                throw fail("\"\(path)\" must be at most \(max) characters.")
            }
        case "array":
            guard let list = v.arrayValue else { throw fail("\"\(path)\" must be an array.") }
            let items = schema["items"] ?? .object(["type": .string("string")])
            v = .array(try list.enumerated().map { try coerce($1, schema: items, path: "\(path)[\($0)]", fail: fail) })
        case "object":
            guard let o = v.objectValue else { throw fail("\"\(path)\" must be an object.") }
            let props = schema["properties"]?.objectValue ?? [:]
            if let extra = o.keys.sorted().first(where: { props[$0] == nil }) { throw fail("\"\(path)\" has no field \"\(extra)\".") }
            var out: [String: JSONValue] = [:]
            for (k, sub) in o where sub != .null { out[k] = try coerce(sub, schema: props[k]!, path: "\(path).\(k)", fail: fail) }
            for k in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where out[k] == nil {
                throw fail("\"\(path).\(k)\" is required.")
            }
            v = .object(out)
        default:
            break
        }
        if let options = schema["enum"]?.arrayValue, !options.contains(v) {
            throw fail("\"\(path)\" must be one of \(options.map(\.canonical).joined(separator: ", ")).")
        }
        return v
    }
}
