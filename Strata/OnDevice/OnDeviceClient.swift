import Foundation

/// Streams a turn from Apple's on-device model. Every request that goes through the app's streamer (turns, titles, a
/// "Summarize now") lands here for an on-device endpoint (`ChatClient` routes it).
///
/// Tools: the framework runs a session's tools itself, inside one response. The app runs tools (with its progress,
/// sources, per-chat switches and refusals), so the session's tools only record the call and stop the answer; the
/// call goes out as a tool-call delta, the app runs it, and the next request carries the result
/// (`OnDevicePromptBuilder`). Only web search and page fetch are offered.
///
/// Context: the prompt is fitted to the window before it is sent. If the model still says it doesn't fit, it is
/// built again with less room, twice; an answer that runs out of room partway ends there, as a cut-off answer.
struct OnDeviceClient: ChatStreaming {
    var model: any OnDeviceLanguageModel = OnDevice.system

    /// Builds of one request: the first, then two with less room after the model says the prompt didn't fit.
    static let attempts = 3
    /// How much of the room for the prompt each new build keeps.
    static let squeezeStep = 0.6

    func stream(_ request: ChatRequest, endpoint: Endpoint) -> AsyncThrowingStream<ChatDelta, Error> {
        let model = model
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let availability = model.availability
                    guard availability.isAvailable else { throw OnDeviceFailure.unavailable(availability) }
                    let tools = OnDevicePromptBuilder.tools(for: request)
                    var squeeze = 1.0
                    for attempt in 1...Self.attempts {
                        let prompt = OnDevicePromptBuilder.build(request, contextSize: model.contextSize,
                                                                 readsImages: model.readsImages, tools: tools, squeeze: squeeze)
                        var answered = false
                        do {
                            try await Self.run(prompt, tools: tools, model: model) { delta in
                                if delta.content?.isEmpty == false { answered = true }
                                continuation.yield(delta)
                            }
                            break
                        } catch OnDeviceFailure.contextExceeded where answered {
                            // The answer itself ran out of room: keep what came, as an answer cut at its limit.
                            continuation.yield(ChatDelta(finishReason: "length"))
                            break
                        } catch OnDeviceFailure.contextExceeded where attempt < Self.attempts {
                            squeeze *= Self.squeezeStep
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let failure as OnDeviceFailure {
                    continuation.finish(throwing: Task.isCancelled ? nil : failure.apiError)
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? nil : OnDeviceFailure.other(error.localizedDescription).apiError)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One response: its text as content deltas, then its tool calls (if it stopped at one), its usage and why it
    /// ended. Usage the system doesn't report is estimated, so the context ring still moves.
    static func run(_ prompt: OnDevicePrompt, tools: [OnDeviceToolSpec], model: any OnDeviceLanguageModel,
                    yield: (ChatDelta) -> Void) async throws {
        var answer = ""
        var calls: [ToolCallDelta] = []
        var usage: Usage?
        for try await event in model.respond(to: prompt, tools: tools) {
            try Task.checkCancellation()
            switch event {
            case .text(let text):
                guard !text.isEmpty else { continue }
                answer += text
                yield(ChatDelta(content: text))
            case .toolCall(let name, let arguments):
                calls.append(ToolCallDelta(index: calls.count, id: "call_\(UUID().uuidString.prefix(8).lowercased())",
                                           name: name, arguments: arguments))
            case .usage(let input, let output):
                usage = Usage(promptTokens: input, completionTokens: output)
            }
        }
        try Task.checkCancellation()
        if !calls.isEmpty { yield(ChatDelta(toolCalls: calls)) }
        yield(ChatDelta(usage: usage ?? estimatedUsage(prompt, answer: answer)))
        yield(ChatDelta(finishReason: calls.isEmpty ? "stop" : "tool_calls"))
    }

    /// Tokens of the prompt and the answer, by `OnDevicePromptBuilder.estimateTokens`.
    static func estimatedUsage(_ prompt: OnDevicePrompt, answer: String) -> Usage {
        let texts = [prompt.instructions, prompt.prompt] + prompt.history.map(\.text)
        let input = texts.reduce(0) { $0 + OnDevicePromptBuilder.estimateTokens($1) + OnDevicePromptBuilder.turnOverhead }
        return Usage(promptTokens: input, completionTokens: OnDevicePromptBuilder.estimateTokens(answer))
    }
}
