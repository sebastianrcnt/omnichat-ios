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
        /// Space kept clear above the composer for the jump-to-bottom button.
        static let composerClearance: CGFloat = 150
    }

    // MARK: Corner radii
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
        static let bubble: CGFloat = 22
        static let thumbnail: CGFloat = 12
        static let composer: CGFloat = 26
    }

    // MARK: Icon & control sizes
    enum IconSize {
        static let sm: CGFloat = 14
        static let md: CGFloat = 18
        static let lg: CGFloat = 22
        /// Header circular glass buttons.
        static let controlDiameter: CGFloat = 44
        static let headerIcon: CGFloat = 17
        /// Composer buttons and chip height.
        static let compactControlDiameter: CGFloat = 36
        static let composerIcon: CGFloat = 16
        /// Minimum touch target, kept via `contentShape` even where the visual is smaller.
        static let minHitTarget: CGFloat = 44
        static let ring: CGFloat = 20
        /// Site icon in a source chip.
        static let favicon: CGFloat = 16
        static let ringStroke: CGFloat = 2.5
        static let thumbnail: CGFloat = 64
        static let cameraTile: CGFloat = 112
    }

    // MARK: Typography roles
    enum Typography {
        /// Extra leading for answer and thinking text (about 1.3x to 1.4x line height).
        static let answerLineSpacing: CGFloat = 3
        /// Answer body: serif, as in the reference screenshots.
        static let answer = Font.system(.body, design: .serif)
        static let answerEmphasis = Font.system(.body, design: .serif).weight(.semibold)
        /// UI sans for controls and chrome.
        static let ui = Font.system(.body)
        static let uiEmphasis = Font.system(.body).weight(.medium)
        static let uiSmall = Font.system(.subheadline)
        /// Composer chip label.
        static let chip = Font.system(size: 15)
        static let uiCaption = Font.system(.caption)
        /// Initial in a monogram disc (the favicon fallback).
        static let monogram = Font.system(size: 10, weight: .bold)
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
    /// Accent for small text on `accentMuted`: darkened in light mode, lightened in dark mode so it reads at 4.5:1.
    var accentOnTint: Color {
        let base = UIColor(accent)
        return Color(UIColor { trait in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.resolvedColor(with: trait).getRed(&r, green: &g, blue: &b, alpha: &a)
            let dark = trait.userInterfaceStyle == .dark
            let t: CGFloat = dark ? 0.45 : 0.5          // blend toward white (dark) or black (light)
            let target: CGFloat = dark ? 1 : 0
            return UIColor(red: r + (target - r) * t, green: g + (target - g) * t, blue: b + (target - b) * t, alpha: 1)
        })
    }

    // Surfaces
    var background: Color { Color(light: 0xFFFFFF, dark: 0x121212) }
    var surface: Color { Color(light: 0xF3F3F5, dark: 0x1E1E1E) }
    var surfaceRaised: Color { Color(light: 0xE8E8EC, dark: 0x2A2A2A) }
    var bubble: Color { Color(light: 0xEDEDF0, dark: 0x2B2B2B) }
    var separator: Color { Color(light: 0xD9D9DE, dark: 0x333333) }
    /// Subtle fill for disabled controls.
    /// Capsule behind inline citation chips.
    var chipFill: Color { fillTertiary }
    /// Glyph on an accent-filled control (send, stop, selected swatch).
    var onAccent: Color { .white }
    /// Dark backing for badges drawn over photos.
    var photoBadgeBackdrop: Color { .black.opacity(0.6) }
    /// Light disc behind a site icon so dark glyphs stay visible in dark mode.
    var faviconBackdrop: Color { Color(light: 0xFFFFFF, dark: 0xF2F2F2) }
    var fillTertiary: Color { Color(light: 0xE4E4E8, dark: 0x2E2E32) }

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


// MARK: - Previews

#Preview("Tokens · Light") { TokensPreview().previewStyle(.light) }
#Preview("Tokens · Dark") { TokensPreview().previewStyle(.dark) }
#Preview("Tokens · Dark · Orange") { TokensPreview().previewStyle(.dark, accent: Color(hex: "#F97316")) }

/// Every color role and type role in one place.
private struct TokensPreview: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let colors: [(String, Color)] = [
            ("accent", theme.accent), ("accentMuted", theme.accentMuted), ("accentOnTint", theme.accentOnTint),
            ("background", theme.background), ("surface", theme.surface), ("surfaceRaised", theme.surfaceRaised),
            ("bubble", theme.bubble), ("separator", theme.separator), ("chipFill", theme.chipFill),
            ("textPrimary", theme.textPrimary), ("textSecondary", theme.textSecondary), ("textTertiary", theme.textTertiary),
            ("destructive", theme.destructive), ("warning", theme.warning), ("onAccent", theme.onAccent),
            ("faviconBackdrop", theme.faviconBackdrop),
        ]
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                FlowLayout(spacing: DS.Spacing.sm) {
                    ForEach(colors, id: \.0) { name, color in
                        HStack(spacing: DS.Spacing.xs) {
                            RoundedRectangle(cornerRadius: DS.Radius.thumbnail / 2).fill(color).frame(width: DS.IconSize.md, height: DS.IconSize.md)
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.thumbnail / 2).stroke(theme.separator))
                            Text(name).font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                Text("Answer body, serif").font(DS.Typography.answer).foregroundStyle(theme.textPrimary)
                Text("UI text").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                Text("UI small").font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                Text("Caption").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
                Text("let mono = 1").font(DS.Typography.mono).foregroundStyle(theme.textPrimary)
            }
            .padding()
        }
    }
}
