import Testing
import Foundation
import SwiftData
@testable import Strata

// MARK: - When to offer

struct TranslationLanguageTests {
    private let korean = "오늘은 날씨가 정말 좋아서 공원에서 산책을 하고 점심을 먹었습니다. 저녁에는 친구들과 영화를 볼 예정입니다."
    private let english = "The weather was lovely today, so I walked around the park and had lunch outside. Tonight we are going to the cinema."

    @Test func differentLanguagesDiffer() {
        #expect(TranslationLanguage.differs("ko", "en-US"))
        #expect(TranslationLanguage.differs("fr", "en"))
    }

    @Test func regionsAndScriptlessTagsDoNotCount() {
        #expect(!TranslationLanguage.differs("en", "en-US"))
        #expect(!TranslationLanguage.differs("en-GB", "en-US"))
        #expect(!TranslationLanguage.differs("pt-BR", "pt-PT"))
        #expect(!TranslationLanguage.differs("nb", "no"))
    }

    @Test func chineseScriptsAreDifferentLanguagesToAReader() {
        #expect(TranslationLanguage.differs("zh-Hans", "zh-Hant"))
        #expect(TranslationLanguage.differs("zh-Hans", "zh-Hant-TW"))
        #expect(TranslationLanguage.differs("zh-Hans", "zh-TW"))
        #expect(!TranslationLanguage.differs("zh-Hans", "zh-CN"))
        #expect(!TranslationLanguage.differs("zh-Hant", "zh-HK"))
        #expect(!TranslationLanguage.differs("zh", "zh-Hans")) // no script on one side: same language
    }

    @Test func aKoreanAnswerIsOfferedToAnEnglishReader() {
        #expect(TranslationLanguage.dominant(of: korean) == "ko")
        #expect(TranslationLanguage.shouldOffer(text: korean, preferred: "en-US"))
    }

    @Test func anAnswerInTheReadersLanguageIsNotOffered() {
        #expect(TranslationLanguage.dominant(of: english) == "en")
        #expect(!TranslationLanguage.shouldOffer(text: english, preferred: "en-US"))
        #expect(!TranslationLanguage.shouldOffer(text: english, preferred: "en-GB"))
        #expect(TranslationLanguage.shouldOffer(text: english, preferred: "ko-KR"))
    }

    @Test func noPreferredLanguageMeansNoOffer() {
        #expect(!TranslationLanguage.shouldOffer(text: korean, preferred: nil))
    }

    @Test func tooLittleProseIsNotOffered() {
        #expect(!TranslationLanguage.shouldOffer(text: "네", preferred: "en"))
        #expect(!TranslationLanguage.shouldOffer(text: "", preferred: "en"))
    }

    @Test func codeAndLinksDoNotDecideTheLanguage() {
        // Korean prose around English code: the code is not prose.
        let mixed = "다음 코드는 목록을 정렬합니다.\n\n```swift\nlet sortedNamesInAlphabeticalOrder = names.sorted { $0 < $1 }\nprint(sortedNamesInAlphabeticalOrder)\n```\n\n결과는 알파벳 순서로 출력됩니다. https://example.com/documentation/sorting"
        #expect(TranslationLanguage.dominant(of: mixed) == "ko")
        // An English answer that is only code and a link has no prose to name.
        #expect(TranslationLanguage.dominant(of: "```swift\nlet value = computeTheResult(with: someArgument)\n```") == nil)
    }

    @Test func onlyFinishedAnswersAreEligible() {
        func ok(_ role: MessageRole = .assistant, text: String = "hello", streaming: Bool = false, error: Bool = false, unfinished: Bool = false) -> Bool {
            TranslationEligibility.isEligible(role: role, text: text, isStreaming: streaming, hasError: error, hasUnfinishedTurn: unfinished)
        }
        #expect(ok())
        #expect(!ok(.user))
        #expect(!ok(streaming: true))
        #expect(!ok(error: true))
        #expect(!ok(unfinished: true))
        #expect(!ok(text: "  \n"))
    }

    @Test func aStoredTranslationOnlyCountsForTheLanguageItWasMadeFor() {
        func state(_ target: String?, current: String?, showing: Bool = true, text: String? = "t") -> TranslationState {
            TranslationState.resolve(translatedText: text, storedTarget: target, showing: showing, currentTarget: current)
        }
        #expect(state("en-US", current: "en-GB") == .translated(showing: true))
        #expect(state("en-US", current: "en-GB", showing: false) == .translated(showing: false))
        #expect(state("en-US", current: "fr-FR") == .none)
        #expect(state("en-US", current: "en-US", text: nil) == .none)
        #expect(state("en-US", current: "en-US", text: "") == .none)
        #expect(state(nil, current: "en-US") == .none)
    }
}

// MARK: - Protecting spans

struct TranslationProtectorTests {
    private func roundTrip(_ text: String) -> (protected: String, tokens: [String], restored: String?) {
        let (p, tokens) = TranslationProtector.protect(text)
        return (p, tokens, TranslationProtector.restore(p, tokens: tokens))
    }

    @Test func inlineCodeIsProtected() {
        let r = roundTrip("Use `git rebase -i` to edit history.")
        #expect(r.tokens == ["`git rebase -i`"])
        #expect(!r.protected.contains("git"))
        #expect(r.restored == "Use `git rebase -i` to edit history.")
    }

    @Test func doubleBacktickCodeKeepsABacktickInside() {
        let r = roundTrip("Write ``a ` b`` here")
        #expect(r.tokens == ["``a ` b``"])
        #expect(r.restored == "Write ``a ` b`` here")
    }

    @Test func urlsAreProtectedWithoutTheSentencePunctuation() {
        let r = roundTrip("See https://example.com/a_(b)?q=1&r=2. Then go on.")
        #expect(r.tokens == ["https://example.com/a_(b)?q=1&r=2"])
        #expect(r.restored == "See https://example.com/a_(b)?q=1&r=2. Then go on.")
    }

    @Test func linkTargetsAreProtectedAndTheLinkTextIsNot() {
        let r = roundTrip("Read [the docs](https://example.com/docs \"Docs\") first.")
        #expect(r.tokens == ["(https://example.com/docs \"Docs\")"])
        #expect(r.protected.contains("[the docs]"))
        #expect(r.restored == "Read [the docs](https://example.com/docs \"Docs\") first.")
    }

    @Test func citationMarkersAreProtectedButNumberedLinkTextIsNot() {
        let r = roundTrip("It is fast [1][2], see [3](https://x.dev).")
        #expect(r.tokens.contains("[1]") && r.tokens.contains("[2]"))
        #expect(!r.tokens.contains("[3]"))
        #expect(r.restored == "It is fast [1][2], see [3](https://x.dev).")
    }

    @Test func footnotesAutolinksAndHTMLAreProtected() {
        let r = roundTrip("Note[^a] <https://a.dev> line<br>break")
        #expect(r.tokens == ["[^a]", "<https://a.dev>", "<br>"])
        #expect(r.restored == "Note[^a] <https://a.dev> line<br>break")
    }

    @Test func nothingToProtectLeavesTheTextAlone() {
        let r = roundTrip("Plain words only.")
        #expect(r.protected == "Plain words only." && r.tokens.isEmpty && r.restored == "Plain words only.")
    }

    @Test func placeholdersComeBackEvenWithSpacesInside() {
        let (_, tokens) = TranslationProtector.protect("`a` and `b`")
        #expect(TranslationProtector.restore("\u{27E6} 1 \u{27E7} et \u{27E6}0\u{27E7}", tokens: tokens) == "`b` et `a`")
    }

    @Test func aLinkTargetThatLostItsPlaceTightnessIsPulledBackToItsText() {
        let (p, tokens) = TranslationProtector.protect("[docs](https://x.dev)")
        #expect(p == "[docs]\(TranslationProtector.token(0))")
        #expect(TranslationProtector.restore("[docs] \(TranslationProtector.token(0))", tokens: tokens) == "[docs](https://x.dev)")
    }

    @Test func aMissingOrRepeatedPlaceholderCannotBeRestored() {
        let (_, tokens) = TranslationProtector.protect("`a` and `b`")
        #expect(TranslationProtector.restore("only \(TranslationProtector.token(0))", tokens: tokens) == nil)
        #expect(TranslationProtector.restore("\(TranslationProtector.token(0)) \(TranslationProtector.token(0)) \(TranslationProtector.token(1))", tokens: tokens) == nil)
        #expect(TranslationProtector.restore("\(TranslationProtector.token(0)) \(TranslationProtector.token(7))", tokens: tokens) == nil)
    }
}

// MARK: - Plan and assembly

struct TranslationPlanTests {
    /// Marks every block so it is visible what was translated and what was not.
    private func fake(_ plan: TranslationPlan) -> [String] { plan.requests.map { "«" + $0 + "»" } }

    private func translate(_ markdown: String) -> (requests: [String], output: String) {
        let plan = TranslationPlan(markdown: markdown)
        return (plan.requests, plan.assemble(fake(plan)))
    }

    @Test func fencedCodeIsNeverSent() {
        let md = "Run this:\n\n```bash\necho \"hello world from the shell\"\n```\n\nThen wait."
        let r = translate(md)
        #expect(r.requests == ["Run this:", "Then wait."])
        #expect(r.output == "«Run this:»\n\n```bash\necho \"hello world from the shell\"\n```\n\n«Then wait.»")
    }

    @Test func aFenceIsClosedOnlyByTheSameKindAndLength() {
        let md = "Intro text here\n\n````md\n```\ninner words that are not prose\n```\n````\n\nAfter the fence"
        #expect(TranslationPlan(markdown: md).requests == ["Intro text here", "After the fence"])
        let tilde = "~~~\nsome ``` words\n~~~\nafter fence words"
        #expect(TranslationPlan(markdown: tilde).requests == ["after fence words"])
    }

    @Test func anUnclosedFenceKeepsTheRestAsCode() {
        #expect(TranslationPlan(markdown: "Before words\n```\nthe rest of the text").requests == ["Before words"])
    }

    @Test func inlineCodeAndCitationsAreSentAsPlaceholders() {
        let plan = TranslationPlan(markdown: "Call `fetch()` before parsing [1].")
        #expect(plan.requests == ["Call \(TranslationProtector.token(0)) before parsing \(TranslationProtector.token(1))."])
        #expect(plan.assemble(plan.requests) == "Call `fetch()` before parsing [1].")
    }

    @Test func urlsNeverReachTheTranslator() {
        let plan = TranslationPlan(markdown: "Visit https://example.com/path?x=1 for details.")
        #expect(!plan.requests[0].contains("example.com"))
    }

    @Test func headingsListsQuotesAndTasksKeepTheirMarkers() {
        let md = "# Title words\n- first item here\n  * nested item here\n3. third item here\n> quoted words here\n- [x] done task here"
        let r = translate(md)
        #expect(r.requests == ["Title words", "first item here", "nested item here", "third item here", "quoted words here", "done task here"])
        #expect(r.output == "# «Title words»\n- «first item here»\n  * «nested item here»\n3. «third item here»\n> «quoted words here»\n- [x] «done task here»")
    }

    @Test func linesOfOneParagraphAreOneBlock() {
        let r = translate("first line of text\nsecond line of text\n\nnew paragraph here")
        #expect(r.requests == ["first line of text\nsecond line of text", "new paragraph here"])
        #expect(r.output == "«first line of text\nsecond line of text»\n\n«new paragraph here»")
    }

    @Test func aQuotedParagraphKeepsItsPrefixOnEveryLine() {
        let plan = TranslationPlan(markdown: "> first quoted line\n> second quoted line")
        #expect(plan.requests == ["first quoted line\nsecond quoted line"])
        #expect(plan.assemble(["uno\ndos"]) == "> uno\n> dos")
    }

    @Test func tableCellsAreTranslatedOneByOneAndThePipesStay() {
        let md = "| Name | Value |\n| --- | :-: |\n| Speed | `fast` |\n| 12 | 3.5 |"
        let r = translate(md)
        #expect(r.requests == ["Name", "Value", "Speed"])
        #expect(r.output == "| «Name» | «Value» |\n| --- | :-: |\n| «Speed» | `fast` |\n| 12 | 3.5 |")
    }

    @Test func rulesAndBlockWithNoLettersAreKept() {
        let md = "Words here\n\n---\n\n[1][2]\n\n42"
        let r = translate(md)
        #expect(r.requests == ["Words here"])
        #expect(r.output == "«Words here»\n\n---\n\n[1][2]\n\n42")
    }

    @Test func anEmptyAnswerOrOneOfOnlyCodeHasNothingToSend() {
        #expect(TranslationPlan(markdown: "").sources.isEmpty)
        #expect(TranslationPlan(markdown: "```\ncode words only\n```").sources.isEmpty)
    }

    @Test func assemblingWithUntouchedTextGivesBackTheOriginal() {
        let md = """
        # Heading words

        Some **bold** words with `code` and a [link](https://a.dev/x) [1].

        - one item here
        - two items here
          continuation words here

        > quote words here
        > more quote words

        | A | B |
        |---|---|
        | cell words | x |

        ```swift
        let a = 1
        ```

        Last words here.
        """
        for ending in ["", "\n", "\n\n"] {
            let plan = TranslationPlan(markdown: md + ending)
            #expect(plan.assemble(plan.requests) == md + ending)
        }
    }

    @Test func aBlockWhoseTranslationLostAPlaceholderKeepsItsOriginalText() {
        let plan = TranslationPlan(markdown: "Use `fetch()` here.\n\nPlain second paragraph.")
        let out = plan.assemble(["Utilisez ici.", "Deuxième paragraphe."])
        #expect(out == "Use `fetch()` here.\n\nDeuxième paragraphe.")
        #expect(plan.untrusted(["Utilisez ici.", "Deuxième paragraphe."]) == 1)
    }

    @Test func anEmptyTranslationKeepsTheOriginal() {
        let plan = TranslationPlan(markdown: "Some words here.")
        #expect(plan.assemble(["  "]) == "Some words here.")
    }

    @Test func whitespaceAtTheEndsOfABlockIsKept() {
        let plan = TranslationPlan(markdown: "Words here  \nnext paragraph")
        // The two trailing spaces of the first line end a paragraph of two lines: they stay inside the joined block.
        #expect(plan.assemble(plan.requests) == "Words here  \nnext paragraph")
    }
}

// MARK: - Running

struct TranslationRunnerTests {
    struct Upper: TextTranslating {
        func translate(_ texts: [String]) async throws -> [String] { texts.map { $0.uppercased() } }
    }
    struct Short: TextTranslating {
        func translate(_ texts: [String]) async throws -> [String] { Array(texts.dropLast()) }
    }

    @Test func codeAndCitationsComeThroughTranslationUntouched() async throws {
        let md = "Call `fetchData()` first [1].\n\n```swift\nlet value = await fetchData()\n```\n\nSee [docs](https://example.com/Docs)."
        let out = try await TranslationRunner.translate(md, with: Upper())
        // The fake upper-cases everything it sees; protected spans and code were not shown to it.
        #expect(out == "CALL `fetchData()` FIRST [1].\n\n```swift\nlet value = await fetchData()\n```\n\nSEE [DOCS](https://example.com/Docs).")
    }

    @Test func aTranslatorThatReturnsTheWrongCountFails() async {
        await #expect(throws: TranslationFailure.countMismatch) {
            _ = try await TranslationRunner.translate("One block.\n\nTwo block.", with: Short())
        }
    }

    @Test func nothingToTranslateReturnsTheTextWithoutCallingTheTranslator() async throws {
        struct Boom: TextTranslating { func translate(_ texts: [String]) async throws -> [String] { throw TranslationFailure.unavailable } }
        let md = "```\nonly code here\n```"
        #expect(try await TranslationRunner.translate(md, with: Boom()) == md)
    }
}

// MARK: - Service, persistence and the API history

@MainActor
struct TranslationServiceTests {
    nonisolated(unsafe) private static var containers: [ModelContainer] = []

    struct Fixed: TextTranslating {
        var prefix = "[en] "
        func translate(_ texts: [String]) async throws -> [String] { texts.map { prefix + $0 } }
    }

    private func rig() throws -> (ModelContext, Conversation) {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self, CompactionRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.containers.append(container)
        let context = container.mainContext
        let c = Conversation(connectionID: nil, modelID: "m")
        context.insert(c)
        return (context, c)
    }

    @discardableResult
    private func add(_ c: Conversation, _ context: ModelContext, _ role: MessageRole, _ text: String) -> Message {
        let m = Message(role: role, text: text, sortIndex: (c.messages.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(m)
        c.attach(m, parent: c.leafMessage)
        return m
    }

    private let korean = "오늘은 날씨가 정말 좋아서 공원에서 산책을 하고 점심을 먹었습니다. 저녁에는 친구들과 영화를 볼 예정입니다."

    private func service(installed: Bool = true, target: String = "en-US") -> TranslationService {
        let s = TranslationService()
        s.preferredLanguage = { target }
        s.availability = { _, _ in installed ? .installed : .unsupported }
        s.installedTranslator = { _, _ in Fixed() }
        return s
    }

    private func settle(_ s: TranslationService, _ m: Message) async {
        for _ in 0..<200 where s.translating.contains(m.id) || m.translatedText == nil && s.errors[m.id] == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func translatingStoresTheTextTheTargetAndShowsIt() async throws {
        let (context, c) = try rig()
        add(c, context, .user, "질문")
        let m = add(c, context, .assistant, korean)
        let s = service()
        #expect(s.ui(for: m, isStreaming: false).offered)
        s.translate(m, context: context)
        await settle(s, m)
        #expect(m.translatedText == "[en] " + korean)
        #expect(m.translationTarget == "en-US")
        #expect(m.showingTranslation)
        let ui = s.ui(for: m, isStreaming: false)
        #expect(ui.hasTranslation && ui.showing && ui.translatedText == m.translatedText && !ui.isTranslating)
    }

    @Test func theTranslationSurvivesAReload() async throws {
        let (context, c) = try rig()
        let m = add(c, context, .assistant, korean)
        let s = service()
        s.translate(m, context: context)
        await settle(s, m)
        s.toggle(m, context: context) // back to the original
        let container = context.container
        let fresh = ModelContext(container)
        let loaded = try #require(try fresh.fetch(FetchDescriptor<Message>()).first { $0.id == m.id })
        #expect(loaded.translatedText == "[en] " + korean)
        #expect(loaded.translationTarget == "en-US")
        #expect(!loaded.showingTranslation)
        #expect(loaded.text == korean)
    }

    @Test func aMessageWithoutATranslationLoadsWithDefaults() throws {
        let (context, c) = try rig()
        let m = add(c, context, .assistant, "hi")
        try context.save()
        #expect(m.translatedText == nil && m.translationTarget == nil && !m.showingTranslation)
    }

    @Test func theToggleFlipsBetweenOriginalAndTranslation() async throws {
        let (context, c) = try rig()
        let m = add(c, context, .assistant, korean)
        let s = service()
        s.translate(m, context: context)
        await settle(s, m)
        s.toggle(m, context: context)
        #expect(!s.ui(for: m, isStreaming: false).showing)
        s.translate(m, context: context) // already translated: shows it again, translates nothing
        #expect(m.showingTranslation && m.translatedText == "[en] " + korean)
    }

    @Test func theAPIHistoryNeverSeesTheTranslation() async throws {
        let (context, c) = try rig()
        let q = add(c, context, .user, "질문입니다")
        let a = add(c, context, .assistant, korean)
        let before = MessageAssembler.apiMessages(from: c.activePath.map(\.historyMessage), systemPrompt: "sys")
        let s = service()
        s.translate(a, context: context)
        await settle(s, a)
        let after = MessageAssembler.apiMessages(from: c.activePath.map(\.historyMessage), systemPrompt: "sys")
        #expect(before == after)
        let body = String(decoding: try ChatRequest(model: "m", messages: after).encoded(), as: UTF8.self)
        #expect(body.contains(korean) && !body.contains("[en]"))
        #expect(q.historyMessage.text == "질문입니다" && a.historyMessage.text == korean)
        #expect(c.transcript.contains(korean) && !c.transcript.contains("[en]"))
    }

    @Test func onlyAnswersInAnotherLanguageAreOffered() throws {
        let (context, c) = try rig()
        let english = add(c, context, .assistant, "The weather was lovely today, so I walked around the park and had lunch outside.")
        let ko = add(c, context, .assistant, korean)
        let user = add(c, context, .user, korean)
        let s = service()
        #expect(!s.ui(for: english, isStreaming: false).offered)
        #expect(s.ui(for: ko, isStreaming: false).offered)
        #expect(!s.ui(for: user, isStreaming: false).offered)
        #expect(!s.ui(for: ko, isStreaming: true).offered) // not while it is being written
        ko.errorText = "boom"
        #expect(!s.ui(for: ko, isStreaming: false).offered)
    }

    @Test func aTranslationForAnotherReaderLanguageIsNotShown() async throws {
        let (context, c) = try rig()
        let m = add(c, context, .assistant, korean)
        let s = service()
        s.translate(m, context: context)
        await settle(s, m)
        s.preferredLanguage = { "fr-FR" }
        let ui = s.ui(for: m, isStreaming: false)
        #expect(ui.offered && !ui.hasTranslation && ui.translatedText == nil)
    }

    @Test func anUnsupportedPairReportsAnErrorAndStoresNothing() async throws {
        let (context, c) = try rig()
        let m = add(c, context, .assistant, korean)
        let s = service(installed: false)
        s.translate(m, context: context)
        await settle(s, m)
        #expect(m.translatedText == nil)
        #expect(s.errors[m.id] != nil)
        #expect(s.ui(for: m, isStreaming: false).error != nil)
    }

    @Test func aLanguageThatNeedsDownloadingWaitsForTheViewsSession() async throws {
        let (context, c) = try rig()
        let m = add(c, context, .assistant, korean)
        let s = service()
        s.availability = { _, _ in .needsDownload }
        s.translate(m, context: context)
        for _ in 0..<200 where s.configuration == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(s.configuration != nil)
        #expect(s.translating.contains(m.id))
        #expect(m.translatedText == nil)
    }
}
