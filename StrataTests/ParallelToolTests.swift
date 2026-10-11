import Testing
import Foundation
@testable import Strata

/// Tool that sleeps for the `delay` (ms) in its arguments, records how many calls overlap, and returns the `url`
/// as a source.
final class TimedTools: ToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var maxRunning = 0
    private(set) var started: [String] = []
    private(set) var executed: [String] = []

    func execute(name: String, arguments: String) async -> ToolOutput {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let delay = args["delay"] as? Int ?? 0
        let url = args["url"] as? String ?? "https://example.com/none"
        lock.withLock { running += 1; maxRunning = max(maxRunning, running); started.append(url) }
        defer { lock.withLock { running -= 1 } }
        try? await Task.sleep(for: .milliseconds(delay))
        if Task.isCancelled { return ToolOutput(text: "cancelled", isError: true) }
        lock.withLock { executed.append(url) }
        return ToolOutput(text: "page \(url)", sources: [SourceCandidate(title: "T \(url)", url: url, content: "content of \(url)")])
    }
}

private func calls(_ spec: [(String, Int)]) -> [ChatDelta] {
    spec.enumerated().map { i, s in
        ChatDelta(toolCalls: [ToolCallDelta(index: i, id: "c\(i + 1)", name: "web_fetch",
                                            arguments: "{\"url\":\"\(s.0)\",\"delay\":\(s.1)}")])
    }
}

private func endpoint() -> Endpoint {
    Endpoint(connectionID: UUID(), connectionName: "t", baseURL: URL(string: "http://localhost/v1")!, apiKey: nil, headers: [:],
             model: ModelInfo(id: "m", supportsEffort: false, supportsTools: true))
}

@MainActor
struct ParallelToolTests {
    private func run(_ spec: [(String, Int)], limit: Int = ToolRound.maxConcurrent, tools: TimedTools = TimedTools(),
                     sources: SourceStore? = nil, events: ((TurnEvent) -> Void)? = nil) async throws -> (TurnOutcome, ScriptedStreamer) {
        let streamer = ScriptedStreamer([calls(spec), [ChatDelta(content: "Answer")]])
        var runner = TurnRunner(streamer: streamer, tools: tools)
        runner.maxConcurrentTools = limit
        let outcome = try await runner.run(endpoint: endpoint(), messages: [.user("hi")], effort: nil, sources: sources) { events?($0) }
        return (outcome, streamer)
    }

    @Test func theLimitIsThree() { #expect(ToolRound.maxConcurrent == 3) }

    @Test func resultsAreAppendedInCallOrderWhateverTheFinishingOrder() async throws {
        var finished: [String] = []
        let (outcome, streamer) = try await run([("https://a.test/1", 300), ("https://a.test/2", 20), ("https://a.test/3", 150)]) {
            if case .toolFinished(let r) = $0 { finished.append(r.id) }
        }
        #expect(outcome.steps[0].calls.map(\.id) == ["c1", "c2", "c3"])
        #expect(finished == ["c1", "c2", "c3"]) // announced in order too
        let second = streamer.requests[1].messages
        #expect(second.count == 5)
        #expect(second.dropFirst(2).map { $0 } == [
            .tool(callID: "c1", content: "page https://a.test/1"),
            .tool(callID: "c2", content: "page https://a.test/2"),
            .tool(callID: "c3", content: "page https://a.test/3"),
        ])
    }

    @Test func callsActuallyOverlap() async throws {
        let tools = TimedTools()
        let start = ContinuousClock.now
        _ = try await run([("https://a.test/1", 300), ("https://a.test/2", 300), ("https://a.test/3", 300)], tools: tools)
        #expect(ContinuousClock.now - start < .milliseconds(800)) // not 900 ms in sequence
        #expect(tools.maxRunning == 3)
    }

    @Test func atMostThreeRunAtOnce() async throws {
        let tools = TimedTools()
        let spec = (1...8).map { ("https://a.test/\($0)", 60) }
        let (outcome, _) = try await run(spec, tools: tools)
        #expect(tools.maxRunning == 3)
        #expect(outcome.steps[0].calls.count == 8)
        #expect(tools.executed.count == 8)
    }

    @Test func aLimitOfOneRunsOneByOne() async throws {
        let tools = TimedTools()
        _ = try await run([("https://a.test/1", 40), ("https://a.test/2", 20), ("https://a.test/3", 5)], limit: 1, tools: tools)
        #expect(tools.maxRunning == 1)
        #expect(tools.started == ["https://a.test/1", "https://a.test/2", "https://a.test/3"])
    }

    @Test func sourceNumbersMatchAOneByOneRun() async throws {
        let urls = ["https://a.test/x", "https://b.test/y", "https://a.test/x/", "https://c.test/z", "https://b.test/y#frag"]
        let delays = [250, 10, 120, 5, 60] // finish out of order
        let spec = Array(zip(urls, delays))

        let parallelStore = SourceStore()
        let (parallel, parallelStreamer) = try await run(spec, sources: parallelStore)
        let sequentialStore = SourceStore()
        let (sequential, sequentialStreamer) = try await run(spec, limit: 1, sources: sequentialStore)

        #expect(parallel.steps[0].calls.map(\.sourceIDs) == sequential.steps[0].calls.map(\.sourceIDs))
        #expect(parallel.steps[0].calls.map(\.sourceIDs) == [[1], [2], [1], [3], [2]])
        #expect(parallel.steps[0].calls.map(\.result) == sequential.steps[0].calls.map(\.result))
        #expect(parallelStore.items == sequentialStore.items)
        // The next request is byte-identical to the one-by-one run.
        let a = try parallelStreamer.requests[1].encoded()
        let b = try sequentialStreamer.requests[1].encoded()
        #expect(a == b)
    }

    @Test func stopCancelsEveryRunningCallPromptly() async throws {
        let tools = TimedTools()
        let spec = (1...5).map { ("https://a.test/\($0)", 30_000) }
        let task = Task { @MainActor in try await self.run(spec, tools: tools) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(tools.maxRunning == 3)
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(tools.started.count == 3) // the queued calls never started
        #expect(tools.executed.isEmpty)
    }

    @Test func eachFinishingResultIsCheckpointedBeforeItsTurnToBeAppended() async throws {
        var sawPending: [[String]] = []
        _ = try await run([("https://a.test/1", 400), ("https://a.test/2", 10), ("https://a.test/3", 60)]) {
            if case .checkpoint(let cp) = $0, cp.streamDone, !(cp.pendingResults ?? []).isEmpty {
                sawPending.append((cp.pendingResults ?? []).map(\.callID).sorted())
            }
        }
        // c2 and c3 finished while c1 still ran: both were held in the checkpoint, not lost.
        #expect(sawPending.contains { $0.count == 1 })
        #expect(sawPending.contains(["c2", "c3"]))
    }

    @Test func aRestoredCheckpointRunsOnlyWhatIsMissing() async throws {
        let spec = [("https://a.test/1", 0), ("https://a.test/2", 0), ("https://a.test/3", 0)]
        var cp = try TurnCheckpoint(messages: [.user("hi")])
        cp.submissionStarted = true
        cp.streamDone = true
        for d in calls(spec) { _ = try cp.apply(d) }
        let sources = SourceStore()
        // c1 was flushed; c3 finished early and was held; c2 never finished.
        cp.records = [ToolCallRecord(id: "c1", name: "web_fetch", arguments: cp.accumulator.toolCalls[0].arguments,
                                     result: "r1", isError: false, sourceIDs: [])]
        cp.pendingResults = [RawToolResult(callID: "c3", output: ToolOutput(text: "page https://a.test/3",
                             sources: [SourceCandidate(title: "T3", url: "https://a.test/3", content: "c3")]))]
        let tools = TimedTools()
        let streamer = ScriptedStreamer([[ChatDelta(content: "Answer")]])
        let outcome = try await TurnRunner(streamer: streamer, tools: tools)
            .run(endpoint: endpoint(), messages: [.user("hi")], effort: nil, sources: sources, checkpoint: cp) { _ in }
        #expect(tools.started == ["https://a.test/2"])
        #expect(outcome.steps[0].calls.map(\.id) == ["c1", "c2", "c3"])
        // c2 was numbered before c3, as a one-by-one run would.
        #expect(outcome.steps[0].calls[1].sourceIDs == [1])
        #expect(outcome.steps[0].calls[2].sourceIDs == [2])
        let tail = streamer.requests[0].messages.suffix(3)
        #expect(tail.map { $0 } == [
            .tool(callID: "c1", content: "r1"),
            .tool(callID: "c2", content: outcome.steps[0].calls[1].result),
            .tool(callID: "c3", content: outcome.steps[0].calls[2].result),
        ])
    }

    @Test func pendingResultsSurviveTheDynamicHalf() throws {
        var cp = try TurnCheckpoint(messages: [.user("hi")])
        cp.pendingResults = [RawToolResult(callID: "c2", output: ToolOutput(text: "t", isError: false, sources: [SourceCandidate(title: "a", url: "u", content: "c")]))]
        let data = try JSONEncoder().encode(cp.dynamicPart)
        var fresh = try TurnCheckpoint(messages: [.user("hi")])
        fresh.overlay(try JSONDecoder().decode(CheckpointDynamic.self, from: data))
        #expect(fresh.pendingResults == cp.pendingResults)
    }

    @Test func aDynamicPartSavedBeforeThisFieldStillDecodes() throws {
        // Encode a current one and drop the new key, which is how an older build wrote it.
        let cp = try TurnCheckpoint(messages: [.user("hi")])
        var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(cp.dynamicPart)) as? [String: Any])
        obj["pendingResults"] = nil
        let decoded = try JSONDecoder().decode(CheckpointDynamic.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(decoded.pendingResults == nil)
    }
}

// MARK: - Same page, one load

@MainActor
struct InFlightLoadTests {
    private struct PublicResolver: HostResolving {
        func resolve(_ host: String) async -> [String] { ["93.184.216.34"] }
    }

    @MainActor
    private final class Counter { var loads = 0 }

    private func tool(inFlight: InFlightLoads, counter: Counter, delay: Duration = .milliseconds(200)) -> WebFetchTool {
        var t = WebFetchTool(resolver: PublicResolver(), cache: PageCache(), limit: 1000, loader: { url in
            counter.loads += 1
            if let sink = ToolContext.progressSink {
                sink(0.3)
                try await Task.sleep(for: delay)
                sink(0.6)
            }
            return FetchedPage(title: "T", url: url.absoluteString, text: "body of \(url.absoluteString)")
        })
        t.inFlight = inFlight
        return t
    }

    @Test func twoFetchesOfOnePageLoadItOnce() async {
        let inFlight = InFlightLoads()
        let counter = Counter()
        let t = tool(inFlight: inFlight, counter: counter)
        async let a = ToolContext.$callID.withValue("a") { await t.run(urlString: "https://example.com/page") }
        async let b = ToolContext.$callID.withValue("b") { await t.run(urlString: "https://example.com/page#section") }
        let (ra, rb) = await (a, b)
        #expect(counter.loads == 1)
        #expect(!ra.isError && !rb.isError)
        #expect(ra.sources.first?.url == rb.sources.first?.url)
        #expect(inFlight.count == 0)
    }

    @Test func differentPagesLoadSeparately() async {
        let inFlight = InFlightLoads()
        let counter = Counter()
        let t = tool(inFlight: inFlight, counter: counter)
        async let a = t.run(urlString: "https://example.com/one")
        async let b = t.run(urlString: "https://example.com/two")
        _ = await (a, b)
        #expect(counter.loads == 2)
    }

    @Test func progressReachesEveryCallWaitingOnTheLoad() async throws {
        let inFlight = InFlightLoads()
        let counter = Counter()
        let t = tool(inFlight: inFlight, counter: counter, delay: .milliseconds(400))
        let idA = "a-\(UUID().uuidString)", idB = "b-\(UUID().uuidString)"
        let a = Task { @MainActor in await ToolContext.$callID.withValue(idA) { await t.run(urlString: "https://example.com/shared") } }
        try await Task.sleep(for: .milliseconds(100))
        let b = Task { @MainActor in await ToolContext.$callID.withValue(idB) { await t.run(urlString: "https://example.com/shared") } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(ToolProgress.shared.value(for: idA) == 0.3)
        #expect(ToolProgress.shared.value(for: idB) == 0.3) // joined late, caught up
        _ = await (a.value, b.value)
        ToolProgress.shared.clear(idA); ToolProgress.shared.clear(idB)
    }

    @Test func cancellingOneWaiterKeepsTheLoadForTheOther() async throws {
        let inFlight = InFlightLoads()
        let counter = Counter()
        let t = tool(inFlight: inFlight, counter: counter, delay: .milliseconds(300))
        let a = Task { @MainActor in await t.run(urlString: "https://example.com/keep") }
        let b = Task { @MainActor in await t.run(urlString: "https://example.com/keep") }
        try await Task.sleep(for: .milliseconds(80))
        a.cancel()
        let ra = await a.value
        let rb = await b.value
        #expect(ra.isError)
        #expect(!rb.isError)
        #expect(counter.loads == 1)
    }

    @Test func cancellingTheLastWaiterCancelsTheLoad() async throws {
        let inFlight = InFlightLoads()
        let counter = Counter()
        let t = tool(inFlight: inFlight, counter: counter, delay: .seconds(30))
        let a = Task { @MainActor in await t.run(urlString: "https://example.com/gone") }
        let b = Task { @MainActor in await t.run(urlString: "https://example.com/gone") }
        try await Task.sleep(for: .milliseconds(80))
        let start = ContinuousClock.now
        a.cancel(); b.cancel()
        _ = await (a.value, b.value)
        #expect(ContinuousClock.now - start < .milliseconds(500))
        try await Task.sleep(for: .milliseconds(100))
        #expect(inFlight.count == 0)
    }

    @Test func aFailedLoadIsSharedAndForgotten() async {
        let inFlight = InFlightLoads()
        let counter = Counter()
        var built = WebFetchTool(resolver: PublicResolver(), cache: PageCache(), limit: 1000, loader: { _ in
            counter.loads += 1
            try await Task.sleep(for: .milliseconds(100))
            throw WebToolError.timeout
        })
        built.inFlight = inFlight
        let t = built
        async let a = t.run(urlString: "https://example.com/bad")
        async let b = t.run(urlString: "https://example.com/bad")
        let (ra, rb) = await (a, b)
        #expect(ra.isError && rb.isError)
        #expect(counter.loads == 1)
        #expect(inFlight.count == 0)
        _ = await t.run(urlString: "https://example.com/bad") // a later call tries again
        #expect(counter.loads == 2)
    }
}
