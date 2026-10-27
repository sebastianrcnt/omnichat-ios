import Foundation

enum TurnEvent: Sendable {
    case reasoning(String)
    case content(String)
    case toolsRequested([ToolCall])
    /// A tool call the model is still writing (`ToolDraft`): which tool, the title so far, and the arguments' size.
    case drafting(name: String, title: String, bytes: Int)
    /// The signed thinking that led to the calls about to be announced (an Anthropic connection only), kept with their
    /// step for later turns (`StepThinking`).
    case stepThinking(StepThinking)
    case toolFinished(ToolCallRecord)
    case usage(Usage)
    /// A new request is about to start (round 0 is the first).
    case roundStarted(Int)
    case checkpoint(TurnCheckpoint)
    /// The conversation is about to be summarized (the request is being sent).
    case compactionStarted
    /// The notes are written. `anchorSteps` is how many tool steps of this turn the summary covers; `preTurn` says it
    /// was made before the turn's own request, so it covers the history up to (not including) the user message.
    case compacted(CompactionOutcome, anchorSteps: Int, preTurn: Bool)
}

/// Turns on compaction for a turn.
struct CompactionSettings: Sendable {
    var window: Int
    var maxOutput: Int?
    /// The context size before the turn's own message (see `ContextMeter`).
    var meter: ContextMeter
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

/// "Continue when the answer is empty": a model that searched and then stopped without writing anything gets one
/// more request, with a short nudge appended and tools off.
enum EmptyAnswerRetry {
    /// Appended as a user message after the tool results. Sent as is; never shown.
    static let nudge = "Write the final answer now based on the results above."

    /// Retry when the setting is on, tools ran earlier in the turn (`round > 0`), the reply has no text, and this turn
    /// has not retried yet (an early answer, already tool-less, counts as one).
    static func shouldRetry(enabled: Bool, round: Int, alreadyRetried: Bool, content: String) -> Bool {
        enabled && round > 0 && !alreadyRetried && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Runs one assistant turn: stream, execute tool calls on device, append results, continue.
struct TurnRunner: Sendable {
    static let maxToolRounds = 8
    /// The result of a call that can act outside the app and was cut off when the app ended (`TurnCheckpoint.startedCalls`).
    static let interruptedCallNote = "Error: this call was interrupted when the app closed, so it may or may not have taken effect. "
        + "Don't repeat it blindly: check whether it went through first (or ask the user)."
    /// The result of such a call that was still running when the user stopped the reply.
    static let stoppedCallNote = "Error: this call was stopped before it finished, so it may or may not have taken effect. "
        + "Don't repeat it blindly: check whether it went through first (or ask the user)."

    var streamer: any ChatStreaming
    var tools: any ToolExecuting
    /// How many calls of one round run at once.
    var maxConcurrentTools = ToolRound.maxConcurrent
    /// Tools stay in the request (so the prefix is the same) but are not to be called: `tool_choice: "none"` on every
    /// request, and any call the model makes anyway is ignored. Used for the early answer.
    var toolsDisabled = false
    /// Compacts the history before a request when it has grown to the model's limit. Off when nil.
    var compaction: CompactionSettings?
    /// When the model ends a turn that used tools with no answer text, send one more round asking for the answer
    /// (`EmptyAnswerRetry`). Opt-in; never more than once per turn.
    var continueOnEmptyAnswer = false
    /// Told about each request actually sent (not the replay of one restored from a checkpoint).
    var requestLog: (@MainActor @Sendable (RequestLogEvent) -> Void)?
    /// The tool groups the requests offer (the chat's frozen set, `Conversation.offeredTools`). Web search only by
    /// default in tests.
    var offered: Set<ToolGroup> = [.web]
    /// The chat's groups turned off now: calls to their tools are refused (`OfferedTools`), though they stay offered.
    var switches: ChatToolSwitches?
    /// The chat's packages (`Conversation.packageSnapshot`) and the tools they add after the built-in ones.
    var packages: PackageSnapshot?
    var packageTools: [ToolDefinition] = []
    /// Offer `run_python` (and `view_image` to a model that reads images).
    var python: Bool {
        get { offered.contains(.python) }
        set { if newValue { offered.insert(.python) } else { offered.remove(.python) } }
    }
    /// Offer the browser tools and skills.
    var browser: Bool {
        get { offered.contains(.browser) }
        set { if newValue { offered.insert(.browser) } else { offered.remove(.browser) } }
    }

    /// The round's calls with ids no earlier round of the turn used. A server that sends no ids gets `call_0` in every
    /// round (`StreamAccumulator.toolCalls`), and some reuse their own; the rounds share one feed, approvals and
    /// progress keyed by id, so a repeat would hide the new call. Deterministic, so a restored round renames alike.
    static func uniqueIDs(_ calls: [ToolCall], after steps: [ToolStep], round: Int) -> [ToolCall] {
        var seen = Set(steps.flatMap { $0.calls.map(\.id) })
        guard !seen.isEmpty else { return calls }
        return calls.map { call in
            var call = call
            if seen.contains(call.id) { call.id += "_r\(round)" }
            while seen.contains(call.id) { call.id += "_" }
            seen.insert(call.id)
            return call
        }
    }

    /// - Parameter messages: the API history up to and including the new user message.
    @MainActor
    func run(endpoint: Endpoint,
             messages initial: [APIMessage],
             effort: Effort?,
             sources: SourceStore? = nil,
             checkpoint restored: TurnCheckpoint? = nil,
             onEvent: @MainActor (TurnEvent) throws -> Void) async throws -> TurnOutcome {
        if let saved = restored?.endpointFingerprint, saved != TurnCheckpoint.fingerprint(endpoint) {
            throw APIError.server(String(localized: "This reply was started with a different server or model, so it can't be resumed. Try again to send it with the current one."))
        }
        var checkpoint = restored ?? TurnCheckpoint()
        var messages = try restored?.messages ?? initial // the history stays in memory: nothing is encoded and decoded back
        var steps: [ToolStep] = checkpoint.steps
        var lastUsage: Usage?
        var hitCap = false
        var finalReasoning = ""
        let toolsEnabled = endpoint.model.supportsTools
        let readsImages = endpoint.model.supportsImages
        let toolList = ToolDefinition.available(groups: offered, images: readsImages) + packageTools

        var meter = compaction?.meter ?? ContextMeter()
        if restored != nil { meter = .estimate(messages) }
        let compactionLimit = compaction.map { Compaction.limit(window: $0.window, maxOutput: $0.maxOutput) } ?? 0

        func makeRequest(_ messages: [APIMessage], capped: Bool) -> ChatRequest {
            var request = ChatRequest(model: endpoint.model.id, messages: messages)
            if endpoint.model.supportsEffort, let effort { request.reasoningEffort = effort.apiValue }
            if toolsEnabled {
                request.tools = toolList // identical on every request
                if capped { request.toolChoice = "none" }
            }
            return request
        }

        var round = checkpoint.round
        while true {
            try Task.checkCancellation()
            let retrying = checkpoint.emptyAnswerRetry == true
            let capped = toolsDisabled || retrying || round >= Self.maxToolRounds
            if capped && !toolsDisabled && !retrying { hitCap = true }
            try onEvent(.roundStarted(round))

            // Checked before the turn and before each continuation: the history is summarized when the last reported
            // usage plus what was appended since has reached the limit. A request already built (a replayed round) is
            // never rebuilt.
            if let compaction, compactionLimit > 0, checkpoint.requestData == nil, !checkpoint.streamDone {
                let preTurn = round == 0 && restored == nil
                let system = messages.first?.role == "system" ? [messages[0]] : []
                var pending: APIMessage?
                if preTurn, let last = messages.last, last.role == "user" { pending = last }
                let history = messages.count - system.count - (pending == nil ? 0 : 1)
                if (!preTurn || pending != nil), history > 0,
                   Compaction.needsCompaction(meter, limit: compactionLimit, extraChars: pending.map(Compaction.messageChars) ?? 0) {
                    try onEvent(.compactionStarted)
                    let base = makeRequest(pending == nil ? messages : Array(messages.dropLast()), capped: capped)
                    let log = requestLog
                    let url = endpoint.requestURL.absoluteString
                    let outcome = try await Compactor(streamer: streamer).compact(
                        endpoint: endpoint, base: base, meter: meter, window: compaction.window,
                        extra: pending.map { [$0] } ?? []) { request in
                        if let log, let body = try? request.encoded() { log(.sent(id: UUID(), url: url, body: body)) }
                    }
                    messages = system + outcome.replacement + (pending.map { [$0] } ?? [])
                    meter = .estimate(messages)
                    lastUsage = nil // what was reported belongs to the history before it
                    try onEvent(.compacted(outcome, anchorSteps: steps.count, preTurn: preTurn))
                }
            }
            let request = makeRequest(messages, capped: capped)

            if restored != nil && round == restored?.round {
                if !checkpoint.accumulator.reasoning.isEmpty { try onEvent(.reasoning(checkpoint.accumulator.reasoning)) }
                if !checkpoint.accumulator.content.isEmpty { try onEvent(.content(checkpoint.accumulator.content)) }
            }
            try onEvent(.checkpoint(checkpoint))
            if !checkpoint.streamDone {
                // A restored round was submitted as a resumable request. With recovery now off for the connection,
                // sending it again would start a second, unkeyed generation appended to the saved partial answer.
                if restored != nil, round == restored?.round, checkpoint.submissionStarted, !endpoint.supportsResumable {
                    throw APIError.server(String(localized: "This reply was interrupted and can't be resumed: resumable replies are now off for this connection. Try again to send it again."))
                }
                if endpoint.supportsResumable && checkpoint.idempotencyKey == nil {
                    // Legacy checkpoints created before the gateway supported idempotency.
                    // Never invent a key for an unidentified request already sent without one.
                    if checkpoint.submissionStarted && checkpoint.requestID == nil {
                        throw APIError.transport(String(localized: "This reply was started before idempotency support and has no recovery key."))
                    }
                    checkpoint.idempotencyKey = UUID().uuidString.lowercased()
                }
                if checkpoint.requestData == nil {
                    checkpoint.requestData = try request.encoded()
                    checkpoint.reasoningByMessage = TurnCheckpoint.reasoning(of: messages)
                    checkpoint.endpointFingerprint = TurnCheckpoint.fingerprint(endpoint)
                }
                let firstSend = !checkpoint.submissionStarted
                checkpoint.submissionStarted = true
                try onEvent(.checkpoint(checkpoint))
                let logID = UUID()
                if firstSend, let log = requestLog, let body = checkpoint.requestData {
                    log(.sent(id: logID, url: endpoint.requestURL.absoluteString, body: body))
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
                var draft = ToolDraft()
                for try await delta in stream {
                    try Task.checkCancellation()
                    guard try checkpoint.apply(delta) else { continue }
                    if !delta.toolCalls.isEmpty, let call = checkpoint.accumulator.toolCalls.last, let shown = draft.update(call) {
                        try onEvent(.drafting(name: shown.name, title: shown.title, bytes: shown.bytes))
                    }
                    if let r = delta.reasoning, !r.isEmpty { try onEvent(.reasoning(r)) }
                    if let c = delta.content, !c.isEmpty { try onEvent(.content(c)) }
                    if let u = delta.usage { meter.record(u); try onEvent(.usage(u)) }
                    try onEvent(.checkpoint(checkpoint))
                }
                try Task.checkCancellation()
                checkpoint.streamDone = true
                try onEvent(.checkpoint(checkpoint))
            }
            let acc = checkpoint.accumulator
            if let u = acc.usage { lastUsage = u }
            let usageCounted = acc.usage.map { $0.promptTokens > 0 || $0.completionTokens > 0 } ?? false
            finalReasoning = acc.reasoning

            let calls = capped || !toolsEnabled ? [] : Self.uniqueIDs(acc.toolCalls, after: steps, round: round)
            if calls.isEmpty {
                if EmptyAnswerRetry.shouldRetry(enabled: continueOnEmptyAnswer, round: round,
                                                alreadyRetried: retrying || toolsDisabled, content: acc.content) {
                    // The empty reply is dropped; a short user nudge goes at the end of the history (the prefix, the
                    // tools and the system prompt stay the same), and the next request may not call tools.
                    messages.append(.user(EmptyAnswerRetry.nudge))
                    meter.append(messages[messages.count - 1])
                    round += 1
                    let priorReasoning = checkpoint.priorReasoning + acc.reasoning + (acc.reasoning.isEmpty ? "" : "\n\n")
                    checkpoint = TurnCheckpoint()
                    checkpoint.round = round
                    checkpoint.steps = steps
                    checkpoint.priorReasoning = priorReasoning
                    checkpoint.emptyAnswerRetry = true
                    try onEvent(.checkpoint(checkpoint))
                    continue
                }
                return TurnOutcome(steps: steps, finalContent: acc.content, finalReasoning: finalReasoning,
                                   lastUsage: lastUsage, hitToolCap: hitCap)
            }

            let thinking = endpoint.kind == .anthropic && !acc.reasoningItems.isEmpty
                ? StepThinking(model: endpoint.model.id, items: acc.reasoningItems) : nil
            if let thinking { try onEvent(.stepThinking(thinking)) }
            try onEvent(.toolsRequested(calls))
            // Calls run side by side, a few at a time. Results are numbered and appended in call order, so the
            // history and the source ids are what a one-by-one run would produce; a result that finishes early waits
            // (and is checkpointed) until the calls before it are done.
            var records: [ToolCallRecord] = checkpoint.records
            var outputs = records.map(\.output)
            for record in records { try onEvent(.toolFinished(record)) }
            var finished: [Int: ToolOutput] = [:]
            let flushed = Set(records.map(\.id))
            let stashed = Dictionary((checkpoint.pendingResults ?? []).map { ($0.callID, $0) }, uniquingKeysWith: { first, _ in first })
            // A call that can act outside the app and had started when the turn was cut off may have taken effect:
            // it isn't run a second time, the model is told to check.
            let started = Set(checkpoint.startedCalls ?? [])
            var toRun: [Int] = []
            for (i, call) in calls.enumerated() where !flushed.contains(call.id) {
                if let raw = stashed[call.id] {
                    finished[i] = raw.output
                } else if started.contains(call.id) {
                    finished[i] = ToolOutput(text: Self.interruptedCallNote, isError: true)
                } else {
                    toRun.append(i)
                }
            }
            var nextToAppend = calls.firstIndex { !flushed.contains($0.id) } ?? calls.count

            func appendReady() throws {
                var appended = false
                while nextToAppend < calls.count, var out = finished[nextToAppend] {
                    let call = calls[nextToAppend]
                    finished[nextToAppend] = nil
                    nextToAppend += 1
                    var ids: [Int] = []
                    var infos: [SourceInfo] = []
                    if let sources, !out.sources.isEmpty, !out.isError {
                        infos = out.sources.map { sources.assign($0) }
                        ids = infos.map(\.id)
                        let blocks = zip(infos, out.sources).map { SourceFormatter.block($0, content: $1.content) }.joined(separator: "\n")
                        out.text = (out.engine.map { "Results from \($0):\n" + blocks } ?? blocks) + (out.trailer.map { "\n\n" + $0 } ?? "")
                    }
                    var record = ToolCallRecord(id: call.id, name: call.name, arguments: call.arguments,
                                                result: out.text, isError: out.isError, sourceIDs: ids)
                    record.sources = infos.isEmpty ? nil : SourceSnapshots.snapshot(infos)
                    record.figures = out.figures.isEmpty ? nil : out.figures
                    record.viewedImage = out.viewedImage
                    record.shownImage = out.shownImage
                    record.places = out.places
                    record.artifact = out.artifact
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

            /// Stopped mid-round: every result that came in is reported, also one still waiting behind an earlier call,
            /// and a call that can act outside the app and had started gets `stoppedCallNote` (its effect may have
            /// happened). A read-only call cut off is dropped: a call without a result cannot be sent back.
            var startedIndices: Set<Int> = []
            func flushStopped() throws {
                for i in nextToAppend..<calls.count where finished[i] == nil && startedIndices.contains(i)
                    && ToolNames.mayActOutside(calls[i].name) {
                    finished[i] = ToolOutput(text: Self.stoppedCallNote, isError: true)
                }
                while nextToAppend < calls.count {
                    if finished[nextToAppend] == nil { nextToAppend += 1 } else { try appendReady() }
                }
            }

            try Task.checkCancellation()
            try appendReady() // results restored from a checkpoint
            let offered = OfferedTools(base: tools, names: Set(toolList.map(\.function.name)), switches: switches, packages: packages)
            do {
                try await ToolRound.execute(calls, indices: toRun, tools: offered, limit: maxConcurrentTools, onStart: { index in
                    startedIndices.insert(index)
                    guard ToolNames.mayActOutside(calls[index].name) else { return }
                    checkpoint.startedCalls = (checkpoint.startedCalls ?? []) + [calls[index].id]
                    try onEvent(.checkpoint(checkpoint)) // on disk before the call runs, or the round stops here
                }) { index, out in
                    finished[index] = out
                    checkpoint.pendingResults = (checkpoint.pendingResults ?? []) + [RawToolResult(callID: calls[index].id, output: out)]
                    try appendReady()
                    try onEvent(.checkpoint(checkpoint))
                }
            } catch {
                if error is CancellationError || Task.isCancelled { try? flushStopped() }
                throw error
            }
            try Task.checkCancellation()
            let before = messages.count
            MessageAssembler.appendToolRound(to: &messages, assistantContent: acc.content, calls: calls, results: outputs,
                                             readsImages: readsImages, reasoningItems: acc.reasoningItems)
            // The reported usage already counts the assistant message that made the calls; the results are new.
            for m in messages[before...] where !(usageCounted && m.role == "assistant") { meter.append(m) }
            steps.append(ToolStep(assistantContent: acc.content, calls: records, thinking: thinking))
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

/// Runs only the tools the request offered and the chat has on. A model can name a tool that is not offered anyway,
/// and a group the user turned off in the chat stays offered (for the cached prefix): the switch has to hold at
/// execution, not only in the tool list. Skills (`load_skill`, `run_skill_script`, `save_skill`) are browser tools,
/// plugins (`run_plugin`) are web search's. A package's tools and skills follow its own switch.
struct OfferedTools: ToolExecuting {
    let base: any ToolExecuting
    let names: Set<String>
    var switches: ChatToolSwitches?
    var packages: PackageSnapshot?
    var usesWebKit: Bool { base.usesWebKit }

    func execute(name: String, arguments: String) async -> ToolOutput {
        guard names.contains(name) else {
            return ToolOutput(text: "Error: the tool \(name) is not available in this chat.", isError: true)
        }
        if let packages, let entry = Self.package(of: name, arguments: arguments, in: packages) {
            if let switches, await switches.offPackages.contains(entry.id) {
                return ToolOutput(text: ToolSwitch.packageRefusal(name: entry.name), isError: true)
            }
            return await base.execute(name: name, arguments: arguments)
        }
        if let switches, let group = ToolGroup.group(of: name), await switches.off.contains(group) {
            return ToolOutput(text: group.refusal, isError: true)
        }
        return await base.execute(name: name, arguments: arguments)
    }

    /// The package a call belongs to: one of its tools, or a skill call naming one of its skills.
    static func package(of name: String, arguments: String, in packages: PackageSnapshot) -> PackageSnapshot.Entry? {
        if name.contains("__") { return packages.tool(named: name)?.entry }
        guard name == ToolNames.loadSkill || name == ToolNames.runSkillScript,
              let skill = PackageSkillCall.skillName(tool: name, arguments: arguments)?.trimmingCharacters(in: .whitespaces).lowercased()
        else { return nil }
        return packages.entries.first { $0.skillNames.contains(skill) }
    }
}
