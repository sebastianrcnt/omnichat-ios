import Testing
import Foundation
import os
@testable import Strata

/// Fixes from the code reviews: inputs that used to crash, hang, or lose data.
struct ReviewFixTests {
    @Test func reusedCallIDsBecomeUnique() {
        var acc = StreamAccumulator()
        acc.apply(ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "call_0", name: "web_search", arguments: "{}")]))
        acc.apply(ChatDelta(toolCalls: [ToolCallDelta(index: 1, id: "call_0", name: "web_fetch", arguments: "{}")]))
        let ids = acc.toolCalls.map(\.id)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids[0] == "call_0")
    }

    @Test func serverCountersSaturateInsteadOfTrapping() {
        #expect(ContextLimits.add(Int.max, 1) == Int.max)
        #expect(ContextLimits.add(3, -5, 4) == 7)
        #expect(Usage(promptTokens: Int.max, completionTokens: 1).totalTokens == Int.max)
        #expect(Compaction.limit(window: Int.max, maxOutput: nil) == ContextLimits.maxTokens * 9 / 10)
    }

    @Test func chatsAreGroupedByAge() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        func label(daysAgo: Int) -> String {
            ConversationGroups.label(for: calendar.date(byAdding: .day, value: -daysAgo, to: now)!, now: now, calendar: calendar)
        }
        #expect(label(daysAgo: 0) == "Today")
        #expect(label(daysAgo: 1) == "Yesterday")
        #expect(label(daysAgo: 3) == "Previous 7 Days")
        #expect(label(daysAgo: 20) == "Previous 30 Days")
        #expect(label(daysAgo: 400).contains("2025"))
    }

    @Test func toolsThatAreOffAreRefusedAtExecution() async {
        struct Echo: ToolExecuting {
            func execute(name: String, arguments: String) async -> ToolOutput { ToolOutput(text: "ran \(name)") }
        }
        let offered = OfferedTools(base: Echo(), names: ["web_search"])
        #expect(await offered.execute(name: "web_search", arguments: "{}").text == "ran web_search")
        let refused = await offered.execute(name: "current_location", arguments: "{}")
        #expect(refused.isError)
    }

    @Test func onlyReadingToolsAreRetriedAfterTheBackground() {
        #expect(ToolNames.isSafeToRetry(ToolNames.webFetch))
        #expect(!ToolNames.isSafeToRetry(ToolNames.runPython))
        #expect(!ToolNames.isSafeToRetry(ToolNames.browserEval))
    }

    @Test func newIPv6TunnelRangesAreBlocked() {
        #expect(URLGuard.isBlocked(address: "2002:c0a8:0101::1"))   // 6to4 of 192.168.1.1
        #expect(!URLGuard.isBlocked(address: "2002:0808:0808::1"))  // 6to4 of 8.8.8.8
        #expect(URLGuard.isBlocked(address: "2001:0:4136:e378::1")) // Teredo
        #expect(URLGuard.isBlocked(address: "fec0::1"))
        #expect(URLGuard.isBlocked(address: "64:ff9b:1::1"))
        #expect(URLGuard.isIPLiteralPrivate("192.168.0.10"))
        #expect(!URLGuard.isIPLiteralPrivate("example.com"))
    }

    @Test func redactionCoversOAuthFields() {
        let json = #"{"refresh_token":"r-123","id_token":"i-456","client_secret":"s","max_tokens":100}"#
        let out = DebugRedaction.redact(json)
        #expect(!out.contains("r-123") && !out.contains("i-456"))
        #expect(out.contains("\"max_tokens\":100"))
        let form = DebugRedaction.redact("grant_type=refresh_token&refresh_token=abc123&client_id=x")
        #expect(!form.contains("abc123"))
    }

    @Test func compactionNotesEndingInAHashtagAreWhole() {
        #expect(Compaction.cutReason(finishReason: "stop", content: "Notes\n#hashtag") == nil)
        #expect(Compaction.cutReason(finishReason: "stop", content: "Notes\n## Next") != nil)
    }

    @Test func indentedFencesAreCode() {
        #expect(TranslationPlan.fenceMarker("        ```swift") != nil)
    }

    @Test func aStreamCutOffWithoutDoneIsAnError() async {
        let cut = Array("data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n".utf8)
        await #expect(throws: APIError.self) {
            try await ChatClient.consume(cut.async) { _ in }
        }
        let finished = Array("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"},\"finish_reason\":\"stop\"}]}\n\n".utf8)
        var text = ""
        try? await ChatClient.consume(finished.async) { text += $0.content ?? "" }
        #expect(text == "Hi")
    }
}

private extension Array where Element == UInt8 {
    var async: AsyncStream<UInt8> {
        let bytes = self
        return AsyncStream { continuation in
            for b in bytes { continuation.yield(b) }
            continuation.finish()
        }
    }
}

/// SSE servers may end lines with CR alone: each event arrives as it is sent, not at the end of the stream.
struct CROnlySSETests {
    @Test func crOnlyLinesAreDeliveredAsTheyArrive() async throws {
        let (bytes, input) = AsyncStream<UInt8>.makeStream()
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        let reader = Task {
            try await ChatClient.consume(bytes) { delta in
                if let t = delta.content { seen.withLock { $0.append(t) } }
            }
        }
        for b in Array("data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\r\r".utf8) { input.yield(b) }
        // The first event arrives while the stream is still open.
        let deadline = ContinuousClock.now + .seconds(2)
        while seen.withLock({ $0.isEmpty }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(seen.withLock { $0 } == ["Hel"])
        for b in Array("data: {\"choices\":[{\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"stop\"}]}\r\rdata: [DONE]\r\r".utf8) {
            input.yield(b)
        }
        input.finish()
        try await reader.value
        #expect(seen.withLock { $0 } == ["Hel", "lo"])
    }

    @Test func crlfStillCountsAsOneLineBreak() {
        var parser = SSEParser()
        var events = parser.feed("data: a\r")
        events += parser.feed("\n\r\n")
        #expect(events.map(\.data) == ["a"])
    }
}
