import SwiftUI

/// Settings > Appearance > Text size: follow the system, or pick one of seven sizes, with a preview in the real answer styles.
struct TextSizeSection: View {
    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        GroupedSection(header: "Appearance", footer: "Text size changes the whole app. Sizes beyond Largest are available through the system setting.") {
            SettingsToggleRow(title: "Use system size", subtitle: "Follow the text size set in iOS Settings.",
                              isOn: $settings.useSystemTextSize)
            if !settings.useSystemTextSize {
                TextSizeSlider(step: $settings.textSizeStep)
            }
            TextSizePreview()
        }
        .animation(DS.Motion.ease, value: settings.useSystemTextSize)
    }
}

/// Seven steps, a small "A" at one end and a large one at the other. The letters keep their own size.
struct TextSizeSlider: View {
    @Environment(\.theme) private var theme
    @Binding var step: Int

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.md) {
                Text("A").font(Font.custom(DS.Typography.family, fixedSize: 13)).foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
                Slider(value: Binding(get: { Double(step) }, set: { step = TextSizeSetting.clamped(Int($0.rounded())) }),
                       in: 0...Double(TextSizeSetting.sizes.count - 1), step: 1)
                    .tint(theme.accent)
                    .accessibilityLabel(Text("Text size"))
                    .accessibilityValue(Text(TextSizeSetting.label(forStep: step)))
                Text("A").font(Font.custom(DS.Typography.family, fixedSize: 24)).foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(verbatim: TextSizeSetting.label(forStep: step)).font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
    }
}

/// A short answer in the real answer styles: bold, a citation chip, a line of inline code. It scales with the setting.
struct TextSizePreview: View {
    @Environment(\.theme) private var theme

    /// A sample, not UI text: it stays as written whatever the app's language.
    private static let paragraph = "Liquid Glass는 **컨트롤과 내비게이션**에만 쓰세요. Apply it to *controls* and bars, never to body text [1]."
    private static let code = "인접한 컨트롤은 `GlassEffectContainer`로 묶습니다."

    private static let sources = [1: SourceInfo(id: 1, title: "Applying Liquid Glass", url: "https://developer.apple.com/documentation/swiftui",
                                                snippet: "")]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.blockSpacing) {
            InlineMarkdownText(source: Self.paragraph, font: DS.Typography.answer, color: theme.textPrimary)
            InlineMarkdownText(source: Self.code, font: DS.Typography.answer, color: theme.textPrimary)
        }
        .environment(\.citations, CitationContext(sources: Self.sources))
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
