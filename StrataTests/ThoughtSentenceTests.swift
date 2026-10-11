import Testing
import Foundation
@testable import Strata

struct ThoughtSentenceTests {
    private func latest(_ s: String) -> String? { ThoughtSentences.latest(in: s)?.text }

    @Test func emptyAndWhitespaceHaveNoSentence() {
        #expect(latest("") == nil)
        #expect(latest("  \n \n") == nil)
    }

    @Test func aGrowingSentenceKeepsItsStart() {
        let a = ThoughtSentences.latest(in: "The user wants")
        let b = ThoughtSentences.latest(in: "The user wants current information")
        #expect(a?.start == 0 && b?.start == 0)
        #expect(b?.text == "The user wants current information")
    }

    @Test func periodQuestionAndBangFollowedByWhitespaceEndASentence() {
        #expect(latest("First one. Second one") == "Second one")
        #expect(latest("Is it? Maybe so") == "Maybe so")
        #expect(latest("Wow! Next") == "Next")
        #expect(latest("Tabs.\tAfter") == "After")
    }

    @Test func aFinishedSentenceStaysUntilTheNextOneBegins() {
        #expect(latest("First one. ") == "First one.")
        #expect(latest("First one.") == "First one.")
        #expect(latest("First one. S") == "S")
    }

    @Test func punctuationInsideTokensIsNotABoundary() {
        #expect(latest("Version 3.5 is out") == "Version 3.5 is out")
        #expect(latest("See example.com for details") == "See example.com for details")
        #expect(latest("Wait... what") == "what")
    }

    @Test func newlinesStartANewSentence() {
        #expect(latest("**Planning**\nLook at the docs") == "Look at the docs")
        #expect(latest("One\n\nTwo") == "Two")
    }

    @Test func koreanEndingsAndCJKFullStop() {
        #expect(latest("문서를 확인해야 한다. 그 다음에 정리한다") == "그 다음에 정리한다")
        #expect(latest("좋아요. 이제 시작해요") == "이제 시작해요")
        #expect(latest("これは文です。次の文") == "次の文")
    }

    @Test func startIsAUTF8OffsetThatIncreasesForEachNewSentence() throws {
        let one = try #require(ThoughtSentences.latest(in: "한국어 문장이다. Second"))
        #expect(one.text == "Second")
        let text = "한국어 문장이다. Second"
        #expect(one.start == text.utf8.count - "Second".utf8.count)
        let two = try #require(ThoughtSentences.latest(in: text + " sentence here. Third"))
        #expect(two.start > one.start && two.text == "Third")
    }

    @MainActor @Test func modelPublishesTheCurrentSentenceAcrossParagraphs() {
        let m = ReasoningChunkModel(text: "Plan the work. Then check\n\nNext paragraph starts")
        #expect(m.thought?.text == "Next paragraph starts")
        m.load("Plan the work. Then check")
        #expect(m.thought?.text == "Then check")
    }
}

struct ThoughtPreviewGateTests {
    private func s(_ start: Int, _ text: String) -> ThoughtSentence { ThoughtSentence(start: start, text: text) }

    @Test func theFirstSentenceShowsImmediately() {
        var gate = ThoughtPreviewGate()
        #expect(gate.update(latest: s(0, "Hello"), now: 100) == s(0, "Hello"))
        #expect(gate.nextSwitchAt == nil)
    }

    @Test func nilInputKeepsWhatIsShown() {
        var gate = ThoughtPreviewGate()
        #expect(gate.update(latest: nil, now: 0) == nil)
        gate.update(latest: s(0, "A"), now: 1)
        #expect(gate.update(latest: nil, now: 2) == s(0, "A"))
    }

    @Test func aGrowingSentenceUpdatesInPlaceWithoutSwitching() {
        var gate = ThoughtPreviewGate()
        gate.update(latest: s(0, "The user"), now: 0)
        #expect(gate.update(latest: s(0, "The user wants"), now: 0.05) == s(0, "The user wants"))
        #expect(gate.update(latest: s(0, "The user wants data"), now: 0.1) == s(0, "The user wants data"))
        #expect(gate.nextSwitchAt == nil)
    }

    @Test func aNewSentenceInsideTheWindowIsHeldAndReportsWhenItMaySwitch() {
        var gate = ThoughtPreviewGate(minInterval: 1.2)
        gate.update(latest: s(0, "One."), now: 10)
        let shown = gate.update(latest: s(5, "Two"), now: 10.4)
        #expect(shown == s(0, "One."), "held back")
        #expect(gate.nextSwitchAt == 11.2)
    }

    @Test func atTheEndOfTheWindowItJumpsStraightToTheLatestSentence() {
        var gate = ThoughtPreviewGate(minInterval: 1.2)
        gate.update(latest: s(0, "One."), now: 10)
        gate.update(latest: s(5, "Two."), now: 10.3)
        gate.update(latest: s(10, "Three."), now: 10.8)
        gate.update(latest: s(18, "Four is being writ"), now: 11.1)
        #expect(gate.displayed == s(0, "One."))
        // The caller wakes at nextSwitchAt and passes whatever is latest then: sentences 2 and 3 are skipped.
        #expect(gate.nextSwitchAt == 11.2)
        #expect(gate.update(latest: s(18, "Four is being written"), now: 11.2) == s(18, "Four is being written"))
        #expect(gate.nextSwitchAt == nil)
    }

    @Test func eachSwitchOpensANewWindow() {
        var gate = ThoughtPreviewGate(minInterval: 1.2)
        gate.update(latest: s(0, "A."), now: 0)
        gate.update(latest: s(3, "B"), now: 1.2) // exactly at the boundary: allowed
        #expect(gate.displayed == s(3, "B"))
        gate.update(latest: s(6, "C"), now: 2.0) // 0.8 s after the last switch
        #expect(gate.displayed == s(3, "B") && gate.nextSwitchAt == 2.4)
        gate.update(latest: s(6, "C"), now: 2.4)
        #expect(gate.displayed == s(6, "C"))
    }

    @Test func slowStreamsSwitchWithoutDelay() {
        var gate = ThoughtPreviewGate(minInterval: 1.2)
        gate.update(latest: s(0, "A."), now: 0)
        #expect(gate.update(latest: s(3, "B"), now: 5) == s(3, "B"))
    }
}
