import SwiftUI

/// The context gauge's sheet: one card with the window's use as a bar split by category, the total and where it
/// summarizes, and a row per category; then "Summarize now". Display only: the split is an estimate scaled to the last request's real size,
/// and nothing here changes what is sent. Usage and balance moved behind the chart button.
struct ContextSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(\.chatController) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let conversation: Conversation?
    /// The model's effective context length, as the gauge uses it.
    let window: Int
    let maxOutput: Int?
    let connection: Connection?

    /// Tokens per category (`ContextCategory` order), computed when the total changes.
    @State private var split: [Int]?
    @State private var shownTotal = 0.0
    @State private var focus: Int?

    /// The gauge's number: the last request's prompt plus completion.
    private var used: Int { conversation?.lastUsage?.totalTokens ?? 0 }
    private var hasData: Bool { conversation?.lastUsage != nil }

    var body: some View {
        let used = used
        let tokens = hasData ? (split ?? []) : []
        let limit = Compaction.limit(window: window, maxOutput: maxOutput)
        SheetScaffold(title: "Context") {
            VStack(alignment: .leading, spacing: 0) {
                // One card: the window's use as a stacked bar, then each category.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Context window").font(DS.Typography.uiEmphasis).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text(percentUsed(used)).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary).monospacedDigit()
                    }
                    ContextStackBar(tokens: tokens, window: window, limit: limit, focus: focus)
                        .padding(.top, DS.Spacing.md)
                    HStack(spacing: DS.Spacing.xs) {
                        CountingTokens(value: shownTotal)
                        Text("of \(ContextGrid.sizeLabel(window)) tokens · summarizes at \(TokenFormat.short(limit))")
                    }
                    .font(DS.Typography.uiCaption)
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
                    .padding(.top, DS.Spacing.sm)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(TokenFormat.short(used)) of \(ContextGrid.sizeLabel(window)) tokens used"))
                    Divider().overlay(theme.separator).padding(.vertical, DS.Spacing.md)
                    legend(tokens: tokens, used: used)
                }
                .padding(DS.Spacing.lg)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))

                summarizeButton
                    .padding(.top, DS.Spacing.md)

                if let usage = conversation?.lastUsage {
                    GroupedSection(header: "Last request") {
                        SettingsRow(title: "Input tokens", value: usage.promptTokens.formatted())
                        SettingsRow(title: "Output tokens", value: usage.completionTokens.formatted())
                        if let r = usage.reasoningTokens { SettingsRow(title: "Reasoning tokens", value: r.formatted()) }
                        SettingsRow(title: "Cache hit", value: Self.cacheText(usage))
                    }
                    .padding(.top, DS.Spacing.xl)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            computeSplit()
            countTo(used)
        }
        .onChange(of: used) { _, n in
            computeSplit()
            countTo(n)
        }
    }

    private func percentUsed(_ used: Int) -> String {
        guard hasData else { return String(localized: "No messages yet") }
        let pct = window > 0 ? Double(used) / Double(window) : 0
        return String(localized: "\(pct.formatted(.percent.precision(.fractionLength(1)))) used")
    }

    @ViewBuilder
    private func legend(tokens: [Int], used: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(ContextCategory.allCases.filter { tokens.indices.contains($0.rawValue) && tokens[$0.rawValue] > 0 }, id: \.self) { c in
                ContextLegendRow(color: theme.contextCategory(c), title: c.title, tokens: tokens[c.rawValue], window: window,
                                 isSelected: focus == c.rawValue, isDimmed: focus != nil && focus != c.rawValue) {
                    focus = focus == c.rawValue ? nil : c.rawValue
                }
            }
            ContextLegendRow(color: theme.contextFree, title: String(localized: "Free"), tokens: max(0, window - used),
                             window: window, tokensText: used == 0 ? ContextGrid.sizeLabel(window) : nil,
                             isDimmed: focus != nil)
        }
        .animation(.easeOut(duration: 0.2), value: focus)
    }

    static func cacheText(_ u: Usage) -> String {
        guard let cached = u.cachedTokens else { return String(localized: "Not reported") }
        guard u.promptTokens > 0 else { return String(localized: "None") }
        let pct = Int((Double(cached) / Double(u.promptTokens) * 100).rounded())
        return String(localized: "\(cached.formatted()) of \(u.promptTokens.formatted()) (\(pct)%)")
    }

    @ViewBuilder
    private var summarizeButton: some View {
        let busy = controller.isCompacting(conversation)
        Button {
            if let c = conversation { controller.compactNow(conversation: c, context: context) }
        } label: {
            Text(busy ? "Summarizing…" : "Summarize now")
                .font(DS.Typography.uiEmphasis)
                .frame(maxWidth: .infinity)
                .frame(height: DS.IconSize.controlDiameter)
        }
        .buttonStyle(.glass)
        .disabled(conversation.map { controller.isStreaming($0) } ?? true || (conversation?.activePath.isEmpty ?? true))
    }

    private func computeSplit() {
        guard let conversation, hasData else { split = nil; return }
        split = controller.contextSplit(conversation: conversation, total: used)
            ?? ContextEstimator.scale([0, 0, 1, 0, 0, 0], to: used) // no endpoint: all of it as messages
    }

    private func countTo(_ n: Int) {
        if reduceMotion {
            shownTotal = Double(n)
        } else {
            withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.6)) { shownTotal = Double(n) }
        }
    }
}
