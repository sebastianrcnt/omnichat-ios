import Foundation

enum TurnEvent: Sendable {
    case reasoning(String)
    case content(String)
    case toolsRequested([ToolCall])
    case toolFinished(ToolCallRecord)
    case usage(Usage)
    /// A new request is about to start (round 0 is the first).
    case roundStarted(Int)
}

struct TurnOutcome: Sendable, Equatable {
    var steps: [ToolStep]
    var finalContent: String
    var finalReasoning: String
    var lastUsage: Usage?
    var hitToolCap: Bool
}

/// Runs one assistant turn: stream, execute tool calls on device, append results, continue.
struct TurnRunner: Sendable {
    static let maxToolRounds = 8

    var streamer: any ChatStreaming
    var tools: any ToolExecuting

    /// - Parameter messages: the API history up to and including the new user message.
    @MainActor
    func run(endpoint: Endpoint,
             messages initial: [APIMessage],
             effort: Effort?,
             sources: SourceStore? = nil,
             onEvent: @MainActor (TurnEvent) -> Void) async throws -> TurnOutcome {
        var messages = initial
        var steps: [ToolStep] = []
        var lastUsage: Usage?
        var hitCap = false
        var finalReasoning = ""
        let toolsEnabled = endpoint.model.supportsTools

        var round = 0
        while true {
            try Task.checkCancellation()
            let capped = round >= Self.maxToolRounds
            if capped { hitCap = true }
            var request = ChatRequest(model: endpoint.model.id, messages: messages)
            if endpoint.model.supportsEffort, let effort { request.reasoningEffort = effort.apiValue }
            if toolsEnabled {
                request.tools = ToolDefinition.standard // identical on every request
                if capped { request.toolChoice = "none" }
            }
            onEvent(.roundStarted(round))

            var acc = StreamAccumulator()
            for try await delta in streamer.stream(request, endpoint: endpoint) {
                if let r = delta.reasoning, !r.isEmpty { onEvent(.reasoning(r)) }
                if let c = delta.content, !c.isEmpty { onEvent(.content(c)) }
                acc.apply(delta)
                if let u = delta.usage { onEvent(.usage(u)) }
            }
            if let u = acc.usage { lastUsage = u }
            finalReasoning = acc.reasoning

            let calls = capped || !toolsEnabled ? [] : acc.toolCalls
            if calls.isEmpty {
                return TurnOutcome(steps: steps, finalContent: acc.content, finalReasoning: finalReasoning,
                                   lastUsage: lastUsage, hitToolCap: hitCap)
            }

            onEvent(.toolsRequested(calls))
            var records: [ToolCallRecord] = []
            var outputs: [ToolOutput] = []
            for call in calls {
                try Task.checkCancellation()
                var out = await tools.execute(name: call.name, arguments: call.arguments)
                var ids: [Int] = []
                if let sources, !out.sources.isEmpty, !out.isError {
                    let infos = out.sources.map { sources.assign($0) }
                    ids = infos.map(\.id)
                    out.text = zip(infos, out.sources).map { SourceFormatter.block($0, content: $1.content) }.joined(separator: "\n")
                }
                let record = ToolCallRecord(id: call.id, name: call.name, arguments: call.arguments,
                                            result: out.text, isError: out.isError, sourceIDs: ids)
                records.append(record)
                outputs.append(out)
                onEvent(.toolFinished(record))
            }
            MessageAssembler.appendToolRound(to: &messages, assistantContent: acc.content, calls: calls, results: outputs)
            steps.append(ToolStep(assistantContent: acc.content, calls: records))
            round += 1
        }
    }
}
