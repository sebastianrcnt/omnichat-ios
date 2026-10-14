import Foundation

/// `GET https://api.openai.com/v1/models` with a ChatGPT account's token: the account's own catalog, as a `models`
/// array of `{slug, display_name, visibility, …}`. Only `visibility: "list"` entries are meant for a picker.
enum ChatGPTModelsAPI {
    struct Entry: Sendable, Equatable {
        var slug: String
        var displayName: String
        /// Read when the catalog carries them (the docs only promise `slug`, `display_name` and `visibility`).
        var contextLength: Int?
        var supportsImages: Bool?
    }

    static func parse(_ data: Data) throws -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["models"] as? [[String: Any]] else {
            throw APIError.server(String(localized: "ChatGPT returned an unexpected model catalog. Try again."))
        }
        return list.compactMap { item in
            guard item["visibility"] as? String == "list",
                  let slug = (item["slug"] as? String)?.trimmingCharacters(in: .whitespaces), !slug.isEmpty else { return nil }
            let name = (item["display_name"] as? String)?.trimmingCharacters(in: .whitespaces)
            var context: Int?
            for key in ["context_window", "max_context_window", "context_length"] {
                if let n = item[key] as? Int, n > 0 { context = n; break }
            }
            var images: Bool?
            if let inputs = item["input_modalities"] as? [String] { images = inputs.contains { $0.lowercased() == "image" } }
            return Entry(slug: slug, displayName: (name?.isEmpty == false ? name : nil) ?? slug,
                         contextLength: context, supportsImages: images)
        }
    }

    static func fetch(connectionID: UUID, auth: any ChatGPTTokenProviding, session: URLSession = .shared) async throws -> [Entry] {
        var token = try await auth.accessToken(connectionID: connectionID)
        for attempt in 0..<2 {
            var req = URLRequest(url: URL(string: ChatGPTOAuth.resource + "/models")!)
            req.timeoutInterval = 20
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 {
                token = try await auth.tokenAfterRejection(connectionID: connectionID, rejected: token)
                continue
            }
            guard (200..<300).contains(status) else { throw ResponsesErrorMapper.error(status: status, data: data) }
            // The catalog is model metadata, not account data: logged whole (in pieces, as the log cuts long lines) to
            // see which fields it carries beyond the documented ones.
            let text = String(decoding: data, as: UTF8.self)
            for (i, start) in stride(from: 0, to: text.count, by: 800).enumerated() {
                let piece = text.dropFirst(start).prefix(800)
                ResponsesEventDecoder.log.debug("catalog[\(i, privacy: .public)] \(String(piece), privacy: .public)")
            }
            return try parse(data)
        }
        throw APIError.http(status: 401, message: String(localized: "ChatGPT didn't accept the sign-in. Sign in again in Settings."))
    }
}
