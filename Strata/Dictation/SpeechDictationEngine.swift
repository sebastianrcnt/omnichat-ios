import AVFoundation
import Speech

/// On-device dictation: `SpeechAnalyzer` with a `SpeechTranscriber`, or `SFSpeechRecognizer` restricted to on-device
/// recognition when the transcriber does not cover the language (or this device). Nothing leaves the device.
@MainActor
final class SpeechDictationEngine: DictationEngine {
    private enum Backend {
        case analyzer(Locale)
        case recognizer(Locale)
    }

    /// The running session's teardown. Set by `start`, cleared by `finish` / `cancel`.
    private var session: Session?
    /// The transcriber's model could not be installed; the older recognizer is used instead.
    private var transcriberFailed: Set<String> = []

    // MARK: Permission

    func authorize() async -> DictationAuthorization {
        let microphone: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphone = true
        case .denied: microphone = false
        default: microphone = await AVAudioApplication.requestRecordPermission()
        }
        guard microphone else { return .microphoneDenied }
        return await Self.speechAuthorized() ? .authorized : .speechDenied
    }

    private nonisolated static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        }
    }

    // MARK: Model

    private func backend(for locale: Locale) async -> Backend? {
        if SpeechTranscriber.isAvailable, !transcriberFailed.contains(locale.identifier),
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let status = await AssetInventory.status(forModules: [Self.transcriber(supported)])
            if status != .unsupported { return .analyzer(supported) }
        }
        if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition {
            return .recognizer(locale)
        }
        return nil
    }

    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    func needsPreparation(for locale: Locale) async -> Bool {
        guard case .analyzer(let supported) = await backend(for: locale) else { return false }
        return await AssetInventory.status(forModules: [Self.transcriber(supported)]) != .installed
    }

    func prepare(for locale: Locale) async throws {
        guard case .analyzer(let supported) = await backend(for: locale) else { return }
        let modules: [any SpeechModule] = [Self.transcriber(supported)]
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
            if await AssetInventory.status(forModules: modules) == .installed { return }
        } catch {}
        // No model: the older on-device recognizer, if it knows the language.
        transcriberFailed.insert(locale.identifier)
        if case .recognizer = await backend(for: locale) { return }
        throw DictationError.assetUnavailable
    }

    // MARK: Listening

    func start(locale: Locale) async throws -> AsyncThrowingStream<DictationEvent, Error> {
        cancel()
        guard let backend = await backend(for: locale) else { throw DictationError.unsupportedLocale }
        let (events, continuation) = AsyncThrowingStream.makeStream(of: DictationEvent.self)
        let audio = AudioSessionScope()
        try audio.begin()
        do {
            switch backend {
            case .analyzer(let supported):
                session = try await startAnalyzer(locale: supported, continuation: continuation, audio: audio)
            case .recognizer(let locale):
                session = try startRecognizer(locale: locale, continuation: continuation, audio: audio)
            }
        } catch {
            audio.end()
            throw (error as? DictationError) ?? .failed(error.localizedDescription)
        }
        return events
    }

    private func startAnalyzer(locale: Locale, continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation,
                               audio: AudioSessionScope) async throws -> Session {
        let transcriber = Self.transcriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.unsupportedLocale
        }
        let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: input)

        let results = Task.detached {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    continuation.yield(result.isFinal ? .finalized(text) : .volatile(text))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let capture = AudioCapture()
        do {
            try capture.start(target: format,
                              deliver: { feed.yield(AnalyzerInput(buffer: $0)) },
                              level: { continuation.yield(.level($0)) })
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return Session(
            finish: {
                capture.stop()
                feed.finish()
                audio.end()
                do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { continuation.finish(throwing: error) }
            },
            cancel: {
                capture.stop()
                feed.finish()
                audio.end()
                results.cancel()
                continuation.finish()
                Task { await analyzer.cancelAndFinishNow() }
            })
    }

    private func startRecognizer(locale: Locale, continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation,
                                 audio: AudioSessionScope) throws -> Session {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw DictationError.unsupportedLocale
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let box = RequestBox(request)
        // The recognizer reports the whole transcript every time: tentative until the final one.
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                continuation.yield(result.isFinal ? .finalized(text) : .volatile(text))
                if result.isFinal { continuation.finish() }
            } else if let error {
                continuation.finish(throwing: error)
            }
        }
        let capture = AudioCapture()
        do {
            try capture.start(target: nil, deliver: { box.request.append($0) }, level: { continuation.yield(.level($0)) })
        } catch {
            task.cancel()
            throw error
        }
        return Session(
            finish: {
                capture.stop()
                box.request.endAudio()
                audio.end()
            },
            cancel: {
                capture.stop()
                task.cancel()
                audio.end()
                continuation.finish()
            })
    }

    /// Kept until `cancel`, which the controller always calls afterwards, so a recognizer that never settles is still
    /// torn down.
    func finish() async {
        await session?.finish()
    }

    func cancel() {
        guard let session else { return }
        self.session = nil
        session.cancel()
    }

    private struct Session {
        let finish: @MainActor () async -> Void
        let cancel: @MainActor () -> Void
    }
}

/// The recognition request is filled from the audio thread; it is made for that.
private final class RequestBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
}

/// The audio session, set up for recording only while dictating and put back afterwards (iOS; a Mac has none).
@MainActor
private final class AudioSessionScope {
    #if os(iOS)
    private var saved: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)?
    #endif

    func begin() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        saved = (session.category, session.mode, session.categoryOptions)
        do {
            // Record only: other audio pauses while dictating, as with the keyboard's dictation.
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            end()
            throw DictationError.microphoneUnavailable
        }
        #endif
    }

    func end() {
        #if os(iOS)
        guard let saved else { return }
        self.saved = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(saved.category, mode: saved.mode, options: saved.options)
        #endif
    }
}

/// Microphone input through `AVAudioEngine`: buffers converted to the recognizer's format, plus the input level.
/// The tap runs on the audio thread, so nothing here is tied to the main actor.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var running = false

    func start(target: AVAudioFormat?, deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               level: @escaping @Sendable (Float) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.microphoneUnavailable }
        let processor = TapProcessor(input: format, target: target, deliver: deliver, level: level)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(processor))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationError.microphoneUnavailable
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Made outside any actor, so the block is not assumed to run on one.
    private nonisolated static func tap(_ processor: TapProcessor) -> AVAudioNodeTapBlock {
        { buffer, _ in processor.process(buffer) }
    }
}

private final class TapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let target: AVAudioFormat?
    private let deliver: @Sendable (AVAudioPCMBuffer) -> Void
    private let level: @Sendable (Float) -> Void
    private var lastLevel: UInt64 = 0

    init(input: AVAudioFormat, target: AVAudioFormat?, deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         level: @escaping @Sendable (Float) -> Void) {
        self.target = target
        self.converter = target.flatMap { $0 == input ? nil : AVAudioConverter(from: input, to: $0) }
        self.deliver = deliver
        self.level = level
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        reportLevel(buffer)
        guard let converter, let target else { deliver(buffer); return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status != .error, out.frameLength > 0 { deliver(out) }
    }

    /// About twenty times a second: enough for the waveform, without waking the main actor for every buffer.
    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastLevel > 50_000_000, let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        lastLevel = now
        let samples = data[0]
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        level(Self.normalized(rms: rms))
    }

    /// -50 dB and below is silence, 0 dB is full.
    static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 50) / 50))
    }
}
