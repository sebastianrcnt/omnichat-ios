import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The app's appearance: as the system is, or always light or dark (Settings > Appearance).
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Applies the appearance to the whole app, sheets and menus included. Set on the windows (iPhone) or the app (Mac)
/// rather than with `preferredColorScheme`, which doesn't let go again when it goes back to the system's.
struct AppearanceApplier: ViewModifier {
    let mode: AppearanceMode

    func body(content: Content) -> some View {
        content.onChange(of: mode, initial: true) { _, mode in Self.apply(mode) }
    }

    @MainActor
    static func apply(_ mode: AppearanceMode) {
        #if os(iOS)
        let style: UIUserInterfaceStyle = switch mode {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
        #else
        NSApp.appearance = switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        #endif
    }
}
