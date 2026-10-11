import SwiftUI

/// Thin rule between the process segments and the final answer.
struct ProcessDivider: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Rectangle().fill(theme.separator).frame(height: 0.5)
            .padding(.vertical, DS.Spacing.xs)
            .accessibilityHidden(true)
    }
}

/// What happened before the answer, in stream order: a collapsed row per thinking segment and tool round,
/// and the preamble text the model wrote in between. Rows expand in place.
struct ProcessSegmentsView: View {
    let segments: [ProcessSegment]
    /// Opens the Timeline sheet (from a thinking row's "Show all").
    var onShowAll: () -> Void = {}

    /// Debug launch argument `-StrataExpandSegments 1` starts rows expanded (simulator screenshots).
    static var startsExpanded: Bool {
        #if DEBUG
        DebugHooks.value("StrataExpandSegments") != nil
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .thinking: ThinkingSegmentRow(segment: segment, onShowAll: onShowAll)
                case .text: PreambleText(text: segment.text)
                case .toolRound: ToolRoundRow(segment: segment)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Header shared by the expandable rows: icon, title, rotating chevron.
private struct SegmentHeader: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: icon).font(.system(size: DS.IconSize.md)).foregroundStyle(theme.textSecondary)
                Text(title).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary).lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.IconSize.sm, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(expanded ? "Expanded" : "Collapsed"))
    }
}

/// "Thought for 7s"; expands to the raw reasoning, capped at about eight lines, with "Show all".
struct ThinkingSegmentRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let segment: ProcessSegment
    var onShowAll: () -> Void = {}
    @State private var expanded = ProcessSegmentsView.startsExpanded

    static let lineCap = 8

    static func title(seconds: Double?) -> String {
        guard let seconds else { return String(localized: "Thought") }
        return String(localized: "Thought for \(max(1, Int(seconds.rounded())))s")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SegmentHeader(icon: "clock", title: Self.title(seconds: segment.seconds), expanded: expanded) {
                withAnimation(reduceMotion ? nil : DS.Motion.snappy) { expanded.toggle() }
            }
            if expanded {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text(segment.text)
                        .font(DS.Typography.monoSmall).lineSpacing(DS.Typography.answerLineSpacing)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(Self.lineCap)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Show all", action: onShowAll)
                        .font(DS.Typography.uiSmall).foregroundStyle(theme.accent)
                }
                .padding(.leading, DS.Spacing.xl)
                .transition(.opacity)
            }
        }
    }
}

/// "Searched 5 sites"; expands to the queries and a wrapping grid of source chips.
struct ToolRoundRow: View {
    @Environment(\.citations) private var citations
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let segment: ProcessSegment
    @State private var expanded = ProcessSegmentsView.startsExpanded

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SegmentHeader(icon: "globe", title: ProcessSegment.toolTitle(calls: segment.calls), expanded: expanded) {
                withAnimation(reduceMotion ? nil : DS.Motion.snappy) { expanded.toggle() }
            }
            if expanded {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    ForEach(segment.calls, id: \.id) { call in
                        ActivityRow(entry: ActivityEntry(call: call, sources: citations.sources), wrapsChips: true)
                    }
                }
                .padding(.leading, DS.Spacing.xl)
                .transition(.opacity)
            }
        }
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
    return VStack(alignment: .leading, spacing: DS.Spacing.lg) {
        ProcessSegmentsView(segments: [
            .init(index: 0, kind: .thinking, text: "The user wants current information.\n\nI should search first.", seconds: 7),
            .init(index: 1, kind: .text, text: "Let me look at the official docs."),
            .init(index: 2, kind: .toolRound, calls: [search]),
        ])
        ProcessDivider()
        Text("Final answer").font(DS.Typography.answer)
    }
    .padding()
    .environment(\.citations, CitationContext(sources: sources))
}
