import Foundation

/// The ChatGPT records of each connection, in the Keychain through `KeyStoring`: the registration (issued client id,
/// verified identity) and the tokens, kept apart so sign-out can clear the tokens and keep the registration.
/// The host id is not a secret (the docs: an opaque identifier, not a credential) and lives in UserDefaults.
struct ChatGPTCredentialStore: Sendable {
    let registrations: any KeyStoring
    let tokenStore: any KeyStoring
    let hostIDStore: HostIDStore

    static let keychain = ChatGPTCredentialStore(
        registrations: KeychainKeyStore(service: "cc.coolservices.strata.chatgpt.registration"),
        tokenStore: KeychainKeyStore(service: "cc.coolservices.strata.chatgpt.tokens"),
        hostIDStore: HostIDStore())

    static func inMemory() -> ChatGPTCredentialStore {
        ChatGPTCredentialStore(registrations: InMemoryKeyStore(), tokenStore: InMemoryKeyStore(),
                               hostIDStore: HostIDStore(defaults: UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!))
    }

    func registration(_ id: UUID) -> ChatGPTRegistration? { read(registrations, id) }
    func setRegistration(_ value: ChatGPTRegistration?, _ id: UUID) throws { try write(registrations, id, value) }
    func tokens(_ id: UUID) -> ChatGPTTokens? { read(tokenStore, id) }
    func setTokens(_ value: ChatGPTTokens?, _ id: UUID) throws { try write(tokenStore, id, value) }
    func hasTokens(_ id: UUID) -> Bool { tokens(id) != nil }

    /// Deleting the connection forgets the account completely.
    func removeAll(_ id: UUID) {
        try? setTokens(nil, id)
        try? setRegistration(nil, id)
    }

    private func read<T: Decodable>(_ store: any KeyStoring, _ id: UUID) -> T? {
        guard let text = store.key(for: id) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    private func write<T: Encodable>(_ store: any KeyStoring, _ id: UUID, _ value: T?) throws {
        guard let value else { try store.setKey(nil, for: id); return }
        try store.setKey(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), for: id)
    }
}

/// This installation's `ext_agent_host_id`: chosen once, before the first sign-in, and shared by every account.
struct HostIDStore: @unchecked Sendable { // UserDefaults is thread-safe
    let defaults: UserDefaults
    static let key = "chatgpt.hostID"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func hostID() -> String {
        if let id = defaults.string(forKey: Self.key), !id.isEmpty { return id }
        let id = ChatGPTOAuth.newHostID()
        defaults.set(id, forKey: Self.key)
        return id
    }
}

/// Supplies the access token for a ChatGPT connection's requests.
protocol ChatGPTTokenProviding: Sendable {
    /// A token that is valid now, refreshed first when it is close to expiry.
    func accessToken(connectionID: UUID) async throws -> String
    /// After a 401: refreshes unless another request already replaced `rejected`, and returns the new token.
    func tokenAfterRejection(connectionID: UUID, rejected: String) async throws -> String
}

/// Sends one HTTP request (the token, revocation, JWKS and models endpoints). Replaced in tests.
protocol ChatGPTHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionChatGPTHTTP: ChatGPTHTTP {
    var session: URLSession = .shared
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Token lifecycle for ChatGPT connections: code exchange and ID-token validation at sign-in, refresh before expiry
/// and after a 401 (one refresh at a time per connection, since refresh tokens rotate), and revocation at sign-out.
actor ChatGPTAuth: ChatGPTTokenProviding {
    static let shared = ChatGPTAuth()

    nonisolated let store: ChatGPTCredentialStore
    private let http: any ChatGPTHTTP
    private let now: @Sendable () -> Date
    private var refreshes: [UUID: Task<ChatGPTTokens, Error>] = [:]
    private var jwks: Data?

    init(store: ChatGPTCredentialStore = .keychain, http: any ChatGPTHTTP = URLSessionChatGPTHTTP(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.http = http
        self.now = now
    }

    // MARK: Tokens for requests

    func accessToken(connectionID: UUID) async throws -> String {
        guard let tokens = store.tokens(connectionID) else { throw ChatGPTAuthError.signInRequired }
        if tokens.needsRefresh(now: now()) { return try await refresh(connectionID).accessToken }
        return tokens.accessToken
    }

    func tokenAfterRejection(connectionID: UUID, rejected: String) async throws -> String {
        guard let tokens = store.tokens(connectionID) else { throw ChatGPTAuthError.signInRequired }
        if tokens.accessToken != rejected { return tokens.accessToken } // already refreshed by another request
        return try await refresh(connectionID).accessToken
    }

    /// One refresh per connection at a time: callers that arrive while one runs share its result.
    func refresh(_ id: UUID) async throws -> ChatGPTTokens {
        if let running = refreshes[id] { return try await running.value }
        let task = Task { try await performRefresh(id) }
        refreshes[id] = task
        defer { refreshes[id] = nil }
        return try await task.value
    }

    private func performRefresh(_ id: UUID) async throws -> ChatGPTTokens {
        guard let tokens = store.tokens(id), let refreshToken = tokens.refreshToken,
              let registration = store.registration(id) else { throw ChatGPTAuthError.signInRequired }
        let (data, status) = try await postForm(ChatGPTOAuth.tokenEndpoint,
                                                ChatGPTOAuth.refreshRequestBody(clientID: registration.clientID,
                                                                                refreshToken: refreshToken))
        guard (200..<300).contains(status) else {
            let code = Self.oauthErrorCode(data)
            if let code, ChatGPTAuthError.unusableRefreshCodes.contains(code) {
                // The session is over: drop the tokens, keep the registration for the next sign-in.
                try? store.setTokens(nil, id)
                throw ChatGPTAuthError.sessionExpired
            }
            if status == 400 || status == 401, code == nil {
                try? store.setTokens(nil, id)
                throw ChatGPTAuthError.sessionExpired
            }
            throw APIError.http(status: status, message: code ?? HTTP.errorMessage(from: data))
        }
        let response: ChatGPTTokenResponse
        do { response = try JSONDecoder().decode(ChatGPTTokenResponse.self, from: data) }
        catch { throw ChatGPTAuthError.invalidTokenResponse }
        var fresh = try response.tokens(receivedAt: now(), previous: tokens)
        // The old refresh token is spent: save the replacement before anything else can fail.
        try store.setTokens(fresh, id)
        if let idToken = response.idToken {
            // A refreshed identity must still be the account this registration belongs to.
            do {
                let claims = try await verify(idToken: idToken, clientID: registration.clientID, nonce: nil)
                if let subject = registration.subject, claims.sub != subject {
                    try? store.setTokens(nil, id)
                    throw ChatGPTAuthError.accountMismatch
                }
            } catch ChatGPTAuthError.accountMismatch {
                throw ChatGPTAuthError.accountMismatch
            } catch {
                // Key set unavailable or an unverifiable refreshed ID token: keep the earlier verified one.
                fresh.idToken = tokens.idToken
                try store.setTokens(fresh, id)
            }
        }
        return fresh
    }

    // MARK: Sign-in

    /// Exchanges the code, validates the ID token and the granted scopes, and saves the registration and tokens.
    /// The issued client id must already be saved (`saveIssuedClientID`), so a failed exchange can retry with it.
    func completeSignIn(connectionID id: UUID, attempt: ChatGPTOAuth.Attempt, code: String,
                        clientID: String) async throws -> ChatGPTRegistration {
        let (data, status) = try await postForm(ChatGPTOAuth.tokenEndpoint,
                                                attempt.tokenRequestBody(code: code, clientID: clientID))
        guard (200..<300).contains(status) else {
            if let code = Self.oauthErrorCode(data) {
                if code == "invalid_grant" { throw ChatGPTAuthError.oauth(code: "invalid_grant: try signing in again") }
                throw ChatGPTAuthError.oauth(code: code)
            }
            throw APIError.http(status: status, message: HTTP.errorMessage(from: data))
        }
        let response: ChatGPTTokenResponse
        do { response = try JSONDecoder().decode(ChatGPTTokenResponse.self, from: data) }
        catch { throw ChatGPTAuthError.invalidTokenResponse }
        guard let idToken = response.idToken else { throw ChatGPTAuthError.invalidIDToken("missing") }
        let tokens = try response.tokens(receivedAt: now())
        let claims = try await verify(idToken: idToken, clientID: clientID, nonce: attempt.nonce)
        let previous = store.registration(id)
        if let subject = previous?.subject, subject != claims.sub { throw ChatGPTAuthError.accountMismatch }
        let registration = ChatGPTRegistration(clientID: clientID, subject: claims.sub,
                                               email: claims.email ?? previous?.email, name: claims.name ?? previous?.name)
        try store.setRegistration(registration, id)
        try store.setTokens(tokens, id)
        return registration
    }

    /// Saved before the code exchange: a retry after an expired code reuses the client instead of registering another.
    func saveIssuedClientID(_ clientID: String, connectionID id: UUID) throws {
        var registration = store.registration(id) ?? ChatGPTRegistration(clientID: clientID)
        registration.clientID = clientID
        try store.setRegistration(registration, id)
    }

    /// Sign-out: revokes the refresh token (best effort, one retry on a network error or 5xx), then clears the tokens.
    /// The registration stays. Returns false when the revocation was not confirmed.
    @discardableResult
    func signOut(connectionID id: UUID) async -> Bool {
        defer { try? store.setTokens(nil, id) }
        guard let tokens = store.tokens(id), let refreshToken = tokens.refreshToken,
              let registration = store.registration(id) else { return true }
        for attempt in 0..<2 {
            do {
                let (_, status) = try await postForm(ChatGPTOAuth.revocationEndpoint,
                                                     ChatGPTOAuth.revocationRequestBody(clientID: registration.clientID,
                                                                                        refreshToken: refreshToken))
                if status == 200 { return true }
                if status < 500 { return false }
            } catch {}
            if attempt == 0 { try? await Task.sleep(for: .milliseconds(300)) }
        }
        return false
    }

    // MARK: ID token

    /// Signature (RS256 against OpenAI's JWKS, refetched once for an unknown `kid`) and claims.
    func verify(idToken: String, clientID: String, nonce: String?) async throws -> ChatGPTIDClaims {
        let jwt = try JWT(idToken)
        let claims = try jwt.claims()
        try IDTokenValidator.validateClaims(claims, clientID: clientID, nonce: nonce, now: now())
        if let cached = jwks, try IDTokenValidator.verifySignature(jwt, jwks: cached) { return claims }
        var request = URLRequest(url: ChatGPTOAuth.jwksURL)
        request.timeoutInterval = 15
        let (data, status) = try await http.send(request)
        guard status == 200 else { throw ChatGPTAuthError.invalidIDToken("keys unavailable") }
        jwks = data
        guard try IDTokenValidator.verifySignature(jwt, jwks: data) else { throw ChatGPTAuthError.invalidIDToken("unknown key") }
        return claims
    }

    // MARK: HTTP

    private func postForm(_ url: URL, _ body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await http.send(request)
    }

    /// The OAuth `error` code of a token-endpoint error body (`{"error": "invalid_grant"}` or `{"error": {"code": …}}`).
    static func oauthErrorCode(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let code = root["error"] as? String { return code }
        if let error = root["error"] as? [String: Any] { return (error["code"] as? String) ?? (error["type"] as? String) }
        return root["code"] as? String
    }
}
