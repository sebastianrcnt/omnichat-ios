import AVFoundation

/// Dictation through an OpenAI-compatible transcription API: the microphone is recorded to a small AAC file (16 kHz
/// mono) while the waveform shows the level, and at `finish()` the file goes to `POST /audio/transcriptions`; its
/// text comes back as one `.finalized` event. Nothing is sent before confirm, and a cancel sends nothing.
///
/// A recording that reaches `maxDuration` stops the microphone and waits, shown as stopped: confirm sends it, cancel
/// deletes it unsent. `stopCapture()` (the app going to the background) does the same.
@MainActor
final class APIDictationEngine: DictationEngine {
    let endpoint: TranscriptionEndpoint
    private let session: URLSession
    /// Longest recording; well under the 25 MB upload limit at the file's bit rate.
    var maxDuration: Duration = .seconds(600)
    /// Shorter recordings are dropped without a request (a tap on the microphone and straight on Done).
    static let minimumSeconds = 0.3

    private var recording: Recording?

    init(endpoint: TranscriptionEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    var transcribesOnFinish: Bool { true }

    func authorize() async -> DictationAuthorization {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .authorized
        case .denied: return .microphoneDenied
        default: return await AVAudioApplication.requestRecordPermission() ? .authorized : .microphoneDenied
        }
    }

    func needsPreparation(for locale: Locale) async -> Bool { false }

    func prepare(for locale: Locale) async throws {}

    func start(locale: Locale) async throws -> AsyncThrowingStream<DictationEvent, Error> {
        cancel()
        let (events, continuation) = AsyncThrowingStream.makeStream(of: DictationEvent.self)
        let url = FileManager.default.temporaryDirectory.appending(path: "dictation-\(UUID().uuidString).m4a")
        let writer: AudioFileWriter
        do {
            writer = try AudioFileWriter(url: url)
        } catch {
            throw DictationError.failed(error.localizedDescription)
        }
        let audio = AudioSessionScope()
        try audio.begin()
        let capture = AudioCapture()
        do {
            try capture.start(target: writer.format, deliver: { writer.write($0) }, level: { continuation.yield(.level($0)) })
        } catch {
            audio.end()
            writer.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let recording = Recording(url: url, writer: writer, capture: capture, audio: audio, continuation: continuation,
                                  language: TranscriptionAPI.languageHint(for: locale))
        self.recording = recording
        let limit = maxDuration
        recording.limit = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, self.recording === recording else { return }
            self.hold(recording)
            recording.continuation.yield(.captureEnded)
        }
        return events
    }

    func finish() async {
        guard let recording else { return }
        await transcribe(recording)
    }

    func cancel() {
        guard let recording else { return }
        self.recording = nil
        recording.limit?.cancel()
        recording.upload?.cancel()
        recording.stopAudio()
        recording.continuation.finish()
        try? FileManager.default.removeItem(at: recording.url)
    }

    func stopCapture() {
        guard let recording else { return }
        hold(recording)
    }

    /// Stops the microphone; the file stays for `finish()` or `cancel()`.
    private func hold(_ recording: Recording) {
        guard recording.upload == nil else { return }
        recording.limit?.cancel()
        recording.stopAudio()
    }

    /// Stops the microphone, uploads the file once, and ends the stream with its text or the error.
    private func transcribe(_ recording: Recording) async {
        if let upload = recording.upload { await upload.value; return }
        recording.limit?.cancel()
        recording.stopAudio()
        let endpoint = endpoint, session = session
        let upload = Task {
            defer { try? FileManager.default.removeItem(at: recording.url) }
            do {
                if recording.writer.seconds >= Self.minimumSeconds {
                    let data = try Data(contentsOf: recording.url)
                    let audio = TranscriptionAudio(data: data, fileName: "dictation.m4a", mimeType: "audio/mp4")
                    let text = try await TranscriptionAPI.transcribe(endpoint: endpoint, audio: audio,
                                                                     language: recording.language, session: session)
                    if !text.isEmpty { recording.continuation.yield(.finalized(text)) }
                }
                recording.continuation.finish()
            } catch is CancellationError {
                recording.continuation.finish()
            } catch {
                recording.continuation.finish(throwing: TranscriptionAPI.error(for: error))
            }
        }
        recording.upload = upload
        await upload.value
    }

    @MainActor
    private final class Recording {
        let url: URL
        let writer: AudioFileWriter
        let capture: AudioCapture
        let audio: AudioSessionScope
        let continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation
        let language: String?
        var limit: Task<Void, Never>?
        var upload: Task<Void, Never>?

        init(url: URL, writer: AudioFileWriter, capture: AudioCapture, audio: AudioSessionScope,
             continuation: AsyncThrowingStream<DictationEvent, Error>.Continuation, language: String?) {
            self.url = url
            self.writer = writer
            self.capture = capture
            self.audio = audio
            self.continuation = continuation
            self.language = language
        }

        func stopAudio() {
            capture.stop()
            writer.close()
            audio.end()
        }
    }
}

/// An AAC file written from the audio thread: 16 kHz mono, about 32 kbit/s, so ten minutes stay near 2.5 MB.
final class AudioFileWriter: @unchecked Sendable {
    /// What `write` takes (the capture converts the microphone's buffers to it).
    let format: AVAudioFormat
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        format = file.processingFormat
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let file else { return }
            do {
                try file.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
            } catch {}
        }
    }

    /// Finishes the file; later buffers are dropped.
    func close() {
        lock.withLock {
            file?.close()
            file = nil
        }
    }

    /// The length written so far.
    var seconds: Double { lock.withLock { Double(frames) / format.sampleRate } }
}
