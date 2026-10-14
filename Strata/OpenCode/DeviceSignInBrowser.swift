import AuthenticationServices
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The device-code sign-in page on iOS: an ASWebAuthenticationSession sheet over the app, which shares Safari's
/// cookies (an existing Console login is reused). Device flow has no redirect, so the sheet never ends by itself:
/// `close()` dismisses it once polling sees the approval. Closing it by hand leaves the sign-in waiting.
@MainActor
final class DeviceSignInBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// False when the sheet could not be shown (the caller opens the browser instead).
    func open(_ url: URL) -> Bool {
        close()
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("cc.coolservices.strata.opencode")) { [weak self] _, _ in
            Task { @MainActor in self?.session = nil }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        guard session.start() else {
            self.session = nil
            return false
        }
        return true
    }

    func close() {
        session?.cancel()
        session = nil
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
