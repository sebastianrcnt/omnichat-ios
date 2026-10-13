import SwiftUI

/// The context gauge's sheet (reference/mockups/context-grid.html): the total, a 200-cell grid by category with auto
/// zoom, the legend and "Summarize now". Display only: the split is an estimate scaled to the last request's real size,
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
    @State private var showUsage = false

    /// The gauge's number: the last request's prompt plus completion.
    private var used: Int { conversation?.lastUsage?.totalTokens ?? 0 }
    private var hasData: Bool { conversation?.lastUsage != nil }

    var body: some View {
        let used = used
        let tokens = hasData ? (split ?? []) : []
        let range = ContextGrid.range(used: used, window: window)
        let limit = Compaction.limit(window: window, maxOutput: maxOutput)
        SheetScaffold(title: "Context", trailing: {
            GlassIconButton(systemName: "chart.bar", label: "Usage") { showUsage = true }
        }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                    CountingTokens(value: shownTotal)
                        .font(DS.Typography.contextTotal)
                        .foregroundStyle(theme.textPrimary)
                    Text("/ \(ContextGrid.sizeLabel(window)) tokens")
                        .font(DS.Typography.uiSmall.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                }
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(TokenFormat.short(used)) of \(ContextGrid.sizeLabel(window)) tokens used"))
                Text(meta(used: used, limit: limit))
                    .font(DS.Typography.uiCaption)
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
                    .padding(.top, DS.Spacing.xxs)
                    .padding(.bottom, DS.Spacing.md)

                if !hasData || split != nil {
                    ContextGridCanvas(owners: ContextGrid.allocate(tokens, range: range), range: range,
                                      summarizeCell: ContextGrid.summarizeCell(limit: limit, range: range), focus: focus)
                } else {
                    Color.clear.frame(height: 1) // the split is computed on appear, before the grid's first frame
                }
                HStack {
                    Text("1 cell ≈ \(TokenFormat.short(ContextGrid.tokensPerCell(range: range))) tokens")
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    Group {
                        if range < window {
                            Text("Showing \(ContextGrid.sizeLabel(range)) of \(ContextGrid.sizeLabel(window))")
                        } else {
                            Text("Whole window")
                        }
                    }
                    .foregroundStyle(theme.textSecondary)
                }
                .font(DS.Typography.feedMeta)
                .monospacedDigit()
                .padding(.top, DS.Spacing.sm)
                ContextZoomBar(range: range, used: used, window: window)
                    .padding(.top, DS.Spacing.sm - 2)

                legend(tokens: tokens, used: used)
                    .padding(.top, DS.Spacing.md)

                summarizeButton
                    .padding(.top, DS.Spacing.md)
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
        .sheet(isPresented: $showUsage) {
            UsageSheet(conversation: conversation, contextLength: window, connection: connection)
                .environment(\.theme, theme)
        }
    }

    private func meta(used: Int, limit: Int) -> String {
        let at = String(localized: "summarizes at \(TokenFormat.short(limit))")
        guard hasData else { return String(localized: "No messages yet") + " · " + at }
        let pct = window > 0 ? Double(used) / Double(window) : 0
        return String(localized: "\(pct.formatted(.percent.precision(.fractionLength(1)))) used") + " · " + at
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

    @ViewBuilder
    private var summarizeButton: some View {
        let busy = conversation.map { controller.compactingConversationID == $0.id } ?? false
        Button {
            if let c = conversation { controller.compactNow(conversation: c, context: context) }
        } label: {
            Text(busy ? "Summarizing…" : "Summarize now")
                .font(DS.Typography.uiEmphasis)
                .frame(maxWidth: .infinity)
                .frame(height: DS.IconSize.controlDiameter)
        }
        .buttonStyle(.glass)
        .disabled(conversation == nil || controller.isStreaming || (conversation?.activePath.isEmpty ?? true))
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
