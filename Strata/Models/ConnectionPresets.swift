import Foundation

/// A starting point for a new connection: the add-connection screen lists these, and each prefills the connection's
/// editor. Anthropic is not here: its Messages API is only spoken through an OpenCode account, not to a server of its own.
enum ConnectionPreset: String, CaseIterable, Identifiable, Sendable {
    case openAI, openRouter, groq, ollama, lmStudio, chatGPT, openCode, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .groq: "Groq"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .chatGPT: String(localized: "ChatGPT account")
        case .openCode: String(localized: "OpenCode account")
        case .custom: String(localized: "Other server")
        }
    }

    var subtitle: String {
        switch self {
        case .openAI: String(localized: "API key from platform.openai.com")
        case .openRouter: String(localized: "One key for many providers' models")
        case .groq: String(localized: "API key from console.groq.com")
        case .ollama: Self.localNote(port: 11434)
        case .lmStudio: Self.localNote(port: 1234)
        case .chatGPT: String(localized: "Sign in to use your ChatGPT plan")
        case .openCode: String(localized: "Sign in to use OpenCode Go or pay as you go")
        case .custom: String(localized: "Any OpenAI-compatible API: enter its URL")
        }
    }

    var systemImage: String {
        switch self {
        case .openAI, .openRouter, .groq: "key"
        case .ollama, .lmStudio: "desktopcomputer"
        case .chatGPT, .openCode: "person.badge.plus"
        case .custom: "server.rack"
        }
    }

    /// Runs on this device or another computer. A phone can't reach `localhost` on the Mac, so it says to use the
    /// Mac's address on the network instead.
    private static func localNote(port: Int) -> String {
        #if os(macOS)
        String(localized: "Runs on this Mac (port \(port))")
        #else
        String(localized: "On your Mac: replace localhost with the Mac's network address (port \(port))")
        #endif
    }

    /// Where the API lives, or nil for an account (its address is fixed) or a custom server (the user types it).
    var baseURL: String? {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .ollama: "http://localhost:11434/v1"
        case .lmStudio: "http://localhost:1234/v1"
        case .chatGPT, .openCode, .custom: nil
        }
    }

    /// The new connection, ready for its editor (which asks for the key or the sign-in).
    func makeConnection() -> Connection {
        switch self {
        case .chatGPT: return .chatGPT(name: String(localized: "ChatGPT"))
        case .openCode: return .openCode(name: String(localized: "OpenCode"))
        case .custom: return Connection(name: String(localized: "New connection"), baseURL: "https://")
        default: return Connection(name: title, baseURL: baseURL ?? "https://")
        }
    }
}

/// `openchat://add-connection?name=…&url=…&api=openai|responses&images=1&effort=1&resumable=1`: a link that offers to
/// add an OpenAI-compatible connection. It never carries a key (a `key` parameter is dropped and the confirmation says
/// so); after the user confirms, the editor asks for one.
struct AddConnectionLink: Equatable, Sendable {
    static let scheme = "openchat"
    static let host = "add-connection"

    var name: String
    var baseURL: URL
    /// Nil is Automatic (Chat Completions, switching when a model needs the Responses API).
    var api: ChatAPI?
    var images: Bool
    var effort: Bool
    var resumable: Bool
    /// The link had a `key` parameter, which was ignored.
    var droppedKey: Bool

    enum Failure: Error, Equatable, LocalizedError {
        case notAnAddLink
        case missingURL
        case invalidURL
        case unsupportedAPI(String)

        var errorDescription: String? {
            switch self {
            case .notAnAddLink: String(localized: "This link isn't an OpenChat add-connection link.")
            case .missingURL: String(localized: "The link doesn't say which server to add.")
            case .invalidURL: String(localized: "The server address in the link isn't an http or https URL.")
            case .unsupportedAPI(let api):
                api == "anthropic"
                    ? String(localized: "The link asks for Anthropic's Messages API, which OpenChat can't use with a server yet.")
                    : String(localized: "The link asks for an API OpenChat doesn't know (\(api)).")
            }
        }
    }

    static func isAddLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host()?.lowercased() == host
    }

    static func parse(_ url: URL) -> Result<AddConnectionLink, Failure> {
        guard isAddLink(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.notAnAddLink)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name.lowercased()] == nil {
            query[item.name.lowercased()] = item.value ?? ""
        }
        guard let raw = query["url"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .failure(.missingURL)
        }
        let candidate = Connection(name: "", baseURL: raw)
        guard let base = candidate.normalizedBaseURL, base.user == nil, base.password == nil else { return .failure(.invalidURL) }
        let api: ChatAPI?
        switch query["api"]?.lowercased() ?? "" {
        case "", "openai", "chat", "chat_completions": api = nil
        case "responses": api = .responses
        case let other: return .failure(.unsupportedAPI(other))
        }
        func flag(_ name: String) -> Bool { ["1", "true", "yes", "on"].contains(query[name]?.lowercased() ?? "") }
        let name = ModelAlias.normalized(query["name"]) ?? base.host(percentEncoded: false) ?? base.absoluteString
        return .success(AddConnectionLink(name: name, baseURL: base, api: api, images: flag("images"), effort: flag("effort"),
                                          resumable: flag("resumable"), droppedKey: query["key"] != nil))
    }

    /// Plain http: the key and the messages travel unencrypted.
    var isPlainHTTP: Bool { baseURL.scheme?.lowercased() == "http" }

    /// The address is on this device or a private network (localhost, `.local`, 10.x, 192.168.x, …).
    var isPrivateAddress: Bool {
        guard let host = baseURL.host(percentEncoded: false) else { return false }
        return URLGuard.isBlockedHostname(host) || URLGuard.isIPLiteralPrivate(host)
    }

    /// The connection the link describes, with no key and no models yet.
    func makeConnection() -> Connection {
        var c = Connection(name: name, baseURL: baseURL.absoluteString, supportsResumable: resumable)
        c.defaultChatAPI = api
        c.imagesByDefault = images
        c.effortByDefault = effort
        return c
    }
}
