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

/// What the diagnostics ring needs to know about a request the runner sends.
enum RequestLogEvent: Sendable {
    case sent(id: UUID, url: String, body: Data)
    case finished(id: UUID, finishReason: String?, usage: Usage?)
}

/// Runs one assistant turn: stream, execute tool calls on device, append results, continue.
struct TurnRunner: Sendable {
    static let maxToolRounds = 8

    var streamer: any ChatStreaming
    var tools: any ToolExecuting
    /// How many calls of one round run at once.
    var maxConcurrentTools = ToolRound.maxConcurrent
    /// Told about each request actually sent (not the replay of one restored from a checkpoint).
    var requestLog: (@MainActor @Sendable (RequestLogEvent) -> Void)?

    /// - Parameter messages: the API history up to and including the new user message.
    @MainActor
    func run(endpoint: Endpoint,
             messages initial: [APIMessage],
             effort: Effort?,
             sources: SourceStore? = nil,
             checkpoint restored: TurnCheckpoint? = nil,
             onEvent: @MainActor (TurnEvent) throws -> Void) async throws -> TurnOutcome {
        var checkpoint = restored ?? TurnCheckpoint()
        var messages = try restored?.messages ?? initial // the history stays in memory: nothing is encoded and decoded back
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
            try onEvent(.roundStarted(round))

            if restored != nil && round == restored?.round {
                if !checkpoint.accumulator.reasoning.isEmpty { try onEvent(.reasoning(checkpoint.accumulator.reasoning)) }
                if !checkpoint.accumulator.content.isEmpty { try onEvent(.content(checkpoint.accumulator.content)) }
            }
            try onEvent(.checkpoint(checkpoint))
            if !checkpoint.streamDone {
                if endpoint.supportsResumable && checkpoint.idempotencyKey == nil {
                    // Legacy checkpoints created before the gateway supported idempotency.
                    // Never invent a key for an unidentified request already sent without one.
                    if checkpoint.submissionStarted && checkpoint.requestID == nil {
                        throw APIError.transport(String(localized: "This reply was started before idempotency support and has no recovery key."))
                    }
                    checkpoint.idempotencyKey = UUID().uuidString.lowercased()
                }
                if checkpoint.requestData == nil { checkpoint.requestData = try request.encoded() }
                let firstSend = !checkpoint.submissionStarted
                checkpoint.submissionStarted = true
                try onEvent(.checkpoint(checkpoint))
                let logID = UUID()
                if firstSend, let log = requestLog, let body = checkpoint.requestData {
                    log(.sent(id: logID, url: endpoint.baseURL.appendingPathComponent("chat/completions").absoluteString, body: body))
                }
                defer {
                    if firstSend, let log = requestLog {
                        log(.finished(id: logID, finishReason: checkpoint.accumulator.finishReason, usage: checkpoint.accumulator.usage))
                    }
                }
                let stream: AsyncThrowingStream<ChatDelta, Error>
                if endpoint.supportsResumable, let resumable = streamer as? any ResumableChatStreaming {
                    stream = resumable.stream(request, endpoint: endpoint, checkpoint: checkpoint)
                } else {
                    stream = streamer.stream(request, endpoint: endpoint)
                }
                for try await delta in stream {
                    try Task.checkCancellation()
                    guard try checkpoint.apply(delta) else { continue }
                    if let r = delta.reasoning, !r.isEmpty { try onEvent(.reasoning(r)) }
                    if let c = delta.content, !c.isEmpty { try onEvent(.content(c)) }
                    if let u = delta.usage { try onEvent(.usage(u)) }
                    try onEvent(.checkpoint(checkpoint))
                }
                try Task.checkCancellation()
                checkpoint.streamDone = true
                try onEvent(.checkpoint(checkpoint))
            }
            let acc = checkpoint.accumulator
            if let u = acc.usage { lastUsage = u }
            finalReasoning = acc.reasoning

            let calls = capped || !toolsEnabled ? [] : acc.toolCalls
            if calls.isEmpty {
                return TurnOutcome(steps: steps, finalContent: acc.content, finalReasoning: finalReasoning,
                                   lastUsage: lastUsage, hitToolCap: hitCap)
            }

            try onEvent(.toolsRequested(calls))
            // Calls run side by side, a few at a time. Results are numbered and appended in call order, so the
            // history and the source ids are what a one-by-one run would produce; a result that finishes early waits
            // (and is checkpointed) until the calls before it are done.
            var records: [ToolCallRecord] = checkpoint.records
            var outputs = records.map { ToolOutput(text: $0.result, isError: $0.isError) }
            for record in records { try onEvent(.toolFinished(record)) }
            var finished: [Int: ToolOutput] = [:]
            let flushed = Set(records.map(\.id))
            let stashed = Dictionary(uniqueKeysWithValues: (checkpoint.pendingResults ?? []).map { ($0.callID, $0) })
            var toRun: [Int] = []
            for (i, call) in calls.enumerated() where !flushed.contains(call.id) {
                if let raw = stashed[call.id] { finished[i] = raw.output } else { toRun.append(i) }
            }
            var nextToAppend = calls.firstIndex { !flushed.contains($0.id) } ?? calls.count

            func appendReady() throws {
                var appended = false
                while nextToAppend < calls.count, var out = finished[nextToAppend] {
                    let call = calls[nextToAppend]
                    finished[nextToAppend] = nil
                    nextToAppend += 1
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
                    checkpoint.pendingResults?.removeAll { $0.callID == call.id }
                    try onEvent(.toolFinished(record))
                    appended = true
                }
                if appended {
                    checkpoint.records = records
                    if checkpoint.pendingResults?.isEmpty == true { checkpoint.pendingResults = nil }
                }
            }

            try Task.checkCancellation()
            try appendReady() // results restored from a checkpoint
            try await ToolRound.execute(calls, indices: toRun, tools: tools, limit: maxConcurrentTools) { index, out in
                finished[index] = out
                checkpoint.pendingResults = (checkpoint.pendingResults ?? []) + [RawToolResult(callID: calls[index].id, output: out)]
                try appendReady()
                try onEvent(.checkpoint(checkpoint))
            }
            try Task.checkCancellation()
            MessageAssembler.appendToolRound(to: &messages, assistantContent: acc.content, calls: calls, results: outputs)
            steps.append(ToolStep(assistantContent: acc.content, calls: records))
            round += 1
            let priorReasoning = checkpoint.priorReasoning + acc.reasoning + "\n\n"
            checkpoint = TurnCheckpoint()
            checkpoint.round = round
            checkpoint.steps = steps
            checkpoint.priorReasoning = priorReasoning
            try onEvent(.checkpoint(checkpoint))
        }
    }
}
