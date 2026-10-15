import Foundation

/// What a compaction produced.
struct CompactionOutcome: Sendable, Equatable {
    var notes: String
    /// The history that replaces the conversation (no system message): recent user messages, the notes, and whatever
    /// the latest turn kept.
    var replacement: [APIMessage]
    var tokensBefore: Int
    var tokensAfter: Int
    /// Messages dropped from the oldest turns of the request because it did not fit (the history itself is untouched).
    var trimmed: Int
    var requests: Int
}

enum CompactionError: LocalizedError, Equatable {
    case nothingToCompact
    case failed(String)
    case cutOff(String)

    var errorDescription: String? {
        switch self {
        case .nothingToCompact: String(localized: "There is nothing to summarize yet.")
        case .failed(let m): String(localized: "Couldn't summarize the conversation: \(m)")
        case .cutOff(let why): String(localized: "Couldn't summarize the conversation: the notes were cut off (\(why)), twice. The conversation is unchanged.")
        }
    }
}

/// Asks the model for handoff notes. The request is the existing one plus one appended instruction (so the prefix
/// stays cached); the conversation itself is untouched until the notes succeed.
struct Compactor: Sendable {
    var streamer: any ChatStreaming

    /// - Parameters:
    ///   - base: the request as it would be sent now (model, effort, tools, the whole history); the instruction is added.
    ///   - meter: the context size before compaction.
    ///   - systemChars: characters of the system message, for the size after.
    ///   - extra: messages that follow the compacted history (a user message about to be sent); counted in the size after.
    ///   - onRequest: told each request sent (diagnostics).
    func compact(endpoint: Endpoint, base: ChatRequest, meter: ContextMeter, window: Int, extra: [APIMessage] = [],
                 onRequest: (@MainActor @Sendable (ChatRequest) -> Void)? = nil) async throws -> CompactionOutcome {
        let system = base.messages.first?.role == "system" ? base.messages.first : nil
        let history = Array(base.messages.dropFirst(system == nil ? 0 : 1))
        guard !history.isEmpty else { throw CompactionError.nothingToCompact }

        let before = meter.tokens
        var request = Compaction.request(from: base)
        var est = before + Compaction.messageChars(request.messages[request.messages.count - 1]) / 4
        var retained: [APIMessage] = []
        var trimmed = 0
        var sent = 0
        var content = ""
        var cut: String?
        var attempt = 0

        for again in 0... {
            while true {
                // The conversation is at its limit by now, and one large tool result can take it past the point where
                // the request plus a full-size answer fits: give the notes the room that is left, and when that is too
                // little drop the oldest turns from the request. If even the last turn cannot fit, keep its latest
                // tool-call/result group outside the summary request.
                let fit = Compaction.fit(&request, window: window, estimate: est, need: Compaction.room << attempt)
                est = fit.estimate
                trimmed += fit.dropped
                retained = fit.kept + retained
                sent += 1
                if let onRequest { await onRequest(request) }
                do {
                    let result = try await stream(request, endpoint: endpoint)
                    content = result.content
                    cut = Compaction.cutReason(finishReason: result.finishReason, content: result.content)
                    break
                } catch {
                    if attempt >= 2 || !Compaction.isContextOverflow(error) || Task.isCancelled {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        throw (error as? CompactionError) ?? CompactionError.failed(error.localizedDescription)
                    }
                    attempt += 1
                }
            }
            // Notes cut off would replace the conversation with half a handoff: write them again, once.
            if cut == nil || again >= 1 { break }
        }
        if let cut { throw CompactionError.cutOff(cut) }

        let notes = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // No notes means nothing to stand in for the history: keep the history rather than drop it.
        if notes.isEmpty { throw CompactionError.failed(String(localized: "the model wrote no notes")) }
        let replacement = Compaction.replacement(history: history, notes: notes, retained: retained)
        let after = ContextMeter.estimate((system.map { [$0] } ?? []) + replacement + extra).tokens
        return CompactionOutcome(notes: notes, replacement: replacement, tokensBefore: before, tokensAfter: after,
                                 trimmed: trimmed, requests: sent)
    }

    /// Streams one request (through the resumable client when the endpoint has one, so a dropped connection resumes and
    /// a retried POST is not run twice). Cancelling also cancels the request on the server.
    private func stream(_ request: ChatRequest, endpoint: Endpoint) async throws -> (content: String, finishReason: String?) {
        var checkpoint = TurnCheckpoint()
        checkpoint.requestData = try request.encoded()
        checkpoint.submissionStarted = true
        let resumable = endpoint.supportsResumable ? streamer as? any ResumableChatStreaming : nil
        let deltas = resumable?.stream(request, endpoint: endpoint, checkpoint: checkpoint) ?? streamer.stream(request, endpoint: endpoint)
        do {
            for try await delta in deltas {
                try Task.checkCancellation()
                _ = try checkpoint.apply(delta)
            }
            try Task.checkCancellation()
        } catch {
            if let resumable, let id = checkpoint.requestID, error is CancellationError || Task.isCancelled {
                // Detached: this task is cancelled, and a cancelled task cannot make the request.
                Task.detached { try? await resumable.cancel(requestID: id, endpoint: endpoint) }
            }
            throw error
        }
        return (checkpoint.accumulator.content, checkpoint.accumulator.finishReason)
    }
}
