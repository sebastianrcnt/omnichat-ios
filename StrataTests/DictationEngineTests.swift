import Testing
import Foundation
import AVFoundation
@testable import Strata

/// Answers `/audio/transcriptions` with one scripted reply (or a transport error), recording the request.
private final class TranscriptionStub: URLProtocol, @unchecked Sendable {
    enum Reply { case http(Int, String, contentType: String); case failure(URLError.Code) }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply: Reply = .http(200, #"{"text":"ok"}"#, contentType: "application/json")
    nonisolated(unsafe) private static var log: [(request: URLRequest, body: Data)] = []

    static func reset(_ reply: Reply) { lock.withLock { self.reply = reply; log = [] } }
    static var requests: [(request: URLRequest, body: Data)] { lock.withLock { log } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        let reply = Self.lock.withLock { () -> Reply in
            Self.log.append((request, body))
            return Self.reply
        }
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let text, let contentType):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranscriptionStub.self]
        return URLSession(configuration: config)
    }
}

private let endpoint = TranscriptionEndpoint(baseURL: URL(string: "https://api.groq.com/openai/v1")!, apiKey: "sk-test",
                                             headers: ["X-Org": "team"], model: "whisper-large-v3")
private let audio = TranscriptionAudio(data: Data([0x00, 0x01, 0xFF, 0x0D, 0x0A]), fileName: "dictation.m4a", mimeType: "audio/mp4")

private func http(_ status: Int, contentType: String = "application/json") -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://x/audio/transcriptions")!, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": contentType])!
}

/// Runs `body` and returns the `DictationError` it threw, if any.
private func dictationError(_ body: () async throws -> Void) async -> DictationError? {
    do { try await body(); return nil } catch { return error as? DictationError }
}

// The stub's script is shared, so these run one at a time.
@Suite(.serialized)
struct TranscriptionAPITests {
    @Test func buildsAMultipartRequest() throws {
        let request = TranscriptionAPI.request(endpoint: endpoint, audio: audio, language: "ko", boundary: "BOUNDARY")
        #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "X-Org") == "team")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY")
        var expected = Data()
        expected.append(Data(("--BOUNDARY\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3\r\n"
            + "--BOUNDARY\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nko\r\n"
            + "--BOUNDARY\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n"
            + "--BOUNDARY\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.m4a\"\r\n"
            + "Content-Type: audio/mp4\r\n\r\n").utf8))
        expected.append(audio.data)
        expected.append(Data("\r\n--BOUNDARY--\r\n".utf8))
        #expect(request.httpBody == expected)
    }

    @Test func leavesOutAnEmptyKeyAndLanguage() throws {
        var local = endpoint
        local.apiKey = "  "
        local.headers = [:]
        let request = TranscriptionAPI.request(endpoint: local, audio: audio, language: nil, boundary: "B")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(!body.contains("name=\"language\""))
        #expect(body.contains("name=\"model\""))
    }

    @Test func languageHintIsTheTwoLetterCode() {
        #expect(TranscriptionAPI.languageHint(for: Locale(identifier: "ko-KR")) == "ko")
        #expect(TranscriptionAPI.languageHint(for: Locale(identifier: "en_US")) == "en")
        #expect(TranscriptionAPI.languageHint(for: Locale(identifier: "")) == nil)
    }

    @Test func parsesTheText() throws {
        #expect(try TranscriptionAPI.parse(data: Data(#"{"text":" Hello there. "}"#.utf8), response: http(200)) == "Hello there.")
        #expect(try TranscriptionAPI.parse(data: Data(#"{"text":"안녕하세요","x_groq":{"id":"r"}}"#.utf8), response: http(200)) == "안녕하세요")
        #expect(try TranscriptionAPI.parse(data: Data("plain words\n".utf8), response: http(200, contentType: "text/plain; charset=utf-8")) == "plain words")
        #expect(throws: DictationError.self) { try TranscriptionAPI.parse(data: Data(#"{"foo":1}"#.utf8), response: http(200)) }
        #expect(throws: DictationError.self) { try TranscriptionAPI.parse(data: Data("<html>".utf8), response: http(200, contentType: "text/html")) }
    }

    @Test func mapsErrorAnswers() {
        func error(_ status: Int, _ body: String) -> DictationError? {
            do { _ = try TranscriptionAPI.parse(data: Data(body.utf8), response: http(status)); return nil }
            catch { return error as? DictationError }
        }
        #expect(error(401, #"{"error":{"message":"Incorrect API key provided"}}"#) == .unauthorized)
        #expect(error(403, "") == .unauthorized)
        #expect(error(413, "") == .tooLong)
        #expect(error(400, #"{"error":{"message":"Audio file is too long. Maximum duration is 1500 seconds."}}"#) == .tooLong)
        #expect(error(404, #"{"detail":"Not Found"}"#) == .service("HTTP 404: Not Found"))
        #expect(error(500, #"{"error":"boom"}"#) == .service("HTTP 500: boom"))
    }

    @Test func mapsTransportErrors() {
        #expect(TranscriptionAPI.error(for: URLError(.notConnectedToInternet)) == .network)
        #expect(TranscriptionAPI.error(for: URLError(.cannotConnectToHost)) == .network)
        #expect(TranscriptionAPI.error(for: URLError(.timedOut)) == .timedOut)
        #expect(TranscriptionAPI.error(for: DictationError.tooLong) == .tooLong)
    }

    @Test func transcribesThroughTheSession() async throws {
        TranscriptionStub.reset(.http(200, #"{"text":"Summarize the thread"}"#, contentType: "application/json"))
        let text = try await TranscriptionAPI.transcribe(endpoint: endpoint, audio: audio, language: "en",
                                                         session: TranscriptionStub.session)
        #expect(text == "Summarize the thread")
        let sent = try #require(TranscriptionStub.requests.first)
        #expect(sent.request.url?.path == "/openai/v1/audio/transcriptions")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = String(decoding: sent.body, as: UTF8.self)
        #expect(body.contains("name=\"language\"\r\n\r\nen\r\n"))
        #expect(body.contains("filename=\"dictation.m4a\""))
    }

    @Test func surfacesFailures() async {
        TranscriptionStub.reset(.http(401, #"{"error":{"message":"Invalid API Key"}}"#, contentType: "application/json"))
        #expect(await dictationError {
            _ = try await TranscriptionAPI.transcribe(endpoint: endpoint, audio: audio, language: nil, session: TranscriptionStub.session)
        } == .unauthorized)
        TranscriptionStub.reset(.failure(.notConnectedToInternet))
        #expect(await dictationError {
            _ = try await TranscriptionAPI.transcribe(endpoint: endpoint, audio: audio, language: nil, session: TranscriptionStub.session)
        } == .network)
    }

    @Test func refusesAnOversizedFileWithoutARequest() async {
        TranscriptionStub.reset(.http(200, #"{"text":"x"}"#, contentType: "application/json"))
        let big = TranscriptionAudio(data: Data(count: TranscriptionAPI.maxUploadBytes + 1), fileName: "a.m4a", mimeType: "audio/mp4")
        #expect(await dictationError {
            _ = try await TranscriptionAPI.transcribe(endpoint: endpoint, audio: big, language: nil, session: TranscriptionStub.session)
        } == .tooLong)
        #expect(TranscriptionStub.requests.isEmpty)
    }
}

@MainActor
struct DictationSettingsTests {
    let groq = Connection(name: "Groq", baseURL: "https://api.groq.com/openai/v1/ ", customHeaders: "X-Org: team")
    let chatGPT = Connection.chatGPT()

    @Test func defaultsToApple() throws {
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        #expect(DictationSettings.load(defaults) == DictationSettings())
        #expect(AppSettings(defaults: defaults).dictationEngine == .apple)
        #expect(try DictationSettings().resolve(connections: [], key: { _ in nil }) == .apple)
    }

    @Test func savesAndLoads() {
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.dictationEngine = .openAICompatible
        settings.dictationConnectionID = groq.id
        settings.dictationModel = "whisper-large-v3"
        #expect(DictationSettings.load(defaults)
                == DictationSettings(engine: .openAICompatible, connectionID: groq.id, model: "whisper-large-v3"))
    }

    @Test func resolvesAConnection() throws {
        let settings = DictationSettings(engine: .openAICompatible, connectionID: groq.id, model: " whisper-large-v3 ")
        let resolved = try settings.resolve(connections: [chatGPT, groq], key: { $0 == groq.id ? "gsk-1" : nil })
        #expect(resolved == .api(TranscriptionEndpoint(baseURL: URL(string: "https://api.groq.com/openai/v1")!,
                                                       apiKey: "gsk-1", headers: ["X-Org": "team"], model: "whisper-large-v3")))
    }

    @Test func misconfiguredIsAnError() {
        func check(_ settings: DictationSettings) {
            #expect(throws: DictationError.notConfigured) { try settings.resolve(connections: [groq, chatGPT], key: { _ in nil }) }
        }
        check(DictationSettings(engine: .openAICompatible, connectionID: groq.id, model: "  ")) // no model
        check(DictationSettings(engine: .openAICompatible, connectionID: nil, model: "whisper-1")) // no connection
        check(DictationSettings(engine: .openAICompatible, connectionID: UUID(), model: "whisper-1")) // deleted
        check(DictationSettings(engine: .openAICompatible, connectionID: chatGPT.id, model: "whisper-1")) // not OpenAI-compatible
        var broken = groq
        broken.baseURL = "https://"
        #expect(throws: DictationError.notConfigured) {
            try DictationSettings(engine: .openAICompatible, connectionID: broken.id, model: "whisper-1")
                .resolve(connections: [broken], key: { _ in nil })
        }
        #expect(DictationSettings.eligible([groq, chatGPT, broken]).map(\.id) == [groq.id])
    }

    @Test func misconfiguredAPIEngineShowsAnErrorInsteadOfFallingBack() async {
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!, keys: InMemoryKeyStore())
        let engine = ConfiguredDictationEngine(
            settings: { DictationSettings(engine: .openAICompatible, connectionID: nil, model: "whisper-1") },
            connections: { store })
        let c = DictationController(engine: engine, locale: Locale(identifier: "en_US"))
        c.start(expanded: false)
        for _ in 0..<500 where c.failure == nil { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(c.failure == .notConfigured)
        #expect(!engine.transcribesOnFinish)
    }

    @Test func picksTheAPIEngineForAConnection() async throws {
        let store = ConnectionStore(defaults: UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!, keys: InMemoryKeyStore())
        store.upsert(groq)
        try store.setAPIKey("gsk-2", for: groq.id)
        let resolved = try DictationSettings(engine: .openAICompatible, connectionID: groq.id, model: "whisper-1")
            .resolve(connections: store.connections, key: store.apiKey(for:))
        guard case .api(let endpoint) = resolved else { Issue.record("expected the API engine"); return }
        #expect(endpoint.apiKey == "gsk-2")
        #expect(APIDictationEngine(endpoint: endpoint).transcribesOnFinish)
    }
}

@MainActor
struct TranscribingControllerTests {
    let engine = FakeDictationEngine()

    func controller() -> DictationController {
        engine.transcribes = true
        return DictationController(engine: engine, locale: Locale(identifier: "en_US"))
    }

    func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }

    @Test func confirmWaitsForTheTranscription() async {
        let c = controller()
        c.finishTimeout = .milliseconds(10) // the live engines' limit doesn't apply
        c.start(expanded: false)
        await until { c.isListening }
        #expect(!c.isTranscribing)
        engine.send(.level(0.4))
        engine.onFinish = [.finalized("Recorded words.")]
        #expect(await c.confirm() == "Recorded words.")
        #expect(c.phase == .idle)
    }

    @Test func showsTranscribingWhileFinishing() async {
        let c = controller()
        c.transcriptionTimeout = .milliseconds(300)
        engine.hangsOnFinish = true
        c.start(expanded: false)
        await until { c.isListening }
        let confirm = Task { await c.confirm() }
        await until { c.phase == .finishing }
        #expect(c.isTranscribing)
        #expect(await confirm.value == "")
        #expect(c.failure == .timedOut) // no words to fall back on: the timeout is shown
    }

    @Test func transcriptionErrorsAreShown() async {
        let c = controller()
        c.start(expanded: false)
        await until { c.isListening }
        engine.finishError = .unauthorized
        #expect(await c.confirm() == "")
        #expect(c.failure == .unauthorized)
        #expect(engine.cancelled >= 1)
    }

    @Test func liveEngineStillKeepsItsWordsOnAFinishError() async {
        let c = controller()
        engine.transcribes = false
        c.start(expanded: false)
        await until { c.isListening }
        engine.send(.finalized("kept"))
        await until { c.transcript == "kept" }
        engine.finishError = .failed("x")
        #expect(await c.confirm() == "kept")
        #expect(c.phase == .idle)
    }

    @Test func failureMapping() {
        #expect(DictationController.failure(for: DictationError.notConfigured) == .notConfigured)
        #expect(DictationController.failure(for: DictationError.network) == .network)
        #expect(DictationController.failure(for: DictationError.tooLong) == .tooLong)
        #expect(DictationController.failure(for: DictationError.service("HTTP 404: Not Found")) == .service("HTTP 404: Not Found"))
        #expect(!DictationController.Failure.unauthorized.opensSettings)
    }
}

struct AudioFileWriterTests {
    /// The recording format encodes here: a second of tone becomes a small AAC file of about that length.
    @Test func writesAnAACFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "writer-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileWriter(url: url)
        #expect(writer.format.sampleRate == 16_000 && writer.format.channelCount == 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: writer.format, frameCapacity: 1600))
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.2) * 0.3 }
        for _ in 0..<10 { writer.write(buffer) }
        #expect(abs(writer.seconds - 1) < 0.01)
        writer.close()
        writer.write(buffer) // dropped after close
        #expect(abs(writer.seconds - 1) < 0.01)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size > 1000 && size < 40_000)
        let read = try AVAudioFile(forReading: url)
        #expect(abs(Double(read.length) / read.fileFormat.sampleRate - 1) < 0.1)
    }
}
