import SwiftUI
import MarkdownUI

/// Renders a streaming Markdown document: equatable finalized blocks, then the open tail.
struct MarkdownDocumentView: View {
    let model: StreamingMarkdownModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            FinalizedBlocksView(model: model)
            TailBlocksView(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reads only `finalized`, so tail updates never invalidate it.
private struct FinalizedBlocksView: View {
    @Environment(\.theme) private var theme
    let model: StreamingMarkdownModel

    var body: some View {
        ForEach(model.finalized) { block in
            MarkdownBlockView(block: block, theme: theme).equatable()
        }
    }
}

/// Reads only `tail` and `freshSpans`.
private struct TailBlocksView: View {
    @Environment(\.theme) private var theme
    let model: StreamingMarkdownModel

    var body: some View {
        let tail = model.tail
        ForEach(Array(tail.enumerated()), id: \.element.id) { offset, block in
            if offset == tail.count - 1 && !(block.kind == .table && block.isClosed) {
                OpenBlockView(block: block, spans: model.freshSpans)
            } else {
                // A block followed by another block is stable: full renderer, re-rendered only if its text changes.
                MarkdownBlockView(block: block, theme: theme).equatable()
            }
        }
    }
}

/// A block rendered with the full Markdown renderer. Equatable so SwiftUI skips unchanged blocks.
struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let theme: DSTheme

    var body: some View {
        Markdown(block.renderText)
            .markdownTheme(.strata(theme))
            .textSelection(.enabled)
            .padding(.top, block.kind.isHeading ? DS.Spacing.sm : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MarkdownBlock.Kind {
    var isHeading: Bool { if case .heading = self { true } else { false } }
}

// MARK: - Open (last) block: cheap path

/// The last block while it is still growing: inline Markdown into AttributedString, no highlighting,
/// open fences as plain monospaced text, unfinished tables as raw rows.
struct OpenBlockView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let block: MarkdownBlock
    var spans: [StreamingMarkdownModel.FreshSpan] = []

    var body: some View {
        switch block.kind {
        case .paragraph:
            fading(block.text.replacingOccurrences(of: "\n", with: " "), font: DS.Typography.answer)
        case .heading(let level):
            fading(Self.headingText(block.text), font: Self.headingFont(level))
                .padding(.top, DS.Spacing.sm)
        case .blockquote:
            let body = block.text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { Substring($0).drop(while: { $0 == ">" || $0 == " " }) }
                .joined(separator: " ")
            fading(body, font: DS.Typography.answer, color: theme.textSecondary)
                .padding(.leading, DS.Spacing.md)
                .overlay(alignment: .leading) { Rectangle().fill(theme.separator).frame(width: 3) }
        case .list:
            OpenListView(text: block.text, spans: reduceMotion ? [] : spans)
        case .code:
            plainCode(Self.codeBody(block.text))
        case .table:
            plainCode(block.text)
        case .thematicBreak:
            Divider()
        }
    }

    private func fading(_ source: String, font: Font, color: Color? = nil) -> some View {
        InlineMarkdownText(source: source, font: font, color: color ?? theme.textPrimary,
                           spans: reduceMotion ? [] : spans)
    }

    private func plainCode(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(DS.Typography.monoSmall)
                .foregroundStyle(theme.textPrimary)
                .padding(DS.Spacing.md)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    static func headingText(_ text: String) -> String {
        let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        let stripped = first.drop(while: { $0 == " " }).drop(while: { $0 == "#" })
        return stripped.trimmingCharacters(in: .whitespaces)
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(.title2, design: .serif).weight(.semibold)
        case 2: .system(.title3, design: .serif).weight(.semibold)
        default: .system(.headline, design: .serif)
        }
    }

    /// Body of a fenced block without the fence lines.
    static func codeBody(_ text: String) -> String {
        var lines = BlockScanner.lines(of: text).map(String.init)
        guard let first = lines.first, let f = BlockScanner.Line(Substring(first)).fence else { return text }
        lines.removeFirst()
        if let last = lines.last, BlockScanner.Line(Substring(last)).closesFence(char: f.char, count: f.count) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// Inline Markdown rendered through `AttributedString`, with optimistic closing and a fade on fresh spans.
struct InlineMarkdownText: View {
    let source: String
    let font: Font
    let color: Color
    var spans: [StreamingMarkdownModel.FreshSpan] = []

    nonisolated static func attributed(_ source: String) -> AttributedString {
        let closed = OptimisticCloser.closeInline(CJKEmphasisFixer.fix(source))
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnly,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: closed, options: options)) ?? AttributedString(source)
    }

    var body: some View {
        if spans.isEmpty {
            Text(Self.attributed(source)).font(font).foregroundStyle(color).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            TimelineView(.animation) { context in
                Text(Self.faded(Self.attributed(source), spans: spans, color: color, now: context.date))
                    .font(font)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Apply a per-span opacity ramp to the end of the string (newest span last).
    static func faded(_ text: AttributedString, spans: [StreamingMarkdownModel.FreshSpan], color: Color, now: Date) -> AttributedString {
        var out = text
        let total = out.characters.count
        var covered = 0
        var ramps: [(covered: Int, alpha: Double)] = []
        for span in spans.reversed() {
            covered = min(total, covered + span.length)
            let age = now.timeIntervalSince(span.born)
            if age < StreamingMarkdownModel.fadeDuration, covered > 0 {
                ramps.append((covered, max(0.05, age / StreamingMarkdownModel.fadeDuration)))
            }
        }
        // Oldest (largest) range first, so newer spans override with their own opacity.
        for ramp in ramps.reversed() {
            let start = out.characters.index(out.endIndex, offsetBy: -ramp.covered)
            out[start..<out.endIndex].foregroundColor = color.opacity(ramp.alpha)
        }
        return out
    }
}

/// Cheap list rendering for the open tail: bullets and numbers with inline Markdown.
struct OpenListView: View {
    @Environment(\.theme) private var theme
    let text: String
    var spans: [StreamingMarkdownModel.FreshSpan] = []

    struct Item: Identifiable { let id: Int; let level: Int; let marker: String; let content: String }

    static func items(_ text: String) -> [Item] {
        var items: [Item] = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line = BlockScanner.Line(raw)
            let level = line.indent / 2
            let rest = line.trimmed
            if let c = rest.first, "-+*".contains(c), rest.dropFirst().first == " " {
                items.append(Item(id: i, level: level, marker: "•", content: String(rest.dropFirst(2))))
            } else if let m = rest.firstMatchOrderedMarker() {
                items.append(Item(id: i, level: level, marker: m.marker, content: m.content))
            } else if var last = items.popLast() {
                last = Item(id: last.id, level: last.level, marker: last.marker, content: last.content + " " + String(rest))
                items.append(last)
            } else {
                items.append(Item(id: i, level: 0, marker: "", content: String(rest)))
            }
        }
        return items
    }

    var body: some View {
        let items = Self.items(text)
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                    Text(item.marker).font(DS.Typography.answer).foregroundStyle(theme.textSecondary)
                    InlineMarkdownText(source: item.content, font: DS.Typography.answer, color: theme.textPrimary,
                                       spans: item.id == items.last?.id ? spans : [])
                }
                .padding(.leading, CGFloat(item.level) * DS.Spacing.lg + DS.Spacing.sm)
            }
        }
    }
}

private extension Substring {
    /// "12. text" -> ("12.", "text")
    func firstMatchOrderedMarker() -> (marker: String, content: String)? {
        let digits = prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = dropFirst(digits.count)
        guard let d = after.first, d == "." || d == ")", after.dropFirst().first == " " else { return nil }
        return (String(digits) + String(d), String(after.dropFirst(2)))
    }
}

// MARK: - Reasoning

/// Raw reasoning chain as plain text: finalized paragraphs are cached views; only the tail changes.
struct ReasoningTextView: View {
    @Environment(\.theme) private var theme
    let model: ReasoningChunkModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ReasoningFinalized(model: model)
            ReasoningTail(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReasoningFinalized: View {
    let model: ReasoningChunkModel
    var body: some View {
        ForEach(model.finalized) { chunk in
            ReasoningChunkView(chunk: chunk).equatable()
        }
    }
}

private struct ReasoningChunkView: View, Equatable {
    @Environment(\.theme) private var theme
    let chunk: ReasoningChunkModel.Chunk
    var body: some View {
        Text(chunk.text).font(DS.Typography.monoSmall).foregroundStyle(theme.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    nonisolated static func == (a: Self, b: Self) -> Bool { a.chunk == b.chunk }
}

private struct ReasoningTail: View {
    @Environment(\.theme) private var theme
    let model: ReasoningChunkModel
    var body: some View {
        if !model.tail.isEmpty {
            Text(model.tail).font(DS.Typography.monoSmall).foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
