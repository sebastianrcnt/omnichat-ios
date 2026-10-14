import Testing
import Foundation
import Security
@testable import Strata

// MARK: - Helpers

/// An RSA key pair that signs ID tokens and publishes itself as a JWKS, like auth.openai.com.
struct TestSigner {
    let privateKey: SecKey
    let kid = "test-key"

    init() {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
    }

    var jwks: Data {
        let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
        let (n, e) = TestDER.rsaComponents(der)
        let json: [String: Any] = ["keys": [["kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256",
                                             "n": n.base64URLEncodedString(), "e": e.base64URLEncodedString()]]]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func token(_ claims: [String: Any], kid: String? = nil) -> String {
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT", "kid": kid ?? self.kid])
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let input = header.base64URLEncodedString() + "." + payload.base64URLEncodedString()
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
        return input + "." + signature.base64URLEncodedString()
    }
}

/// Reads the two INTEGERs of a PKCS#1 RSAPublicKey.
enum TestDER {
    static func rsaComponents(_ der: Data) -> (Data, Data) {
        let bytes = [UInt8](der)
        var i = 0
        func length() -> Int {
            let first = Int(bytes[i]); i += 1
            guard first & 0x80 != 0 else { return first }
            var n = 0
            for _ in 0..<(first & 0x7F) { n = n << 8 | Int(bytes[i]); i += 1 }
            return n
        }
        precondition(bytes[i] == 0x30); i += 1; _ = length()
        precondition(bytes[i] == 0x02); i += 1
        let nLen = length(); let n = Data(bytes[i..<(i + nLen)]); i += nLen
        precondition(bytes[i] == 0x02); i += 1
        let eLen = length(); let e = Data(bytes[i..<(i + eLen)])
        return (n, e)
    }
}

/// A clock tests move by hand.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Answers the auth endpoints from a closure and records each request.
final class FakeAuthHTTP: ChatGPTHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var delay: Duration = .zero
    var handler: @Sendable (URLRequest) -> (Data, Int)

    init(_ handler: @escaping @Sendable (URLRequest) -> (Data, Int)) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.withLock { requests.append(request) }
        if delay > .zero { try await Task.sleep(for: delay) }
        return handler(request)
    }

    func form(_ request: URLRequest) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: request.httpBody ?? Data(), as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }

    var count: Int { lock.withLock { requests.count } }
}

private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

// MARK: - PKCE, state and the authorize URL

struct ChatGPTOAuthTests {
    @Test func codeChallengeMatchesRFC7636Example() {
        #expect(ChatGPTOAuth.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomValuesAreFreshBase64URL() {
        let a = ChatGPTOAuth.randomValue(), b = ChatGPTOAuth.randomValue()
        #expect(a != b)
        #expect(a.count == 43) // 32 bytes, no padding
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func hostIDIsAUUIDURNKeptOnce() {
        let defaults = UserDefaults(suiteName: "hostid.\(UUID().uuidString)")!
        let store = HostIDStore(defaults: defaults)
        let id = store.hostID()
        #expect(id.hasPrefix("urn:uuid:"))
        #expect(UUID(uuidString: String(id.dropFirst(9))) != nil)
        #expect(id == id.lowercased())
        #expect(store.hostID() == id)
    }

    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }

    @Test func firstRegistrationURL() {
        let attempt = ChatGPTOAuth.Attempt.make(port: 54321, hostID: "urn:uuid:abc", savedClientID: nil, loginHint: nil)
        let url = attempt.authorizationURL
        #expect(url.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
        let q = query(url)
        #expect(q["client_id"] == "dynamic_agent_client")
        #expect(q["agent_name_hint"] == "Strata")
        #expect(q["ext_agent_host_id"] == "urn:uuid:abc")
        #expect(q["response_type"] == "code")
        #expect(q["redirect_uri"] == "http://127.0.0.1:54321/auth/callback")
        #expect(q["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(q["resource"] == "https://api.openai.com/v1")
        #expect(q["state"] == attempt.state)
        #expect(q["nonce"] == attempt.nonce)
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["code_challenge"] == ChatGPTOAuth.codeChallenge(for: attempt.verifier))
        #expect(q["login_hint"] == nil)
        #expect(q["id_token_hint"] == nil)
        // Every value is percent-encoded (spaces, colons and slashes included).
        #expect(url.absoluteString.contains("scope=openid%20profile"))
        #expect(url.absoluteString.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Fauth%2Fcallback"))
    }

    @Test func returningSignInURLUsesIssuedClientAndNoNameHint() {
        let attempt = ChatGPTOAuth.Attempt.make(port: 1455, hostID: "urn:uuid:abc", savedClientID: "oaiapp_123",
                                                loginHint: "user+x@example.com")
        let q = query(attempt.authorizationURL)
        #expect(q["client_id"] == "oaiapp_123")
        #expect(q["agent_name_hint"] == nil)
        #expect(q["ext_agent_host_id"] == "urn:uuid:abc")
        #expect(q["login_hint"] == "user+x@example.com")
        #expect(attempt.authorizationURL.absoluteString.contains("login_hint=user%2Bx%40example.com"))
    }

    @Test func tokenRequestBodyCarriesVerifierRedirectAndResource() {
        let attempt = ChatGPTOAuth.Attempt.make(port: 1455, hostID: "h", savedClientID: nil, loginHint: nil)
        let body = String(decoding: attempt.tokenRequestBody(code: "c/1", clientID: "oaiapp_1"), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("client_id=oaiapp_1"))
        #expect(body.contains("code=c%2F1"))
        #expect(body.contains("code_verifier=\(attempt.verifier)"))
        #expect(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback"))
        #expect(body.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1"))
        #expect(!body.contains("client_secret"))
    }

    @Test func refreshAndRevocationBodies() {
        let refresh = String(decoding: ChatGPTOAuth.refreshRequestBody(clientID: "oaiapp_1", refreshToken: "rt"), as: UTF8.self)
        #expect(refresh == "grant_type=refresh_token&client_id=oaiapp_1&refresh_token=rt&resource=https%3A%2F%2Fapi.openai.com%2Fv1")
        let revoke = String(decoding: ChatGPTOAuth.revocationRequestBody(clientID: "oaiapp_1", refreshToken: "rt"), as: UTF8.self)
        #expect(revoke == "token=rt&token_type_hint=refresh_token&client_id=oaiapp_1")
    }

    // MARK: Callback

    private func attempt(saved: String? = nil) -> ChatGPTOAuth.Attempt {
        ChatGPTOAuth.Attempt(state: "S", nonce: "N", verifier: "V", redirectURI: "http://127.0.0.1:9/auth/callback",
                             savedClientID: saved, hostID: "h", loginHint: nil)
    }

    private func callback(_ query: String) -> URL { URL(string: "http://127.0.0.1:9/auth/callback?" + query)! }

    @Test func newRegistrationCallbackReturnsIssuedClientID() {
        #expect(ChatGPTOAuth.parseCallback(callback("code=abc&scope=openid&state=S&client_id=oaiapp_9"), attempt: attempt())
                == .success(code: "abc", clientID: "oaiapp_9"))
    }

    @Test func wrongStateOrPathIsIgnoredNotFailed() {
        #expect(ChatGPTOAuth.parseCallback(callback("code=abc&state=X&client_id=oaiapp_9"), attempt: attempt()) == .ignored)
        #expect(ChatGPTOAuth.parseCallback(callback("code=abc&client_id=oaiapp_9"), attempt: attempt()) == .ignored)
        #expect(ChatGPTOAuth.parseCallback(callback("code=abc&state=S&state=S"), attempt: attempt()) == .ignored)
        #expect(ChatGPTOAuth.parseCallback(URL(string: "http://127.0.0.1:9/callback?code=a&state=S")!, attempt: attempt()) == .ignored)
        #expect(ChatGPTOAuth.parseCallback(URL(string: "http://127.0.0.1:9/favicon.ico")!, attempt: attempt()) == .ignored)
    }

    @Test func deniedConsentFails() {
        #expect(ChatGPTOAuth.parseCallback(callback("error=access_denied&state=S"), attempt: attempt()) == .failure(.accessDenied))
        #expect(ChatGPTOAuth.parseCallback(callback("error=server_error&state=S"), attempt: attempt())
                == .failure(.oauth(code: "server_error")))
    }

    @Test func newRegistrationWithoutIssuedIDIsIncomplete() {
        #expect(ChatGPTOAuth.parseCallback(callback("code=abc&state=S"), attempt: attempt()) == .failure(.registrationIncomplete))
        #expect(ChatGPTOAuth.parseCallback(callback("code=abc&state=S&client_id=dynamic_agent_client"), attempt: attempt())
                == .failure(.registrationIncomplete))
    }

    @Test func returningSignInMayOmitButNotChangeClientID() {
        #expect(ChatGPTOAuth.parseCallback(callback("code=abc&state=S"), attempt: attempt(saved: "oaiapp_1"))
                == .success(code: "abc", clientID: "oaiapp_1"))
        #expect(ChatGPTOAuth.parseCallback(callback("code=abc&state=S&client_id=oaiapp_1"), attempt: attempt(saved: "oaiapp_1"))
                == .success(code: "abc", clientID: "oaiapp_1"))
        #expect(ChatGPTOAuth.parseCallback(callback("code=abc&state=S&client_id=oaiapp_2"), attempt: attempt(saved: "oaiapp_1"))
                == .failure(.registrationIncomplete))
    }

    // MARK: Token response and ID token

    @Test func tokenResponseBecomesTokens() throws {
        let data = json(["access_token": "at", "refresh_token": "rt", "id_token": "it", "token_type": "Bearer",
                         "expires_in": 3600, "scope": "chatgpt.tokens.use.direct email offline_access openid profile resource.invoke",
                         "earliest_refresh_at": 1_790_000_600])
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let tokens = try JSONDecoder().decode(ChatGPTTokenResponse.self, from: data).tokens(receivedAt: now)
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.expiresAt == now.addingTimeInterval(3600))
        #expect(tokens.allowsPlanUsage)
        #expect(tokens.earliestRefreshAt == Date(timeIntervalSince1970: 1_790_000_600))
    }

    @Test func tokenResponseWithoutPlanScopeSignsInWithoutPlanUsage() throws {
        let data = json(["access_token": "at", "refresh_token": "rt", "token_type": "bearer", "expires_in": 3600,
                         "scope": "openid profile email offline_access"])
        let tokens = try JSONDecoder().decode(ChatGPTTokenResponse.self, from: data).tokens(receivedAt: .now)
        #expect(!tokens.allowsPlanUsage)
    }

    @Test func tokenResponseMissingRefreshTokenIsRejected() {
        let data = json(["access_token": "at", "token_type": "Bearer", "expires_in": 3600, "scope": "openid offline_access"])
        #expect(throws: ChatGPTAuthError.invalidTokenResponse) {
            try JSONDecoder().decode(ChatGPTTokenResponse.self, from: data).tokens(receivedAt: .now)
        }
    }

    private func claims(_ overrides: [String: Any] = [:]) throws -> ChatGPTIDClaims {
        var base: [String: Any] = ["iss": "https://auth.openai.com", "sub": "user-1", "aud": "oaiapp_1",
                                   "exp": 1_790_003_600, "iat": 1_790_000_000, "nonce": "N", "email": "a@b.c", "name": "A B"]
        for (k, v) in overrides { base[k] = v }
        return try JSONDecoder().decode(ChatGPTIDClaims.self, from: json(base))
    }

    @Test func idTokenClaimsAreChecked() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_100)
        try IDTokenValidator.validateClaims(try claims(), clientID: "oaiapp_1", nonce: "N", now: now)
        try IDTokenValidator.validateClaims(try claims(["aud": ["oaiapp_1"]]), clientID: "oaiapp_1", nonce: "N", now: now)
        #expect(throws: ChatGPTAuthError.invalidIDToken("issuer")) {
            try IDTokenValidator.validateClaims(try claims(["iss": "https://evil.example"]), clientID: "oaiapp_1", nonce: "N", now: now)
        }
        #expect(throws: ChatGPTAuthError.invalidIDToken("audience")) {
            try IDTokenValidator.validateClaims(try claims(), clientID: "oaiapp_2", nonce: "N", now: now)
        }
        #expect(throws: ChatGPTAuthError.invalidIDToken("nonce")) {
            try IDTokenValidator.validateClaims(try claims(), clientID: "oaiapp_1", nonce: "other", now: now)
        }
        #expect(throws: ChatGPTAuthError.invalidIDToken("expired")) {
            try IDTokenValidator.validateClaims(try claims(), clientID: "oaiapp_1", nonce: "N",
                                                now: Date(timeIntervalSince1970: 1_790_003_700))
        }
        // A refreshed ID token carries no nonce of ours.
        try IDTokenValidator.validateClaims(try claims(["nonce": NSNull()]), clientID: "oaiapp_1", nonce: nil, now: now)
    }

    @Test func rs256SignatureIsVerifiedAgainstJWKS() throws {
        let signer = TestSigner()
        let token = signer.token(["iss": "https://auth.openai.com", "sub": "u", "aud": "c", "exp": 2_000_000_000])
        #expect(try IDTokenValidator.verifySignature(try JWT(token), jwks: signer.jwks))
        // Tampered payload.
        var parts = token.split(separator: ".").map(String.init)
        parts[1] = json(["iss": "https://auth.openai.com", "sub": "attacker", "aud": "c", "exp": 2_000_000_000]).base64URLEncodedString()
        #expect(throws: ChatGPTAuthError.invalidIDToken("signature")) {
            try IDTokenValidator.verifySignature(try JWT(parts.joined(separator: ".")), jwks: signer.jwks)
        }
        // Another key's signature, and an unknown kid.
        #expect(throws: ChatGPTAuthError.invalidIDToken("signature")) {
            try IDTokenValidator.verifySignature(try JWT(TestSigner().token(["sub": "u"])), jwks: signer.jwks)
        }
        #expect(try IDTokenValidator.verifySignature(try JWT(signer.token(["sub": "u"], kid: "rotated")), jwks: signer.jwks) == false)
    }

    @Test func pkcs1DERRoundTripsThroughSecKey() throws {
        let signer = TestSigner()
        let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(signer.privateKey)!, nil)! as Data
        let (n, e) = TestDER.rsaComponents(der)
        #expect(RSAPublicKey.pkcs1DER(modulus: n.drop { $0 == 0 }, exponent: e) == der)
        #expect(RSAPublicKey.make(modulus: n, exponent: e) != nil)
    }
}

// MARK: - Token lifecycle

struct ChatGPTTokenRefreshTests {
    let id = UUID()

    private func setup(expiresIn: TimeInterval = 3600, earliest: Date? = nil, handler: @escaping @Sendable (URLRequest) -> (Data, Int))
        -> (ChatGPTAuth, ChatGPTCredentialStore, FakeAuthHTTP, FakeClock) {
        let store = ChatGPTCredentialStore.inMemory()
        let clock = FakeClock()
        let http = FakeAuthHTTP(handler)
        try! store.setRegistration(ChatGPTRegistration(clientID: "oaiapp_1", subject: "user-1", email: "a@b.c", name: "A"), id)
        try! store.setTokens(ChatGPTTokens(accessToken: "at-1", refreshToken: "rt-1", idToken: "old-id", expiresAt: clock.now.addingTimeInterval(expiresIn),
                                           scopes: ["offline_access", "chatgpt.tokens.use.direct"], savedAt: clock.now,
                                           earliestRefreshAt: earliest), id)
        let auth = ChatGPTAuth(store: store, http: http, now: { clock.now })
        return (auth, store, http, clock)
    }

    private static func refreshed(_ n: Int) -> (Data, Int) {
        (json(["access_token": "at-\(n)", "refresh_token": "rt-\(n)", "token_type": "Bearer", "expires_in": 3600]), 200)
    }

    @Test func needsRefreshWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        var t = ChatGPTTokens(accessToken: "a", refreshToken: "r", idToken: nil, expiresAt: now.addingTimeInterval(3600),
                              scopes: [], savedAt: now)
        #expect(!t.needsRefresh(now: now))
        #expect(!t.needsRefresh(now: now.addingTimeInterval(3600 - 301)))
        #expect(t.needsRefresh(now: now.addingTimeInterval(3600 - 299)))
        #expect(t.needsRefresh(now: now.addingTimeInterval(4000)))
        // The server's earliest refresh time defers a proactive refresh while the token is still valid, not after.
        t.earliestRefreshAt = now.addingTimeInterval(3550)
        #expect(!t.needsRefresh(now: now.addingTimeInterval(3400)))
        #expect(t.needsRefresh(now: now.addingTimeInterval(3560)))
        #expect(t.needsRefresh(now: now.addingTimeInterval(3601)))
    }

    @Test func freshTokenIsUsedWithoutRefreshing() async throws {
        let (auth, _, http, _) = setup { _ in Self.refreshed(2) }
        #expect(try await auth.accessToken(connectionID: id) == "at-1")
        #expect(http.count == 0)
    }

    @Test func tokenNearExpiryIsRefreshedAndRotated() async throws {
        let (auth, store, http, clock) = setup { _ in Self.refreshed(2) }
        clock.advance(3600 - 60)
        #expect(try await auth.accessToken(connectionID: id) == "at-2")
        #expect(http.count == 1)
        let form = http.form(http.requests[0])
        #expect(http.requests[0].url == ChatGPTOAuth.tokenEndpoint)
        #expect(form == ["grant_type": "refresh_token", "client_id": "oaiapp_1", "refresh_token": "rt-1",
                         "resource": "https://api.openai.com/v1"])
        let saved = try #require(store.tokens(id))
        #expect(saved.refreshToken == "rt-2")
        #expect(saved.expiresAt == clock.now.addingTimeInterval(3600))
        #expect(saved.scopes == ["offline_access", "chatgpt.tokens.use.direct"]) // omitted scope keeps the grant
        #expect(saved.idToken == "old-id")
        // Valid again: no second refresh.
        #expect(try await auth.accessToken(connectionID: id) == "at-2")
        #expect(http.count == 1)
    }

    @Test func concurrentRequestsShareOneRefresh() async throws {
        let (auth, _, http, clock) = setup { _ in Self.refreshed(2) }
        http.delay = .milliseconds(100)
        clock.advance(4000)
        async let a = auth.accessToken(connectionID: id)
        async let b = auth.accessToken(connectionID: id)
        async let c = auth.tokenAfterRejection(connectionID: id, rejected: "at-1")
        let tokens = try await [a, b, c]
        #expect(tokens == ["at-2", "at-2", "at-2"])
        #expect(http.count == 1)
    }

    @Test func rejectionOfAnAlreadyReplacedTokenDoesNotRefresh() async throws {
        let (auth, _, http, _) = setup { _ in Self.refreshed(2) }
        #expect(try await auth.tokenAfterRejection(connectionID: id, rejected: "at-0") == "at-1")
        #expect(http.count == 0)
        #expect(try await auth.tokenAfterRejection(connectionID: id, rejected: "at-1") == "at-2")
        #expect(http.count == 1)
    }

    @Test func unusableRefreshTokenClearsTokensButKeepsRegistration() async throws {
        let (auth, store, _, clock) = setup { _ in (json(["error": "refresh_token_reused"]), 400) }
        clock.advance(4000)
        await #expect(throws: ChatGPTAuthError.sessionExpired) { try await auth.accessToken(connectionID: id) }
        #expect(store.tokens(id) == nil)
        #expect(store.registration(id)?.clientID == "oaiapp_1")
        await #expect(throws: ChatGPTAuthError.signInRequired) { try await auth.accessToken(connectionID: id) }
    }

    @Test func serverErrorKeepsCredentials() async throws {
        let (auth, store, _, clock) = setup { _ in (Data("upstream".utf8), 503) }
        clock.advance(4000)
        await #expect(throws: APIError.self) { try await auth.accessToken(connectionID: id) }
        #expect(store.tokens(id)?.refreshToken == "rt-1")
    }

    @Test func signOutRevokesAndKeepsRegistration() async throws {
        let (auth, store, http, _) = setup { _ in (Data(), 200) }
        #expect(await auth.signOut(connectionID: id))
        #expect(http.requests.first?.url == ChatGPTOAuth.revocationEndpoint)
        #expect(http.form(http.requests[0]) == ["token": "rt-1", "token_type_hint": "refresh_token", "client_id": "oaiapp_1"])
        #expect(store.tokens(id) == nil)
        #expect(store.registration(id) == ChatGPTRegistration(clientID: "oaiapp_1", subject: "user-1", email: "a@b.c", name: "A"))
    }

    @Test func unconfirmedRevocationStillClearsTokens() async throws {
        let (auth, store, http, _) = setup { _ in (Data(), 500) }
        #expect(await auth.signOut(connectionID: id) == false)
        #expect(http.count == 2) // one retry
        #expect(store.tokens(id) == nil)
    }

    @Test func codeExchangeValidatesIDTokenAndSavesAccount() async throws {
        let signer = TestSigner()
        let store = ChatGPTCredentialStore.inMemory()
        let clock = FakeClock()
        let attempt = ChatGPTOAuth.Attempt(state: "S", nonce: "nonce-1", verifier: "V", redirectURI: "http://127.0.0.1:9/auth/callback",
                                           savedClientID: nil, hostID: "h", loginHint: nil)
        let idToken = signer.token(["iss": "https://auth.openai.com", "sub": "user-9", "aud": "oaiapp_9", "nonce": "nonce-1",
                                    "exp": clock.now.timeIntervalSince1970 + 3600, "iat": clock.now.timeIntervalSince1970,
                                    "email": "me@example.com", "name": "Me"])
        let jwks = signer.jwks
        let http = FakeAuthHTTP { request in
            if request.url == ChatGPTOAuth.jwksURL { return (jwks, 200) }
            return (json(["access_token": "at", "refresh_token": "rt", "id_token": idToken, "token_type": "Bearer",
                          "expires_in": 3600, "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"]), 200)
        }
        let auth = ChatGPTAuth(store: store, http: http, now: { clock.now })
        let connection = UUID()
        try await auth.saveIssuedClientID("oaiapp_9", connectionID: connection)
        #expect(store.registration(connection)?.clientID == "oaiapp_9") // saved before the exchange
        let account = try await auth.completeSignIn(connectionID: connection, attempt: attempt, code: "code", clientID: "oaiapp_9")
        #expect(account == ChatGPTRegistration(clientID: "oaiapp_9", subject: "user-9", email: "me@example.com", name: "Me"))
        #expect(store.tokens(connection)?.allowsPlanUsage == true)
        #expect(http.form(http.requests[0])["code_verifier"] == "V")

        // A different nonce (a replayed or foreign token) is refused and saves nothing new.
        let other = ChatGPTOAuth.Attempt(state: "S", nonce: "nonce-2", verifier: "V", redirectURI: attempt.redirectURI,
                                         savedClientID: "oaiapp_9", hostID: "h", loginHint: nil)
        try store.setTokens(nil, connection)
        await #expect(throws: ChatGPTAuthError.invalidIDToken("nonce")) {
            try await auth.completeSignIn(connectionID: connection, attempt: other, code: "code", clientID: "oaiapp_9")
        }
        #expect(store.tokens(connection) == nil)
    }
}
