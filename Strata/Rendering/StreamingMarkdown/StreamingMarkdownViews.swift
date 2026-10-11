import SwiftUI
import MarkdownUI

/// Sources available for resolving `[N]` markers in a conversation.
struct CitationContext: Equatable {
    var sources: [Int: SourceInfo] = [:]
}

private struct CitationKey: EnvironmentKey { static let defaultValue = CitationContext() }

extension EnvironmentValues {
    var citations: CitationContext {
        get { self[CitationKey.self] }
        set { self[CitationKey.self] = newValue }
    }
}

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
    @Environment(\.citations) private var citations
    let model: StreamingMarkdownModel

    var body: some View {
        ForEach(model.finalized) { block in
            MarkdownBlockView(block: block, theme: theme, citations: citations).equatable()
        }
    }
}

/// Reads only `tail` and `freshSpans`.
private struct TailBlocksView: View {
    @Environment(\.theme) private var theme
    @Environment(\.citations) private var citations
    let model: StreamingMarkdownModel

    var body: some View {
        let tail = model.tail
        ForEach(Array(tail.enumerated()), id: \.element.id) { offset, block in
            if offset == tail.count - 1 && !(block.kind == .table && block.isClosed) {
                OpenBlockView(block: block, spans: model.freshSpans)
            } else {
                // A block followed by another block is stable: full renderer, re-rendered only if its text changes.
                MarkdownBlockView(block: block, theme: theme, citations: citations).equatable()
            }
        }
    }
}

/// A closed block. Prose blocks use the inline renderer (so citation chips work); code, tables and
/// complex nested structures use MarkdownUI. Equatable so SwiftUI skips unchanged blocks.
struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let theme: DSTheme
    let citations: CitationContext

    var body: some View {
        if block.usesInlineRenderer {
            InlineBlockView(block: block, spans: [], isOpen: false)
        } else if block.kind == .code {
            CodeBlockView(content: CodeBlockContent(blockText: block.text)).equatable()
        } else if block.kind == .thematicBreak {
            Divider()
        } else {
            Markdown(block.markdownUIText)
                .markdownTheme(.strata(theme))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension MarkdownBlock {
    /// Source for MarkdownUI: tildes literal; lenient bold unless the block holds fenced code.
    var markdownUIText: String {
        let escaped = TildeEscaper.escape(renderText)
        if kind == .code || renderText.contains("```") || renderText.contains("~~~") { return escaped }
        return LenientEmphasis.normalize(escaped)
    }

    /// Prose blocks without nested fences, quotes or tables render with the inline renderer.
    var usesInlineRenderer: Bool {
        switch kind {
        case .paragraph, .heading: return true
        case .list:
            return !text.split(separator: "\n").contains { line in
                let t = line.drop(while: { $0 == " " || $0 == "\t" })
                return t.hasPrefix("```") || t.hasPrefix("~~~") || t.hasPrefix(">") || t.hasPrefix("|")
            }
        case .blockquote:
            return !text.split(separator: "\n").contains { line in
                let t = line.drop(while: { $0 == " " || $0 == ">" || $0 == "\t" })
                return t.hasPrefix("```") || t.hasPrefix("~~~") || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("|") || t.hasPrefix("#")
            }
        case .code, .table, .thematicBreak:
            return false
        }
    }
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
        case .code:
            // Streaming: capped height, follows its own bottom; the full block (collapse, header) appears once the fence closes.
            CodeBlockView(content: CodeBlockContent(blockText: block.text), isStreaming: true)
        case .table:
            plainCode(block.text)
        case .thematicBreak:
            Divider()
        default:
            InlineBlockView(block: block, spans: reduceMotion ? [] : spans, isOpen: true)
        }
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

    /// Body of a fenced block without the fence lines.
    static func codeBody(_ text: String) -> String {
        var lines = BlockScanner.lines(of: text).map(String.init)
        guard let first = lines.first, let f = BlockScanner.Line(Substring(first)).fence else { return text }
        lines.removeFirst()
        if let last = lines.last, BlockScanner.Line(Substring(last)).closesFence(char: f.char, count: f.count) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// Prose block rendering shared by closed and open blocks.
struct InlineBlockView: View {
    @Environment(\.theme) private var theme
    let block: MarkdownBlock
    var spans: [StreamingMarkdownModel.FreshSpan]
    let isOpen: Bool

    var body: some View {
        switch block.kind {
        case .heading(let level):
            InlineMarkdownText(source: Self.headingText(block.text), font: Self.headingFont(level), color: theme.textPrimary,
                               spans: spans, isOpen: isOpen)
                .padding(.top, DS.Spacing.sm)
        case .blockquote:
            let body = block.text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { Substring($0).drop(while: { $0 == ">" || $0 == " " }) }
                .joined(separator: " ")
            InlineMarkdownText(source: body, font: DS.Typography.answer, color: theme.textSecondary, spans: spans, isOpen: isOpen)
                .padding(.leading, DS.Spacing.md)
                .overlay(alignment: .leading) { Rectangle().fill(theme.separator).frame(width: 3) }
        case .list:
            InlineListView(text: block.text, spans: spans, isOpen: isOpen)
        default:
            InlineMarkdownText(source: block.text.replacingOccurrences(of: "\n", with: " "), font: DS.Typography.answer,
                               color: theme.textPrimary, spans: spans, isOpen: isOpen)
        }
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
}

/// Inline Markdown rendered through `AttributedString`, with citation chips, optimistic closing and a
/// fade on fresh spans.
struct InlineMarkdownText: View {
    @Environment(\.citations) private var citations
    @Environment(\.theme) private var theme
    let source: String
    let font: Font
    let color: Color
    var spans: [StreamingMarkdownModel.FreshSpan] = []
    var isOpen = false

    nonisolated static func attributed(_ source: String, sources: [Int: SourceInfo] = [:], isOpen: Bool = false,
                                       chipFont: Font = .system(size: 12, weight: .medium),
                                       chipColor: Color = .secondary, chipBackground: Color = .gray.opacity(0.2)) -> AttributedString {
        var text = TildeEscaper.escape(source)
        text = CitationParser.transform(text, sources: sources, holdBack: isOpen)
        text = CJKEmphasisFixer.fix(text)
        let closed = LenientEmphasis.normalize(isOpen ? OptimisticCloser.closeInline(text) : text)
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnly,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var result = (try? AttributedString(markdown: closed, options: options)) ?? AttributedString(source)
        result = LenientEmphasis.stripZeroWidth(result)
        // Style citation links as chips.
        var chipRanges: [Range<AttributedString.Index>] = []
        for run in result.runs {
            if let url = run.link, url.scheme == CitationParser.scheme { chipRanges.append(run.range) }
        }
        for range in chipRanges {
            result[range].font = chipFont
            result[range].foregroundColor = chipColor
            result[range].underlineStyle = nil
        }
        return result
    }

    private func make() -> AttributedString {
        Self.attributed(source, sources: citations.sources, isOpen: isOpen,
                        chipColor: theme.textSecondary, chipBackground: theme.surfaceRaised)
    }

    var body: some View {
        if spans.isEmpty {
            styled(make())
        } else {
            TimelineView(.animation) { context in
                styled(Self.faded(make(), spans: spans, color: color, now: context.date), selectable: false)
            }
        }
    }

    @ViewBuilder
    private func styled(_ attributed: AttributedString, selectable: Bool = true) -> some View {
        let composed = Self.composed(attributed)
        let base = composed.text
            .font(font)
            .lineSpacing(DS.Typography.answerLineSpacing)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if composed.hasChips {
            base.textRenderer(ChipTextRenderer(fill: theme.chipFill))
        } else if selectable {
            base.textSelection(.enabled)
        } else {
            base
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

/// List rendering: bullets and numbers with inline Markdown, nested by indentation.
struct InlineListView: View {
    @Environment(\.theme) private var theme
    let text: String
    var spans: [StreamingMarkdownModel.FreshSpan] = []
    var isOpen = false

    struct Item: Identifiable { let id: Int; let level: Int; let marker: String; let content: String }

    nonisolated static func items(_ text: String) -> [Item] {
        var items: [Item] = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line = BlockScanner.Line(raw)
            if line.isBlank { continue }
            let level = line.indent / 2
            let rest = line.trimmed
            if let c = rest.first, "-+*".contains(c), rest.dropFirst().first == " " {
                items.append(Item(id: i, level: level, marker: "•", content: String(rest.dropFirst(2))))
            } else if let m = rest.firstMatchOrderedMarker() {
                items.append(Item(id: i, level: level, marker: m.marker, content: m.content))
            } else if let last = items.popLast() {
                items.append(Item(id: last.id, level: last.level, marker: last.marker, content: last.content + " " + String(rest)))
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
                        .frame(minWidth: DS.Spacing.lg, alignment: .trailing)
                    InlineMarkdownText(source: item.content, font: DS.Typography.answer, color: theme.textPrimary,
                                       spans: item.id == items.last?.id ? spans : [], isOpen: isOpen && item.id == items.last?.id)
                }
                .padding(.leading, CGFloat(item.level) * DS.Spacing.lg)
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

struct ReasoningChunkView: View, Equatable {
    @Environment(\.theme) private var theme
    let chunk: ReasoningChunkModel.Chunk
    var body: some View {
        Text(chunk.text).font(DS.Typography.monoSmall).lineSpacing(DS.Typography.answerLineSpacing).foregroundStyle(theme.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    nonisolated static func == (a: Self, b: Self) -> Bool { a.chunk == b.chunk }
}

/// The growing reasoning paragraph: plain text with the same 150 ms fade on newly revealed characters.
/// Only this view reads `tail`, so finalized paragraphs are never re-rendered while streaming.
struct ReasoningTail: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: ReasoningChunkModel
    /// Called whenever the tail grows (the timeline uses it to keep following the bottom).
    var onGrow: () -> Void = {}

    var body: some View {
        Group {
            if !model.tail.isEmpty {
                if model.freshSpans.isEmpty || reduceMotion {
                    text(AttributedString(model.tail))
                } else {
                    TimelineView(.animation) { context in
                        text(InlineMarkdownText.faded(AttributedString(model.tail), spans: model.freshSpans,
                                                      color: theme.textSecondary, now: context.date))
                    }
                }
            }
        }
        .onChange(of: model.tail.utf8.count) { _, _ in onGrow() }
    }

    private func text(_ s: AttributedString) -> some View {
        Text(s).font(DS.Typography.monoSmall).lineSpacing(DS.Typography.answerLineSpacing).foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One-line live preview of the latest thought (inline Markdown, head-truncated, fading in as it is revealed).
struct ReasoningLinePreview: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: ReasoningChunkModel

    var body: some View {
        let line = model.lastLine
        if !line.isEmpty {
            Group {
                if model.freshSpans.isEmpty || reduceMotion {
                    Text(InlineMarkdownText.attributed(line, isOpen: true))
                } else {
                    TimelineView(.animation) { context in
                        Text(InlineMarkdownText.faded(InlineMarkdownText.attributed(line, isOpen: true),
                                                      spans: model.freshSpans, color: theme.textTertiary, now: context.date))
                    }
                }
            }
            .font(DS.Typography.uiSmall)
            .foregroundStyle(theme.textTertiary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
