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

    /// A live tail folding into the summary: fades and shrinks toward the top.
    static func fold(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading))
    }
}

/// Everything before the final answer as ONE row ("Thought for 1m 22s . 8 searches . 4 pages"). Tapping expands it
/// in place into the ordered steps: thinking blocks, search and visit cards, and the text written between rounds.
struct ProcessSummaryBlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let segments: [ProcessSegment]
    let summary: ProcessSummary
    var onOpenTimeline: () -> Void = {}
    @State private var expanded = ProcessSummaryBlock.startsExpanded

    /// Longest list shown inline; beyond it the Timeline sheet has the rest.
    static let inlineLimit = 12

    /// Debug launch argument `-StrataExpandSegments 1` starts expanded (simulator screenshots).
    static var startsExpanded: Bool {
        #if DEBUG
        DebugHooks.value("StrataExpandSegments") != nil
        #else
        false
        #endif
    }

    static func visible(_ segments: [ProcessSegment]) -> [ProcessSegment] { Array(segments.prefix(inlineLimit)) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ActivitySummaryRow(summary: summary, expanded: expanded) {
                withAnimation(reduceMotion ? nil : DS.Motion.enter) { expanded.toggle() }
            }
            if expanded {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    ForEach(Array(Self.visible(segments).enumerated()), id: \.element.index) { i, segment in
                        ProcessSegmentDetail(segment: segment)
                            .transition(.enter(index: i, reduceMotion: reduceMotion))
                    }
                    Button(segments.count > Self.inlineLimit ? "Show all \(segments.count) steps" : "Open timeline", action: onOpenTimeline)
                        .font(DS.Typography.uiSmall)
                        .buttonStyle(.plain)
                        .modifier(AccentText())
                        .transition(.enter(index: Self.visible(segments).count, reduceMotion: reduceMotion))
                }
                .padding(.leading, DS.Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccentText: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View { content.foregroundStyle(theme.accent) }
}

/// One step in the expanded list.
struct ProcessSegmentDetail: View {
    @Environment(\.citations) private var citations
    let segment: ProcessSegment

    var body: some View {
        switch segment.kind {
        case .thinking:
            ThinkingCard(text: segment.text, seconds: segment.seconds)
        case .text:
            PreambleText(text: segment.text)
        case .toolRound:
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                ForEach(segment.calls, id: \.id) { call in
                    ActivityCard(entry: ActivityEntry(call: call, sources: citations.sources))
                }
            }
        }
    }
}

/// Raw reasoning as a card, matching the search and visit cards.
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
            Text(text)
                .font(DS.Typography.uiSmall)
                .lineSpacing(DS.Typography.answerLineSpacing)
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

/// Text the model wrote between tool rounds.
struct PreambleText: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                InlineMarkdownText(source: paragraph.replacingOccurrences(of: "\n", with: " "),
                                   font: DS.Typography.answer, color: theme.textPrimary)
            }
        }
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
        .init(index: 0, kind: .thinking, text: "The user wants current information.\n\nI should search first.", seconds: 7),
        .init(index: 1, kind: .text, text: "Let me look at the official docs."),
        .init(index: 2, kind: .toolRound, calls: [search]),
    ]
    return VStack(alignment: .leading, spacing: DS.Spacing.lg) {
        ProcessSummaryBlock(segments: segments, summary: ProcessSummary(segments: segments))
        ProcessDivider()
        Text("Final answer").font(DS.Typography.answer)
    }
    .padding()
    .environment(\.citations, CitationContext(sources: sources))
}
