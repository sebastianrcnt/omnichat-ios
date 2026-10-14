import Foundation
import os

/// The OpenCode credentials of each connection, in the Keychain through `KeyStoring`: a Console sign-in (session) or a
/// service-account API key. A connection has one or the other; saving one clears the other.
struct OpenCodeCredentialStore: Sendable {
    let sessions: any KeyStoring
    let apiKeys: any KeyStoring

    static let keychain = OpenCodeCredentialStore(
        sessions: KeychainKeyStore(service: "cc.coolservices.strata.opencode.session"),
        apiKeys: KeychainKeyStore(service: "cc.coolservices.strata.opencode.apikey"))

    static func inMemory() -> OpenCodeCredentialStore {
        OpenCodeCredentialStore(sessions: InMemoryKeyStore(), apiKeys: InMemoryKeyStore())
    }

    func session(_ id: UUID) -> OpenCodeSession? {
        guard let text = sessions.key(for: id) else { return nil }
        return try? JSONDecoder().decode(OpenCodeSession.self, from: Data(text.utf8))
    }

    func setSession(_ value: OpenCodeSession?, _ id: UUID) throws {
        guard let value else { try sessions.setKey(nil, for: id); return }
        try sessions.setKey(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), for: id)
        try apiKeys.setKey(nil, for: id)
    }

    func apiKey(_ id: UUID) -> String? { apiKeys.key(for: id) }

    func setAPIKey(_ key: String?, _ id: UUID) throws {
        try apiKeys.setKey(key, for: id)
        if apiKey(id) != nil { try sessions.setKey(nil, for: id) }
    }

    func hasCredential(_ id: UUID) -> Bool { apiKey(id) != nil || session(id) != nil }

    /// Deleting the connection, or signing out, forgets both.
    func removeAll(_ id: UUID) {
        try? sessions.setKey(nil, for: id)
        try? apiKeys.setKey(nil, for: id)
    }
}

/// Supplies the bearer token for an OpenCode connection's requests.
protocol OpenCodeTokenProviding: Sendable {
    /// A token that is valid now: the API key, or the session's access token, refreshed first when close to expiry.
    func accessToken(connectionID: UUID) async throws -> String
    /// After a 401: refreshes the session unless another request already replaced `rejected`. An API key has nothing to
    /// refresh, so it throws `invalidAPIKey`.
    func tokenAfterRejection(connectionID: UUID, rejected: String) async throws -> String
}

/// Token lifecycle for OpenCode connections: the device-code sign-in, refresh before expiry and after a 401 (one
/// refresh at a time per connection: each refresh token works once, and reusing one revokes the whole session), and
/// sign-out (local only; the Console documents no revocation endpoint).
actor OpenCodeAuth: OpenCodeTokenProviding {
    static let shared = OpenCodeAuth()
    /// Status codes and states only, never a token or code: `log stream --level debug --predicate 'category == "opencode"'`.
    static let log = Logger(subsystem: "cc.coolservices.strata", category: "opencode")

    nonisolated let store: OpenCodeCredentialStore
    private let http: any ChatGPTHTTP // a plain request sender, shared with the ChatGPT sign-in
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var refreshes: [UUID: Task<OpenCodeSession, Error>] = [:]

    init(store: OpenCodeCredentialStore = .keychain, http: any ChatGPTHTTP = URLSessionChatGPTHTTP(),
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.store = store
        self.http = http
        self.now = now
        self.sleep = sleep
    }

    // MARK: Tokens for requests

    func accessToken(connectionID: UUID) async throws -> String {
        if let key = store.apiKey(connectionID) { return key }
        guard let session = store.session(connectionID) else { throw OpenCodeAuthError.signInRequired }
        if session.needsRefresh(now: now()) { return try await refresh(connectionID).accessToken }
        return session.accessToken
    }

    func tokenAfterRejection(connectionID: UUID, rejected: String) async throws -> String {
        if let key = store.apiKey(connectionID) {
            if key != rejected { return key }
            throw OpenCodeAuthError.invalidAPIKey
        }
        guard let session = store.session(connectionID) else { throw OpenCodeAuthError.signInRequired }
        if session.accessToken != rejected { return session.accessToken } // already refreshed by another request
        return try await refresh(connectionID).accessToken
    }

    /// One refresh per connection at a time: callers that arrive while one runs share its result.
    func refresh(_ id: UUID) async throws -> OpenCodeSession {
        if let running = refreshes[id] { return try await running.value }
        let task = Task { try await performRefresh(id) }
        refreshes[id] = task
        defer { refreshes[id] = nil }
        return try await task.value
    }

    private func performRefresh(_ id: UUID) async throws -> OpenCodeSession {
        guard let session = store.session(id) else { throw OpenCodeAuthError.signInRequired }
        let (data, status) = try await http.send(OpenCodeAPI.post(OpenCodeAPI.tokenEndpoint,
                                                                  body: OpenCodeAPI.refreshRequestBody(refreshToken: session.refreshToken)))
        Self.log.debug("refresh status=\(status, privacy: .public)")
        guard (200..<300).contains(status) else {
            // `invalid_grant` (expired, revoked or reused refresh token) or an unexplained 400/401: only a new sign-in
            // recovers.
            if OpenCodeAPI.errorCode(data) == "invalid_grant" || status == 400 || status == 401 {
                try? store.setSession(nil, id)
                throw OpenCodeAuthError.sessionExpired
            }
            throw APIError.http(status: status, message: HTTP.errorMessage(from: data))
        }
        let response: OpenCodeTokenResponse
        do { response = try JSONDecoder().decode(OpenCodeTokenResponse.self, from: data) }
        catch { throw OpenCodeAuthError.invalidResponse }
        let fresh = try response.session(receivedAt: now(), previous: session)
        // The old refresh token is spent: save the replacement before anything else can fail.
        try store.setSession(fresh, id)
        return fresh
    }

    // MARK: Sign-in

    /// Starts a sign-in: asks the Console for a device code to show and an approval page to open.
    func requestDeviceCode() async throws -> OpenCodeDeviceCode {
        let (data, status) = try await http.send(OpenCodeAPI.post(OpenCodeAPI.deviceCodeEndpoint,
                                                                  body: OpenCodeAPI.deviceCodeRequestBody()))
        Self.log.debug("device code status=\(status, privacy: .public)")
        guard (200..<300).contains(status) else {
            throw OpenCodeAuthError.failed(Self.tag(data) ?? "HTTP \(status)")
        }
        return try OpenCodeDeviceCode.parse(data, now: now())
    }

    /// Polls until the person approves (or declines, or the code expires), then saves the session and looks up the
    /// account's email. Cancelling the task stops the polling (`OpenCodeAuthError.cancelled`).
    func completeSignIn(connectionID id: UUID, device: OpenCodeDeviceCode) async throws -> OpenCodeSession {
        var interval = device.interval
        while now() < device.expiresAt {
            do { try await sleep(.seconds(interval)) } catch { throw OpenCodeAuthError.cancelled }
            if Task.isCancelled { throw OpenCodeAuthError.cancelled }
            let (data, status) = try await http.send(OpenCodeAPI.post(OpenCodeAPI.tokenEndpoint,
                                                                      body: OpenCodeAPI.pollRequestBody(deviceCode: device.deviceCode)))
            let result = OpenCodePollResult.parse(status: status, data: data)
            switch result {
            case .pending:
                continue
            case .slowDown:
                interval += 5
                continue
            case .expired:
                throw OpenCodeAuthError.expired
            case .denied:
                throw OpenCodeAuthError.denied
            case .failure(let status, let code):
                Self.log.debug("poll failed status=\(status, privacy: .public) code=\(code ?? "-", privacy: .public)")
                throw OpenCodeAuthError.failed(code ?? "HTTP \(status)")
            case .success(let response):
                Self.log.debug("poll approved")
                var session = try response.session(receivedAt: now())
                session.email = await email(token: session.accessToken)
                try store.setSession(session, id)
                return session
            }
        }
        throw OpenCodeAuthError.expired
    }

    /// Saves a service-account key (replacing a sign-in).
    nonisolated func saveAPIKey(_ key: String, connectionID id: UUID) throws {
        try store.setAPIKey(key, id)
    }

    /// Forgets the sign-in and any key on this device.
    func signOut(connectionID id: UUID) {
        refreshes[id]?.cancel()
        store.removeAll(id)
    }

    // MARK: Account

    /// `GET /api/user` → `{id, email}`. Best effort: nil when it does not answer.
    private func email(token: String) async -> String? {
        guard let (data, status) = try? await http.send(OpenCodeAPI.get(OpenCodeAPI.userEndpoint, token: token)),
              (200..<300).contains(status),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The gateways the workspace offers, from `GET /api/v2/config`: its `providers` map lists `opencode` (Console,
    /// pay as you go) and `opencode-go` when the workspace has a Go subscription. Nil when the config can't be read.
    func availableGateways(connectionID id: UUID) async -> Set<OpenCodeGateway>? {
        guard let token = try? await accessToken(connectionID: id),
              let (data, status) = try? await http.send(OpenCodeAPI.get(OpenCodeAPI.configEndpoint, token: token)) else { return nil }
        Self.log.debug("config status=\(status, privacy: .public)")
        guard (200..<300).contains(status) else { return nil }
        return OpenCodeGateway.available(inConfig: data)
    }

    /// The `_tag` or `error` of a Console error body (`{"_tag": "DeviceAuthFailed", …}`).
    static func tag(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["error"] as? String) ?? (root["_tag"] as? String)
    }
}
