import Testing
import Foundation
@testable import Strata

/// What OpenAI's Sign in with ChatGPT guidelines and OpenCode's client rules ask of the app: the one-time plan welcome,
/// "Manage usage" first on a usage limit, the app's name toward both services, and no free OpenCode models.
struct PlanUsageTests {
    private func defaults() -> (UserDefaults, String) {
        let suite = "plan.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    // MARK: Welcome

    @Test func welcomeShowsOnceEverPerDevice() throws {
        let (d, suite) = defaults()
        // A sign-in without plan usage leaves the welcome for the first one with it.
        #expect(!ChatGPTPlanUsage.claimWelcome(planAllowed: false, defaults: d))
        #expect(ChatGPTPlanUsage.claimWelcome(planAllowed: true, defaults: d))
        // Later sign-ins (this connection again, or another one) never show it.
        #expect(!ChatGPTPlanUsage.claimWelcome(planAllowed: true, defaults: d))
        #expect(!ChatGPTPlanUsage.claimWelcome(planAllowed: true, defaults: try #require(UserDefaults(suiteName: suite))))
        #expect(d.bool(forKey: ChatGPTPlanUsage.welcomeShownKey))
    }

    // MARK: Usage limits

    @Test func usageLimitsLeadWithManageUsage() {
        let streamed = ResponsesErrorMapper.error(ResponsesErrorBody(code: "subscription_sharing_usage_limit_exceeded",
                                                                     message: "limit"), status: nil)
        let admitted = ResponsesErrorMapper.error(status: 429, data: Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#.utf8))
        for error in [streamed, admitted] {
            #expect(error == .chatGPTUsageLimit)
            #expect(error.managesUsage && !error.needsSettings)
            #expect(error.errorDescription?.hasPrefix("ChatGPT") == true) // the ChatGPT identity stays visible
        }
        #expect(ChatGPTOAuth.usageURL.absoluteString == "https://chatgpt.com/settings/usage")
        // Other ChatGPT errors keep their own actions.
        #expect(!APIError.chatGPTSignInRequired(connection: "ChatGPT").managesUsage)
        #expect(!ResponsesErrorMapper.error(status: 503, data: Data()).managesUsage)
        #expect(!ResponsesErrorMapper.error(ResponsesErrorBody(code: "subscription_sharing_user_not_eligible"), status: 403).managesUsage)
    }

    // MARK: Names

    @Test func servicesSeeTheAppAsOmniChat() throws {
        #expect(ChatGPTOAuth.agentName == "OmniChat")
        let attempt = ChatGPTOAuth.Attempt.make(port: 1455, hostID: "urn:uuid:abc", savedClientID: nil, loginHint: nil)
        #expect(attempt.authorizationURL.absoluteString.contains("agent_name_hint=OmniChat"))

        let agent = OpenCodeAPI.userAgent
        #expect(agent.hasPrefix("OmniChat/"))
        #if os(macOS)
        #expect(agent.hasSuffix(" (macOS)"))
        #else
        #expect(agent.hasSuffix(" (iOS)"))
        #endif
        #expect(OpenCodeAPI.clientName == "omnichat")
        // The OAuth client id stays: refreshing existing sign-ins sends it.
        #expect(OpenCodeAPI.clientID == "strata")
        let refresh = try #require(try JSONSerialization.jsonObject(with: OpenCodeAPI.refreshRequestBody(refreshToken: "r")) as? [String: String])
        #expect(refresh["client_id"] == "strata")
    }

    @MainActor
    @Test func openCodeRequestsNameTheClientAndKeepTheConversationSession() throws {
        let store = ConnectionStore(defaults: defaults().0, keys: InMemoryKeyStore(),
                                    chatGPT: ChatGPTAuth(store: .inMemory()), openCode: OpenCodeAuth(store: .inMemory()))
        let c = Connection.openCode()
        store.upsert(c)
        let conversation = UUID().uuidString
        let first = try #require(store.endpoint(connectionID: c.id, modelID: "glm-5.3", sessionID: conversation))
        let again = try #require(store.endpoint(connectionID: c.id, modelID: "kimi-k3", sessionID: conversation))
        #expect(first.headers["x-opencode-session"] == conversation && again.headers["x-opencode-session"] == conversation)
        #expect(first.headers["x-opencode-client"] == "omnichat")
        #expect(first.headers["User-Agent"] == OpenCodeAPI.userAgent)
    }

    // MARK: OpenCode free models

    private let catalog = Data("""
    {"opencode": {"npm": "@ai-sdk/openai-compatible", "models": {
        "glm-5.3": {"id": "glm-5.3", "cost": {"input": 1.4, "output": 4.4}},
        "minimax-m3.1-flash-free": {"id": "minimax-m3.1-flash-free", "cost": {"input": 0, "output": 0, "cache_read": 0}},
        "big-pickle": {"id": "big-pickle", "cost": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0}},
        "half-price": {"id": "half-price", "cost": {"input": 0, "output": 2}},
        "unpriced": {"id": "unpriced"},
        "gemini-3.7-flash": {"id": "gemini-3.7-flash", "provider": {"npm": "@ai-sdk/google"}, "cost": {"input": 1.5, "output": 7.5}}
    }}}
    """.utf8)

    @Test func freeModelsAreLeftOut() throws {
        let meta = OpenCodeModelsAPI.parseMetadata(catalog, gateway: .console)
        #expect(meta["big-pickle"]?.zeroCost == true && meta["minimax-m3.1-flash-free"]?.zeroCost == true)
        #expect(meta["half-price"]?.zeroCost == false && meta["unpriced"]?.zeroCost == false)

        // The gateway's list, with a free id models.dev doesn't know yet.
        let ids = ["glm-5.3", "minimax-m3.1-flash-free", "big-pickle", "half-price", "unpriced", "gemini-3.7-flash", "Beam-Free"]
        let merged = OpenCodeModelsAPI.merge(ids: ids, metadata: meta, gateway: .console)
        #expect(merged.supported.map(\.id) == ["glm-5.3", "half-price", "unpriced"])
        #expect(merged.free == ["minimax-m3.1-flash-free", "big-pickle", "Beam-Free"])
        #expect(merged.unsupported == ["gemini-3.7-flash"])
        // Without the gateway's list too.
        #expect(!OpenCodeModelsAPI.merge(ids: nil, metadata: meta, gateway: .console).supported.contains { OpenCodeModelsAPI.isFree($0) })
    }

    /// A chat still set to a model that is now hidden keeps working until the gateway answers, which is worded plainly.
    @MainActor
    @Test func aChatOnAHiddenFreeModelStillGetsAnEndpointAndAClearError() throws {
        let store = ConnectionStore(defaults: defaults().0, keys: InMemoryKeyStore(),
                                    chatGPT: ChatGPTAuth(store: .inMemory()), openCode: OpenCodeAuth(store: .inMemory()))
        var c = Connection.openCode(gateway: .console)
        c.models = [ModelInfo(id: "glm-5.3")]
        store.upsert(c)
        let endpoint = try #require(store.endpoint(connectionID: c.id, modelID: "big-pickle", sessionID: "conv"))
        #expect(endpoint.model.id == "big-pickle")
        let refused = OpenCodeErrorMapper.error(status: 401, data: Data(#"{"type":"error","error":{"type":"FreeTierError","message":"x"}}"#.utf8),
                                                gateway: .console)
        #expect(refused.errorDescription?.contains("free models only work in the OpenCode app") == true)
    }

    @Test func fetchFooterSaysFreeModelsAreHidden() {
        let fetch = ConnectionStore.ModelFetch(finished: .now, count: 3, unsupported: 0, free: 2)
        #expect(fetch.footer?.contains("Free models are hidden") == true)
        #expect(ConnectionStore.ModelFetch(finished: .now, count: 3).footer?.contains("Free") == false)
    }
}
