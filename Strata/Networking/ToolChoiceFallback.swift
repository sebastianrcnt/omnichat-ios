import Foundation
import os

/// Some OpenAI-compatible servers accept only `tool_choice: "auto"` and refuse the `"none"` that capped rounds, the
/// early answer, compaction and title follow-ups send (tools stay listed so the prefix holds; they just may not be
/// called). Refused before any of the answer, the request is sent once more without `tool_choice` and with a short
/// user note saying not to call tools; the callers already ignore calls in those requests. The refusal is remembered
/// per server and model for the app's run, so later requests skip the failing one.
enum ToolChoiceFallback {
    /// Appended as a user message to the retried request. Sent as is; never shown.
    static let nudge = "Do not call any tools in this reply. Answer now with what you have."

    static func shouldRetry(_ request: ChatRequest, status: Int, body: Data) -> Bool {
        guard request.toolChoice == "none", [400, 422].contains(status) else { return false }
        let text = ResponsesFallback.errorText(body)
        return text.contains("tool_choice") || text.contains("tool choice")
    }

    /// The request as such a server takes it: no `tool_choice`, and the note at the end.
    static func adapted(_ request: ChatRequest) -> ChatRequest {
        var r = request
        r.toolChoice = nil
        r.messages.append(.user(nudge))
        return r
    }

    static func isRefused(_ endpoint: Endpoint) -> Bool { refused.withLock { $0.contains(key(endpoint)) } }
    static func remember(_ endpoint: Endpoint) { _ = refused.withLock { $0.insert(key(endpoint)) } }
    static func forgetAll() { refused.withLock { $0.removeAll() } }

    private static let refused = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private static func key(_ endpoint: Endpoint) -> String { endpoint.baseURL.absoluteString + "|" + endpoint.model.id }
}
