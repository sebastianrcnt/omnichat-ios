import Testing
import Foundation
@testable import Strata

private struct FakeTranslator: TextTranslating {
    func translate(_ texts: [String]) async throws -> [String] { texts.map { "KO:" + $0 } }
}

@MainActor
struct ThoughtTranslatorTests {
    private func make(installed: Bool) -> ThoughtTranslator {
        let t = ThoughtTranslator()
        t.translator = FakeTranslator()
        t.isInstalled = { installed }
        return t
    }

    private func settle(_ t: ThoughtTranslator, _ text: String) async {
        for _ in 0..<200 where t.result(for: text) == nil { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func englishIsTranslatedAndKoreanStaysAsWritten() async {
        let t = make(installed: true)
        t.request("Let me check the reviews first.")
        t.request("리뷰를 먼저 확인해 보겠습니다.")
        await settle(t, "Let me check the reviews first.")
        await settle(t, "리뷰를 먼저 확인해 보겠습니다.")
        #expect(t.result(for: "Let me check the reviews first.") == "KO:Let me check the reviews first.")
        #expect(t.result(for: "리뷰를 먼저 확인해 보겠습니다.") == "리뷰를 먼저 확인해 보겠습니다.")
    }

    @Test func nothingIsTranslatedWithoutTheLanguageInstalled() async {
        let t = make(installed: false)
        t.request("Let me check the reviews first.")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(t.result(for: "Let me check the reviews first.") == nil)
    }

    @Test func finishedSentencesEndInPunctuation() {
        #expect(ThoughtCompletion.isFinished("I should search."))
        #expect(ThoughtCompletion.isFinished("Is it open?"))
        #expect(!ThoughtCompletion.isFinished("I should sea"))
    }
}
