import Testing
import Foundation
@testable import Strata

/// A scripted engine: the test pushes events into the stream it handed out.
@MainActor
final class FakeDictationEngine: DictationEngine {
    var authorization: DictationAuthorization = .authorized
    var needsModel = false
    var prepareError: DictationError?
    var startError: DictationError?
    /// Sent when `finish()` is called, before the stream ends.
    var onFinish: [DictationEvent] = []
    /// `finish()` leaves the stream open (a recognizer that never settles).
    var hangsOnFinish = false
    /// `prepare` waits until the test lets it go.
    var holdPrepare = false

    private(set) var prepared = false
    private(set) var started = 0
    private(set) var finished = 0
    private(set) var cancelled = 0
    private var continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation?
    private var prepareGate: CheckedContinuation<Void, Never>?

    func authorize() async -> DictationAuthorization { authorization }

    func needsPreparation(for locale: Locale) async -> Bool { needsModel && !prepared }

    func prepare(for locale: Locale) async throws {
        if holdPrepare { await withCheckedContinuation { prepareGate = $0 } }
        if let prepareError { throw prepareError }
        prepared = true
    }

    func releasePrepare() {
        prepareGate?.resume()
        prepareGate = nil
    }

    func start(locale: Locale) async throws -> AsyncThrowingStream<DictationEvent, Error> {
        if let startError { throw startError }
        started += 1
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DictationEvent.self)
        self.continuation = continuation
        return stream
    }

    func send(_ events: DictationEvent...) {
        for e in events { continuation?.yield(e) }
    }

    func endStream(throwing error: Error? = nil) {
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }

    func finish() async {
        finished += 1
        for e in onFinish { continuation?.yield(e) }
        if !hangsOnFinish { continuation?.finish() }
    }

    func cancel() {
        cancelled += 1
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
struct DictationControllerTests {
    let engine = FakeDictationEngine()

    func controller(locale: String = "en_US") -> DictationController {
        DictationController(engine: engine, locale: Locale(identifier: locale))
    }

    /// Lets the controller's session task run until `condition` holds.
    func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition())
    }

    @Test func startsListening() async {
        let c = controller()
        #expect(c.phase == .idle && !c.isActive)
        c.start(expanded: false)
        #expect(c.phase == .starting)
        #expect(c.isActive && c.showsTranscript && !c.isExpandedStyle)
        await until { c.phase == .listening }
        #expect(engine.started == 1)
        #expect(c.startedAt != nil)
        #expect(c.canConfirm)
    }

    @Test func showsLivePartialsAndLevels() async {
        let c = controller()
        c.start(expanded: false)
        await until { c.isListening }
        engine.send(.volatile("hello"))
        await until { c.transcript == "hello" }
        engine.send(.volatile("hello wor"))
        await until { c.transcript == "hello wor" }
        engine.send(.finalized("Hello world."), .volatile("how are"))
        await until { c.transcript == "Hello world. how are" }
        #expect(c.finalized == "Hello world.")
        #expect(c.volatile == "how are")
        engine.send(.level(0.5), .level(2))
        await until { c.levels.suffix(2) == [0.5, 1] } // clamped
        #expect(c.levels.count == DictationController.barCount)
    }

    @Test func confirmReturnsTheSettledWordsAndGoesIdle() async {
        let c = controller()
        c.start(expanded: false)
        await until { c.isListening }
        engine.send(.finalized("Summarize the"), .volatile("tread"))
        await until { c.volatile == "tread" }
        engine.onFinish = [.finalized("thread for me")]
        let words = await c.confirm()
        #expect(words == "Summarize the thread for me")
        #expect(engine.finished == 1)
        #expect(c.phase == .idle)
        #expect(c.transcript.isEmpty)
        #expect(c.merge(words, into: "") == "Summarize the thread for me") // an empty field gets the words as they are
    }

    @Test func confirmGivesUpOnARecognizerThatNeverSettles() async {
        let c = controller()
        c.finishTimeout = .milliseconds(50)
        engine.hangsOnFinish = true
        c.start(expanded: false)
        await until { c.isListening }
        engine.send(.volatile("still here"))
        await until { c.transcript == "still here" }
        let words = await c.confirm()
        #expect(words == "still here")
        #expect(c.phase == .idle)
        #expect(engine.cancelled >= 1)
    }

    @Test func cancelDiscards() async {
        let c = controller()
        c.start(expanded: false)
        await until { c.isListening }
        engine.send(.finalized("never mind"))
        await until { !c.finalized.isEmpty }
        c.cancel()
        #expect(c.phase == .idle)
        #expect(c.transcript.isEmpty)
        #expect(engine.cancelled == 1)
        #expect(engine.finished == 0)
        // Late events from the cancelled session change nothing.
        engine.send(.finalized("late"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(c.transcript.isEmpty)
    }

    @Test func confirmBeforeListeningInsertsNothing() async {
        engine.holdPrepare = true
        engine.needsModel = true
        let c = controller()
        c.start(expanded: false)
        await until { c.phase == .preparing }
        #expect(await c.confirm() == "")
        #expect(c.phase == .idle)
        engine.releasePrepare()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(c.phase == .idle) // the abandoned session does not come back
        #expect(engine.started == 0)
    }

    @Test func appendModeAddsToTheExistingText() async {
        let c = controller()
        c.start(expanded: true)
        #expect(c.isExpandedStyle)
        await until { c.isListening }
        let draft = "Why did the protest"
        #expect(c.separator(after: draft) == " ")
        #expect(c.separator(after: "Ends with a space ") == "")
        engine.send(.finalized("happen?"))
        await until { c.transcript == "happen?" }
        let words = await c.confirm()
        #expect(c.merge(words, into: draft) == "Why did the protest happen?")
        #expect(c.merge(words, into: "Line one\n") == "Line one\nhappen?")
        #expect(c.merge("", into: draft) == draft)
    }

    @Test func languagesWithoutSpacesJoinWithout() {
        let c = controller(locale: "ja_JP")
        #expect(c.separator == "")
        #expect(c.merge("です", into: "これは") == "これはです")
        #expect(controller(locale: "ko_KR").separator == " ")
    }

    @Test func microphoneDenied() async {
        engine.authorization = .microphoneDenied
        let c = controller()
        c.start(expanded: false)
        await until { c.failure != nil }
        #expect(c.phase == .failed(.microphoneDenied))
        #expect(c.failure?.opensSettings == true)
        #expect(!c.showsTranscript)
        #expect(engine.started == 0)
        c.dismissFailure()
        #expect(c.phase == .idle)
    }

    @Test func speechDenied() async {
        engine.authorization = .speechDenied
        let c = controller()
        c.start(expanded: true)
        await until { c.failure != nil }
        #expect(c.phase == .failed(.speechDenied))
        // Trying again after allowing it in Settings works.
        engine.authorization = .authorized
        c.start(expanded: true)
        await until { c.isListening }
    }

    @Test func downloadsTheModelFirst() async {
        engine.needsModel = true
        engine.holdPrepare = true
        let c = controller()
        c.start(expanded: false)
        await until { c.phase == .preparing }
        #expect(!c.showsTranscript && !c.canConfirm)
        engine.releasePrepare()
        await until { c.isListening }
        #expect(engine.prepared)
    }

    @Test func modelDownloadFailure() async {
        engine.needsModel = true
        engine.prepareError = .assetUnavailable
        let c = controller()
        c.start(expanded: false)
        await until { c.failure != nil }
        #expect(c.phase == .failed(.assetUnavailable))
        #expect(c.failure?.opensSettings == false)
    }

    @Test func unsupportedLanguageAndStartErrors() async {
        engine.startError = .unsupportedLocale
        let c = controller()
        c.start(expanded: false)
        await until { c.failure != nil }
        #expect(c.phase == .failed(.unsupportedLocale))

        engine.startError = .microphoneUnavailable
        c.start(expanded: false)
        await until { c.failure == .microphoneUnavailable }
    }

    @Test func recognizerErrorWhileListening() async {
        let c = controller()
        c.start(expanded: false)
        await until { c.isListening }
        engine.send(.volatile("half a sen"))
        engine.endStream(throwing: NSError(domain: "test", code: 1))
        await until { c.failure != nil }
        #expect(c.phase == .failed(.failed))
        #expect(c.transcript.isEmpty)
        #expect(engine.cancelled >= 1)
    }

    @Test func audioEndingOnItsOwnKeepsTheWordsForConfirm() async {
        let c = controller()
        c.start(expanded: false)
        await until { c.isListening }
        engine.send(.finalized("Long pause after this"))
        engine.endStream()
        await until { c.phase == .stopped }
        #expect(c.endedAt != nil)
        #expect(c.canConfirm)
        #expect(await c.confirm() == "Long pause after this")
        #expect(engine.finished == 0) // nothing left to finish
    }

    @Test func backgroundingKeepsWhatWasHeard() async {
        let c = controller()
        c.start(expanded: false)
        await until { c.isListening }
        engine.send(.finalized("Keep"), .volatile("this"))
        await until { c.volatile == "this" }
        #expect(c.stopKeepingText() == "Keep this")
        #expect(c.phase == .idle)
        #expect(engine.cancelled == 1)
        #expect(c.stopKeepingText() == "")
    }

    @Test func startWhileActiveIsIgnored() async {
        let c = controller()
        c.start(expanded: false)
        await until { c.isListening }
        c.start(expanded: true)
        #expect(!c.isExpandedStyle)
        #expect(engine.started == 1)
    }

    @Test func secondConfirmTapDoesNotDropTheWords() async {
        let c = controller()
        c.finishTimeout = .milliseconds(100)
        engine.hangsOnFinish = true
        c.start(expanded: false)
        await until { c.isListening }
        engine.send(.finalized("Twice"))
        await until { c.finalized == "Twice" }
        async let first = c.confirm()
        await until { c.phase == .finishing }
        #expect(await c.confirm() == "")
        #expect(await first == "Twice")
    }
}

struct DictationLanguageTests {
    @Test func koreanIsTheDefaultWhenTheDeviceListsIt() {
        #expect(DictationLanguage.defaultID(preferred: ["en-KR", "ko-KR"]) == "ko-KR")
        #expect(DictationLanguage.defaultID(preferred: ["ja-JP", "en-US"]) == "ja-JP")
        #expect(DictationLanguage.defaultID(preferred: ["en-US"]) == "en-US")
    }

    @Test func oneOptionPerLanguageWithKoreanAndEnglishAlwaysOffered() {
        #expect(DictationLanguage.options(preferred: ["en-KR", "ko-KR"]) == ["en-KR", "ko-KR"])
        #expect(DictationLanguage.options(preferred: ["ja-JP", "en-GB", "en-US"]) == ["ja-JP", "en-GB", "ko-KR"])
        #expect(DictationLanguage.name("ko-KR") == "한국어")
        #expect(DictationLanguage.name("en-KR") == "English")
    }
}
