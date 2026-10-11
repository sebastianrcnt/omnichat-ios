import Foundation
import Testing
@testable import Strata

@MainActor
struct TimelineGroupTests {
    private func call(_ id: String) -> ToolCallRecord {
        ToolCallRecord(id: id, name: ToolNames.webSearch, arguments: "{\"query\":\"q\"}", result: "", isError: false, sourceIDs: [1])
    }

    @Test func consecutiveThinkingParagraphsShareOneBlock() {
        let step = ToolStep(assistantContent: "", calls: [call("a")], reasoningParagraphs: 2)
        let items = TimelineItem.build(chunks: ["p0", "p1", "p2", "p3"], steps: [step], pending: [], sources: [:])
        let groups = TimelineGroup.group(items)
        #expect(groups.count == 3)
        guard case .thinking(let id0, let first) = groups[0], case .activity = groups[1], case .thinking(_, let last) = groups[2] else {
            Issue.record("unexpected group order"); return
        }
        #expect(id0 == "t0" && first.map(\.text) == ["p0", "p1"] && last.map(\.text) == ["p2", "p3"])
    }

    @Test func aBlockKeepsItsIdAsParagraphsAreAdded() {
        let one = TimelineGroup.group(TimelineItem.build(chunks: ["a"], steps: [], pending: [], sources: [:]))
        let two = TimelineGroup.group(TimelineItem.build(chunks: ["a", "b"], steps: [], pending: [], sources: [:]))
        #expect(one.map(\.id) == two.map(\.id))
    }
}

struct FollowThrottleTests {
    @Test func atMostOneFollowPerInterval() {
        var t = FollowThrottle()
        #expect(t.request(now: 10.0) == 0)
        #expect(abs(t.request(now: 10.03) - 0.07) < 1e-9, "asks to retry once the interval has passed")
        #expect(t.request(now: 10.1) == 0)
        #expect(t.request(now: 10.15) > 0)
        #expect(t.request(now: 10.25) == 0)
    }
}

@MainActor
struct ConversationDateTests {
    @Test func lineFormatAndWeekday() {
        #expect(ConversationDate.line(day: "2026-10-11") == "Current date: 2026-10-11 (Sunday).")
        #expect(ConversationDate.line(day: "2024-02-29") == "Current date: 2024-02-29 (Thursday).")
        #expect(ConversationDate.systemPrompt(base: "  Be brief.  ", day: "2026-10-11") == "Be brief.\n\nCurrent date: 2026-10-11 (Sunday).")
        #expect(ConversationDate.systemPrompt(base: "", day: "2026-10-11") == "Current date: 2026-10-11 (Sunday).")
    }

    @Test func dayUsesTheGivenTimeZone() {
        var cal = Calendar(identifier: .gregorian)
        let moment = Date(timeIntervalSince1970: 1_791_700_000) // 2026-10-11 ~05:46 UTC
        cal.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        let auckland = ConversationDate.day(for: moment, calendar: cal)
        cal.timeZone = TimeZone(identifier: "Pacific/Pago_Pago")!
        let samoa = ConversationDate.day(for: moment, calendar: cal)
        #expect(auckland == "2026-10-11" && samoa == "2026-10-10")
    }

    @Test func theSystemMessageIsByteStableAcrossTurnsAndDays() throws {
        let c = Conversation()
        c.createdDay = "2026-10-11"
        let history = [HistoryMessage(role: "user", text: "hi")]
        func request() throws -> Data {
            let msgs = MessageAssembler.apiMessages(from: history, systemPrompt: ConversationDate.systemPrompt(base: "Base.", day: c.systemDay))
            return try ChatRequest(model: "m", messages: msgs).encoded()
        }
        let first = try request()
        c.createdAt = .now.addingTimeInterval(86_400 * 40) // a later "today" changes nothing
        let second = try request()
        #expect(first == second)
        #expect(String(decoding: first, as: UTF8.self).contains("Current date: 2026-10-11 (Sunday)."))
    }

    @Test func oldConversationsTakeTheirCreationDayOnceAndKeepIt() {
        let c = Conversation()
        c.createdDay = "" // saved before the field existed
        let day = c.systemDay
        #expect(day == ConversationDate.day(for: c.createdAt))
        c.createdAt = .now.addingTimeInterval(-86_400 * 90)
        #expect(c.systemDay == day, "never recomputed")
    }
}
