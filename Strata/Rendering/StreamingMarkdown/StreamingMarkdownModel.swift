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
        scheduleTick()
    }

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
    private(set) var lastLine = ""
    private(set) var hasContent = false
    /// Recently revealed spans for the tail fade-in (same 150 ms ramp as answers).
    private(set) var freshSpans: [StreamingMarkdownModel.FreshSpan] = []

    /// Everything revealed so far.
    @ObservationIgnored private(set) var text = ""
    @ObservationIgnored private var reveal = RevealController()
    @ObservationIgnored private var tickScheduled = false
    @ObservationIgnored var smoothing: Bool

    init(text: String = "", smoothing: Bool = true) {
        self.smoothing = smoothing
        if !text.isEmpty { load(text) }
    }

    func load(_ newText: String) {
        finalized = []
        tail = ""
        text = ""
        freshSpans = []
        reveal = RevealController()
        consume(newText)
    }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        reveal.receive(delta)
        scheduleTick()
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

    private func consume(_ delta: String) {
        text += delta
        var buffer = tail + delta
        var newChunks: [Chunk] = []
        while let range = buffer.range(of: "\n\n") {
            let paragraph = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            if !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newChunks.append(Chunk(id: finalized.count + newChunks.count, text: paragraph))
            }
        }
        if !newChunks.isEmpty { finalized.append(contentsOf: newChunks) }
        tail = buffer
        let line = Self.lastNonEmptyLine(buffer) ?? finalized.last.flatMap { Self.lastNonEmptyLine($0.text) } ?? ""
        if line != lastLine { lastLine = line }
        if !hasContent, !text.isEmpty { hasContent = true }
    }

    static func lastNonEmptyLine(_ s: String) -> String? {
        for line in s.split(whereSeparator: \.isNewline).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return nil
    }
}

/// Everything needed to render one message's streamed parts.
@MainActor
final class MessageRenderState {
    let markdown: StreamingMarkdownModel
    let reasoning: ReasoningChunkModel

    init(text: String = "", reasoning: String = "", smoothing: Bool = true) {
        markdown = StreamingMarkdownModel(text: text, smoothing: smoothing)
        self.reasoning = ReasoningChunkModel(text: reasoning, smoothing: smoothing)
    }

    /// Show everything received so far (stream finished, stopped, or the user scrolled away).
    func revealAll() {
        markdown.revealAll()
        reasoning.revealAll()
    }
}
