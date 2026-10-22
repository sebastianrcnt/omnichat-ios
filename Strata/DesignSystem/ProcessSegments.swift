import SwiftUI

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

    /// A line replaced in place: gone almost at once, so it never overlaps what takes its place. (An `.identity`
    /// removal keeps the view fully drawn until the animation ends, which is the overlap this avoids.)
    static var quickExit: AnyTransition { .opacity.animation(.linear(duration: 0.06)) }

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
            ReasoningMarkdownText(text: ReasoningSpaces.collapse(ReasoningDisplay.trimmed(text)))
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
        ThinkingCard(text: segments[0].text, seconds: 82)
        ActivityCard(entry: ActivityEntry(call: search, sources: Dictionary(uniqueKeysWithValues: sources.map { ($0.key, $0.value) })))
        Text("Final answer").font(DS.Typography.answer)
    }
    .padding()
    .environment(\.citations, CitationContext(sources: sources))
}
