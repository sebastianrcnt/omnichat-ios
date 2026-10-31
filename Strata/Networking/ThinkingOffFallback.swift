import Foundation
import os

/// Off sends `reasoning_effort: "none"` and `chat_template_kwargs.enable_thinking: false` to OpenAI-compatible servers
/// (`ChatRequest.setEffort`); a server that knows neither may refuse the request. Refused before any of the answer, it
/// is sent once more without either, so the model answers as it would by default. The refusal is remembered per server
/// and model for the app's run, so later requests skip the failing one.
enum ThinkingOffFallback {
    static func shouldRetry(_ request: ChatRequest, status: Int, body: Data) -> Bool {
        guard isOff(request), [400, 422].contains(status) else { return false }
        let text = ResponsesFallback.errorText(body)
        return ["chat_template_kwargs", "enable_thinking", "reasoning_effort", "reasoning effort"].contains { text.contains($0) }
    }

    static func isOff(_ request: ChatRequest) -> Bool {
        request.chatTemplateKwargs != nil || request.reasoningEffort == Effort.off.apiValue
    }

    /// The request without the thinking controls.
    static func adapted(_ request: ChatRequest) -> ChatRequest {
        var r = request
        r.chatTemplateKwargs = nil
        if r.reasoningEffort == Effort.off.apiValue { r.reasoningEffort = nil }
        return r
    }

    static func isRefused(_ endpoint: Endpoint) -> Bool { refused.withLock { $0.contains(key(endpoint)) } }
    static func remember(_ endpoint: Endpoint) { _ = refused.withLock { $0.insert(key(endpoint)) } }

    private static let refused = OSAllocatedUnfairLock<Set<String>>(initialState: [])
    private static func key(_ endpoint: Endpoint) -> String { endpoint.baseURL.absoluteString + "|" + endpoint.model.id }
}
