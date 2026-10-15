import SwiftUI

// The Context sheet's pieces: the counting total, the stacked window bar and the legend rows. The numbers come from
// `ContextGrid` and `ContextEstimator`.

/// A token count that counts to its value when it changes (wrap the change in an animation).
struct CountingTokens: View, Animatable {
    nonisolated var value: Double
    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(verbatim: TokenFormat.short(Int(value.rounded()))) }
}

/// The whole window as one bar: each category's share in its color, the rest free, and a tick where it summarizes.
struct ContextStackBar: View {
    @Environment(\.theme) private var theme
    /// Tokens per category, in `ContextCategory` order.
    let tokens: [Int]
    let window: Int
    let limit: Int
    var focus: Int?

    var body: some View {
        let w = Double(max(window, 1))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.contextFree)
                HStack(spacing: 0) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { i, n in
                        if n > 0, let c = ContextCategory(rawValue: i) {
                            Rectangle().fill(theme.contextCategory(c))
                                .frame(width: max(2, geo.size.width * Double(n) / w))
                                .opacity(focus == nil || focus == i ? 1 : 0.3)
                        }
                    }
                }
                .clipShape(Capsule())
                if limit > 0 && limit < window {
                    Rectangle().fill(theme.textTertiary)
                        .frame(width: 2, height: geo.size.height + 6)
                        .offset(x: geo.size.width * Double(limit) / w - 1)
                }
            }
        }
        .frame(height: 8)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6), value: tokens)
        .animation(.easeOut(duration: 0.2), value: focus)
        .accessibilityHidden(true)
    }
}

/// A legend row: swatch, name, tokens, share of the window. Tapping highlights the category.
struct ContextLegendRow: View {
    @Environment(\.theme) private var theme
    let color: Color
    let title: String
    let tokens: Int
    let window: Int
    /// Replaces the token count (an empty window reads "256k", like the total).
    var tokensText: String?
    var isSelected = false
    var isDimmed = false
    var action: (() -> Void)?

    var body: some View {
        let row = HStack(spacing: DS.Spacing.md) {
            RoundedRectangle(cornerRadius: ContextGridCanvas.radius).fill(color)
                .frame(width: DS.Spacing.md - 2, height: DS.Spacing.md - 2)
            Text(verbatim: title).font(DS.Typography.uiSmall).foregroundStyle(theme.textPrimary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: tokensText ?? TokenFormat.short(tokens)).font(DS.Typography.feed).foregroundStyle(theme.textSecondary)
                .monospacedDigit()
            Text(verbatim: Self.percent(tokens, of: window)).font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, DS.Spacing.xs)
        .background(isSelected ? theme.surface : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.cardRow))
        .opacity(isDimmed ? 0.45 : 1)
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            row
        }
    }

    static func percent(_ n: Int, of window: Int) -> String {
        guard window > 0 else { return "0%" }
        return (Double(n) / Double(window)).formatted(.percent.precision(.fractionLength(1)))
    }
}
