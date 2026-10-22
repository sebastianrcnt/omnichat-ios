import Foundation

/// Any JSON value, decoded without `NSNumber` guesswork: booleans stay booleans and integers stay integers. Packages
/// carry schemas, request bodies and API responses as these.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses JSON text (any value at the top, not only objects).
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }

    /// An integer, also from a double with no fraction.
    public var intValue: Int64? {
        switch self {
        case .int(let i): i
        case .double(let d) where d.rounded() == d && abs(d) < 9e15: Int64(d)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// The value as text for a template: strings as they are, numbers and booleans printed, null as "", arrays and
    /// objects as canonical JSON.
    public var templateText: String {
        switch self {
        case .null: ""
        case .string(let s): s
        case .bool(let b): b ? "true" : "false"
        case .int(let i): String(i)
        case .double: canonical
        case .array, .object: canonical
        }
    }

    /// RFC 6901 JSON Pointer: "" is the value itself, "/a/0/b" walks objects and arrays (`~1` is "/", `~0` is "~").
    public func pointer(_ pointer: String) -> JSONValue? {
        guard !pointer.isEmpty else { return self }
        guard pointer.hasPrefix("/") else { return nil }
        var current = self
        for raw in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let token = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            switch current {
            case .object(let o):
                guard let next = o[token] else { return nil }
                current = next
            case .array(let a):
                guard let i = Int(token), a.indices.contains(i) else { return nil }
                current = a[i]
            default:
                return nil
            }
        }
        return current
    }

    /// Whether `pointer` is well formed (empty, or starting with "/").
    public static func isValidPointer(_ pointer: String) -> Bool { pointer.isEmpty || pointer.hasPrefix("/") }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a JSON value.") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Canonical JSON

extension JSONValue {
    /// Canonical JSON: object keys sorted by their UTF-8 bytes, no insignificant whitespace, strings with only the
    /// escapes JSON requires (no `\/`, non-ASCII kept as is), integers as written. The same value always gives the same
    /// bytes, which is what snapshots, digests and the prompt cache rely on.
    public var canonical: String {
        var out = ""
        write(to: &out)
        return out
    }

    public var canonicalData: Data { Data(canonical.utf8) }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if d.isFinite, d.rounded() == d, abs(d) < 1e15 { out += String(Int64(d)) }
            else if d.isFinite { out += String(d) }
            else { out += "null" }
        case .string(let s): JSONValue.writeString(s, to: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, key) in o.keys.sorted(by: JSONValue.byteOrder).enumerated() {
                if i > 0 { out += "," }
                JSONValue.writeString(key, to: &out)
                out += ":"
                o[key]!.write(to: &out)
            }
            out += "}"
        }
    }

    /// UTF-8 byte order, the order canonical keys and snapshot entries use.
    public static func byteOrder(_ a: String, _ b: String) -> Bool { Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
