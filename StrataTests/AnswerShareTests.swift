import Foundation
import Testing
@testable import Strata

/// The text Share hands to another app for one answer.
struct AnswerShareTests {
    @Test func plainTextWithoutMarkdownMarkers() {
        #expect(AnswerShare.text(markdown: "**Seoul** is the *capital*.\n\n- one\n- two", sources: [])
                == "Seoul is the capital.\n\n- one\n- two")
    }

    @Test func linksKeepTheirAddress() {
        #expect(AnswerShare.text(markdown: "See [Apple](https://apple.com/iphone) for more.", sources: [])
                == "See Apple (https://apple.com/iphone) for more.")
    }

    @Test func aLinkWhoseWordsAreItsAddressIsNotRepeated() {
        #expect(AnswerShare.text(markdown: "[https://apple.com](https://apple.com)", sources: []) == "https://apple.com")
    }

    @Test func aLinkWithBoldWordsAddsItsAddressOnce() {
        #expect(AnswerShare.text(markdown: "[**Apple** site](https://apple.com)", sources: [])
                == "Apple site (https://apple.com)")
    }

    @Test func sourcesAreListedAfterTheAnswer() {
        let sources = [SourceInfo(id: 1, title: "Seoul - Wikipedia", url: "https://en.wikipedia.org/wiki/Seoul", snippet: ""),
                       SourceInfo(id: 3, title: "", url: "https://seoul.go.kr", snippet: "")]
        #expect(AnswerShare.text(markdown: "Seoul is the capital [1][3].\n", sources: sources)
                == "Seoul is the capital [1][3].\n\nSources\n[1] Seoul - Wikipedia\nhttps://en.wikipedia.org/wiki/Seoul\n[3] https://seoul.go.kr")
    }

    @Test func copyStillDropsLinkAddresses() {
        #expect(MarkdownPlain.text(from: "See [Apple](https://apple.com).") == "See Apple.")
    }
}
