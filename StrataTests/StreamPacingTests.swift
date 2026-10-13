import Testing
import Foundation
@testable import Strata

@MainActor
struct StreamPacingTests {
    // MARK: Rate math

    @Test func rateIsAShareOfTheIncomingRateWithACatchUpFloor() {
        let p = RevealPacing()
        // Small backlog: 0.85 x incoming.
        #expect(abs(p.charsPerSecond(incomingRate: 100, backlog: 10) - 85) < 1e-9)
        // Large backlog: fast enough to show it within 0.35 s.
        #expect(abs(p.charsPerSecond(incomingRate: 100, backlog: 70) - 200) < 1e-9)
        // Nothing arriving: still drains what is queued.
        #expect(abs(p.charsPerSecond(incomingRate: 0, backlog: 35) - 100) < 1e-9)
        #expect(p.charsPerSecond(incomingRate: 0, backlog: 0) == 0)
    }

    @Test func incomingRateOverTheWindow() {
        let p = RevealPacing()
        let arrivals: [(time: Double, count: Int)] = [(10.0, 50), (10.5, 50), (11.0, 50)]
        #expect(abs(p.incomingRate(arrivals: arrivals, now: 11.0) - 100) < 1e-9) // 100 chars in the last 1 s (10.0 is out)
        // A single burst is measured over at least 0.25 s.
        #expect(abs(p.incomingRate(arrivals: [(5.0, 50)], now: 5.0) - 200) < 1e-9)
        #expect(p.incomingRate(arrivals: [], now: 1) == 0)
        #expect(p.incomingRate(arrivals: [(1.0, 10)], now: 9) == 0)
    }

    @Test func displayNeverFallsFarBehind() {
        // A steady 200 chars/s stream in 50-char bursts every 0.25 s, ticked at 30 Hz for 3 s.
        var r = RevealController(pacing: RevealPacing())
        let text = String(repeating: "word ", count: 200)
        var chars = Array(text)
        var now = 0.0, nextArrival = 0.0, maxBacklog = 0
        let dt = 1.0 / 30
        while now < 3 {
            if now >= nextArrival, !chars.isEmpty {
                r.receive(String(chars.prefix(50)), at: now)
                chars.removeFirst(min(50, chars.count))
                nextArrival += 0.25
            }
            _ = r.tick(dt: dt, now: now)
            maxBacklog = max(maxBacklog, r.backlogCount)
            now += dt
        }
        // At 200 chars/s, 0.35 s behind is 70 characters; one burst (50) on top is the most that can queue.
        #expect(maxBacklog <= 50 + 70)
        #expect(r.revealedCount > 400)
    }

    @Test func revealsWholeWordsAndNeverSplitsGraphemes() {
        #expect(RevealController.wordCut("hello world", upTo: 3, maxWord: 20) == 0) // waits for "hello"
        #expect(RevealController.wordCut("hello world", upTo: 5, maxWord: 20) == 5) // a word ends here
        #expect(RevealController.wordCut("hello world again", upTo: 8, maxWord: 20) == 6) // after the space
        #expect(RevealController.wordCut("abc", upTo: 3, maxWord: 20) == 3) // everything that arrived
        #expect(RevealController.wordCut("출산율이반등했다", upTo: 4, maxWord: 4) == 4) // no spaces: cut once long enough
        let family = "👨‍👩‍👧‍👦 next"
        let cut = RevealController.wordCut(family, upTo: 1, maxWord: 20)
        #expect(cut == 1) // the emoji is one character, followed by a space
        var r = RevealController(pacing: RevealPacing())
        r.receive("👨‍👩‍👧‍👦 é e\u{301} 한국", at: 0)
        var shown = ""
        var t = 0.0
        while r.hasBacklog && t < 5 { shown += r.tick(dt: 1.0 / 30, now: t); t += 1.0 / 30 }
        #expect(shown == "👨‍👩‍👧‍👦 é e\u{301} 한국")
    }

    @Test func flushShowsEverythingAtOnce() {
        var r = RevealController(pacing: RevealPacing())
        r.receive("a long answer that is still queued", at: 0)
        #expect(r.flushAll() == "a long answer that is still queued")
        #expect(!r.hasBacklog)
    }

    @Test func answerFadeIsSlowerAndEasesOut() {
        let now = Date()
        let answer = StreamingMarkdownModel.FreshSpan(length: 5, born: now, duration: StreamingMarkdownModel.answerFadeDuration, easeOut: true)
        let reasoning = StreamingMarkdownModel.FreshSpan(length: 5, born: now)
        #expect(StreamingMarkdownModel.answerFadeDuration == 0.45)
        #expect(answer.isFading(at: now.addingTimeInterval(0.3)))
        #expect(!reasoning.isFading(at: now.addingTimeInterval(0.3)))
        // Ease-out: more than halfway at the halfway point, settled at the end.
        #expect(answer.alpha(at: now.addingTimeInterval(0.225)) > 0.5)
        #expect(answer.alpha(at: now.addingTimeInterval(0.45)) == 1)
        #expect(abs(reasoning.alpha(at: now.addingTimeInterval(0.075)) - 0.5) < 0.01)
    }

    // MARK: Pinned question

    @Test func reserveLetsTheQuestionReachTheTopAndShrinksAsTheAnswerGrows() {
        #expect(PinLayout.reserve(viewport: 700, pinnedTop: 1000, contentEnd: 1100) == 600)
        #expect(PinLayout.reserve(viewport: 700, pinnedTop: 1000, contentEnd: 1500) == 200)
        #expect(PinLayout.reserve(viewport: 700, pinnedTop: 1000, contentEnd: 2000) == 0)
        // A smaller viewport (keyboard up) needs less room; the question's offset stays reachable.
        #expect(PinLayout.reserve(viewport: 400, pinnedTop: 1000, contentEnd: 1100) == 300)
    }

    @Test func chatViewIsKeptOnlyWhenItsOwnFirstSendCreatesTheConversation() {
        let a = UUID(), b = UUID()
        #expect(ChatViewKey.keepsView(old: nil, new: a, active: a)) // the new chat's first send
        #expect(!ChatViewKey.keepsView(old: nil, new: a, active: nil)) // opened from the sidebar
        #expect(!ChatViewKey.keepsView(old: b, new: a, active: a)) // switched chats
        #expect(!ChatViewKey.keepsView(old: a, new: nil, active: nil)) // New chat
        var key = ChatViewKey()
        let first = key.id
        key.update(old: nil, new: a, active: a)
        #expect(key.id == first)
        key.update(old: a, new: b, active: a)
        #expect(key.id != first)
    }
}
