import Testing
import Foundation
@testable import Strata

// `FakeAuthHTTP` and `FakeClock` come from ChatGPTAuthTests.swift.

private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

private func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
}

/// Records each wait and moves the clock by it, so polling runs instantly.
final class FakeSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var waits: [Duration] = []
    let clock: FakeClock
    var cancelAfter: Int?

    init(clock: FakeClock) { self.clock = clock }

    func sleep(_ duration: Duration) async throws {
        let count = lock.withLock { waits.append(duration); return waits.count }
        if let cancelAfter, count > cancelAfter { throw CancellationError() }
        clock.advance(Double(duration.components.seconds))
    }
}

private func device(_ clock: FakeClock, expiresIn: TimeInterval = 600) -> OpenCodeDeviceCode {
    OpenCodeDeviceCode(deviceCode: "dev-1", userCode: "ABCD-EFGH",
                       verificationURL: URL(string: "https://opencode.ai/console/device?user_code=ABCD-EFGH")!,
                       expiresAt: clock.now.addingTimeInterval(expiresIn), interval: 5)
}

// MARK: - Device authorization

struct OpenCodeDeviceFlowTests {
    @Test func deviceCodeRequestUsesOurClientAndOrgScope() {
        let request = OpenCodeAPI.post(OpenCodeAPI.deviceCodeEndpoint, body: OpenCodeAPI.deviceCodeRequestBody())
        #expect(request.url?.absoluteString == "https://opencode.ai/console/auth/device/code")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("OpenChat/") == true)
        let sent = body(request)
        #expect(sent["client_id"] as? String == "strata")
        #expect(sent["supports_org_scope"] as? Bool == true)
    }

    @Test func pollAndRefreshBodies() throws {
        let poll = try JSONSerialization.jsonObject(with: OpenCodeAPI.pollRequestBody(deviceCode: "d")) as! [String: String]
        #expect(poll == ["grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": "d", "client_id": "strata"])
        let refresh = try JSONSerialization.jsonObject(with: OpenCodeAPI.refreshRequestBody(refreshToken: "r")) as! [String: String]
        #expect(refresh == ["grant_type": "refresh_token", "refresh_token": "r", "client_id": "strata"])
    }

    /// The live response shape (values replaced): a relative verification path, 600 s, every 5 s.
    @Test func parsesDeviceCodeAndResolvesTheVerificationPath() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let data = json(["device_code": "0abcdefghij", "user_code": "WXYZ-ABCD", "verification_uri": "/console/device",
                         "verification_uri_complete": "/console/device?user_code=WXYZ-ABCD", "expires_in": 600, "interval": 5])
        let code = try OpenCodeDeviceCode.parse(data, now: now)
        #expect(code.userCode == "WXYZ-ABCD")
        #expect(code.verificationURL.absoluteString == "https://opencode.ai/console/device?user_code=WXYZ-ABCD")
        #expect(code.expiresAt == now.addingTimeInterval(600))
        #expect(code.interval == 5)

        let absolute = try OpenCodeDeviceCode.parse(json(["device_code": "d", "user_code": "U",
                                                          "verification_uri_complete": "https://example.test/x"]), now: now)
        #expect(absolute.verificationURL.absoluteString == "https://example.test/x")
        #expect(absolute.interval == 5 && absolute.expiresAt == now.addingTimeInterval(600)) // defaults
        #expect(throws: OpenCodeAuthError.invalidResponse) {
            try OpenCodeDeviceCode.parse(json(["device_code": "d", "user_code": "U", "verification_uri_complete": "javascript:alert(1)"]), now: now)
        }
        #expect(throws: OpenCodeAuthError.invalidResponse) {
            try OpenCodeDeviceCode.parse(json(["_tag": "DeviceAuthFailed", "message": "Device authorization failed"]), now: now)
        }
    }

    @Test func pollResults() {
        func error(_ code: String) -> Data { json(["_tag": "DeviceTokenError", "error": code, "error_description": "…"]) }
        #expect(OpenCodePollResult.parse(status: 400, data: error("authorization_pending")) == .pending)
        #expect(OpenCodePollResult.parse(status: 400, data: error("slow_down")) == .slowDown)
        #expect(OpenCodePollResult.parse(status: 400, data: error("expired_token")) == .expired)
        #expect(OpenCodePollResult.parse(status: 400, data: error("invalid_grant")) == .expired)
        #expect(OpenCodePollResult.parse(status: 400, data: error("access_denied")) == .denied)
        #expect(OpenCodePollResult.parse(status: 400, data: error("invalid_client")) == .failure(status: 400, code: "invalid_client"))
        #expect(OpenCodePollResult.parse(status: 502, data: Data("bad gateway".utf8)) == .failure(status: 502, code: nil))
        let ok = OpenCodePollResult.parse(status: 200, data: json(["access_token": "a", "refresh_token": "r", "expires_in": 3600, "org_id": "org_1"]))
        #expect(ok == .success(OpenCodeTokenResponse(accessToken: "a", refreshToken: "r", expiresIn: 3600, orgID: "org_1")))
    }

    /// pending → slow_down (+5 s) → approved: the session is saved with the account's email.
    @Test func pollsUntilApprovedAndSlowsDownWhenAsked() async throws {
        let clock = FakeClock()
        let sleeper = FakeSleeper(clock: clock)
        let replies = Replies([
            (json(["error": "authorization_pending"]), 400),
            (json(["error": "slow_down"]), 400),
            (json(["error": "authorization_pending"]), 400),
            (json(["access_token": "acc", "refresh_token": "ref", "expires_in": 3600, "org_id": "org_1"]), 200),
        ])
        let http = FakeAuthHTTP { request in
            if request.url?.path == "/console/api/user" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer acc")
                return (json(["id": "u1", "email": "me@example.com"]), 200)
            }
            return replies.next()
        }
        let auth = OpenCodeAuth(store: .inMemory(), http: http, now: { clock.now }, sleep: sleeper.sleep)
        let id = UUID()
        let session = try await auth.completeSignIn(connectionID: id, device: device(clock))
        #expect(session.accessToken == "acc" && session.refreshToken == "ref" && session.orgID == "org_1")
        #expect(session.email == "me@example.com")
        #expect(auth.store.session(id) == session)
        #expect(sleeper.waits == [.seconds(5), .seconds(5), .seconds(10), .seconds(10)])
        let polls = http.requests.filter { $0.url?.path == "/console/auth/device/token" }
        #expect(polls.count == 4)
        #expect(body(polls[0])["device_code"] as? String == "dev-1")
    }

    @Test func deniedAndFailedPollsSaveNothing() async {
        let clock = FakeClock()
        let id = UUID()
        let denied = OpenCodeAuth(store: .inMemory(), http: FakeAuthHTTP { _ in (json(["error": "access_denied"]), 400) },
                                  now: { clock.now }, sleep: FakeSleeper(clock: clock).sleep)
        await #expect(throws: OpenCodeAuthError.denied) { try await denied.completeSignIn(connectionID: id, device: device(clock)) }
        #expect(denied.store.session(id) == nil)

        let failing = OpenCodeAuth(store: .inMemory(), http: FakeAuthHTTP { _ in (json(["error": "invalid_client"]), 400) },
                                   now: { clock.now }, sleep: FakeSleeper(clock: clock).sleep)
        await #expect(throws: OpenCodeAuthError.failed("invalid_client")) {
            try await failing.completeSignIn(connectionID: id, device: device(clock))
        }
    }

    @Test func expiresWhenTheServerSaysOrTheCodeRunsOut() async {
        let clock = FakeClock()
        let id = UUID()
        let server = OpenCodeAuth(store: .inMemory(), http: FakeAuthHTTP { _ in (json(["error": "expired_token"]), 400) },
                                  now: { clock.now }, sleep: FakeSleeper(clock: clock).sleep)
        await #expect(throws: OpenCodeAuthError.expired) { try await server.completeSignIn(connectionID: id, device: device(clock)) }

        // Pending for longer than the code lives: polling stops at its expiry without asking forever.
        let http = FakeAuthHTTP { _ in (json(["error": "authorization_pending"]), 400) }
        let pending = OpenCodeAuth(store: .inMemory(), http: http, now: { clock.now }, sleep: FakeSleeper(clock: clock).sleep)
        await #expect(throws: OpenCodeAuthError.expired) {
            try await pending.completeSignIn(connectionID: id, device: device(clock, expiresIn: 30))
        }
        #expect(http.count == 6)
    }

    @Test func cancellingStopsPolling() async {
        let clock = FakeClock()
        let sleeper = FakeSleeper(clock: clock)
        sleeper.cancelAfter = 2
        let http = FakeAuthHTTP { _ in (json(["error": "authorization_pending"]), 400) }
        let auth = OpenCodeAuth(store: .inMemory(), http: http, now: { clock.now }, sleep: sleeper.sleep)
        await #expect(throws: OpenCodeAuthError.cancelled) { try await auth.completeSignIn(connectionID: UUID(), device: device(clock)) }
        #expect(http.count == 2)
    }

    /// Cancelled after approval, while the account email is fetched: no session is saved, and a key entered
    /// meanwhile stays.
    @Test func cancellingDuringTheLastStepSavesNothing() async throws {
        let clock = FakeClock()
        let http = FakeAuthHTTP { request in
            if request.url?.path == "/console/api/user" {
                withUnsafeCurrentTask { $0?.cancel() } // the user taps Cancel now
                return (json(["id": "u1", "email": "me@example.com"]), 200)
            }
            return (json(["access_token": "acc", "refresh_token": "ref", "expires_in": 3600]), 200)
        }
        let auth = OpenCodeAuth(store: .inMemory(), http: http, now: { clock.now }, sleep: FakeSleeper(clock: clock).sleep)
        let id = UUID()
        try auth.saveAPIKey("sk-entered-meanwhile", connectionID: id)
        await #expect(throws: OpenCodeAuthError.cancelled) { try await auth.completeSignIn(connectionID: id, device: device(clock)) }
        #expect(auth.store.session(id) == nil)
        #expect(auth.store.apiKey(id) == "sk-entered-meanwhile")
    }

    @Test func requestDeviceCodeReportsTheServerTag() async throws {
        let refused = OpenCodeAuth(store: .inMemory(), http: FakeAuthHTTP { _ in
            (json(["_tag": "DeviceAuthFailed", "message": "Device authorization failed"]), 400)
        })
        await #expect(throws: OpenCodeAuthError.failed("DeviceAuthFailed")) { try await refused.requestDeviceCode() }

        let ok = OpenCodeAuth(store: .inMemory(), http: FakeAuthHTTP { _ in
            (json(["device_code": "d", "user_code": "ABCD-EFGH", "verification_uri_complete": "/console/device?user_code=ABCD-EFGH",
                   "expires_in": 600, "interval": 5]), 200)
        })
        #expect(try await ok.requestDeviceCode().userCode == "ABCD-EFGH")
    }
}

/// Answers in order; the last one repeats.
final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(Data, Int)]
    init(_ list: [(Data, Int)]) { self.list = list }
    func next() -> (Data, Int) { lock.withLock { list.count > 1 ? list.removeFirst() : list[0] } }
}

// MARK: - Tokens

struct OpenCodeTokenTests {
    private func session(expiresIn: TimeInterval, from clock: FakeClock, access: String = "old", refresh: String = "r1") -> OpenCodeSession {
        OpenCodeSession(accessToken: access, refreshToken: refresh, expiresAt: clock.now.addingTimeInterval(expiresIn),
                        savedAt: clock.now, orgID: "org_1", email: "me@example.com")
    }

    @Test func usesTheTokenUntilCloseToExpiryThenRefreshes() async throws {
        let clock = FakeClock()
        let http = FakeAuthHTTP { _ in (json(["access_token": "new", "refresh_token": "r2", "expires_in": 3600]), 200) }
        let auth = OpenCodeAuth(store: .inMemory(), http: http, now: { clock.now })
        let id = UUID()
        try auth.store.setSession(session(expiresIn: 3600, from: clock), id)

        #expect(try await auth.accessToken(connectionID: id) == "old")
        #expect(http.count == 0)

        clock.advance(3600 - 60) // inside the 5-minute leeway
        #expect(try await auth.accessToken(connectionID: id) == "new")
        #expect(http.count == 1)
        let sent = body(http.requests[0])
        #expect(sent["grant_type"] as? String == "refresh_token" && sent["refresh_token"] as? String == "r1")
        #expect(sent["client_id"] as? String == "strata")
        let saved = try #require(auth.store.session(id))
        #expect(saved.refreshToken == "r2" && saved.expiresAt == clock.now.addingTimeInterval(3600))
        #expect(saved.orgID == "org_1" && saved.email == "me@example.com") // kept across the refresh
    }

    @Test func refreshWithoutANewRefreshTokenKeepsTheOld() async throws {
        let clock = FakeClock()
        let auth = OpenCodeAuth(store: .inMemory(), http: FakeAuthHTTP { _ in (json(["access_token": "new"]), 200) }, now: { clock.now })
        let id = UUID()
        try auth.store.setSession(session(expiresIn: 0, from: clock), id)
        let fresh = try await auth.refresh(id)
        #expect(fresh.accessToken == "new" && fresh.refreshToken == "r1")
        #expect(fresh.expiresAt == clock.now.addingTimeInterval(3600)) // no lifetime given: an hour
    }

    @Test func aDeadRefreshTokenEndsTheSession() async throws {
        let clock = FakeClock()
        let http = FakeAuthHTTP { _ in
            (json(["_tag": "DeviceTokenError", "error": "invalid_grant", "error_description": "The grant is invalid"]), 400)
        }
        let auth = OpenCodeAuth(store: .inMemory(), http: http, now: { clock.now })
        let id = UUID()
        try auth.store.setSession(session(expiresIn: -10, from: clock), id)
        await #expect(throws: OpenCodeAuthError.sessionExpired) { try await auth.accessToken(connectionID: id) }
        #expect(auth.store.session(id) == nil)
    }

    @Test func aServerErrorDuringRefreshKeepsTheSession() async throws {
        let clock = FakeClock()
        let auth = OpenCodeAuth(store: .inMemory(), http: FakeAuthHTTP { _ in (Data("upstream".utf8), 503) }, now: { clock.now })
        let id = UUID()
        try auth.store.setSession(session(expiresIn: -10, from: clock), id)
        await #expect(throws: APIError.self) { try await auth.accessToken(connectionID: id) }
        #expect(auth.store.session(id) != nil)
    }

    /// Refresh tokens work once: concurrent callers share a single refresh.
    @Test func concurrentRefreshesShareOneRequest() async throws {
        let clock = FakeClock()
        let http = FakeAuthHTTP { _ in (json(["access_token": "new", "refresh_token": "r2", "expires_in": 3600]), 200) }
        http.delay = .milliseconds(50)
        let auth = OpenCodeAuth(store: .inMemory(), http: http, now: { clock.now })
        let id = UUID()
        try auth.store.setSession(session(expiresIn: 0, from: clock), id)
        async let a = auth.accessToken(connectionID: id)
        async let b = auth.accessToken(connectionID: id)
        async let c = auth.tokenAfterRejection(connectionID: id, rejected: "old")
        let tokens = try await [a, b, c]
        #expect(tokens == ["new", "new", "new"])
        #expect(http.count == 1)
    }

    @Test func aRejectionRefreshesOnlyTheRejectedToken() async throws {
        let clock = FakeClock()
        let http = FakeAuthHTTP { _ in (json(["access_token": "new", "refresh_token": "r2", "expires_in": 3600]), 200) }
        let auth = OpenCodeAuth(store: .inMemory(), http: http, now: { clock.now })
        let id = UUID()
        try auth.store.setSession(session(expiresIn: 3600, from: clock, access: "current"), id)
        // Another request already got a newer token: no refresh.
        #expect(try await auth.tokenAfterRejection(connectionID: id, rejected: "stale") == "current")
        #expect(http.count == 0)
        #expect(try await auth.tokenAfterRejection(connectionID: id, rejected: "current") == "new")
        #expect(http.count == 1)
    }

    @Test func anAPIKeyIsUsedAsIsAndNeverRefreshed() async throws {
        let http = FakeAuthHTTP { _ in (Data(), 500) }
        let auth = OpenCodeAuth(store: .inMemory(), http: http)
        let id = UUID()
        await #expect(throws: OpenCodeAuthError.signInRequired) { try await auth.accessToken(connectionID: id) }
        try auth.saveAPIKey("  oc_sk_test  ", connectionID: id)
        #expect(try await auth.accessToken(connectionID: id) == "oc_sk_test")
        await #expect(throws: OpenCodeAuthError.invalidAPIKey) {
            try await auth.tokenAfterRejection(connectionID: id, rejected: "oc_sk_test")
        }
        #expect(http.count == 0)
    }

    @Test func aKeyAndASignInReplaceEachOther() throws {
        let store = OpenCodeCredentialStore.inMemory()
        let id = UUID()
        let clock = FakeClock()
        try store.setSession(session(expiresIn: 3600, from: clock), id)
        try store.setAPIKey("oc_sk_x", id)
        #expect(store.session(id) == nil && store.apiKey(id) == "oc_sk_x")
        try store.setSession(session(expiresIn: 3600, from: clock), id)
        #expect(store.apiKey(id) == nil && store.session(id) != nil)
        #expect(store.hasCredential(id))
        store.removeAll(id)
        #expect(!store.hasCredential(id))
    }

    @Test func signOutForgetsEverything() async throws {
        let auth = OpenCodeAuth(store: .inMemory(), http: FakeAuthHTTP { _ in (Data(), 500) })
        let id = UUID()
        try auth.saveAPIKey("oc_sk_x", connectionID: id)
        await auth.signOut(connectionID: id)
        #expect(!auth.store.hasCredential(id))
    }

    @Test func goIsDetectedFromTheWorkspaceConfig() async throws {
        let config = json(["providers": ["opencode": ["name": "OpenCode"], "opencode-go": ["name": "OpenCode Go"]]])
        let http = FakeAuthHTTP { request in
            #expect(request.url?.absoluteString == "https://opencode.ai/console/api/v2/config")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oc_sk_x")
            return (config, 200)
        }
        let auth = OpenCodeAuth(store: .inMemory(), http: http)
        let id = UUID()
        try auth.saveAPIKey("oc_sk_x", connectionID: id)
        #expect(await auth.availableGateways(connectionID: id) == [.go, .console])
        #expect(OpenCodeGateway.available(inConfig: json(["providers": ["opencode": [:]]])) == [.console])
        #expect(OpenCodeGateway.available(inConfig: json(["_tag": "Unauthorized"])) == nil)
    }
}
