import Foundation
import Observation

/// What the engine reports while it listens.
enum DictationEvent: Sendable, Equatable {
    /// The tentative tail of the transcript; replaces the previous one.
    case volatile(String)
    /// A settled piece of the transcript, appended to what came before. Clears the tentative tail.
    case finalized(String)
    /// The input level, 0...1.
    case level(Float)
    /// A recording engine stopped the microphone on its own (its length limit). The recording waits for confirm,
    /// which sends it, or cancel, which drops it; the stream stays open until then.
    case captureEnded
}

enum DictationAuthorization: Sendable, Equatable {
    case authorized
    case microphoneDenied
    case speechDenied
}

enum DictationError: Error, Sendable, Equatable {
    /// Neither on-device recognizer handles the language.
    case unsupportedLocale
    /// The on-device model could not be downloaded or installed.
    case assetUnavailable
    /// There is no audio input.
    case microphoneUnavailable
    /// The selected engine needs settings it doesn't have (an API engine without a connection or model).
    case notConfigured
    /// The transcription service could not be reached.
    case network
    /// The transcription service did not answer in time.
    case timedOut
    /// The transcription service refused the API key (401 / 403).
    case unauthorized
    /// The recording is over what the transcription service takes.
    case tooLong
    /// The transcription service answered with an error; the detail is short and meant for the user.
    case service(String)
    case failed(String)
}

/// The speech side of dictation, behind a protocol so `DictationController` can be tested with a fake and so engines
/// can be swapped (`DictationEngineKind`, picked in Settings, resolved by `ConfiguredDictationEngine`).
///
/// Two shapes fit: a live engine streams `.volatile` / `.finalized` text while it listens (Apple on-device); a
/// recording engine only sends `.level` while it listens and the whole text at `finish()` (an upload to a
/// transcription API). The latter says so with `transcribesOnFinish`, so the controller waits longer for `finish()`
/// and shows its errors instead of keeping the (empty) words heard so far.
@MainActor
protocol DictationEngine: AnyObject {
    /// The text comes at `finish()`, not while listening. Read after `start`.
    var transcribesOnFinish: Bool { get }
    /// Asks for (or reads) microphone and speech recognition permission.
    func authorize() async -> DictationAuthorization
    /// True when the on-device model for `locale` has to be downloaded first.
    func needsPreparation(for locale: Locale) async -> Bool
    /// Downloads and installs what `locale` needs.
    func prepare(for locale: Locale) async throws
    /// Starts listening. The stream ends after `finish()` once the last results are in, or with an error.
    func start(locale: Locale) async throws -> AsyncThrowingStream<DictationEvent, Error>
    /// Stops the audio and lets the recognizer settle what it heard; the stream then ends.
    func finish() async
    /// Stops at once; no more events.
    func cancel()
    /// Stops the microphone but keeps what was recorded for `finish()` (the app is going to the background). Only a
    /// recording engine has something to keep.
    func stopCapture()
}

extension DictationEngine {
    var transcribesOnFinish: Bool { false }
    func stopCapture() {}
}

/// The dictation state machine behind the composer's microphone: permission, model download, listening with a live
/// transcript and input level, then confirm (the text goes into the field) or cancel (it is dropped).
@MainActor
@Observable
final class DictationController {
    enum Failure: Equatable, Sendable {
        case microphoneDenied
        case speechDenied
        case unsupportedLocale
        case assetUnavailable
        case microphoneUnavailable
        case notConfigured
        case network
        case timedOut
        case unauthorized
        case tooLong
        case service(String)
        case failed

        /// The failure is fixed in Settings, so the message offers a way there.
        var opensSettings: Bool { self == .microphoneDenied || self == .speechDenied }
    }

    enum Phase: Equatable, Sendable {
        case idle
        /// Asking for permission and starting the recognizer.
        case starting
        /// Downloading the on-device model for the language.
        case preparing
        case listening
        /// The audio ended on its own; the transcript waits for confirm or cancel.
        case stopped
        /// Confirm was tapped; the recognizer settles the last words (or a recording engine transcribes).
        case finishing
        case failed(Failure)
    }

    static let barCount = 7

    private(set) var phase: Phase = .idle
    /// Settled text, and the tentative tail after it.
    private(set) var finalized = ""
    private(set) var volatile = ""
    /// The last few input levels, oldest first, for the waveform.
    private(set) var levels: [Float] = Array(repeating: 0, count: DictationController.barCount)
    private(set) var startedAt: Date?
    /// When listening ended (stopped on its own), so the elapsed time stops too.
    private(set) var endedAt: Date?
    /// Started from the expanded composer: the dictation appends to the text there, shown inline in the accent color.
    private(set) var isExpandedStyle = false

    /// The language listened for: Settings > Dictation language, read at each start so a change applies at once.
    var locale: Locale { fixedLocale ?? DictationLanguage.current }
    @ObservationIgnored private let fixedLocale: Locale?
    @ObservationIgnored private let engine: DictationEngine
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var session: Task<Void, Never>?
    /// Bumped on every start and stop; a session that sees a different number has been abandoned.
    @ObservationIgnored private var generation = 0
    /// Longest wait for the recognizer to settle after confirm.
    @ObservationIgnored var finishTimeout: Duration = .seconds(3)
    /// Longest wait for an engine that transcribes on finish (an upload, then the service's work).
    @ObservationIgnored var transcriptionTimeout: Duration = .seconds(90)

    init(engine: DictationEngine, locale: Locale? = nil, now: @escaping () -> Date = Date.init) {
        self.engine = engine
        self.fixedLocale = locale
        self.now = now
    }


    /// The whole transcript so far.
    var transcript: String { Self.join(finalized, volatile, separator: separator) }

    /// Dictation is on screen (listening, getting ready, or showing a failure).
    var isActive: Bool { phase != .idle }
    var isListening: Bool { phase == .listening }
    /// Confirm was tapped and the recording is being transcribed: "Transcribing…" rather than "Listening…".
    var isTranscribing: Bool { phase == .finishing && engine.transcribesOnFinish }
    /// The live row (waveform, transcript, time, confirm) rather than a status line.
    var showsTranscript: Bool {
        switch phase {
        case .starting, .listening, .stopped, .finishing: true
        case .idle, .preparing, .failed: false
        }
    }
    /// There may be words to insert.
    var canConfirm: Bool { phase == .listening || phase == .stopped }
    var failure: Failure? {
        if case .failed(let f) = phase { return f }
        return nil
    }

    // MARK: Actions

    /// Starts dictating. `expanded`: from the two-row composer, where the words are appended to the text there.
    func start(expanded: Bool) {
        switch phase {
        case .idle, .failed: break
        default: return
        }
        reset()
        isExpandedStyle = expanded
        phase = .starting
        generation += 1
        let current = generation
        session = Task { [weak self] in await self?.run(current) }
    }

    /// Stops listening, waits briefly for the last words, and returns the transcript (possibly empty). Back to idle.
    func confirm() async -> String {
        switch phase {
        case .listening:
            if let abandoned = await settle() { return abandoned }
        case .stopped where engine.transcribesOnFinish:
            // A recording kept when the microphone stopped (the length limit, the app in the background) is sent now.
            if let abandoned = await settle() { return abandoned }
        case .stopped:
            break
        case .finishing: // a second tap; the first one inserts the words
            return ""
        default: // nothing heard yet
            cancel()
            return ""
        }
        let text = transcript
        stopSession()
        return text
    }

    /// Has the engine settle (or transcribe) what it heard. Nil when the transcript is ready; else what confirm returns.
    private func settle() async -> String? {
        phase = .finishing
        let session = self.session
        let current = generation
        // The timeout covers the engine's own finishing too: a recognizer that never settles can't hold the
        // composer in "finishing" for good.
        let transcribes = engine.transcribesOnFinish
        let settled = await finish(within: transcribes ? transcriptionTimeout : finishTimeout, session: session)
        // Cancelled meanwhile, failed, or a new dictation started: its words and session are not this confirm's.
        guard current == generation else { return "" }
        // A transcription that never came has no words to fall back on: say so rather than insert nothing.
        if !settled && transcribes {
            engine.cancel()
            fail(.timedOut)
            return ""
        }
        return nil
    }

    /// Drops what was heard. Back to idle.
    func cancel() {
        guard phase != .idle else { return }
        stopSession()
    }

    /// Stops at once (the app is going to the background) and returns what was heard so far. A recording engine has no
    /// words yet: its microphone stops and the recording waits for confirm or cancel; a transcription already asked for
    /// goes on.
    func stopKeepingText() -> String {
        guard phase != .idle else { return "" }
        if engine.transcribesOnFinish {
            switch phase {
            case .listening:
                engine.stopCapture()
                markStopped()
                return ""
            case .stopped, .finishing:
                return ""
            default:
                break
            }
        }
        let text = transcript
        stopSession()
        return text
    }

    func dismissFailure() {
        if failure != nil { phase = .idle }
    }

    // MARK: Text

    /// Words are joined with a space, except in languages written without one.
    var separator: String {
        switch locale.language.languageCode?.identifier {
        case "ja", "zh", "th", "lo", "km", "my", "yue": ""
        default: " "
        }
    }

    /// `text` with the transcript added after it: a space between them unless either side already has one.
    func merge(_ transcript: String, into text: String) -> String {
        Self.join(text, transcript, separator: separator)
    }

    /// The separator `merge` would put between `text` and the transcript, for showing them apart.
    func separator(after text: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return "" }
        return separator
    }

    nonisolated static func join(_ a: String, _ b: String, separator: String) -> String {
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return a }
        guard let last = a.last else { return b }
        return last.isWhitespace ? a + b : a + separator + b
    }

    // MARK: Session

    private func run(_ current: Int) async {
        let authorization = await engine.authorize()
        guard current == generation else { return }
        switch authorization {
        case .authorized: break
        case .microphoneDenied: fail(.microphoneDenied); return
        case .speechDenied: fail(.speechDenied); return
        }
        do {
            if await engine.needsPreparation(for: locale) {
                guard current == generation else { return }
                phase = .preparing
                try await engine.prepare(for: locale)
            }
            guard current == generation else { return }
            let stream = try await engine.start(locale: locale)
            guard current == generation else { engine.cancel(); return }
            phase = .listening
            startedAt = now()
            for try await event in stream {
                guard current == generation else { return }
                apply(event)
            }
            guard current == generation else { return }
            if phase == .listening { // the audio ended without a confirm
                markStopped()
                engine.cancel() // the recognizer is done: stop the microphone too (the transcript stays here)
            }
        } catch {
            guard current == generation else { return }
            engine.cancel()
            // A live engine's words so far are kept; confirm takes them. A recording engine has none: the error shows.
            if phase == .finishing && !engine.transcribesOnFinish { return }
            fail(Self.failure(for: error))
        }
    }

    private func apply(_ event: DictationEvent) {
        switch event {
        case .volatile(let text):
            volatile = text
        case .finalized(let text):
            finalized = Self.join(finalized, text, separator: separator)
            volatile = ""
        case .level(let level):
            levels.removeFirst()
            levels.append(min(1, max(0, level)))
        case .captureEnded:
            if phase == .listening { markStopped() }
        }
    }

    private func markStopped() {
        phase = .stopped
        endedAt = now()
        levels = Array(repeating: 0, count: Self.barCount)
    }

    private func fail(_ failure: Failure) {
        generation += 1
        session = nil
        reset()
        phase = .failed(failure)
    }

    private func stopSession() {
        generation += 1
        session?.cancel()
        session = nil
        engine.cancel()
        reset()
        phase = .idle
    }

    private func reset() {
        finalized = ""
        volatile = ""
        levels = Array(repeating: 0, count: Self.barCount)
        startedAt = nil
        endedAt = nil
    }

    static func failure(for error: Error) -> Failure {
        switch error as? DictationError {
        case .unsupportedLocale: .unsupportedLocale
        case .assetUnavailable: .assetUnavailable
        case .microphoneUnavailable: .microphoneUnavailable
        case .notConfigured: .notConfigured
        case .network: .network
        case .timedOut: .timedOut
        case .unauthorized: .unauthorized
        case .tooLong: .tooLong
        case .service(let detail): .service(detail)
        default: .failed
        }
    }

    private final class Once { var done = false }

    /// `engine.finish()` and the session's last results, or `timeout`, whichever comes first. False on the timeout.
    private func finish(within timeout: Duration, session: Task<Void, Never>?) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            Task { @MainActor in
                await self.engine.finish()
                await session?.value
                if !once.done { once.done = true; continuation.resume(returning: true) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !once.done else { return }
                session?.cancel()
                once.done = true
                continuation.resume(returning: false)
            }
        }
    }
}

/// Settings > Dictation language: one fixed language, since the recognizer can't tell which one is spoken.
enum DictationLanguage {
    nonisolated static let defaultsKey = "dictationLanguage"

    /// The device's preferred languages plus Korean and English, one entry per language, as locale identifiers.
    static func options(preferred: [String] = Locale.preferredLanguages) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in preferred + ["ko-KR", "en-US"] {
            guard let code = Locale(identifier: id).language.languageCode?.identifier, seen.insert(code).inserted else { continue }
            out.append(id)
        }
        return out
    }

    /// Korean when the device lists it (the app is English, so the phone often is too, while the user speaks Korean),
    /// else the first preferred language. Not `Locale.current`, which the English-only app reports as English.
    static func defaultID(preferred: [String] = Locale.preferredLanguages) -> String {
        let all = options(preferred: preferred)
        return all.first { Locale(identifier: $0).language.languageCode?.identifier == "ko" && preferred.contains($0) } ?? all[0]
    }

    static var current: Locale {
        Locale(identifier: UserDefaults.standard.string(forKey: defaultsKey) ?? defaultID())
    }

    /// The language's name in itself: "한국어", "English".
    static func name(_ id: String) -> String {
        let locale = Locale(identifier: id)
        guard let code = locale.language.languageCode?.identifier,
              let name = locale.localizedString(forLanguageCode: code) else { return id }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
