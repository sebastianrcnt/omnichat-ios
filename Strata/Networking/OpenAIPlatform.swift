import Foundation

/// What OpenAI's own API (`api.openai.com`, the OpenAI preset) takes that a gateway doesn't, and the models of the
/// known providers that can't chat. Other OpenAI-compatible servers get requests and model lists unchanged.
enum OpenAIPlatform {
    static func isHost(_ url: URL?) -> Bool { url?.host()?.lowercased() == "api.openai.com" }

    static func isHost(_ endpoint: Endpoint) -> Bool { endpoint.kind == .openAICompatible && isHost(endpoint.baseURL) }

    // MARK: Effort

    /// The `reasoning_effort` levels a model takes: low, medium and high (o-series, GPT-5), plus `xhigh` from GPT-5.2 on
    /// and on the codex-max models. Max isn't an OpenAI level.
    static func effortLevels(model: String) -> [Effort] {
        let id = model.lowercased()
        if id.contains("codex-max") || (gpt5Minor(id) ?? 0) >= 2 { return [.low, .medium, .high, .xhigh] }
        return [.low, .medium, .high]
    }

    /// The least thinking a model takes, for "thinking off" (the title request): `none` from GPT-5.1 on, `minimal` on
    /// GPT-5, `low` on the o-series.
    static func leastEffort(model: String) -> String {
        let id = model.lowercased()
        guard let minor = gpt5Minor(id) else { return Effort.low.apiValue }
        return minor >= 1 ? "none" : "minimal"
    }

    /// 0 for `gpt-5…`, N for `gpt-5.N…`, nil for any other model.
    private static func gpt5Minor(_ id: String) -> Int? {
        guard id.hasPrefix("gpt-5") else { return nil }
        let rest = id.dropFirst("gpt-5".count)
        guard rest.first == "." else { return 0 }
        return Int(rest.dropFirst().prefix { $0.isNumber }) ?? 0
    }

    /// The request as OpenAI takes it: the output cap as `max_completion_tokens` (`max_tokens` is refused by the
    /// o-series), the effort as one of the model's levels, and no `chat_template_kwargs` (a parameter it doesn't know).
    static func adapted(_ request: ChatRequest) -> ChatRequest {
        var r = request
        if let cap = r.maxTokens {
            r.maxCompletionTokens = cap
            r.maxTokens = nil
        }
        if let raw = r.reasoningEffort {
            if let effort = Effort(rawValue: raw) {
                r.reasoningEffort = effort.resolved(in: effortLevels(model: r.model)).apiValue
            } else if raw == "none" {
                r.reasoningEffort = leastEffort(model: r.model)
            }
        }
        r.chatTemplateKwargs = nil
        return r
    }

    // MARK: Models

    /// Whether a `/models` entry can answer a chat. OpenAI and Groq list their embedding, speech, transcription, image
    /// and moderation models in the same list; those are left out. Every other server's list is taken as it is, and a
    /// model added by hand is never filtered.
    static func isChatModel(_ id: String, baseURL: URL) -> Bool {
        let host = baseURL.host()?.lowercased() ?? ""
        let id = id.lowercased()
        let name = id.split(separator: "/").last.map(String.init) ?? id
        if host == "api.groq.com" {
            return !(name.contains("whisper") || name.contains("tts") || name.contains("orpheus"))
        }
        guard host == "api.openai.com" else { return true }
        let prefixes = ["text-embedding", "whisper", "tts-", "dall-e", "gpt-image", "sora", "omni-moderation",
                        "text-moderation", "babbage", "davinci"]
        let parts = ["embedding", "transcribe", "-tts", "realtime", "moderation", "-instruct"]
        return !prefixes.contains { name.hasPrefix($0) } && !parts.contains { name.contains($0) }
    }
}
