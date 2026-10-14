import Foundation
import AuthenticationServices
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Runs one Sign in with ChatGPT attempt for a connection.
///
/// The redirect is an HTTP loopback URI (`http://127.0.0.1:<port>/auth/callback`), which ASWebAuthenticationSession
/// cannot complete by itself: it only finishes on a custom scheme or an associated https domain. So the session is
/// used purely as the browser (it shares Safari's cookies, so an existing ChatGPT login is reused), with a callback
/// scheme that never fires, while an in-app `LoopbackServer` receives the redirect. The app stays in the foreground
/// behind the sheet, so the listener keeps running; when the callback arrives the listener answers it with a short
/// page and the session is cancelled, which closes the sheet.
@MainActor
final class ChatGPTSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let connectionID: UUID
    private let auth: ChatGPTAuth
    private var session: ASWebAuthenticationSession?
    private var server: LoopbackServer?

    init(connectionID: UUID, auth: ChatGPTAuth = .shared) {
        self.connectionID = connectionID
        self.auth = auth
    }

    /// Signs in (or back in) and returns the validated registration. Throws `ChatGPTAuthError.cancelled` when the user
    /// closes the sheet.
    func run() async throws -> ChatGPTRegistration {
        let store = auth.store
        let registration = store.registration(connectionID)
        let hostID = store.hostIDStore.hostID()

        // The attempt needs the port, and the listener's reply needs the attempt: the box is filled before the browser
        // opens, so every request sees it.
        let box = AttemptBox()
        let server = LoopbackServer { url in
            guard let attempt = box.attempt else { return .init(status: 404, html: "Not found", finishes: false) }
            switch ChatGPTOAuth.parseCallback(url, attempt: attempt) {
            case .ignored:
                return .init(status: 400, html: LoopbackServer.page(title: "Sign-in not recognized",
                                                                   message: "Return to Strata and start sign-in again."),
                             finishes: false)
            case .success:
                return .init(status: 200, html: LoopbackServer.page(title: "Signed in",
                                                                   message: "You can close this page and return to Strata."),
                             finishes: true)
            case .failure:
                return .init(status: 200, html: LoopbackServer.page(title: "Sign-in not completed",
                                                                   message: "You can close this page and return to Strata."),
                             finishes: true)
            }
        }
        self.server = server
        defer { server.stop(); self.server = nil }
        let port = try await server.start()
        let attempt = ChatGPTOAuth.Attempt.make(port: port, hostID: hostID, savedClientID: registration?.clientID,
                                                loginHint: registration?.email)
        box.attempt = attempt

        let callbackURL = try await waitForCallback(url: attempt.authorizationURL, server: server)
        switch ChatGPTOAuth.parseCallback(callbackURL, attempt: attempt) {
        case .ignored: throw ChatGPTAuthError.registrationIncomplete
        case .failure(let error): throw error
        case .success(let code, let clientID):
            try await auth.saveIssuedClientID(clientID, connectionID: connectionID)
            return try await auth.completeSignIn(connectionID: connectionID, attempt: attempt, code: code, clientID: clientID)
        }
    }

    /// Opens the sign-in page and waits for the loopback callback, or for the user to close the sheet.
    private func waitForCallback(url: URL, server: LoopbackServer) async throws -> URL {
        try await withThrowingTaskGroup(of: URL?.self) { group in
            group.addTask {
                for await url in server.received { return url }
                return nil
            }
            let closed = AsyncStream<Void>.makeStream()
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("cc.coolservices.strata.siwc")) { _, _ in
                // Only called when the sheet goes away: closed by the user, or cancelled below after the callback.
                closed.continuation.yield()
                closed.continuation.finish()
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false // reuse the browser's ChatGPT login
            self.session = session
            guard session.start() else { throw ChatGPTAuthError.presentationFailed }
            group.addTask {
                for await _ in closed.stream { break }
                // Let a callback that arrived just before the sheet closed win.
                try? await Task.sleep(for: .milliseconds(300))
                return nil
            }
            defer {
                session.cancel()
                self.session = nil
                group.cancelAll()
            }
            while let next = try await group.next() {
                if let url = next { return url }
                throw ChatGPTAuthError.cancelled
            }
            throw ChatGPTAuthError.cancelled
        }
    }

    func cancel() {
        session?.cancel()
        server?.stop()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
            return window ?? ASPresentationAnchor()
            #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

/// The pending attempt, read by the listener's queue and written once on the main actor before the browser opens.
private final class AttemptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChatGPTOAuth.Attempt?
    var attempt: ChatGPTOAuth.Attempt? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
