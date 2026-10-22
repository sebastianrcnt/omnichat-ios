import Foundation

/// A starting point for a new connection: the add-connection screen lists these, and each prefills the connection's
/// editor. The OpenAI-compatible services (OpenAI, OpenRouter, Groq, Ollama, LM Studio) are data: the presets of the
/// built-in package `app.openchat.connections` (`PackageConnectionPreset`), listed with those of installed packages. Only
/// the connections with code of their own (Anthropic's Messages API, the accounts that sign in) and "Other server" are here.
enum ConnectionPreset: String, CaseIterable, Identifiable, Sendable {
    case anthropic, chatGPT, openCode, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: String(localized: "Anthropic")
        case .chatGPT: String(localized: "ChatGPT account")
        case .openCode: String(localized: "OpenCode account")
        case .custom: String(localized: "Other server")
        }
    }

    var subtitle: String {
        switch self {
        case .anthropic: String(localized: "Claude models, API key from console.anthropic.com")
        case .chatGPT: String(localized: "Use your ChatGPT plan")
        case .openCode: String(localized: "Sign in to use OpenCode Go or pay as you go")
        case .custom: String(localized: "Any OpenAI-compatible API: enter its URL")
        }
    }

    var systemImage: String {
        switch self {
        case .anthropic: "key"
        case .chatGPT, .openCode: "person.badge.plus"
        case .custom: "server.rack"
        }
    }

    /// The new connection, ready for its editor (which asks for the key or the sign-in).
    func makeConnection() -> Connection {
        switch self {
        case .anthropic: .anthropic(name: String(localized: "Anthropic"))
        case .chatGPT: .chatGPT(name: String(localized: "ChatGPT"))
        case .openCode: .openCode(name: String(localized: "OpenCode"))
        case .custom: Connection(name: String(localized: "New connection"), baseURL: "https://")
        }
    }
}

/// A package's connection preset in the add-connection screen.
extension PackageConnectionPreset {
    /// On this device or another computer (`localhost`, a `.local` name or a private address): listed under "On your
    /// computer".
    var isLocal: Bool {
        guard let host = URL(string: url)?.host(percentEncoded: false)?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".local") || URLGuard.isIPLiteralPrivate(host) || URLGuard.isBlockedHostname(host)
    }

    var subtitleText: String {
        if let subtitle, !subtitle.isEmpty { return subtitle }
        if isLocal, let port = URL(string: url)?.port { return Self.localNote(port: port) }
        return URL(string: url)?.host(percentEncoded: false) ?? url
    }

    var systemImage: String { isLocal ? "desktopcomputer" : "key" }

    /// A phone can't reach `localhost` on the Mac, so it says to use the Mac's address on the network instead.
    private static func localNote(port: Int) -> String {
        #if os(macOS)
        String(localized: "Runs on this Mac (port \(String(port)))")
        #else
        String(localized: "On your Mac: replace localhost with the Mac's network address (port \(String(port)))")
        #endif
    }

    /// The new connection, ready for its editor (which asks for the key: presets never carry one).
    func makeConnection() -> Connection {
        var c = Connection(name: name, baseURL: url, supportsResumable: resumable ?? false)
        c.defaultChatAPI = api == "responses" ? .responses : nil // "openai" is Automatic, as in `AddConnectionLink`
        c.imagesByDefault = images ?? false
        c.effortByDefault = effort ?? false
        return c
    }
}

/// `openchat://add-connection?name=…&url=…&api=openai|responses&images=1&effort=1&resumable=1`: a link that offers to
/// add an OpenAI-compatible connection. `api=anthropic` adds an Anthropic connection instead, at `url` or, without one,
/// at Anthropic's own API; its models say what they take, so the flags are ignored. It never carries a key (a `key`
/// parameter is dropped and the confirmation says so); after the user confirms, the editor asks for one.
struct AddConnectionLink: Equatable, Sendable {
    static let scheme = "openchat"
    static let host = "add-connection"

    var name: String
    var baseURL: URL
    /// Nil is Automatic (Chat Completions, switching when a model needs the Responses API).
    var api: ChatAPI?
    /// `api=anthropic`: an Anthropic Messages connection (`api` is nil then).
    var anthropic = false
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
            case .unsupportedAPI(let api): String(localized: "The link asks for an API OpenChat doesn't know (\(api)).")
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
        let api: ChatAPI?
        var anthropic = false
        switch query["api"]?.lowercased() ?? "" {
        case "", "openai", "chat", "chat_completions": api = nil
        case "responses": api = .responses
        case "anthropic", "messages": api = nil; anthropic = true
        case let other: return .failure(.unsupportedAPI(other))
        }
        let given = query["url"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let raw = given.isEmpty ? (anthropic ? AnthropicModels.defaultBaseURL : nil) : given else {
            return .failure(.missingURL)
        }
        let candidate = Connection(name: "", baseURL: raw)
        guard let base = candidate.normalizedBaseURL, base.user == nil, base.password == nil else { return .failure(.invalidURL) }
        func flag(_ name: String) -> Bool { ["1", "true", "yes", "on"].contains(query[name]?.lowercased() ?? "") }
        let name = ModelAlias.normalized(query["name"])
            ?? (anthropic && given.isEmpty ? String(localized: "Anthropic") : nil)
            ?? base.host(percentEncoded: false) ?? base.absoluteString
        if anthropic {
            // The API can't resume a reply, and each model's own capabilities decide images and effort.
            return .success(AddConnectionLink(name: name, baseURL: base, api: nil, anthropic: true, images: false, effort: false,
                                              resumable: false, droppedKey: query["key"] != nil))
        }
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
        if anthropic { return .anthropic(name: name, baseURL: baseURL.absoluteString) }
        var c = Connection(name: name, baseURL: baseURL.absoluteString, supportsResumable: resumable)
        c.defaultChatAPI = api
        c.imagesByDefault = images
        c.effortByDefault = effort
        return c
    }
}
