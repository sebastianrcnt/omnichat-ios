import Foundation

/// Where an API dictation engine sends its recording: an OpenAI-compatible server (OpenAI, Groq, a local whisper
/// server) and the transcription model there. Built from a connection by `DictationSettings.resolve`.
struct TranscriptionEndpoint: Equatable, Sendable {
    var baseURL: URL
    /// Nil or empty: no `Authorization` header (a local server).
    var apiKey: String?
    /// The connection's custom headers.
    var headers: [String: String] = [:]
    var model: String
}

/// The audio to transcribe, as a file would be uploaded.
struct TranscriptionAudio: Sendable {
    var data: Data
    var fileName: String
    var mimeType: String
}

/// `POST {baseURL}/audio/transcriptions`, multipart: `file`, `model`, `language` (ISO-639-1, optional) and
/// `response_format=json`; the answer is `{"text": "..."}`.
enum TranscriptionAPI {
    /// OpenAI's and Groq's upload limit.
    static let maxUploadBytes = 25 * 1024 * 1024
    /// The longest wait for the server between bytes; the controller has its own, longer, overall limit.
    static let requestTimeout: TimeInterval = 60

    static func url(for endpoint: TranscriptionEndpoint) -> URL {
        endpoint.baseURL.appending(path: "audio/transcriptions")
    }

    static func request(endpoint: TranscriptionEndpoint, audio: TranscriptionAudio, language: String?,
                        boundary: String = "strata-\(UUID().uuidString)") -> URLRequest {
        var request = URLRequest(url: url(for: endpoint), timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        for (name, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let key = endpoint.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body(model: endpoint.model, audio: audio, language: language, boundary: boundary)
        return request
    }

    static func body(model: String, audio: TranscriptionAudio, language: String?, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        if let language, !language.isEmpty { field("language", language) }
        field("response_format", "json")
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.fileName)\"\r\n"
                          + "Content-Type: \(audio.mimeType)\r\n\r\n").utf8))
        body.append(audio.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// The ISO-639-1 code the API takes as its `language` hint: "ko", "en". Nil when the locale has none.
    static func languageHint(for locale: Locale) -> String? {
        guard let code = locale.language.languageCode?.identifier, code.count == 2 else { return nil }
        return code
    }

    /// The text of a 2xx answer, or the error an unsuccessful one stands for.
    static func parse(data: Data, response: HTTPURLResponse) throws -> String {
        guard (200..<300).contains(response.statusCode) else {
            throw error(status: response.statusCode, message: errorMessage(data))
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = object["text"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            throw DictationError.service(String(localized: "The answer had no text."))
        }
        // `response_format=text` servers, or one that ignores the field.
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.hasPrefix("text/plain"), let text = String(data: data, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw DictationError.service(String(localized: "The answer wasn't understood."))
    }

    /// `{"error": {"message": ...}}`, `{"error": "..."}`, `{"detail": "..."}` or a short plain body.
    static func errorMessage(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = object["error"] as? String { return message }
            if let message = object["detail"] as? String { return message }
            if let message = object["message"] as? String { return message }
            return nil
        }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count < 300, !text.hasPrefix("<") else { return nil }
        return text
    }

    static func error(status: Int, message: String?) -> DictationError {
        let lower = message?.lowercased() ?? ""
        switch status {
        case 401, 403: return .unauthorized
        case 413: return .tooLong
        case 400 where ["too long", "too large", "longer than", "maximum", "duration"].contains { lower.contains($0) }:
            return .tooLong
        default:
            let detail = message.map { String($0.prefix(140)) } ?? HTTPURLResponse.localizedString(forStatusCode: status)
            return .service("HTTP \(status): \(detail)")
        }
    }

    /// What a transport error means for dictation.
    static func error(for error: Error) -> DictationError {
        if let error = error as? DictationError { return error }
        guard let error = error as? URLError else { return .failed(error.localizedDescription) }
        switch error.code {
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed, .cannotLoadFromNetwork:
            return .network
        default: return .failed(error.localizedDescription)
        }
    }

    static func transcribe(endpoint: TranscriptionEndpoint, audio: TranscriptionAudio, language: String?,
                           session: URLSession) async throws -> String {
        guard audio.data.count <= maxUploadBytes else { throw DictationError.tooLong }
        let request = request(endpoint: endpoint, audio: audio, language: language)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Self.error(for: error)
        }
        guard let http = response as? HTTPURLResponse else { throw DictationError.service(String(localized: "No HTTP answer.")) }
        return try parse(data: data, response: http)
    }
}
