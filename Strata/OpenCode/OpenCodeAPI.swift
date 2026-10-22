import Foundation

// Sign in with OpenCode: the OpenCode Console's OAuth device authorization grant (RFC 8628), as the opencode CLI uses it
// (github.com/anomalyco/opencode, packages/core/src/plugin/provider/opencode.ts) and as the Console API docs describe it
// (opencode.ai/docs/console/api, "Device flow"): JSON `POST {console}/auth/device/code`, then `POST
// {console}/auth/device/token` every `interval` seconds until the person approves in the browser. The access token is a
// bearer token for the inference gateways; refresh tokens are single use. A service-account API key (`oc_sk_…`) is the
// other way in. Everything here is pure (no network, no UI), so it is tested directly.

enum OpenCodeAPI {
    /// The Console: device flow, account and workspace config.
    static let consoleServer = URL(string: "https://opencode.ai/console")!
    static let deviceCodeEndpoint = URL(string: "https://opencode.ai/console/auth/device/code")!
    static let tokenEndpoint = URL(string: "https://opencode.ai/console/auth/device/token")!
    static let userEndpoint = URL(string: "https://opencode.ai/console/api/user")!
    /// The workspace's providers and models (`providers.opencode`, `providers["opencode-go"]`, …).
    static let configEndpoint = URL(string: "https://opencode.ai/console/api/v2/config")!
    /// The Console page for keys, billing, subscriptions and usage.
    static let consoleURL = URL(string: "https://opencode.ai/console")!
    /// Our own client id. The docs invite other CLIs to use the flow with their own id; the Console accepts any id here
    /// (checked live: `strata` gets a code, while `opencode-cli` is refused for this app). Kept from before the app was
    /// named OpenChat: the refresh grant sends it too, so a new id could strand every existing sign-in. Only the client
    /// name below says OpenChat.
    static let clientID = "strata"
    /// Sent as `x-opencode-client` (Go asks clients to name themselves).
    static let clientName = "openchat"
    /// The product part of the User-Agent: the app's name, not a generic HTTP library's.
    static let productName = "OpenChat"
    /// models.dev: per-model API family (`provider.npm`), limits, modalities and reasoning options. The opencode CLI and
    /// the docs' model tables come from it; the gateways' own `/models` lists only ids.
    static let metadataURL = URL(string: "https://models.dev/api.json")!

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        #if os(macOS)
        return "\(productName)/\(version) (macOS)"
        #else
        return "\(productName)/\(version) (iOS)"
        #endif
    }

    /// The `device_code` request. `supports_org_scope` binds the token to the workspace picked on the approval page, so
    /// no `x-org-id` header is needed later.
    static func deviceCodeRequestBody() -> Data {
        json(["client_id": clientID, "supports_org_scope": true])
    }

    static func pollRequestBody(deviceCode: String) -> Data {
        json(["grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": deviceCode, "client_id": clientID])
    }

    static func refreshRequestBody(refreshToken: String) -> Data {
        json(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID])
    }

    /// A JSON `POST` to the Console.
    static func post(_ url: URL, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// An authenticated `GET` to the Console (user, config).
    static func get(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// The OAuth `error` code of a Console error body (`{"_tag": "DeviceTokenError", "error": "authorization_pending"}`).
    static func errorCode(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["error"] as? String
    }
}

// MARK: - Device authorization

/// The Console's answer to a `device_code` request.
struct OpenCodeDeviceCode: Sendable, Equatable {
    var deviceCode: String
    /// What the person types (or sees prefilled) on the approval page, like `ABCD-EFGH`.
    var userCode: String
    /// The approval page with the code filled in.
    var verificationURL: URL
    var expiresAt: Date
    /// Seconds between polls (5 unless the server says otherwise).
    var interval: TimeInterval

    /// Parses the response. `verification_uri_complete` is a path (`/console/device?user_code=…`) resolved against the
    /// Console; only an http(s) result is accepted.
    static func parse(_ data: Data, now: Date) throws -> OpenCodeDeviceCode {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = (root["device_code"] as? String).flatMap(nonEmpty),
              let userCode = (root["user_code"] as? String).flatMap(nonEmpty),
              let verification = ((root["verification_uri_complete"] ?? root["verification_uri"]) as? String).flatMap(nonEmpty),
              let url = URL(string: verification, relativeTo: OpenCodeAPI.consoleServer)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw OpenCodeAuthError.invalidResponse
        }
        let expiresIn = (root["expires_in"] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 600
        let interval = (root["interval"] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 5
        return OpenCodeDeviceCode(deviceCode: deviceCode, userCode: userCode, verificationURL: url,
                                  expiresAt: now.addingTimeInterval(expiresIn), interval: max(1, interval))
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// What one poll of the token endpoint means.
enum OpenCodePollResult: Equatable, Sendable {
    /// Not approved yet: poll again after the interval.
    case pending
    /// Polling too fast: add 5 seconds to the interval (RFC 8628 §3.5), then poll again.
    case slowDown
    /// The code expired (or the server no longer knows it): start over.
    case expired
    /// The person declined on the approval page.
    case denied
    case success(OpenCodeTokenResponse)
    /// Any other error code, or an unreadable answer.
    case failure(status: Int, code: String?)

    static func parse(status: Int, data: Data) -> OpenCodePollResult {
        if (200..<300).contains(status), let response = try? JSONDecoder().decode(OpenCodeTokenResponse.self, from: data),
           response.isUsable {
            return .success(response)
        }
        switch OpenCodeAPI.errorCode(data) {
        case "authorization_pending"?: return .pending
        case "slow_down"?: return .slowDown
        case "expired_token"?, "invalid_grant"?: return .expired
        case "access_denied"?: return .denied
        case let code: return .failure(status: status, code: code)
        }
    }
}

// MARK: - Tokens

/// The token endpoint's answer to a device-code exchange or a refresh.
struct OpenCodeTokenResponse: Decodable, Sendable, Equatable {
    var accessToken: String?
    var refreshToken: String?
    var expiresIn: Double?
    /// The workspace the token is bound to (with `supports_org_scope`).
    var orgID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", orgID = "org_id"
    }

    var isUsable: Bool { !(accessToken ?? "").isEmpty }

    /// The session, checked. A refresh may leave out the refresh token (the old one then stays) and the org.
    func session(receivedAt now: Date, previous: OpenCodeSession? = nil) throws -> OpenCodeSession {
        guard let accessToken, !accessToken.isEmpty,
              let refresh = refreshToken.flatMap({ $0.isEmpty ? nil : $0 }) ?? previous?.refreshToken else {
            throw OpenCodeAuthError.invalidResponse
        }
        // The docs give no lifetime; an hour (what the opencode CLI assumes) when the response has none.
        let lifetime = expiresIn.flatMap { $0 > 0 ? $0 : nil } ?? 3600
        return OpenCodeSession(accessToken: accessToken, refreshToken: refresh, expiresAt: now.addingTimeInterval(lifetime),
                               savedAt: now, orgID: orgID ?? previous?.orgID, email: previous?.email)
    }
}

/// One Console sign-in. Kept in the Keychain only; never logged.
struct OpenCodeSession: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var savedAt: Date
    var orgID: String?
    /// The account's email, for Settings (from `GET /api/user`, when it answers).
    var email: String?

    /// How long before expiry a request refreshes first.
    static let refreshLeeway: TimeInterval = 5 * 60

    func needsRefresh(now: Date) -> Bool { now >= expiresAt.addingTimeInterval(-Self.refreshLeeway) }
}

// MARK: - Errors

enum OpenCodeAuthError: Error, LocalizedError, Equatable {
    case denied
    case expired
    case invalidResponse
    case signInRequired
    /// The refresh token can no longer be used (expired, revoked or reused); the session was cleared.
    case sessionExpired
    /// The gateway refused the saved API key.
    case invalidAPIKey
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .denied: String(localized: "Sign-in was declined on the OpenCode page. You can try again when you are ready.")
        case .expired: String(localized: "The sign-in code expired. Start sign-in again.")
        case .invalidResponse: String(localized: "OpenCode returned an unexpected answer. Try signing in again.")
        case .signInRequired: String(localized: "Sign in with OpenCode in Settings.")
        case .sessionExpired: String(localized: "Your OpenCode session has ended. Sign in again in Settings.")
        case .invalidAPIKey: String(localized: "OpenCode didn't accept the API key. Enter a valid key in Settings.")
        case .cancelled: String(localized: "Sign-in was cancelled.")
        case .failed(let detail): String(localized: "OpenCode sign-in failed (\(detail)).")
        }
    }
}
