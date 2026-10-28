import Foundation
import SwiftUI
import SwiftData
import Observation

/// Feeds streamed deltas into the render models and measures thinking time.
/// Resumable turns checkpoint persisted fields at each applied SSE boundary.
@MainActor
final class TurnTracker {
    let message: Message
    let conversation: Conversation
    let render: MessageRenderState
    private var thinkingStart: ContinuousClock.Instant?
    private var thinkingTotal: Double = 0
    private var roundContent = ""
    private var roundHasReasoning = false
    private var reasoningAll = ""
    private var requested: [ToolCall] = []
    private var stepParagraphs = 0
    private var finishedRecords: [ToolCallRecord] = []
    /// The signed thinking of the round whose calls run now (Anthropic), for its step.
    var stepThinking: StepThinking?
    private(set) var completedSteps: [ToolStep] = []
    // Ordered process segments, appended as the stream produces them.
    private var segments: [ProcessSegment] = []
    private var roundReasoning = ""
    private var roundSeconds: Double = 0
    private var thinkingEmitted = false

    init(message: Message, conversation: Conversation, render: MessageRenderState, checkpoint: TurnCheckpoint? = nil) {
        self.message = message
        self.conversation = conversation
        self.render = render
        completedSteps = checkpoint?.steps ?? []
        reasoningAll = checkpoint?.priorReasoning ?? ""
        if !reasoningAll.isEmpty { render.reasoning.append(reasoningAll) }
        thinkingTotal = message.thinkingSeconds ?? 0
        if let checkpoint { segments = ProcessSegments.derive(steps: checkpoint.steps, reasoning: checkpoint.priorReasoning) }
    }

    func beginRound(_ n: Int) {
        finishThinking()
        roundContent = ""
        roundHasReasoning = false
        roundReasoning = ""
        roundSeconds = 0
        thinkingEmitted = false
        if n > 0 { render.markdown.reset() } // intermediate text lives in the tool step
    }

    func addReasoning(_ r: String) {
        if thinkingStart == nil { thinkingStart = .now }
        roundHasReasoning = true
        reasoningAll += r
        roundReasoning += r
        render.reasoning.append(r)
    }

    func addContent(_ c: String) {
        finishThinking()
        emitThinking() // the thinking row sits above the answer from its first character
        roundContent += c
        render.markdown.append(c)
    }

    func finishThinking() {
        guard let start = thinkingStart else { return }
        let elapsed = (ContinuousClock.now - start).seconds
        thinkingTotal += elapsed
        roundSeconds += elapsed
        thinkingStart = nil
        message.thinkingSeconds = thinkingTotal
    }

    func beginTools(_ calls: [ToolCall]) {
        requested = calls
        finishedRecords = []
        finishThinking() // the round's thinking time, for its line
        emitThinking()
        let preamble = roundContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preamble.isEmpty { append(.init(index: 0, kind: .text, text: preamble)) }
        // The round's text now lives in its segment, shown as a note above this round's calls; clearing the model
        // keeps it from showing twice.
        render.markdown.reset()
        // Force a paragraph boundary so the timeline can place this step after the reasoning so far.
        render.reasoning.beginSection()
        if !reasoningAll.isEmpty && !reasoningAll.hasSuffix("\n\n") { reasoningAll += "\n\n" }
        stepParagraphs = render.reasoning.finalized.count
    }

    func completeTool(_ record: ToolCallRecord) {
        finishedRecords.append(record)
        if finishedRecords.count == requested.count {
            completedSteps.append(ToolStep(assistantContent: roundContent, calls: finishedRecords, reasoningParagraphs: stepParagraphs,
                                           thinking: stepThinking))
            stepThinking = nil
            message.steps = completedSteps
            append(.init(index: 0, kind: .toolRound, calls: finishedRecords.map(\.displayOnly)))
        }
    }

    /// For Stop and an early answer: a round cut short keeps the calls that did finish, each with its result, and drops the rest
    /// (a call without a result cannot be sent back). A round with nothing finished is dropped whole.
    func keepFinishedCallsOfOpenRound() {
        guard !requested.isEmpty, !finishedRecords.isEmpty, finishedRecords.count < requested.count else { return }
        // The thinking stays: it is bound to the history before it, which is unchanged.
        completedSteps.append(ToolStep(assistantContent: roundContent, calls: finishedRecords, reasoningParagraphs: stepParagraphs,
                                       thinking: stepThinking))
        stepThinking = nil
        message.steps = completedSteps
        append(.init(index: 0, kind: .toolRound, calls: finishedRecords.map(\.displayOnly)))
        requested = []
        finishedRecords = []
    }

    private func append(_ segment: ProcessSegment) {
        var s = segment
        s.index = segments.count
        segments.append(s)
        message.segments = segments
    }

    /// The round's reasoning becomes one thinking segment, once.
    private func emitThinking() {
        guard !thinkingEmitted else { return }
        thinkingEmitted = true
        let text = roundReasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        append(.init(index: 0, kind: .thinking, text: text, seconds: roundSeconds > 0 ? roundSeconds : nil))
    }

    /// Persist the final text and reasoning and reconcile the render models.
    func complete(finalText: String?) {
        let text = finalText ?? render.markdown.text
        message.text = text
        message.reasoning = reasoningAll
        emitThinking()
        render.markdown.finish(finalText: text)
        render.reasoning.revealAll()
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
