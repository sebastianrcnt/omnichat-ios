import SwiftUI

/// "Thinking" row above an answer: live preview while streaming, "Thought for Ns" afterwards.
struct ThinkingRow: View {
    @Environment(\.theme) private var theme

    enum State: Equatable {
        /// `preview` is the latest line of the raw reasoning (may be empty before any arrives).
        case live(preview: String)
        case done(seconds: Double)
    }

    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                switch state {
                case .live(let preview):
                    StreamingIndicator()
                    Text(preview.isEmpty ? String(localized: "Thinking…") : preview)
                        .font(DS.Typography.uiSmall)
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                        .truncationMode(.head)
                case .done(let seconds):
                    Image(systemName: "clock").font(.system(size: DS.IconSize.md)).foregroundStyle(theme.textSecondary)
                    Text(Self.doneTitle(seconds: seconds))
                        .font(DS.Typography.uiSmall)
                        .foregroundStyle(theme.textSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.IconSize.sm, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(state.accessibilityText))
    }

    nonisolated static func doneTitle(seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded()))
        return String(localized: "Thought for \(s)s")
    }
}

extension ThinkingRow.State {
    var accessibilityText: String {
        switch self {
        case .live: String(localized: "Thinking. Show thoughts")
        case .done(let s): ThinkingRow.doneTitle(seconds: s)
        }
    }

    /// Latest non-empty line of a raw reasoning chain, for the live preview.
    static func preview(from reasoning: String, maxLength: Int = 160) -> String {
        let line = reasoning.split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > maxLength ? String(line.suffix(maxLength)) : line
    }
}

/// Sheet content with the full raw reasoning chain; follows the bottom while streaming.
struct ThinkingSheet: View {
    @Environment(\.theme) private var theme
    let model: ReasoningChunkModel
    let isStreaming: Bool
    var seconds: Double?

    var body: some View {
        SheetScaffold(title: titleKey) {
            ScrollViewReader { proxy in
                if model.hasContent {
                    ReasoningTextView(model: model)
                } else {
                    Text("Waiting for the model to think…")
                        .font(DS.Typography.monoSmall).foregroundStyle(theme.textTertiary)
                }
                Color.clear.frame(height: 1).id("end")
                    .onChange(of: model.tail) { _, _ in
                        if isStreaming { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .onChange(of: model.finalized.count) { _, _ in
                        if isStreaming { proxy.scrollTo("end", anchor: .bottom) }
                    }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var titleKey: LocalizedStringKey {
        if isStreaming { return "Thinking…" }
        if let seconds { return "Thought for \(max(1, Int(seconds.rounded())))s" }
        return "Thoughts"
    }
}

#Preview("Light · Purple") { thinkingPreview.previewStyle(.light) }
#Preview("Dark · Purple") { thinkingPreview.previewStyle(.dark) }
#Preview("Dark · Orange") { thinkingPreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }
#Preview("Sheet · Dark") {
    ThinkingSheet(model: ReasoningChunkModel(text: "The user wants a summary.\n\nLet me check the constraints first.\n\nNow draft the answer."), isStreaming: false, seconds: 4)
        .previewStyle(.dark)
}

@MainActor private var thinkingPreview: some View {
    VStack(alignment: .leading, spacing: DS.Spacing.lg) {
        ThinkingRow(state: .live(preview: "")) {}
        ThinkingRow(state: .live(preview: "Let me check the constraints first, then draft")) {}
        ThinkingRow(state: .done(seconds: 4)) {}
    }
    .padding()
}
