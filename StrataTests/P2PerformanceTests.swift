import Testing
import Foundation
import UIKit
@testable import Strata

struct StreamingCodeContentTests {
    private func block(lines: Int, language: String = "swift", closed: Bool = false) -> String {
        let body = (1...max(lines, 1)).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        return "```\(language)\n" + (lines == 0 ? "" : body) + (closed ? "\n```" : "")
    }

    @Test func keepsOnlyTheTailAndCountsAllLines() {
        let c = CodeBlockContent.streaming(blockText: block(lines: 5000))
        #expect(c.lineCount == 5000)
        #expect(c.language == "swift")
        let tail = c.code.components(separatedBy: "\n")
        #expect(tail.count == CodeBlockContent.streamingTailLines)
        #expect(tail.last == "let line5000 = 5000")
        #expect(tail.first == "let line4961 = 4961")
    }

    @Test func agreesWithTheFullParseOnShortBlocks() {
        for n in [1, 2, 12, 39, 40] {
            let text = block(lines: n)
            let streaming = CodeBlockContent.streaming(blockText: text)
            let full = CodeBlockContent(blockText: text)
            #expect(streaming.lineCount == full.lineCount, "lines \(n)")
            #expect(streaming.code == full.code, "code \(n)")
            #expect(streaming.language == full.language)
        }
    }

    @Test func aTrailingFenceIsNotCode() {
        let c = CodeBlockContent.streaming(blockText: block(lines: 3, closed: true))
        #expect(c.lineCount == 3)
        #expect(c.code.hasSuffix("let line3 = 3"))
    }

    @Test func justTheOpeningFence() {
        #expect(CodeBlockContent.streaming(blockText: "```python").lineCount == 0)
        let c = CodeBlockContent.streaming(blockText: "```python\n")
        #expect(c.language == "python" && c.lineCount == 0 && c.code.isEmpty)
        #expect(CodeBlockContent.streaming(blockText: "~~~\nx").lineCount == 1)
    }

    @Test func aPartialLastLineCounts() {
        let c = CodeBlockContent.streaming(blockText: "```js\nconst a = 1;\nconst b")
        #expect(c.lineCount == 2 && c.code == "const a = 1;\nconst b")
    }

    @Test func countingLinesIsAByteScan() {
        #expect(CodeBlockContent.countLines("") == 0)
        #expect(CodeBlockContent.countLines("a") == 1)
        #expect(CodeBlockContent.countLines("a\nb\n") == 3)
        #expect(CodeBlockContent(language: "", code: "한국어\n둘").lineCount == 2)
    }
}

struct RateLimiterTests {
    @Test func letsOneThroughPerInterval() {
        var limiter = RateLimiter(interval: .seconds(1))
        let t0 = ContinuousClock.now
        let results = [
            limiter.allow(at: t0),
            limiter.allow(at: t0 + .milliseconds(10)),
            limiter.allow(at: t0 + .milliseconds(999)),
            limiter.allow(at: t0 + .seconds(1)),
            limiter.allow(at: t0 + .milliseconds(1500)),
        ]
        #expect(results == [true, false, false, true, false])
        limiter.reset()
        let afterReset = limiter.allow(at: t0 + .milliseconds(1501))
        #expect(afterReset)
    }
}

struct RecoverySignalsTests {
    @Test func aSignalWakesWaitersEarly() async throws {
        let signals = RecoverySignals(observing: false)
        let start = ContinuousClock.now
        async let a: Void = signals.wait(seconds: 30)
        async let b: Void = signals.wait(seconds: 30)
        while signals.waiterCount < 2 { try await Task.sleep(for: .milliseconds(5)) }
        signals.signal()
        try await a
        try await b
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(signals.waiterCount == 0)
    }

    @Test func itReturnsWhenTheTimeIsUp() async throws {
        let signals = RecoverySignals(observing: false)
        let start = ContinuousClock.now
        try await signals.wait(seconds: 0.1)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(90) && elapsed < .seconds(3))
        #expect(signals.waiterCount == 0)
    }

    @Test func cancellationEndsTheWaitPromptly() async throws {
        let signals = RecoverySignals(observing: false)
        let task = Task { try await signals.wait(seconds: 60) }
        while signals.waiterCount < 1 { try await Task.sleep(for: .milliseconds(5)) }
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(signals.waiterCount == 0)
    }

    @Test func cancelledBeforeItStartsDoesNotWait() async throws {
        let signals = RecoverySignals(observing: false)
        let task = Task {
            try await Task.sleep(for: .milliseconds(50)) // the cancel lands first
            try await signals.wait(seconds: 60)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(signals.waiterCount == 0)
    }
}

/// Fails every request with a lost connection.
private final class AlwaysOffline: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct StreamRecoveryCapTests {
    @Test func aLongOutageStopsRetrying() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AlwaysOffline.self]
        let client = ChatClient(session: URLSession(configuration: config))
        let endpoint = Endpoint(connectionID: UUID(), connectionName: "t", baseURL: URL(string: "http://offline.test/v1")!, apiKey: "k",
                                headers: [:], model: ModelInfo(id: "m"), supportsResumable: true)
        var checkpoint = TurnCheckpoint()
        checkpoint.idempotencyKey = UUID().uuidString.lowercased()
        checkpoint.submissionStarted = true
        let saved = StreamRecoveryPolicy.maxOutage
        StreamRecoveryPolicy.maxOutage = 0.3
        defer { StreamRecoveryPolicy.maxOutage = saved }
        // The backoff is woken by signals, as the network coming back would; here it keeps coming back and failing again.
        let waker = Task { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)); RecoverySignals.shared.signal() } }
        defer { waker.cancel() }

        let started = ContinuousClock.now
        var failure: Error?
        do {
            for try await _ in client.stream(ChatRequest(model: "m", messages: [.user("hi")]), endpoint: endpoint, checkpoint: checkpoint) {}
        } catch { failure = error }
        let error = try #require(failure)
        #expect(error is APIError)
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}

@MainActor
struct BackgroundRevealTests {
    @Test func textArrivingInTheBackgroundStartsNoTimerAndShowsOnActivation() async throws {
        let model = StreamingMarkdownModel(smoothing: true)
        model.isDisplayActive = { false }
        model.append("Hello **world**, this arrived while the screen was off.")
        #expect(model.unrevealedCount > 0)
        try await Task.sleep(for: .milliseconds(300)) // a display timer would have revealed some by now
        #expect(model.unrevealedCount > 0)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<100 where model.unrevealedCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.unrevealedCount == 0)
    }

    @Test func reasoningToo() async throws {
        let model = ReasoningChunkModel(smoothing: true)
        model.isDisplayActive = { false }
        model.append("Thinking about the question for a while.\n\nSecond paragraph.")
        #expect(model.unrevealedCount > 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.unrevealedCount > 0)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<100 where model.unrevealedCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.unrevealedCount == 0)
        #expect(model.text.contains("Second paragraph"))
    }

    @Test func activeTextStillSmooths() async throws {
        let model = StreamingMarkdownModel(smoothing: true)
        model.isDisplayActive = { true }
        model.append(String(repeating: "word ", count: 200))
        let before = model.unrevealedCount
        #expect(before > 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.unrevealedCount < before) // the timer is draining it
        model.revealAll()
        #expect(model.unrevealedCount == 0)
    }

    @Test func finishingRevealsEverythingEvenInTheBackground() {
        let model = StreamingMarkdownModel(smoothing: true)
        model.isDisplayActive = { false }
        model.append("Final answer text.")
        model.finish()
        #expect(model.unrevealedCount == 0)
    }

    @Test func goingToTheBackgroundWithATickPendingShowsEverythingAndStops() async throws {
        let model = StreamingMarkdownModel(smoothing: true)
        var active = true
        model.isDisplayActive = { active }
        model.append(String(repeating: "word ", count: 400)) // a tick is scheduled
        active = false
        for _ in 0..<100 where model.unrevealedCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.unrevealedCount == 0)
    }
}

@MainActor
struct BackgroundRevealRobustnessTests {
    /// A turn that runs entirely in the background touches every model entry point with text still hidden.
    @Test func aWholeTurnInTheBackgroundThenForeground() async throws {
        let render = MessageRenderState(smoothing: true)
        render.markdown.isDisplayActive = { false }
        render.reasoning.isDisplayActive = { false }
        for round in 0..<3 {
            render.reasoning.append("Round \(round) thinking.\n\nMore thought here.\n\n")
            render.markdown.append("Preamble \(round) with `code` and **bold**.\n\n```swift\nlet a = 1\n```\n")
            render.reasoning.beginSection()
            render.markdown.reset()
        }
        render.markdown.append("The final answer, with a [link](https://example.com) and a list:\n\n- one\n- two\n")
        render.reasoning.append("Last thought.")
        render.markdown.finish(finalText: "The final answer.")
        render.revealAll()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(render.markdown.unrevealedCount == 0 && render.reasoning.unrevealedCount == 0)
    }
}

struct AttachmentThumbnailTests {
    @Test func attachmentWithoutAThumbnailKeepsItNil() {
        let a = Attachment(jpegData: Data(repeating: 1, count: 10), sortIndex: 0, thumbnailData: nil)
        #expect(a.thumbnailData == nil)
        let b = Attachment(jpegData: Data(repeating: 1, count: 10), sortIndex: 0, thumbnailData: Data([1, 2, 3]))
        #expect(b.thumbnailData == Data([1, 2, 3]))
    }
}
