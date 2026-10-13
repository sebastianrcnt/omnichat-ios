import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Design tokens. Feature views read these instead of hardcoding colors, fonts, paddings or animations.
enum DS {
    // MARK: Spacing
    enum Spacing {
        static let xxs: CGFloat = 2
        /// Between items of a list in an answer.
        static let listItem: CGFloat = 6
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
        static let ring: CGFloat = 22
        /// Site icon in a source chip.
        static let favicon: CGFloat = 16
        static let ringStroke: CGFloat = 3
        static let thumbnail: CGFloat = 64
        static let cameraTile: CGFloat = 112
    }

    // MARK: Typography roles
    /// Pretendard (SIL OFL 1.1), the variable font, registered through `UIAppFonts`. Every text role below uses it;
    /// only code stays in the system monospaced face. Sizes are the system text styles' sizes at the default Dynamic
    /// Type setting, and scale with it.
    enum Typography {
        /// Family name of the bundled variable font. `Font.weight` selects the weight on it.
        static let family = "Pretendard Variable"
        /// PostScript name, for `UIFont(name:)`.
        static let regularFontName = "PretendardVariable-Regular"

        static func pretendard(_ size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
            Font.custom(family, size: size, relativeTo: style).weight(weight)
        }

        /// Answer body.
        static let answer = pretendard(17, relativeTo: .body)
        static let answerEmphasis = pretendard(17, relativeTo: .body, weight: .semibold)
        /// UI sans for controls and chrome.
        static let ui = pretendard(17, relativeTo: .body)
        static let uiEmphasis = pretendard(17, relativeTo: .body, weight: .medium)
        static let uiSmall = pretendard(15, relativeTo: .subheadline)
        /// Composer chip label (does not scale: the composer's row has a fixed height).
        static let chip = Font.custom(family, fixedSize: 15)
        static let uiCaption = pretendard(12, relativeTo: .caption)
        /// Initial in a monogram disc (the favicon fallback).
        static let monogram = Font.custom(family, fixedSize: 10).weight(.bold)
        static let sectionHeader = pretendard(13, relativeTo: .footnote, weight: .medium)
        static let title = pretendard(17, relativeTo: .headline, weight: .semibold)
        static let largeTitle = pretendard(22, relativeTo: .title2, weight: .medium)
        /// Inline citation chip text.
        static let chipInline = pretendard(12, relativeTo: .caption, weight: .medium)
        /// Citation chip inside a table cell: smaller, so a chip does not widen its column much.
        static let chipCompact = pretendard(11, relativeTo: .caption2, weight: .medium)
        /// Table cells in an answer, and the header row.
        static let tableCell = pretendard(15, relativeTo: .subheadline)
        static let tableHeader = pretendard(15, relativeTo: .subheadline, weight: .semibold)
        /// Headings inside an answer.
        static func heading(_ level: Int) -> Font {
            switch level {
            case 1: pretendard(22, relativeTo: .title2, weight: .semibold)
            case 2: pretendard(20, relativeTo: .title3, weight: .semibold)
            default: pretendard(17, relativeTo: .headline, weight: .semibold)
            }
        }
        /// Code and raw thinking.
        static let mono = Font.system(.callout, design: .monospaced)
        static let monoSmall = Font.system(.footnote, design: .monospaced)
    }

    /// Navigation bar titles and bar buttons are UIKit text: give them Pretendard too. (A Mac window title is the system's.)
    @MainActor
    static func applyBarAppearance() {
        #if canImport(UIKit)
        func font(_ name: String, _ size: CGFloat) -> UIFont { UIFont(name: name, size: size) ?? .systemFont(ofSize: size) }
        UINavigationBar.appearance().titleTextAttributes = [.font: font("PretendardVariable-SemiBold", 17)]
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: font("PretendardVariable-Bold", 30)]
        let button = [NSAttributedString.Key.font: font("PretendardVariable-Medium", 17)]
        for state in [UIControl.State.normal, .highlighted, .disabled] {
            UIBarButtonItem.appearance().setTitleTextAttributes(button, for: state)
        }
        #endif
    }

    /// How much larger than the default (large) size text is at `size`: the system's body-text sizes divided by 17.
    /// For things that take points, not a text style (MarkdownUI's theme, the code viewer).
    static func typeScale(_ size: DynamicTypeSize) -> CGFloat {
        let body: CGFloat
        switch size {
        case .xSmall: body = 14
        case .small: body = 15
        case .medium: body = 16
        case .large: body = 17
        case .xLarge: body = 19
        case .xxLarge: body = 21
        case .xxxLarge: body = 23
        case .accessibility1: body = 28
        case .accessibility2: body = 33
        case .accessibility3: body = 40
        case .accessibility4: body = 47
        case .accessibility5: body = 53
        @unknown default: body = 17
        }
        return body / 17
    }

    /// Line height as a multiple of the font size: Pretendard's own line height is tight (about 1.2), so the gap is
    /// derived from the font's metrics at the size on screen.
    struct Leading: Equatable, Sendable {
        var multiple: CGFloat
        var size: CGFloat
        var style: Font.TextStyle

        /// Answer body.
        static let answer = Leading(multiple: 1.65, size: 17, style: .body)
        /// Controls, rows, sheets.
        static let ui = Leading(multiple: 1.4, size: 17, style: .body)
        /// Thinking cards and timeline text (15 pt).
        static let thinking = Leading(multiple: 1.55, size: 15, style: .subheadline)
        static func heading(_ level: Int) -> Leading {
            switch level {
            case 1: Leading(multiple: 1.4, size: 22, style: .title2)
            case 2: Leading(multiple: 1.4, size: 20, style: .title3)
            default: Leading(multiple: 1.45, size: 17, style: .headline)
            }
        }

        /// The extra space between lines, in points, for a font drawn at `size`.
        static func spacing(multiple: CGFloat, size: CGFloat) -> CGFloat {
            #if canImport(UIKit)
            let lineHeight = UIFont(name: Typography.regularFontName, size: size)?.lineHeight ?? size * 1.2
            #else
            let lineHeight = NSFont(name: Typography.regularFontName, size: size).map { $0.ascender - $0.descender + $0.leading } ?? size * 1.2
            #endif
            return max(0, multiple * size - lineHeight)
        }

        /// The same gap as a fraction of the font size (it does not change with the size), for MarkdownUI.
        var em: CGFloat { max(0, Self.spacing(multiple: multiple, size: 100) / 100) }
    }

    /// Space between blocks of an answer (paragraphs, lists, code), a little more than the old 12 since lines are looser.
    static let blockSpacing: CGFloat = 16

    // MARK: Motion
    enum Motion {
        static let fast: Double = 0.15
        static let standard: Double = 0.25
        static let slow: Double = 0.4
        static let spring = Animation.spring(response: 0.35, dampingFraction: 0.86)
        static let snappy = Animation.snappy(duration: 0.25)
        static let ease = Animation.easeInOut(duration: standard)
        /// A block entering or leaving the transcript or a sheet: a spring with no bounce, about 0.35 s.
        static let enter = Animation.spring(duration: 0.35, bounce: 0)
        /// Delay between consecutive children (chips, list items) fading in.
        static let stagger: Double = 0.035
        /// Following the bottom while content grows.
        static let follow = Animation.smooth(duration: 0.25)
        /// Minimum time between animated follow-scrolls while streaming.
        static let followInterval: Duration = .milliseconds(100)
        static let indicatorPulse = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)
    }
}

// MARK: - Adaptive colors

extension Color {
    /// Color that switches between a light and a dark value.
    init(light: UInt32, dark: UInt32) {
        func color(_ v: UInt32) -> PlatformColor {
            PlatformColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                          blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        #if canImport(UIKit)
        self = Color(UIColor { traits in color(traits.userInterfaceStyle == .dark ? dark : light) })
        #else
        self = Color(nsColor: NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
        #endif
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
        let base = PlatformColor(accent)
        func tinted(_ base: PlatformColor, dark: Bool) -> PlatformColor {
            let (r, g, b, _) = base.rgbaComponents
            let t: CGFloat = dark ? 0.45 : 0.5          // blend toward white (dark) or black (light)
            let target: CGFloat = dark ? 1 : 0
            return PlatformColor(red: r + (target - r) * t, green: g + (target - g) * t, blue: b + (target - b) * t, alpha: 1)
        }
        #if canImport(UIKit)
        return Color(UIColor { trait in
            tinted(base.resolvedColor(with: trait), dark: trait.userInterfaceStyle == .dark)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            tinted(base, dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        })
        #endif
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

// MARK: - Line spacing

/// Sets the line spacing for a role at the text size on screen (Dynamic Type included).
private struct LeadingModifier: ViewModifier {
    let leading: DS.Leading
    @ScaledMetric private var size: CGFloat

    init(_ leading: DS.Leading) {
        self.leading = leading
        _size = ScaledMetric(wrappedValue: leading.size, relativeTo: leading.style)
    }

    func body(content: Content) -> some View {
        content.lineSpacing(DS.Leading.spacing(multiple: leading.multiple, size: size))
    }
}

extension View {
    /// Line height for a text role: `.dsLeading(.answer)`.
    func dsLeading(_ leading: DS.Leading) -> some View { modifier(LeadingModifier(leading)) }
}

/// Forces a Dynamic Type size on the whole app when the person chose one in Settings; otherwise the system decides.
/// The size is set in the SwiftUI environment at the root and as a trait override on the app's windows, because a sheet
/// is a separate hosting controller that takes its size from the window, not from the view that presented it.
struct TextSizeOverride: ViewModifier {
    let size: DynamicTypeSize?

    /// Every size, so `.dynamicTypeSize(range)` leaves the system's size alone.
    private static let anySize = DynamicTypeSize.xSmall...DynamicTypeSize.accessibility5

    /// One modifier either way (a range of one size forces it, the full range changes nothing), so the app's view
    /// identity does not change when the setting does.
    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content
            .dynamicTypeSize(size.map { $0...$0 } ?? Self.anySize)
            .onChange(of: size, initial: true) { _, new in Self.applyToWindows(new) }
        #else
        content.dynamicTypeSize(size.map { $0...$0 } ?? Self.anySize)
        #endif
    }

    #if canImport(UIKit)

    static func contentSizeCategory(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }

    /// Writes only what differs, so a launch with the system size, or an unchanged size, does not invalidate any window's traits.
    @MainActor
    static func applyToWindows(_ size: DynamicTypeSize?) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let size {
                    let category = contentSizeCategory(size)
                    // Reading an override that was never set is an assertion failure, so check `contains` first.
                    if !window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self)
                        || window.traitOverrides.preferredContentSizeCategory != category {
                        window.traitOverrides.preferredContentSizeCategory = category
                    }
                } else if window.traitOverrides.contains(UITraitPreferredContentSizeCategory.self) {
                    window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
                }
            }
        }
    }
    #endif
}
