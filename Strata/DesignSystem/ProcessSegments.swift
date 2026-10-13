import SwiftUI

/// Thin rule between the process summary and the final answer.
struct ProcessDivider: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Rectangle().fill(theme.separator).frame(height: 0.5)
            .padding(.vertical, DS.Spacing.xs)
            .accessibilityHidden(true)
    }
}

extension AnyTransition {
    /// A block entering: fades in rising a little with a soft blur; Reduce Motion keeps only the fade.
    /// `index` staggers consecutive children.
    static func enter(index: Int = 0, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return AnyTransition.opacity
            .combined(with: .offset(y: 12))
            .combined(with: AnyTransition(.blurReplace))
            .animation(DS.Motion.enter.delay(Double(index) * DS.Motion.stagger))
    }

    /// A source chip arriving: fades and grows a little, delayed by its position.
    static func chipIn(index: Int, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return AnyTransition.opacity.combined(with: .scale(scale: 0.88))
            .animation(DS.Motion.enter.delay(Double(index) * DS.Motion.stagger))
    }

    /// A live tail folding into the summary: fades and shrinks toward the top.
    static func fold(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading))
    }
}

/// Raw reasoning as a card, matching the search and visit cards (Timeline sheet).
struct ThinkingCard: View {
    @Environment(\.theme) private var theme
    let text: String
    var seconds: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "clock").font(.system(size: DS.IconSize.sm)).foregroundStyle(theme.textTertiary)
                Text(seconds.map { String(localized: "Thought for \(ProcessSummary.duration($0))") } ?? String(localized: "Thinking"))
                    .font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
            }
            Text(ReasoningSpaces.collapse(ReasoningDisplay.trimmed(text)))
                .font(DS.Typography.uiSmall)
                .dsLeading(.thinking)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }
}

/// A search or page visit as a card.
struct ActivityCard: View {
    @Environment(\.theme) private var theme
    let entry: ActivityEntry

    var body: some View {
        ActivityRow(entry: entry, wrapsChips: true)
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }
}

/// The current thought: status line plus the one-line preview. Tapping opens the Timeline.
struct LiveThinkingTail: View {
    let label: String
    let start: Date
    let reasoning: ReasoningChunkModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                ActivityStatusLine(label: label, start: start)
                ReasoningLinePreview(model: reasoning, isDimmed: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Every call of the running tool round, in request order, with its progress.
struct LiveToolsTail: View {
    let label: String
    let start: Date
    let entries: [ActivityEntry]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                ActivityStatusLine(label: label, start: start)
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    ForEach(entries) { ActivityRow(entry: $0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Light · Purple") { segmentsPreview.previewStyle(.light) }
#Preview("Dark · Purple") { segmentsPreview.previewStyle(.dark) }
#Preview("Dark · Orange") { segmentsPreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }

@MainActor private var segmentsPreview: some View {
    let sources = [1: SourceInfo(id: 1, title: "Liquid Glass", url: "https://developer.apple.com/docs", snippet: ""),
                   2: SourceInfo(id: 2, title: "HWS", url: "https://www.hackingwithswift.com/", snippet: "")]
    let search = ToolCallRecord(id: "a", name: "web_search", arguments: "{\"query\":\"liquid glass\"}", result: "", isError: false, sourceIDs: [1, 2])
    let segments: [ProcessSegment] = [
        .init(index: 0, kind: .thinking, text: "The user wants current information.\n\nI should search first.", seconds: 82),
        .init(index: 1, kind: .toolRound, calls: [search]),
    ]
    return VStack(alignment: .leading, spacing: DS.Spacing.lg) {
        ActivitySummaryRow(summary: ProcessSummary(segments: segments)) {}
        ThinkingCard(text: segments[0].text, seconds: 82)
        ActivityCard(entry: ActivityEntry(call: search, sources: Dictionary(uniqueKeysWithValues: sources.map { ($0.key, $0.value) })))
        ProcessDivider()
        Text("Final answer").font(DS.Typography.answer)
    }
    .padding()
    .environment(\.citations, CitationContext(sources: sources))
}
