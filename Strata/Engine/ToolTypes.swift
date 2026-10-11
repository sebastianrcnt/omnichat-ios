import Foundation

/// Result of running a tool on device.
struct ToolOutput: Sendable, Equatable {
    var text: String
    var isError: Bool = false
}

protocol ToolExecuting: Sendable {
    func execute(name: String, arguments: String) async -> ToolOutput
}

/// A persisted tool call plus its result, shown in the tool row and replayed in later requests.
struct ToolCallRecord: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var arguments: String
    var result: String
    var isError: Bool

    /// Human-readable argument (the query or URL).
    var primaryArgument: String {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return arguments }
        switch name {
        case "web_search": return (obj["query"] as? String) ?? arguments
        case "web_fetch": return (obj["url"] as? String) ?? arguments
        default: return arguments
        }
    }

    var toolCall: ToolCall { ToolCall(id: id, name: name, arguments: arguments) }
}

/// One tool round: the assistant message that requested tools, and the results.
struct ToolStep: Codable, Hashable, Sendable {
    var assistantContent: String
    var calls: [ToolCallRecord]
}

enum ToolNames {
    static let webSearch = "web_search"
    static let webFetch = "web_fetch"
}

/// Plain-value message used to build API history without touching SwiftData.
struct HistoryMessage: Sendable, Equatable {
    var role: String          // "user" | "assistant"
    var text: String
    var images: [Data] = []   // JPEG
    var steps: [ToolStep] = []
}

enum MessageAssembler {
    /// Convert stored conversation messages to API messages, expanding tool steps.
    static func apiMessages(from history: [HistoryMessage]) -> [APIMessage] {
        var out: [APIMessage] = []
        for m in history {
            switch m.role {
            case "user":
                if m.images.isEmpty {
                    out.append(.user(m.text))
                } else {
                    var parts: [ContentPart] = m.images.map { ContentPart.jpegDataURL($0) }
                    if !m.text.isEmpty { parts.append(.text(m.text)) }
                    out.append(.user(parts: parts))
                }
            case "assistant":
                for step in m.steps {
                    appendToolRound(to: &out, assistantContent: step.assistantContent,
                                    calls: step.calls.map(\.toolCall),
                                    results: step.calls.map { ToolOutput(text: $0.result, isError: $0.isError) })
                }
                if !m.text.isEmpty || m.steps.isEmpty { out.append(.assistant(m.text)) }
            default:
                break
            }
        }
        return out
    }

    /// Append the assistant message carrying `tool_calls`, then one `tool` message per call.
    static func appendToolRound(to messages: inout [APIMessage], assistantContent: String,
                                calls: [ToolCall], results: [ToolOutput]) {
        messages.append(.assistant(assistantContent, toolCalls: calls))
        for (call, result) in zip(calls, results) {
            messages.append(.tool(callID: call.id, content: result.text))
        }
    }
}
