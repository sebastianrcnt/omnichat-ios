import Foundation
import Observation
import os

/// Publishes the finalized blocks and the mutable tail of a streaming Markdown document.
///
/// Deltas are coalesced to one publish per `interval` (~33 ms). Parsing happens on a background task;
/// the main actor only receives newly finalized blocks plus the new tail.
@MainActor
@Observable
final class StreamingMarkdownModel {
    static let signposter = OSSignposter(subsystem: "cc.coolservices.strata", category: "StreamingMarkdown")
    static let publishInterval: Duration = .milliseconds(33)

    private(set) var finalized: [MarkdownBlock] = []
    private(set) var tail: [MarkdownBlock] = []
    private(set) var hasContent = false
    /// Recently revealed spans (for the tail fade-in). Only the tail block reads this.
    private(set) var freshSpans: [FreshSpan] = []

    /// Everything received so far (not necessarily revealed yet).
    @ObservationIgnored private(set) var text = ""
    @ObservationIgnored private var reveal = RevealController()
    @ObservationIgnored private var tickScheduled = false
    @ObservationIgnored private let activation = ActivationFlush()
    /// Whether anyone can see the screen; replaced in tests.
    @ObservationIgnored var isDisplayActive: () -> Bool = { DisplayActivity.isActive() }
    @ObservationIgnored private var pipeline: Pipeline?
    @ObservationIgnored var smoothing: Bool
    /// Called on the main actor after each publish with the time spent applying it (perf harness hook).
    @ObservationIgnored var onApply: ((Duration) -> Void)?

    struct FreshSpan: Equatable, Sendable {
        var length: Int
        var born: Date
    }

    init(text: String = "", smoothing: Bool = true) {
        self.smoothing = smoothing
        if !text.isEmpty { load(text) }
    }

    var blocks: [MarkdownBlock] { finalized + tail }

    // MARK: Streaming input

    /// Append streamed text. Cheap: queues it and schedules a display tick.
    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        text += delta
        reveal.receive(delta)
        if isDisplayActive() {
            scheduleTick()
        } else {
            // Nobody is looking: no display timer. What arrived is revealed when the app is active again.
            activation.arm { [weak self] in self?.revealAll() }
        }
    }

    /// Characters received but not yet shown.
    var unrevealedCount: Int { reveal.backlogCount }

    /// Reveal everything received so far right now (stream end, stop, or the user scrolled away).
    func revealAll() {
        let rest = reveal.flushAll()
        if !rest.isEmpty { publish(rest, fresh: false) }
        freshSpans = []
    }

    /// Final reconciliation once the stream ends: one full parse replaces the incremental result.
    func finish(finalText: String? = nil) {
        if let finalText, finalText != text { reset(); text = finalText; reveal.receive(finalText) }
        revealAll()
        pipeline?.send(.finish)
        if pipeline == nil { load(text) }
    }

    /// Drop everything (a new tool round starts a fresh answer).
    func reset() {
        text = ""
        reveal = RevealController()
        pipeline?.send(.reset)
        finalized = []
        tail = []
        freshSpans = []
        hasContent = false
    }

    /// Replace the document synchronously (finished messages loaded from history).
    func load(_ newText: String) {
        pipeline = nil
        reveal = RevealController()
        text = newText
        finalized = IncrementalBlockParser.parse(newText)
        tail = []
        freshSpans = []
        hasContent = !finalized.isEmpty
    }

    // MARK: Pipeline

    private func scheduleTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.publishInterval)
            self?.tick()
        }
    }

    private func tick() {
        tickScheduled = false
        if !isDisplayActive() { // went to the background with a tick pending: show everything, stop
            revealAll()
            return
        }
        let dt = Self.publishInterval.seconds
        let delta = smoothing ? reveal.tick(dt: dt) : reveal.flushAll()
        if !delta.isEmpty { publish(delta, fresh: smoothing) }
        let now = Date()
        if !freshSpans.isEmpty, freshSpans.allSatisfy({ now.timeIntervalSince($0.born) > Self.fadeDuration }) { freshSpans = [] }
        if reveal.hasBacklog || !freshSpans.isEmpty { scheduleTick() }
    }

    static let fadeDuration: TimeInterval = 0.15

    private func publish(_ delta: String, fresh: Bool) {
        if fresh {
            let now = Date()
            freshSpans = freshSpans.filter { now.timeIntervalSince($0.born) <= Self.fadeDuration }
            freshSpans.append(FreshSpan(length: delta.count, born: now))
        }
        if pipeline == nil {
            // Everything received before this delta, by byte count (Character counts drift across chunk boundaries).
            let keep = max(0, text.utf8.count - delta.utf8.count - reveal.backlog.utf8.count)
            pipeline = Pipeline(model: self, seed: String(decoding: text.utf8.prefix(keep), as: UTF8.self))
        }
        pipeline?.send(.append(delta))
    }

    fileprivate func apply(_ result: PipelineResult) {
        let interval = Self.signposter.beginInterval("apply")
        let start = ContinuousClock.now
        switch result {
        case .update(let u):
            if !u.newlyFinalized.isEmpty { finalized.append(contentsOf: u.newlyFinalized) }
            if tail != u.tail { tail = u.tail }
        case .reconcile(let all):
            if all != finalized + tail {
                finalized = all
            } else if !tail.isEmpty {
                finalized = all
            }
            if !tail.isEmpty { tail = [] }
        }
        if !hasContent, !(finalized.isEmpty && tail.isEmpty) { hasContent = true }
        Self.signposter.endInterval("apply", interval)
        onApply?(ContinuousClock.now - start)
    }

    fileprivate enum PipelineResult: Sendable {
        case update(BlockUpdate)
        case reconcile([MarkdownBlock])
    }

    fileprivate enum Command: Sendable {
        case append(String), finish, reset
    }

    /// Serial background parser. Commands are processed in order.
    fileprivate final class Pipeline: Sendable {
        private let continuation: AsyncStream<Command>.Continuation
        private let task: Task<Void, Never>

        @MainActor
        init(model: StreamingMarkdownModel, seed: String) {
            let (stream, continuation) = AsyncStream<Command>.makeStream()
            self.continuation = continuation
            task = Task.detached(priority: .userInitiated) { [weak model] in
                var parser = IncrementalBlockParser()
                if !seed.isEmpty { parser.reset(text: seed) }
                for await command in stream {
                    switch command {
                    case .append(let s):
                        let update = parser.append(s)
                        await model?.apply(.update(update))
                    case .finish:
                        await model?.apply(.reconcile(parser.finish()))
                    case .reset:
                        parser = IncrementalBlockParser()
                    }
                }
            }
        }

        func send(_ command: Command) { continuation.yield(command) }

        deinit {
            continuation.finish()
            task.cancel()
        }
    }
}

// MARK: - Reasoning chunks

/// Raw reasoning chain split by paragraph. Finalized paragraphs are immutable (and cached by id);
/// only the tail paragraph changes while streaming. Plain text only.
@MainActor
@Observable
final class ReasoningChunkModel {
    struct Chunk: Identifiable, Equatable, Sendable {
        let id: Int
        let text: String
    }

    private(set) var finalized: [Chunk] = []
    private(set) var tail = ""
    /// The sentence being written now (drives the one-line preview).
    private(set) var thought: ThoughtSentence?
    private(set) var hasContent = false
    /// Recently revealed spans for the tail fade-in (same 150 ms ramp as answers).
    private(set) var freshSpans: [StreamingMarkdownModel.FreshSpan] = []

    /// Everything revealed so far.
    @ObservationIgnored private(set) var text = ""
    @ObservationIgnored private var reveal = RevealController()
    @ObservationIgnored private var tickScheduled = false
    @ObservationIgnored private let activation = ActivationFlush()
    /// Whether anyone can see the screen; replaced in tests.
    @ObservationIgnored var isDisplayActive: () -> Bool = { DisplayActivity.isActive() }
    @ObservationIgnored var smoothing: Bool

    init(text: String = "", smoothing: Bool = true) {
        self.smoothing = smoothing
        if !text.isEmpty { load(text) }
    }

    /// Characters received but not yet shown.
    var unrevealedCount: Int { reveal.backlogCount }

    func load(_ newText: String) {
        finalized = []
        tail = ""
        text = ""
        thought = nil
        freshSpans = []
        reveal = RevealController()
        consume(newText)
    }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        reveal.receive(delta)
        if isDisplayActive() {
            scheduleTick()
        } else {
            activation.arm { [weak self] in self?.revealAll() }
        }
    }

    /// Start a new reasoning section (a new tool round).
    func beginSection() {
        revealAll()
        if !text.isEmpty && !text.hasSuffix("\n\n") { consume("\n\n") }
    }

    func revealAll() {
        let rest = reveal.flushAll()
        if !rest.isEmpty { consume(rest) }
        if !freshSpans.isEmpty { freshSpans = [] }
    }

    private func scheduleTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: StreamingMarkdownModel.publishInterval)
            self?.tick()
        }
    }

    private func tick() {
        tickScheduled = false
        if !isDisplayActive() {
            revealAll()
            return
        }
        let delta = smoothing ? reveal.tick(dt: StreamingMarkdownModel.publishInterval.seconds) : reveal.flushAll()
        if !delta.isEmpty {
            consume(delta)
            if smoothing {
                let now = Date()
                freshSpans = freshSpans.filter { now.timeIntervalSince($0.born) <= StreamingMarkdownModel.fadeDuration }
                freshSpans.append(.init(length: delta.count, born: now))
            }
        }
        let now = Date()
        if !freshSpans.isEmpty, freshSpans.allSatisfy({ now.timeIntervalSince($0.born) > StreamingMarkdownModel.fadeDuration }) { freshSpans = [] }
        if reveal.hasBacklog || !freshSpans.isEmpty { scheduleTick() }
    }

    private func consume(_ raw: String) {
        // Display-only: runs of ASCII spaces collapse to one, also across the join with what is already shown.
        let delta = ReasoningSpaces.collapse(raw, after: text.last)
        guard !delta.isEmpty else { return }
        text += delta
        let buffer = tail + delta
        var newChunks: [Chunk] = []
        var searchFrom = buffer.startIndex
        var paragraphStart = buffer.startIndex
        // One pass over the buffer: paragraphs are cut at blank lines without re-copying the remainder.
        while let range = buffer.range(of: "\n\n", range: searchFrom..<buffer.endIndex) {
            let paragraph = buffer[paragraphStart..<range.lowerBound]
            if !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newChunks.append(Chunk(id: finalized.count + newChunks.count, text: String(paragraph)))
            }
            paragraphStart = range.upperBound
            searchFrom = range.upperBound
        }
        if !newChunks.isEmpty { finalized.append(contentsOf: newChunks) }
        tail = String(buffer[paragraphStart...])
        let sentence = ThoughtSentences.latest(in: text)
        if sentence != thought { thought = sentence }
        if !hasContent, !text.isEmpty { hasContent = true }
    }

}

/// Everything needed to render one message's streamed parts.
@MainActor
final class MessageRenderState {
    let markdown: StreamingMarkdownModel
    private let initialReasoning: String
    private let smoothing: Bool
    /// Built on first use: history rows never need it, so their reasoning is not parsed while scrolling.
    var reasoning: ReasoningChunkModel {
        if let existing = builtReasoning { return existing }
        let model = ReasoningChunkModel(text: initialReasoning, smoothing: smoothing)
        builtReasoning = model
        return model
    }
    private var builtReasoning: ReasoningChunkModel?

    init(text: String = "", reasoning: String = "", smoothing: Bool = true) {
        markdown = StreamingMarkdownModel(text: text, smoothing: smoothing)
        initialReasoning = reasoning
        self.smoothing = smoothing
    }

    /// Show everything received so far (stream finished, stopped, or the user scrolled away).
    func revealAll() {
        markdown.revealAll()
        builtReasoning?.revealAll()
    }
}
