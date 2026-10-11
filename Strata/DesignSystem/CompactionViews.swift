import SwiftUI

/// A rule across the transcript where earlier messages were summarized. Tapping it shows the notes.
struct CompactionDivider: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                Rectangle().fill(theme.separator).frame(height: 0.5)
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward").font(.system(size: DS.IconSize.sm))
                    Text("Earlier messages summarized").font(DS.Typography.uiCaption)
                }
                .foregroundStyle(theme.textTertiary)
                .fixedSize()
                Rectangle().fill(theme.separator).frame(height: 0.5)
            }
            .frame(minHeight: DS.IconSize.controlDiameter)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Earlier messages summarized")
        .accessibilityHint("Shows the notes that replaced them")
    }
}

/// "Summarizing conversation…" while the notes are written without a turn around them ("Summarize now").
struct CompactionStatusRow: View {
    @Environment(\.theme) private var theme
    let start: Date

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            StreamingIndicator()
            TimelineView(.periodic(from: start, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(start)))
                Text("Summarizing conversation… · \(seconds)s")
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.accent)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }
}

/// The handoff notes of one compaction.
struct CompactionNotesSheet: View {
    @Environment(\.theme) private var theme
    let notes: String
    let tokensBefore: Int
    let tokensAfter: Int
    let date: Date
    var isAutomatic = true

    var body: some View {
        SheetScaffold(title: "Summary") {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Earlier messages were replaced by these notes when the conversation neared the model's limit. They stay in the transcript.")
                    .font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                Text("\(TokenFormat.short(tokensBefore)) → \(TokenFormat.short(tokensAfter)) tokens · \(date.formatted(date: .abbreviated, time: .shortened))\(isAutomatic ? "" : " · " + String(localized: "Summarize now"))")
                    .font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.attributed(notes))
                .font(DS.Typography.uiSmall)
                .lineSpacing(DS.Typography.answerLineSpacing)
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
                .padding(DS.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Inline Markdown, with heading lines shown in bold (the sheet is a plain text view).
    static func attributed(_ notes: String) -> AttributedString {
        let lines = notes.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.drop { $0 == "#" }
            return line.hasPrefix("#") && t.first == " " ? "**" + t.dropFirst() + "**" : String(line)
        }
        let text = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(notes)
    }
}

#Preview("Divider · Dark") {
    VStack { CompactionDivider {}; CompactionStatusRow(start: .now) }.padding().previewStyle(.dark)
}
