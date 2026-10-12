import SwiftUI
#if canImport(UIKit)
import SafariServices
#else
import AppKit
#endif

/// Every http(s) link in the app opens in an in-app Safari view controller, presented over whatever is
/// on screen (including sheets). Other schemes (mailto:, tel:) go to the system. On a Mac they open in the default browser.
@MainActor
enum InAppBrowser {
    static func isWeb(_ url: URL) -> Bool {
        let s = url.scheme?.lowercased()
        return s == "http" || s == "https"
    }

    #if canImport(UIKit)
    static var tint: UIColor?

    static func present(_ url: URL) {
        guard isWeb(url), let top = topViewController() else { return }
        let vc = SFSafariViewController(url: url)
        vc.view.tintColor = tint
        top.present(vc, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
    #else
    static func present(_ url: URL) {
        guard isWeb(url) else { return }
        NSWorkspace.shared.open(url)
    }
    #endif
}

private struct InAppLinks: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content
            .environment(\.openURL, OpenURLAction { url in
                guard InAppBrowser.isWeb(url) else { return .systemAction }
                InAppBrowser.tint = UIColor(theme.accent)
                InAppBrowser.present(url)
                return .handled
            })
            .onAppear { InAppBrowser.tint = UIColor(theme.accent) }
        #else
        content // links open in the default browser
        #endif
    }
}

extension View {
    /// Routes links to the in-app browser. Apply at the root and on every sheet (sheets can lose the environment).
    func inAppLinks() -> some View { modifier(InAppLinks()) }
}
