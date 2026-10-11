import Foundation

/// Reads a recorded chat request body and compares it with the one before it. Ported from atto's debug bundle
/// (`requestMessages`, `prefixNote`, `sameJSON`): a growing conversation should send each request as the previous one
/// plus new messages, because that is what keeps the provider's prompt cache warm.
enum RequestInspection {
    static func root(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// The body's `messages` array (or `input` for response-style bodies).
    static func messages(in body: Data) -> [Any] {
        guard let root = root(body) else { return [] }
        return (root["messages"] as? [Any]) ?? (root["input"] as? [Any]) ?? []
    }

    static func tools(in body: Data) -> Any? { root(body)?["tools"] }

    static func role(of message: Any) -> String {
        ((message as? [String: Any])?["role"] as? String) ?? "?"
    }

    /// Equal parsed JSON, ignoring key order and spacing.
    static func sameJSON(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return (x as AnyObject).isEqual(y)
        default: return false
        }
    }
}

/// Describes how a request relates to the one before it.
enum PrefixNote {
    struct Result: Equatable {
        var note: String
        var toolsDiffer: Bool

        /// `"same prefix, +2 messages; tools differ"`.
        var text: String { toolsDiffer ? note + "; tools differ" : note }
    }

    /// Message-by-message comparison. Indexes are positions in the `messages` array, starting at 0.
    static func compute(previous: [Any], current: [Any]) -> String {
        for (i, old) in previous.enumerated() {
            if i >= current.count {
                return "shorter than the previous request (\(current.count) of its \(previous.count) messages)"
            }
            if !RequestInspection.sameJSON(old, current[i]) {
                return "diverges at message \(i) (\(RequestInspection.role(of: current[i])))"
            }
        }
        let added = current.count - previous.count
        return added == 1 ? "same prefix, +1 message" : "same prefix, +\(added) messages"
    }

    /// The note for `current` against `previous` bodies; nil when there is no previous request.
    static func describe(previous: Data?, current: Data) -> Result? {
        guard let previous else { return nil }
        let note = compute(previous: RequestInspection.messages(in: previous), current: RequestInspection.messages(in: current))
        let differ = !RequestInspection.sameJSON(RequestInspection.tools(in: previous), RequestInspection.tools(in: current))
        return Result(note: note, toolsDiffer: differ)
    }
}
