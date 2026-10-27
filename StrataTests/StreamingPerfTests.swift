import Testing
import Foundation
import SwiftUI
import UIKit
import os
@testable import Strata

/// Replays a long markdown answer into a real UIHostingController and measures the main thread.
///
/// Default is about 1,500 tokens at 400 tokens/s (4 s): faster than a real stream, so each publish carries more text
/// while the document grows to the same size. For the full 10k-token run at a real stream's 100 tokens/s (about 100 s):
///   TEST_RUNNER_STRATA_PERF_TOKENS=10000 TEST_RUNNER_STRATA_PERF_RATE=100 xcodebuild test ... -only-testing:StrataTests/StreamingPerfTests
/// Simulator-only: the bounds are loose and meant to catch regressions (an O(n^2) re-render), not to benchmark.
@MainActor
struct StreamingPerfTests {
    static let signposter = OSSignposter(subsystem: "cc.coolservices.strata", category: "StreamingPerf")

    /// A realistic answer: headings, lists, code, a table, quotes and Korean, repeated to the token target.
    static func document(tokens target: Int) -> String {
        let section = { (n: Int) in """
        ## Section \(n): rendering notes

        A paragraph with **bold**, *italic*, `inline code` and a [link](https://example.com/\(n)) that keeps going for a while so it wraps over several lines on a phone screen [1][2].

        - First point about layout \(n)
        - Second point with `code` and **emphasis**
          - A nested point
        - Third point

        1. Measure the apply cost
        2. Measure the layout cost

        > A quoted remark that spans a line or two of the answer.

        ```swift
        let value\(n) = configure(glassEffect: .regular, id: \(n))
        print(value\(n))
        ```

        | API | Use | Notes |
        | --- | --- | --- |
        | glassEffect | Apply the material | Controls only |
        | GlassEffectContainer | Blend neighbours | Group related views |

        한국어 요약 \(n): 글래스 효과는 컨트롤에만 쓰고, 본문 텍스트는 유리 위에 올리지 않는 것이 좋습니다.


        """ }
        var out = "# Streaming performance replay\n\n"
        var n = 1
        while approximateTokens(out) < target { out += section(n); n += 1 }
        return out
    }

    /// Roughly one token per four characters (Korean counts one per character).
    static func approximateTokens(_ s: String) -> Int {
        var count = 0.0
        for ch in s { count += ch.isASCII ? 0.25 : 1.0 }
        return Int(count)
    }

    /// Cut the text into chunks of about one token each, ignoring markdown boundaries like a real stream.
    static func tokens(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var weight = 0.0
        for ch in text {
            current.append(ch)
            weight += ch.isASCII ? 0.25 : 1.0
            if weight >= 1 { out.append(current); current = ""; weight = 0 }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1 < 0 ? 0 : Int((Double(sorted.count) * p).rounded(.up)) - 1)]
    }

    private static func makeWindow(_ root: some View) -> (UIWindow, UIHostingController<AnyView>)? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return nil }
        let host = UIHostingController(rootView: AnyView(root))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.isHidden = false
        host.view.layoutIfNeeded()
        return (window, host)
    }

    @Test func tenKTokenReplayStaysSmooth() async throws {
        let target = Int(ProcessInfo.processInfo.environment["STRATA_PERF_TOKENS"] ?? "") ?? 1_500
        let rate = max(1, Int(ProcessInfo.processInfo.environment["STRATA_PERF_RATE"] ?? "") ?? 400) // tokens per second
        let text = Self.document(tokens: target)
        let tokens = Self.tokens(of: text)
        let model = StreamingMarkdownModel(smoothing: true)
        var applyMs: [Double] = []
        model.onApply = { applyMs.append($0.seconds * 1000) }

        let root = ScrollView { MarkdownDocumentView(model: model).padding(16) }
            .environment(\.theme, DSTheme())
            .environment(\.citations, CitationContext(sources: [:]))
        guard let (window, host) = Self.makeWindow(root) else {
            Issue.record("no window scene available; perf replay skipped")
            return
        }
        defer { window.isHidden = true }

        // Main-thread busy time per run-loop turn: apply, SwiftUI update, layout and the commit all land here.
        var turnMs: [Double] = []
        var turnStart: CFAbsoluteTime = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            if activity == .afterWaiting { turnStart = CFAbsoluteTimeGetCurrent() }
            else if turnStart > 0 { turnMs.append((CFAbsoluteTimeGetCurrent() - turnStart) * 1000); turnStart = 0 }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }

        let signpost = Self.signposter.beginInterval("replay", "tokens=\(tokens.count)")
        let clock = ContinuousClock()
        let start = clock.now
        let interval = Duration.seconds(1) / rate
        let layoutEvery = max(1, rate * 33 / 1000) // roughly one forced layout per publish (33 ms)
        var layoutMs: [Double] = []
        for (i, token) in tokens.enumerated() {
            model.append(token)
            if i % layoutEvery == 0 {
                let id = Self.signposter.beginInterval("layout")
                let t0 = clock.now
                host.view.layoutIfNeeded()
                layoutMs.append((clock.now - t0).seconds * 1000)
                Self.signposter.endInterval("layout", id)
            }
            try await Task.sleep(until: start + interval * (i + 1), clock: clock)
        }
        model.finish()
        // The final parse comes back from the background pipeline.
        let parsed = IncrementalBlockParser.parse(text)
        let deadline = clock.now + .seconds(5)
        while model.blocks != parsed, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        Self.signposter.endInterval("replay", signpost)

        let applyP95 = Self.percentile(applyMs, 0.95), layoutP95 = Self.percentile(layoutMs, 0.95), turnP95 = Self.percentile(turnMs, 0.95)
        let line = String(format: "PERF tokens=%d publishes=%d apply p50=%.2fms p95=%.2fms max=%.2fms | layout p95=%.2fms max=%.2fms | runloop-turn p95=%.2fms p99=%.2fms max=%.2fms",
                          tokens.count, applyMs.count, Self.percentile(applyMs, 0.5), applyP95, applyMs.max() ?? 0,
                          layoutP95, layoutMs.max() ?? 0, turnP95, Self.percentile(turnMs, 0.99), turnMs.max() ?? 0)
        print(line)
        Logger(subsystem: "cc.coolservices.strata", category: "StreamingPerf").info("\(line, privacy: .public)")

        #expect(model.blocks == parsed, "the streamed document equals a one-shot parse")
        #expect(!applyMs.isEmpty)
        // Loose simulator bounds: a 16 ms frame budget with generous headroom for a busy CI host.
        #expect(applyP95 < 16, "apply p95 \(applyP95) ms")
        #expect(layoutP95 < 33, "layout p95 \(layoutP95) ms")
        #expect(turnP95 < 50, "run-loop turn p95 \(turnP95) ms")
    }

    @Test func percentileHelper() {
        #expect(Self.percentile([], 0.95) == 0)
        #expect(Self.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95) == 10)
        #expect(Self.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.5) == 5)
    }

    @Test func generatedDocumentHitsTheTokenTarget() {
        let doc = Self.document(tokens: 800)
        #expect(Self.approximateTokens(doc) >= 800)
        #expect(doc.contains("| API |") && doc.contains("```swift") && doc.contains("한국어"))
        #expect(Self.tokens(of: doc).joined() == doc)
    }
}
