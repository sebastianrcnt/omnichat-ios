import SwiftUI
import UIKit

/// Design tokens. Feature views read these instead of hardcoding colors, fonts, paddings or animations.
enum DS {
    // MARK: Spacing
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Horizontal page margin for chat content.
        static let page: CGFloat = 16
    }

    // MARK: Corner radii
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
        static let bubble: CGFloat = 22
        static let thumbnail: CGFloat = 12
    }

    // MARK: Icon & control sizes
    enum IconSize {
        static let sm: CGFloat = 14
        static let md: CGFloat = 18
        static let lg: CGFloat = 22
        static let controlDiameter: CGFloat = 44
        static let compactControlDiameter: CGFloat = 36
        static let ring: CGFloat = 22
        static let thumbnail: CGFloat = 64
        static let cameraTile: CGFloat = 112
    }

    // MARK: Typography roles
    enum Typography {
        /// Answer body: serif, as in the reference screenshots.
        static let answer = Font.system(.body, design: .serif)
        static let answerEmphasis = Font.system(.body, design: .serif).weight(.semibold)
        /// UI sans for controls and chrome.
        static let ui = Font.system(.body)
        static let uiEmphasis = Font.system(.body).weight(.medium)
        static let uiSmall = Font.system(.subheadline)
        static let uiCaption = Font.system(.caption)
        static let sectionHeader = Font.system(.footnote).weight(.medium)
        static let title = Font.system(.headline)
        static let largeTitle = Font.system(.title2, design: .serif).weight(.medium)
        /// Code and raw thinking.
        static let mono = Font.system(.callout, design: .monospaced)
        static let monoSmall = Font.system(.footnote, design: .monospaced)
    }

    // MARK: Motion
    enum Motion {
        static let fast: Double = 0.15
        static let standard: Double = 0.25
        static let slow: Double = 0.4
        static let spring = Animation.spring(response: 0.35, dampingFraction: 0.86)
        static let snappy = Animation.snappy(duration: 0.25)
        static let ease = Animation.easeInOut(duration: standard)
        static let indicatorPulse = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)
    }
}

// MARK: - Adaptive colors

extension Color {
    /// Color that switches between a light and a dark value.
    init(light: UInt32, dark: UInt32) {
        self = Color(UIColor { traits in
            let v = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Color roles derived from the user-selected accent.
struct DSTheme: Equatable {
    var accent: Color

    init(accent: Color = Color(hex: AccentPreset.defaultHex)) { self.accent = accent }

    var accentMuted: Color { accent.opacity(0.16) }
    var accentStrong: Color { accent.opacity(0.9) }

    // Surfaces
    var background: Color { Color(light: 0xFFFFFF, dark: 0x121212) }
    var surface: Color { Color(light: 0xF3F3F5, dark: 0x1E1E1E) }
    var surfaceRaised: Color { Color(light: 0xE8E8EC, dark: 0x2A2A2A) }
    var bubble: Color { Color(light: 0xEDEDF0, dark: 0x2B2B2B) }
    var separator: Color { Color(light: 0xD9D9DE, dark: 0x333333) }

    // Text
    var textPrimary: Color { Color(light: 0x111111, dark: 0xF2F2F2) }
    var textSecondary: Color { Color(light: 0x5E5E66, dark: 0xA3A3AB) }
    var textTertiary: Color { Color(light: 0x8E8E96, dark: 0x6E6E76) }

    // Status
    var destructive: Color { Color(light: 0xD92D20, dark: 0xF16A60) }
    var warning: Color { Color(light: 0xB54708, dark: 0xF5A524) }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = DSTheme() }

extension EnvironmentValues {
    var theme: DSTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Glass styles (controls only)

extension View {
    /// Regular glass on a control, optionally tinted and interactive.
    func glassControl<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
    }

    /// Standard page background from the theme.
    func themedBackground() -> some View { modifier(ThemedBackground()) }
}

private struct ThemedBackground: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content.background(theme.background.ignoresSafeArea())
    }
}

/// Preview helper: applies a color scheme, accent and themed background.
extension View {
    func previewStyle(_ scheme: ColorScheme, accent: Color = Color(hex: AccentPreset.defaultHex)) -> some View {
        self
            .environment(\.theme, DSTheme(accent: accent))
            .tint(accent)
            .preferredColorScheme(scheme)
            .background(DSTheme(accent: accent).background)
    }
}
