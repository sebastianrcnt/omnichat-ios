import Foundation

enum TurnEvent: Sendable {
    case reasoning(String)
    case content(String)
    case toolsRequested([ToolCall])
    case toolFinished(ToolCallRecord)
    case usage(Usage)
    /// A new request is about to start (round 0 is the first).
    case roundStarted(Int)
    case checkpoint(TurnCheckpoint)
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
             checkpoint restored: TurnCheckpoint? = nil,
             onEvent: @MainActor (TurnEvent) -> Void) async throws -> TurnOutcome {
        var checkpoint = try restored ?? TurnCheckpoint(messages: initial)
        var messages = try checkpoint.messages
        var steps: [ToolStep] = checkpoint.steps
        var lastUsage: Usage?
        var hitCap = false
        var finalReasoning = ""
        let toolsEnabled = endpoint.model.supportsTools

        var round = checkpoint.round
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

            if restored != nil && round == restored?.round {
                if !checkpoint.accumulator.reasoning.isEmpty { onEvent(.reasoning(checkpoint.accumulator.reasoning)) }
                if !checkpoint.accumulator.content.isEmpty { onEvent(.content(checkpoint.accumulator.content)) }
            }
            onEvent(.checkpoint(checkpoint))
            if !checkpoint.streamDone {
                if endpoint.supportsResumable && restored?.round == round && checkpoint.submissionStarted && checkpoint.requestID == nil {
                    throw APIError.transport(String(localized: "The reply connection was lost before the server returned its request id. It cannot be safely retried automatically."))
                }
                checkpoint.submissionStarted = true
                onEvent(.checkpoint(checkpoint))
                let stream: AsyncThrowingStream<ChatDelta, Error>
                if endpoint.supportsResumable, let resumable = streamer as? any ResumableChatStreaming {
                    stream = resumable.stream(request, endpoint: endpoint, checkpoint: checkpoint)
                } else {
                    stream = streamer.stream(request, endpoint: endpoint)
                }
                for try await delta in stream {
                    try Task.checkCancellation()
                    guard try checkpoint.apply(delta) else { continue }
                    if let r = delta.reasoning, !r.isEmpty { onEvent(.reasoning(r)) }
                    if let c = delta.content, !c.isEmpty { onEvent(.content(c)) }
                    if let u = delta.usage { onEvent(.usage(u)) }
                    onEvent(.checkpoint(checkpoint))
                }
                try Task.checkCancellation()
                checkpoint.streamDone = true
                onEvent(.checkpoint(checkpoint))
            }
            let acc = checkpoint.accumulator
            if let u = acc.usage { lastUsage = u }
            finalReasoning = acc.reasoning

            let calls = capped || !toolsEnabled ? [] : acc.toolCalls
            if calls.isEmpty {
                return TurnOutcome(steps: steps, finalContent: acc.content, finalReasoning: finalReasoning,
                                   lastUsage: lastUsage, hitToolCap: hitCap)
            }

            onEvent(.toolsRequested(calls))
            var records: [ToolCallRecord] = checkpoint.records
            var outputs = records.map { ToolOutput(text: $0.result, isError: $0.isError) }
            for record in records { onEvent(.toolFinished(record)) }
            for call in calls {
                if records.contains(where: { $0.id == call.id }) { continue }
                try Task.checkCancellation()
                var out = try await ToolExecutionRecovery.execute(call, using: tools)
                try Task.checkCancellation()
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
                checkpoint.records = records
                onEvent(.checkpoint(checkpoint))
            }
            MessageAssembler.appendToolRound(to: &messages, assistantContent: acc.content, calls: calls, results: outputs)
            steps.append(ToolStep(assistantContent: acc.content, calls: records))
            round += 1
            let priorReasoning = checkpoint.priorReasoning + acc.reasoning + "\n\n"
            checkpoint = try TurnCheckpoint(messages: messages)
            checkpoint.round = round
            checkpoint.steps = steps
            checkpoint.priorReasoning = priorReasoning
            onEvent(.checkpoint(checkpoint))
        }
    }
}
