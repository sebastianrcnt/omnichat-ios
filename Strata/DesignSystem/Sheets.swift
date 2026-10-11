import SwiftUI

/// Bottom-sheet chrome: a glass close (or back) button, a centered title, optional trailing content.
struct SheetScaffold<Trailing: View, Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    enum Leading { case close, back(() -> Void) }

    let title: LocalizedStringKey
    var leading: Leading = .close
    /// When set, tracks whether the user left the bottom (updated when a user scroll ends).
    var followsBottom: Binding<Bool>?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(DS.Typography.title).foregroundStyle(theme.textPrimary)
                HStack {
                    switch leading {
                    case .close:
                        GlassIconButton(systemName: "xmark", label: "Close") { dismiss() }
                    case .back(let action):
                        GlassIconButton(systemName: "chevron.left", label: "Back", action: action)
                    }
                    Spacer()
                    trailing()
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.top, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.md)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) { content() }
                    .padding(.top, DS.Spacing.sm)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.bottom, DS.Spacing.xl)
            }
            .onScrollPhaseChange { old, new, context in
                // Only a user scroll that just ended decides; programmatic scrolls never unpin.
                guard let followsBottom, new == .idle, old == .interacting || old == .decelerating else { return }
                let g = context.geometry
                followsBottom.wrappedValue = g.visibleRect.maxY >= g.contentSize.height - 40
            }
        }
        .background(theme.background.ignoresSafeArea())
        .presentationBackground(theme.background)
        .inAppLinks()
    }
}

extension SheetScaffold where Trailing == EmptyView {
    init(title: LocalizedStringKey, leading: Leading = .close, followsBottom: Binding<Bool>? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, leading: leading, followsBottom: followsBottom, trailing: { EmptyView() }, content: content)
    }
}

/// Rounded group of rows with an optional header and footer. Dividers are inserted between rows.
struct GroupedSection<Content: View>: View {
    @Environment(\.theme) private var theme
    var header: LocalizedStringKey?
    var footer: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if let header {
                Text(header).font(DS.Typography.sectionHeader).foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, DS.Spacing.lg)
            }
            Group(subviews: content()) { subviews in
                VStack(spacing: 0) {
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, sub in
                        sub
                        if index < subviews.count - 1 {
                            Rectangle().fill(theme.separator).frame(height: 0.5)
                                .padding(.leading, DS.Spacing.lg)
                        }
                    }
                }
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            if let footer {
                Text(footer).font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, DS.Spacing.lg)
            }
        }
    }
}

/// A row with a title, optional subtitle, right-aligned value, and a chevron or checkmark.
struct SettingsRow: View {
    @Environment(\.theme) private var theme
    var systemImage: String?
    let title: LocalizedStringKey
    var subtitle: String?
    var value: String?
    var showsChevron = false
    var isChecked = false
    var isDestructive = false
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { rowBody }.buttonStyle(RowButtonStyle())
        } else {
            rowBody
        }
    }

    private var rowBody: some View {
        HStack(spacing: DS.Spacing.md) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: DS.IconSize.md))
                    .foregroundStyle(isDestructive ? theme.destructive : theme.textSecondary)
                    .frame(width: DS.IconSize.lg)
            }
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title).font(DS.Typography.ui)
                    .foregroundStyle(isDestructive ? theme.destructive : theme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: DS.Spacing.sm)
            if let value {
                Text(value).font(DS.Typography.ui).foregroundStyle(theme.textSecondary).lineLimit(1)
            }
            if isChecked {
                Image(systemName: "checkmark").font(.system(size: DS.IconSize.md, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            if showsChevron {
                Image(systemName: "chevron.right").font(.system(size: DS.IconSize.sm, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct RowButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? theme.surfaceRaised : .clear)
    }
}

/// A row with a switch.
struct SettingsToggleRow: View {
    @Environment(\.theme) private var theme
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(title).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                }
            }
        }
        .tint(theme.accent)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
    }
}

/// A row with an inline text field.
struct SettingsFieldRow: View {
    @Environment(\.theme) private var theme
    let title: LocalizedStringKey
    var prompt: LocalizedStringKey = ""
    @Binding var text: String
    var isSecure = false
    var keyboard: UIKeyboardType = .default
    var multiline = false

    var body: some View {
        HStack(alignment: multiline ? .top : .center, spacing: DS.Spacing.md) {
            Text(title).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                .frame(minWidth: 84, alignment: .leading)
            Group {
                if isSecure {
                    SecureField("", text: $text, prompt: Text(prompt))
                } else if multiline {
                    TextField("", text: $text, prompt: Text(prompt), axis: .vertical).lineLimit(2...5)
                } else {
                    TextField("", text: $text, prompt: Text(prompt))
                }
            }
            .font(DS.Typography.ui)
            .foregroundStyle(theme.textPrimary)
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
    }
}

/// Card with a title, value, progress bar and caption (e.g. the context window).
struct UsageCard: View {
    @Environment(\.theme) private var theme
    let title: LocalizedStringKey
    let valueText: String
    /// 0...1
    let fraction: Double
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Text(title).font(DS.Typography.uiEmphasis).foregroundStyle(theme.textPrimary)
                Spacer()
                Text(valueText).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.accentMuted)
                    Capsule().fill(theme.accent)
                        .frame(width: max(8, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 8)
            Text(caption).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
        }
        .padding(DS.Spacing.lg)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
}

#Preview("Light · Purple") { sheetsPreview.previewStyle(.light) }
#Preview("Dark · Purple") { sheetsPreview.previewStyle(.dark) }
#Preview("Dark · Orange") { sheetsPreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }

@MainActor private var sheetsPreview: some View {
    SheetScaffold(title: "Usage") {
        GroupedSection(header: "Context") {
            UsageCard(title: "Context window", valueText: "37% used", fraction: 0.37, caption: "149k of 400k tokens used")
        }
        GroupedSection(header: "Fields") {
            SettingsToggleRow(title: "Smooth streaming", subtitle: "Reveal text at a steady pace.", isOn: .constant(true))
            SettingsFieldRow(title: "Name", prompt: "Strata", text: .constant("My gateway"))
            SettingsFieldRow(title: "API key", prompt: "sk-", text: .constant("secret"), isSecure: true)
        }
        GroupedSection(header: "Effort", footer: "Higher effort thinks longer.") {
            SettingsRow(title: "Medium", subtitle: "Recommended", isChecked: true, action: {})
            SettingsRow(title: "High", value: "8,192", showsChevron: true, action: {})
            SettingsRow(systemImage: "trash", title: "Delete", isDestructive: true, action: {})
        }
    }
}
