import Foundation
import CryptoKit
import Security

// Sign in with ChatGPT for an open-source / local app, as documented at
// developers.openai.com/siwc/token-sharing-open-source: a public OAuth client registered on first sign-in
// (`client_id=dynamic_agent_client`), PKCE + state + nonce, a loopback callback on 127.0.0.1, and a bearer access
// token for the Responses API. Everything here is pure (no network, no UI), so it is tested directly.

enum ChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let authorizationEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let revocationEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    /// The audience of the access token, and the base URL of the models and Responses endpoints.
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    /// The scope that allows inference on the user's plan. A sign-in without it is kept, but cannot send requests.
    static let planScope = "chatgpt.tokens.use.direct"
    /// The first-registration entry point; never saved and never used for a token request.
    static let dynamicClientID = "dynamic_agent_client"
    /// Sent as `agent_name_hint` on first registration only: the app's actual name, the same on every installation (the
    /// sign-in docs). The user can rename it on the consent page; it is display metadata, so registrations made under an
    /// earlier name keep working (returning sign-ins send the issued client id and no name).
    static let agentName = "OmniChat"
    /// Only the port of the redirect URI may vary between sign-ins.
    static let callbackPath = "/auth/callback"
    /// ChatGPT Settings → Usage: plan usage and per-app limits.
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!

    /// A fresh 32-byte random value, base64url without padding (state, nonce, PKCE verifier).
    static func randomValue() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64URLEncodedString()
    }

    /// S256: base64url(SHA-256(verifier)), no padding.
    static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    /// A new `urn:uuid:` host id (UUIDv4), generated once per installation.
    static func newHostID() -> String { "urn:uuid:" + UUID().uuidString.lowercased() }

    static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)\(callbackPath)" }

    /// Everything one sign-in attempt keeps until its callback: fresh per attempt.
    struct Attempt: Sendable, Equatable {
        var state: String
        var nonce: String
        var verifier: String
        var redirectURI: String
        /// The registration's issued client id when signing in again; nil registers a new client.
        var savedClientID: String?
        var hostID: String
        /// The saved account's email, sent as `login_hint` on a returning sign-in.
        var loginHint: String?

        static func make(port: UInt16, hostID: String, savedClientID: String?, loginHint: String?) -> Attempt {
            Attempt(state: randomValue(), nonce: randomValue(), verifier: randomValue(),
                    redirectURI: ChatGPTOAuth.redirectURI(port: port), savedClientID: savedClientID, hostID: hostID, loginHint: loginHint)
        }

        /// The authorize URL. A new registration sends `dynamic_agent_client` and `agent_name_hint`; a returning one
        /// sends its issued client id and no name hint. The host id goes on both. No `id_token_hint`: the docs ask to
        /// keep it out of logs, and `login_hint` already picks the account.
        var authorizationURL: URL {
            var items: [URLQueryItem] = [
                .init(name: "client_id", value: savedClientID ?? ChatGPTOAuth.dynamicClientID),
                .init(name: "response_type", value: "code"),
                .init(name: "redirect_uri", value: redirectURI),
                .init(name: "scope", value: ChatGPTOAuth.scopes),
                .init(name: "resource", value: ChatGPTOAuth.resource),
                .init(name: "state", value: state),
                .init(name: "nonce", value: nonce),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "code_challenge", value: ChatGPTOAuth.codeChallenge(for: verifier)),
                .init(name: "ext_agent_host_id", value: hostID),
            ]
            if savedClientID == nil { items.append(.init(name: "agent_name_hint", value: ChatGPTOAuth.agentName)) }
            if let loginHint, !loginHint.isEmpty { items.append(.init(name: "login_hint", value: loginHint)) }
            var components = URLComponents(url: ChatGPTOAuth.authorizationEndpoint, resolvingAgainstBaseURL: false)!
            components.percentEncodedQuery = items.map { "\($0.name)=\(ChatGPTOAuth.formEncode($0.value ?? ""))" }
                .joined(separator: "&")
            return components.url!
        }

        /// The `authorization_code` grant for the token endpoint.
        func tokenRequestBody(code: String, clientID: String) -> Data {
            ChatGPTOAuth.formBody([("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
                                   ("code_verifier", verifier), ("redirect_uri", redirectURI),
                                   ("resource", ChatGPTOAuth.resource)])
        }
    }

    /// What a loopback request means for the pending attempt.
    enum CallbackOutcome: Equatable, Sendable {
        /// Not the callback (another path), or a state that does not match: answered, and the attempt keeps waiting.
        case ignored
        /// The code and the client id to exchange it with.
        case success(code: String, clientID: String)
        /// The callback for this attempt, but it failed (`access_denied`, a missing or mismatched client id).
        case failure(ChatGPTAuthError)
    }

    /// Checks a callback against the attempt: state first (an unrelated request never consumes the attempt), then an
    /// OAuth error, then the code and client id. A new registration must return its issued id; a returning one may
    /// omit it, and may not return a different one.
    static func parseCallback(_ url: URL, attempt: Attempt) -> CallbackOutcome {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == callbackPath else { return .ignored }
        let items = components.queryItems ?? []
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        let states = values("state")
        guard states.count == 1, constantTimeEqual(states[0], attempt.state) else { return .ignored }
        if let error = values("error").first {
            return .failure(error == "access_denied" ? .accessDenied : .oauth(code: error))
        }
        let codes = values("code")
        let returned = values("client_id")
        guard codes.count == 1, !codes[0].isEmpty, returned.count <= 1 else { return .failure(.registrationIncomplete) }
        if let saved = attempt.savedClientID, let id = returned.first, id != saved { return .failure(.registrationIncomplete) }
        guard let clientID = returned.first ?? attempt.savedClientID, isValidClientID(clientID) else {
            return .failure(.registrationIncomplete)
        }
        return .success(code: codes[0], clientID: clientID)
    }

    static func isValidClientID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200 && id != dynamicClientID
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" }
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The `refresh_token` grant: the issued client id, the saved refresh token, the resource, no scope.
    static func refreshRequestBody(clientID: String, refreshToken: String) -> Data {
        formBody([("grant_type", "refresh_token"), ("client_id", clientID), ("refresh_token", refreshToken),
                  ("resource", resource)])
    }

    /// Revokes the renewable session at sign-out.
    static func revocationRequestBody(clientID: String, refreshToken: String) -> Data {
        formBody([("token", refreshToken), ("token_type_hint", "refresh_token"), ("client_id", clientID)])
    }

    static func formBody(_ pairs: [(String, String)]) -> Data {
        Data(pairs.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&").utf8)
    }

    /// `application/x-www-form-urlencoded` value encoding (also used for the query): only unreserved characters stay.
    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.unicodeScalars.map { scalar -> String in
            scalar.isASCII && allowed.contains(scalar) ? String(scalar)
                : String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }
}

// MARK: - Token responses

/// The token endpoint's answer to a code exchange or a refresh.
struct ChatGPTTokenResponse: Decodable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var tokenType: String?
    var expiresIn: Double?
    var scope: String?
    var earliestRefreshAt: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
        case tokenType = "token_type", expiresIn = "expires_in", scope, earliestRefreshAt = "earliest_refresh_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        idToken = try c.decodeIfPresent(String.self, forKey: .idToken)
        tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType)
        expiresIn = try c.decodeIfPresent(Double.self, forKey: .expiresIn)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        // Documented as a field, not its type: Unix seconds as a number, or an ISO 8601 string.
        if let n = try? c.decodeIfPresent(Double.self, forKey: .earliestRefreshAt) {
            earliestRefreshAt = n
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .earliestRefreshAt) {
            earliestRefreshAt = Double(s) ?? ISO8601DateFormatter().date(from: s)?.timeIntervalSince1970
        }
    }

    /// The credentials, checked: a bearer access token with a positive lifetime and, with `offline_access`, a refresh
    /// token. A refresh may omit `scope` (the grant is unchanged) and the ID token.
    func tokens(receivedAt now: Date, previous: ChatGPTTokens? = nil) throws -> ChatGPTTokens {
        let scopes = scope.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) } ?? previous?.scopes
        guard let scopes else { throw ChatGPTAuthError.invalidTokenResponse }
        guard let accessToken, !accessToken.isEmpty, tokenType?.lowercased() == "bearer",
              let expiresIn, expiresIn > 0 else { throw ChatGPTAuthError.invalidTokenResponse }
        // A refresh that doesn't rotate the refresh token leaves the old one valid: keep it.
        let refresh = (refreshToken ?? "").isEmpty ? previous?.refreshToken : refreshToken
        if scopes.contains("offline_access") && (refresh ?? "").isEmpty { throw ChatGPTAuthError.invalidTokenResponse }
        return ChatGPTTokens(accessToken: accessToken, refreshToken: refresh, idToken: idToken ?? previous?.idToken,
                             expiresAt: now.addingTimeInterval(expiresIn), scopes: scopes, savedAt: now,
                             earliestRefreshAt: earliestRefreshAt.map { Date(timeIntervalSince1970: $0) })
    }
}

/// One account's tokens. Kept in the Keychain only; never logged.
struct ChatGPTTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    /// Kept for the identity it carries (the account picker) and for a later `id_token_hint`.
    var idToken: String?
    var expiresAt: Date
    var scopes: [String]
    var savedAt: Date
    /// From the token response: no proactive refresh before this time (a rejected token still refreshes).
    var earliestRefreshAt: Date?

    /// How long before expiry a request refreshes first (access tokens last an hour).
    static let refreshLeeway: TimeInterval = 5 * 60

    /// Whether the plan permission was granted: without it, requests are refused.
    var allowsPlanUsage: Bool { scopes.contains(ChatGPTOAuth.planScope) }

    /// True when the access token is within `refreshLeeway` of expiry (or past it), unless the server asked to wait
    /// and the token is still valid.
    func needsRefresh(now: Date) -> Bool {
        guard now >= expiresAt.addingTimeInterval(-Self.refreshLeeway) else { return false }
        if now < expiresAt, let earliestRefreshAt, now < earliestRefreshAt { return false }
        return true
    }
}

/// One account registration: the issued client id and the verified identity. Survives sign-out (the docs: keep the
/// account/client mapping so the next sign-in reuses the client).
struct ChatGPTRegistration: Codable, Sendable, Equatable {
    var clientID: String
    /// The ID token's `sub`; nil until the first sign-in is validated (the client id is saved before the exchange).
    var subject: String?
    var email: String?
    var name: String?
}

// MARK: - Errors

enum ChatGPTAuthError: Error, LocalizedError, Equatable {
    case accessDenied
    case oauth(code: String)
    case registrationIncomplete
    case invalidTokenResponse
    case invalidIDToken(String)
    case accountMismatch
    case signInRequired
    /// The refresh token can no longer be used; the tokens were cleared.
    case sessionExpired
    case cancelled
    case listenerFailed
    case presentationFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied: String(localized: "Sign-in was not completed. You can try again when you are ready.")
        case .oauth(let code): String(localized: "ChatGPT sign-in failed (\(code)).")
        case .registrationIncomplete: String(localized: "ChatGPT did not complete app registration. Please try signing in again.")
        case .invalidTokenResponse: String(localized: "ChatGPT returned incomplete credentials. Please sign in again.")
        case .invalidIDToken(let why): String(localized: "The ChatGPT identity could not be verified (\(why)). Please sign in again.")
        case .accountMismatch: String(localized: "This sign-in returned a different ChatGPT account. Sign in with the original account, or add another ChatGPT connection.")
        case .signInRequired: String(localized: "Sign in to ChatGPT in Settings.")
        case .sessionExpired: String(localized: "Your ChatGPT session has ended. Sign in again in Settings.")
        case .cancelled: String(localized: "Sign-in was cancelled.")
        case .listenerFailed: String(localized: "The local sign-in listener could not start. Try again.")
        case .presentationFailed: String(localized: "The sign-in page could not be opened.")
        }
    }

    /// Refresh errors that mean the refresh token is unusable (clear it, sign in again with the saved client id).
    static let unusableRefreshCodes: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired",
                                                     "refresh_token_expired", "refresh_token_invalidated",
                                                     "refresh_token_reused"]
}

// MARK: - ID token

/// The claims the app reads from an ID token.
struct ChatGPTIDClaims: Decodable, Sendable, Equatable {
    var iss: String
    var sub: String
    var aud: [String]
    var azp: String?
    var exp: Double
    var iat: Double?
    var nonce: String?
    var email: String?
    var name: String?

    enum CodingKeys: String, CodingKey { case iss, sub, aud, azp, exp, iat, nonce, email, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iss = try c.decode(String.self, forKey: .iss)
        sub = try c.decode(String.self, forKey: .sub)
        if let one = try? c.decode(String.self, forKey: .aud) { aud = [one] } else { aud = try c.decode([String].self, forKey: .aud) }
        azp = try c.decodeIfPresent(String.self, forKey: .azp)
        exp = try c.decode(Double.self, forKey: .exp)
        iat = try c.decodeIfPresent(Double.self, forKey: .iat)
        nonce = try c.decodeIfPresent(String.self, forKey: .nonce)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}

/// A compact JWS split into its parts.
struct JWT: Sendable {
    struct Header: Decodable, Sendable { var alg: String; var kid: String? }

    var header: Header
    var payload: Data
    var signingInput: Data
    var signature: Data

    init(_ token: String) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let h = Data(base64URLEncoded: String(parts[0])),
              let p = Data(base64URLEncoded: String(parts[1])),
              let s = Data(base64URLEncoded: String(parts[2])) else { throw ChatGPTAuthError.invalidIDToken("malformed") }
        header = try JSONDecoder().decode(Header.self, from: h)
        payload = p
        signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        signature = s
    }

    func claims() throws -> ChatGPTIDClaims {
        do { return try JSONDecoder().decode(ChatGPTIDClaims.self, from: payload) }
        catch { throw ChatGPTAuthError.invalidIDToken("claims") }
    }
}

enum IDTokenValidator {
    /// Small clock-skew tolerance, as the docs advise.
    static let clockSkew: TimeInterval = 5

    /// Checks issuer, audience (the issued client id), `azp`, expiry and, on sign-in, the nonce of the attempt.
    /// - Parameter nonce: nil for an ID token from a refresh (it carries no nonce of ours).
    static func validateClaims(_ claims: ChatGPTIDClaims, clientID: String, nonce: String?, now: Date) throws {
        guard claims.iss == ChatGPTOAuth.issuer else { throw ChatGPTAuthError.invalidIDToken("issuer") }
        guard claims.aud.contains(clientID) else { throw ChatGPTAuthError.invalidIDToken("audience") }
        if let azp = claims.azp, azp != clientID { throw ChatGPTAuthError.invalidIDToken("authorized party") }
        if claims.aud.count > 1 && claims.azp != clientID { throw ChatGPTAuthError.invalidIDToken("authorized party") }
        guard now.timeIntervalSince1970 < claims.exp + clockSkew else { throw ChatGPTAuthError.invalidIDToken("expired") }
        if let nonce, claims.nonce.map({ ChatGPTOAuth.constantTimeEqual($0, nonce) }) != true {
            throw ChatGPTAuthError.invalidIDToken("nonce")
        }
        guard !claims.sub.isEmpty else { throw ChatGPTAuthError.invalidIDToken("subject") }
    }

    /// RS256 signature check against a JWKS document (`keys` with `kty: RSA`, `n`, `e`, `kid`).
    /// - Returns: false when no key matches the token's `kid` (the caller refetches the key set once).
    static func verifySignature(_ jwt: JWT, jwks: Data) throws -> Bool {
        guard jwt.header.alg == "RS256" else { throw ChatGPTAuthError.invalidIDToken("algorithm") }
        struct Set: Decodable { struct Key: Decodable { var kty: String; var kid: String?; var n: String?; var e: String? }; var keys: [Key] }
        guard let set = try? JSONDecoder().decode(Set.self, from: jwks) else { return false }
        guard let key = set.keys.first(where: { $0.kty == "RSA" && $0.kid == jwt.header.kid && $0.n != nil && $0.e != nil }),
              let n = key.n.flatMap(Data.init(base64URLEncoded:)), let e = key.e.flatMap(Data.init(base64URLEncoded:)),
              let publicKey = RSAPublicKey.make(modulus: n, exponent: e) else { return false }
        var error: Unmanaged<CFError>?
        let ok = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, jwt.signingInput as CFData,
                                       jwt.signature as CFData, &error)
        if !ok { throw ChatGPTAuthError.invalidIDToken("signature") }
        return true
    }
}

/// Builds a `SecKey` from a JWK's modulus and exponent (a PKCS#1 `RSAPublicKey` DER).
enum RSAPublicKey {
    static func make(modulus: Data, exponent: Data) -> SecKey? {
        let der = pkcs1DER(modulus: modulus, exponent: exponent)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    /// SEQUENCE { INTEGER modulus, INTEGER exponent }.
    static func pkcs1DER(modulus: Data, exponent: Data) -> Data {
        func integer(_ bytes: Data) -> Data {
            var b = Data(bytes.drop { $0 == 0 })
            if b.isEmpty { b = Data([0]) }
            if b[b.startIndex] & 0x80 != 0 { b.insert(0, at: b.startIndex) } // keep it positive
            return Data([0x02]) + length(b.count) + b
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30]) + length(body.count) + body
    }

    private static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
