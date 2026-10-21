import SwiftUI
import MarkdownUI

/// Sources available for resolving `[N]` markers in a conversation.
struct CitationContext: Equatable {
    var sources: [Int: SourceInfo] = [:]
    /// Resolves `![caption](figure-N)` to the chat's stored figures (`FigureReference`).
    var conversationID: UUID?
}

/// A paragraph of `![caption](figure-N)` lines: the figures, at the answer's width.
private struct FigureBlockView: View {
    let refs: [FigureReference.Ref]
    let conversationID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ForEach(refs, id: \.self) { ref in
                AnswerFigure(image: FigureReference.image(id: ref.id, conversationID: conversationID), caption: ref.caption)
            }
        }
    }
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
        VStack(alignment: .leading, spacing: DS.blockSpacing) {
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
    @Environment(\.dynamicTypeSize) private var typeSize
    let model: StreamingMarkdownModel

    var body: some View {
        let quotes = QuoteCitations.plan(model.finalized)
        ForEach(model.finalized) { block in
            let plan = quotes[block.id]
            if plan != .absorbed {
                MarkdownBlockView(block: block, theme: theme, citations: citations, typeScale: DS.typeScale(typeSize),
                                  quote: plan).equatable()
            }
        }
    }
}

/// Reads only `tail` and `freshSpans`.
private struct TailBlocksView: View {
    @Environment(\.theme) private var theme
    @Environment(\.citations) private var citations
    @Environment(\.dynamicTypeSize) private var typeSize
    let model: StreamingMarkdownModel

    var body: some View {
        let tail = model.tail
        // Quote source lines only among blocks that are already followed by another (closed) block.
        let quotes = QuoteCitations.plan(Array(tail.dropLast()))
        ForEach(Array(tail.enumerated()), id: \.element.id) { offset, block in
            if block.kind == .paragraph, let cid = citations.conversationID, let refs = FigureReference.block(block.text) {
                FigureBlockView(refs: refs, conversationID: cid)
            } else if offset == tail.count - 1 && !(block.kind == .table && block.isClosed) {
                OpenBlockView(block: block, spans: model.freshSpans)
            } else if quotes[block.id] != .absorbed {
                // A block followed by another block is stable: full renderer, re-rendered only if its text changes.
                MarkdownBlockView(block: block, theme: theme, citations: citations, typeScale: DS.typeScale(typeSize),
                                  quote: quotes[block.id]).equatable()
            }
        }
    }
}

/// A closed block. Prose blocks and top-level tables use the inline renderer (so citation chips work); code
/// has its own view and complex nested structures use MarkdownUI. Equatable so SwiftUI skips unchanged blocks.
struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let theme: DSTheme
    let citations: CitationContext
    /// `DS.typeScale` of the text size on screen: MarkdownUI sizes are points, so they are scaled here.
    var typeScale: CGFloat = 1
    /// A quote's source line (see `QuoteCitations`).
    var quote: QuoteCitations.Plan?

    var body: some View {
        if block.kind == .paragraph, let cid = citations.conversationID, let refs = FigureReference.block(block.text) {
            FigureBlockView(refs: refs, conversationID: cid)
        } else if block.kind == .blockquote {
            if case .quote(let ids, let text)? = quote {
                QuoteBlockView(source: text ?? block.text, simple: block.usesInlineRenderer, sourceIDs: ids, typeScale: typeScale)
            } else {
                QuoteBlockView(source: block.text, simple: block.usesInlineRenderer, typeScale: typeScale)
            }
        } else if block.usesInlineRenderer {
            InlineBlockView(block: block, spans: [], isOpen: false)
        } else if block.kind == .code, OpenUIFence.isOpenUI(blockText: block.text) {
            OpenUIBlockView(blockText: block.text, blockID: block.id, isClosed: block.isClosed)
        } else if block.kind == .code {
            CodeBlockView(content: CodeBlockContent(blockText: block.text)).equatable()
        } else if block.kind == .thematicBreak {
            Divider()
        } else if block.kind == .table, let table = MarkdownTable.parse(block.text) {
            MarkdownTableView(table: table, typeScale: typeScale)
        } else {
            Markdown(block.markdownUIText)
                .markdownTheme(.strata(theme, scale: typeScale))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension MarkdownBlock {
    /// Source for MarkdownUI: tildes literal; lenient bold unless the block holds fenced code.
    var markdownUIText: String {
        if kind == .code { return TildeEscaper.escape(renderText) }
        return Self.markdownUISource(renderText)
    }

    nonisolated static func markdownUISource(_ text: String) -> String {
        let escaped = TildeEscaper.escape(text)
        if text.contains("```") || text.contains("~~~") { return escaped }
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

// MARK: - Tables

/// A GFM table split into cells. Cell text is still inline Markdown (rendered with the inline renderer).
struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable { case leading, center, trailing }

    var header: [String]
    var alignments: [Alignment]
    /// Body rows, each padded or cut to the header's column count.
    var rows: [[String]]

    var columnCount: Int { header.count }

    /// Parses a table block (header row, delimiter row, body rows). Nil if it is not one.
    nonisolated static func parse(_ text: String) -> MarkdownTable? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        let header = cells(lines[0])
        let delimiter = cells(lines[1])
        guard !header.isEmpty, delimiter.allSatisfy({ $0.contains("-") && $0.allSatisfy { "-: ".contains($0) } }) else { return nil }
        let alignments: [Alignment] = (0..<header.count).map { i in
            guard i < delimiter.count else { return .leading }
            let d = delimiter[i]
            switch (d.hasPrefix(":"), d.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
        let rows = lines.dropFirst(2).map { line -> [String] in
            var row = cells(line)
            if row.count > header.count { row.removeLast(row.count - header.count) }
            while row.count < header.count { row.append("") }
            return row
        }
        return MarkdownTable(header: header, alignments: alignments, rows: rows)
    }

    /// Splits a row on unescaped pipes (GFM: a pipe splits even inside a code span unless escaped). `\|` becomes `|`.
    nonisolated static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in line {
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        // The optional leading and trailing pipes leave empty edge cells.
        if line.hasPrefix("|"), cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.count > 1, cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// A finished table: header row on a tinted band, natural-width columns (long cells wrap at a cap),
/// horizontally scrollable, and cells through the inline renderer so citation chips work.
struct MarkdownTableView: View {
    @Environment(\.theme) private var theme
    let table: MarkdownTable
    var typeScale: CGFloat = 1

    var body: some View {
        let columns = Array(0..<table.columnCount)
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(columns, id: \.self) { c in
                        cell(table.header[c], column: c, header: true)
                            .gridColumnAlignment(Self.horizontal(table.alignments[c]))
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Rectangle().fill(theme.separator).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    // Baseline-aligned, so a cell holding only a (smaller) chip lines up with its neighbours.
                    GridRow(alignment: .firstTextBaseline) {
                        ForEach(columns, id: \.self) { c in cell(row[c], column: c, header: false) }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .scrollBounceBehavior(.basedOnSize)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay { RoundedRectangle(cornerRadius: DS.Radius.md).stroke(theme.separator, lineWidth: 1) }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ source: String, column: Int, header: Bool) -> some View {
        let alignment = table.alignments[column]
        return TableCellText(source: source, header: header, alignment: alignment, maxWidth: 260 * typeScale)
            .padding(.vertical, DS.Spacing.sm)
            .padding(.horizontal, DS.Spacing.md)
            // Fill the grid cell so the header band has no gaps when cells differ in height.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: Self.horizontal(alignment), vertical: .top))
            .background(header ? theme.fillTertiary : Color.clear)
    }

    static func horizontal(_ a: MarkdownTable.Alignment) -> HorizontalAlignment {
        switch a {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// One table cell: inline Markdown with compact citation chips, at its natural width up to `maxWidth`, then wrapping.
struct TableCellText: View {
    @Environment(\.citations) private var citations
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .caption2) private var chipHeight: CGFloat = 17
    let source: String
    let header: Bool
    var alignment: MarkdownTable.Alignment = .leading
    var maxWidth: CGFloat = 260

    /// The cell's attributed text. Bold is drawn in the semibold weight, as in prose (the header is semibold throughout).
    nonisolated static func attributed(_ source: String, sources: [Int: SourceInfo],
                                       chipColor: Color = .secondary) -> AttributedString {
        let result = InlineMarkdownText.attributed(source, sources: sources, isOpen: false,
                                                   chipFont: DS.Typography.chipCompact, chipColor: chipColor)
        return InlineMarkdownText.withSemiboldStrong(result, font: DS.Typography.tableHeader)
    }

    var body: some View {
        let composed = InlineMarkdownText.composed(Self.attributed(source, sources: citations.sources,
                                                                   chipColor: theme.textSecondary))
        let text = composed.text
            .font(header ? DS.Typography.tableHeader : DS.Typography.tableCell)
            .dsLeading(.ui)
            .foregroundStyle(theme.textPrimary)
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
        CappedWidth(maxWidth: maxWidth) {
            if composed.hasChips {
                // The header band is already chipFill-tinted: its chips take the page colour so they still show.
                text.textRenderer(ChipTextRenderer(fill: header ? theme.background : theme.chipFill, height: chipHeight))
            } else {
                text.textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Lays its child out at the proposed width, capped at `maxWidth`. With no proposal (a horizontal scroll view)
/// the child gets `maxWidth`, so text takes its natural width when short and wraps at the cap when long.
struct CappedWidth: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
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
        case .code where OpenUIFence.isOpenUI(blockText: block.text):
            // An interactive view builds up line by line (`OpenUIBlockView`).
            OpenUIBlockView(blockText: block.text, blockID: block.id, isClosed: block.isClosed)
        case .code:
            // Streaming: capped height, follows its own bottom; the full block (collapse, header) appears once the fence closes.
            CodeBlockView(content: CodeBlockContent.streaming(blockText: block.text), isStreaming: true)
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
                               leading: .heading(level), semiboldStrong: false, spans: spans, isOpen: isOpen)
                .padding(.top, DS.Spacing.sm)
        case .blockquote:
            QuoteBlockView(source: block.text, simple: true, spans: spans, isOpen: isOpen)
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

    static func headingFont(_ level: Int) -> Font { DS.Typography.heading(level) }
}

// MARK: - Quotes

/// A block quote as a card: normal text on a faint fill, a bar on the left, rounded on the right. With `sourceIDs`, a
/// source line (favicon, domain, page title) under a hairline; it opens the source like a citation chip.
struct QuoteBlockView: View {
    @Environment(\.theme) private var theme
    @Environment(\.citations) private var citations
    @Environment(\.openURL) private var openURL
    /// The quote's Markdown, `>` markers included.
    let source: String
    /// Plain prose (inline renderer); otherwise the inside is rendered by MarkdownUI.
    var simple = true
    var sourceIDs: [Int] = []
    var spans: [StreamingMarkdownModel.FreshSpan] = []
    var isOpen = false
    var typeScale: CGFloat = 1

    /// The quote's paragraphs without their `>` markers (lines of one paragraph joined with a space).
    nonisolated static func paragraphs(_ source: String) -> [String] {
        var out: [String] = []
        var current: [Substring] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let content = line.drop(while: { $0 == ">" || $0 == " " || $0 == "\t" })
            if content.isEmpty {
                if !current.isEmpty { out.append(current.joined(separator: " ")); current = [] }
            } else {
                current.append(content)
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }

    /// The inside of a quote as Markdown: one level of `>` removed from each line.
    nonisolated static func inner(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var rest = line.drop(while: { $0 == " " })
            if rest.first == ">" { rest = rest.dropFirst(); if rest.first == " " { rest = rest.dropFirst() } }
            return String(rest)
        }.joined(separator: "\n")
    }

    var body: some View {
        let sources = sourceIDs.compactMap { citations.sources[$0] }
        VStack(alignment: .leading, spacing: 0) {
            content
            if let first = sources.first {
                Rectangle().fill(theme.separator).frame(height: 0.5)
                    .padding(.top, DS.Spacing.md)
                    .padding(.bottom, DS.Spacing.sm)
                sourceLine(first, more: sources.count - 1)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.quoteFill, in: UnevenRoundedRectangle(bottomTrailingRadius: DS.Radius.quote, topTrailingRadius: DS.Radius.quote))
        .overlay(alignment: .leading) { Rectangle().fill(theme.textSecondary).frame(width: 3) }
    }

    @ViewBuilder
    private var content: some View {
        if simple {
            let paragraphs = Self.paragraphs(source)
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { i, text in
                    let last = i == paragraphs.count - 1
                    InlineMarkdownText(source: text, font: DS.Typography.answer, color: theme.textPrimary,
                                       spans: last ? spans : [], isOpen: isOpen && last)
                }
            }
        } else {
            Markdown(MarkdownBlock.markdownUISource(CJKEmphasisFixer.fix(Self.inner(source))))
                .markdownTheme(.strata(theme, scale: typeScale))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceLine(_ info: SourceInfo, more: Int) -> some View {
        Button {
            if let url = URL(string: CitationParser.citeURL(ids: sourceIDs)) { openURL(url) }
        } label: {
            HStack(spacing: DS.Spacing.sm - 2) {
                FaviconView(host: info.host, size: DS.IconSize.favicon - 2)
                Text(info.shortHost)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !info.title.isEmpty, info.title != info.host {
                    Text(info.title)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if more > 0 {
                    Text(verbatim: "+\(more)").foregroundStyle(theme.textTertiary).layoutPriority(1)
                }
                Spacer(minLength: 0)
            }
            .font(DS.Typography.quoteSource)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Source: \(info.shortHost)"))
        .accessibilityHint(Text("Shows the source"))
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
    var leading: DS.Leading = .answer
    /// Bold text inside is drawn in the semibold weight of the answer font (not in headings, whose size differs).
    var semiboldStrong = true
    var spans: [StreamingMarkdownModel.FreshSpan] = []
    var isOpen = false

    nonisolated static func attributed(_ source: String, sources: [Int: SourceInfo] = [:], isOpen: Bool = false,
                                       chipFont: Font = DS.Typography.chipInline,
                                       chipColor: Color = .secondary, chipBackground: Color = .gray.opacity(0.2)) -> AttributedString {
        var text = TildeEscaper.escape(source)
        text = CitationParser.transform(text, sources: sources, holdBack: isOpen)
        // Closers first: the CJK fix adds hair spaces around `**`, which would make a closer look like an opener.
        if isOpen { text = OptimisticCloser.closeInline(text) }
        let closed = LenientEmphasis.normalize(CJKEmphasisFixer.fix(text))
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
        // A closed block's text no longer changes, yet its body runs again on every reveal tick of the block still
        // streaming below it: keep its result instead of running the whole inline pipeline each time.
        let key = isOpen ? nil : InlineCache.Key(source: source, conversation: citations.conversationID,
                                                 sources: citations.sources.count, semibold: semiboldStrong,
                                                 chip: "\(theme.textSecondary)")
        if let key, let hit = InlineCache.shared.value(for: key) { return hit }
        let result = Self.attributed(source, sources: citations.sources, isOpen: isOpen,
                                     chipColor: theme.textSecondary, chipBackground: theme.surfaceRaised)
        let out = semiboldStrong ? Self.withSemiboldStrong(result) : result
        if let key { InlineCache.shared.store(out, for: key) }
        return out
    }

    /// Bold is drawn as Pretendard SemiBold, from the font itself, instead of the heavier Bold that the system picks for
    /// a bold run. The run keeps its other traits (italic, links).
    nonisolated static func withSemiboldStrong(_ text: AttributedString, font: Font = DS.Typography.answerEmphasis) -> AttributedString {
        var out = text
        for run in text.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true && run.link?.scheme != CitationParser.scheme {
            out[run.range].font = font
            out[run.range].inlinePresentationIntent?.remove(.stronglyEmphasized)
        }
        return out
    }

    var body: some View {
        // The expensive inline pipeline runs once per body (that is, per reveal tick); a frame only applies the fade.
        let attributed = make()
        if spans.isEmpty {
            styled(attributed)
        } else {
            let now = Date()
            let allFaded = !spans.contains { $0.isFading(at: now) }
            TimelineView(.animation(paused: allFaded)) { context in
                styled(Self.faded(attributed, spans: spans, color: color, now: context.date), selectable: false)
            }
        }
    }

    @ViewBuilder
    private func styled(_ attributed: AttributedString, selectable: Bool = true) -> some View {
        let composed = Self.composed(attributed)
        let base = composed.text
            .font(font)
            .dsLeading(leading)
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
            if span.isFading(at: now), covered > 0 {
                ramps.append((covered, span.alpha(at: now)))
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
        VStack(alignment: .leading, spacing: DS.Spacing.listItem) {
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

/// Display-only cleanup of reasoning text: a paragraph that follows a tool call can start (or end) with stray newlines,
/// which would show as an empty line under the "Thinking" header. Stored reasoning is never changed.
enum ReasoningDisplay {
    nonisolated static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the text shows anything at all once trimmed.
    nonisolated static func isVisible(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }
}

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
        Text(ReasoningDisplay.trimmed(chunk.text)).font(DS.Typography.uiSmall).dsLeading(.thinking).foregroundStyle(theme.textSecondary)
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
            let shown = ReasoningDisplay.trimmed(model.tail)
            if !shown.isEmpty {
                if model.freshSpans.isEmpty || reduceMotion {
                    text(AttributedString(shown))
                } else {
                    TimelineView(.animation) { context in
                        text(InlineMarkdownText.faded(AttributedString(shown), spans: model.freshSpans,
                                                      color: theme.textSecondary, now: context.date))
                    }
                }
            }
        }
        .onChange(of: model.tail.utf8.count) { _, _ in onGrow() }
    }

    private func text(_ s: AttributedString) -> some View {
        Text(s).font(DS.Typography.uiSmall).dsLeading(.thinking).foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One-line live preview of the sentence being thought: shown from its start, tail-truncated, and replaced
/// (with a short crossfade) only when a new sentence begins, at most about once every 1.2 s.
struct ReasoningLinePreview: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: ReasoningChunkModel?
    /// A tool is running: the last thought stays in the slot at reduced opacity.
    var isDimmed = false
    var font: Font = DS.Typography.uiSmall
    /// Nil: the tertiary text color.
    var color: Color?
    /// Shown until the first sentence arrives (otherwise the slot stays blank).
    var placeholder: String?
    /// Lines the sentence may wrap to. The slot is as tall as the sentence: the live line is the last thing in a
    /// message, so its height moves nothing above it, and a finished line (sized the same way) keeps that height.
    var lines = 1
    /// Show finished English sentences in Korean (`ThoughtTranslator`).
    var translate = false
    @State private var gate = ThoughtPreviewGate()
    /// Finished sentences sent for translation, oldest first.
    @State private var finished: [String] = []
    /// The latest sentence as last received, so the full sentence is known when the next one begins.
    @State private var lastLatest: ThoughtSentence?
    @State private var shown: ThoughtSentence?
    @State private var deadline: Double?

    /// Slot state: blank before any thought, full while thinking, half while a tool runs.
    static func opacity(hasThought: Bool, toolRunning: Bool) -> Double {
        guard hasThought else { return 0 }
        return toolRunning ? 0.5 : 1
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(" ").font(font).lineLimit(1).hidden() // reserves one line
            if let shown {
                // Plain, as the finished line shows it (`MessageLayout.plain`), so the words keep their width.
                let text = MessageLayout.plain(displayed(shown))
                let translated = text != MessageLayout.plain(shown.text)
                let spans = translated || reduceMotion ? [] : (model?.freshSpans ?? [])
                // New words fade in as the answer's do; a translation (a whole sentence) rises in instead.
                TimelineView(.animation(paused: spans.isEmpty)) { context in
                    Text(Self.fading(text, spans: spans, now: context.date, color: color ?? theme.textTertiary))
                }
                .font(font)
                .foregroundStyle(color ?? theme.textTertiary)
                .lineLimit(lines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .id(translated ? "t:" + text : "s\(shown.start)")
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            } else if let placeholder {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(color ?? theme.textTertiary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: translationIdentity)
        .onChange(of: translationIdentity, initial: true) { _, shown in
            if !shown.isEmpty { ThoughtTranslator.shared.noteShown(shown) }
        }
        .opacity(Self.opacity(hasThought: shown != nil || placeholder != nil, toolRunning: isDimmed))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isDimmed)
        .onChange(of: model?.thought, initial: true) { _, latest in apply(latest) }
        .task(id: deadline) {
            guard let deadline else { return }
            try? await Task.sleep(for: .seconds(max(0, deadline - Self.now)))
            apply(model?.thought)
        }
    }

    /// Changes when a translation arrives (or the next one replaces it), which animates the swap.
    private var translationIdentity: String {
        guard translate, let shown else { return "" }
        let text = displayed(shown)
        return text == shown.text ? "" : text
    }

    /// `text` with its last characters faint, newest faintest, as `spans` (newest last) were revealed.
    static func fading(_ text: String, spans: [StreamingMarkdownModel.FreshSpan], now: Date, color: Color) -> AttributedString {
        let chars = Array(text)
        var cursor = chars.count
        var runs: [(range: Range<Int>, alpha: Double)] = []
        for span in spans.reversed() where cursor > 0 {
            let alpha = span.alpha(at: now)
            let lower = max(0, cursor - span.length)
            if alpha < 1 { runs.append((lower..<cursor, alpha)) }
            cursor = lower
        }
        guard !runs.isEmpty else { return AttributedString(text) }
        var out = AttributedString(String(chars[0..<(runs.last?.range.lowerBound ?? chars.count)]))
        var position = runs.last?.range.lowerBound ?? chars.count
        for run in runs.reversed() {
            if run.range.lowerBound > position { out += AttributedString(String(chars[position..<run.range.lowerBound])) }
            var piece = AttributedString(String(chars[run.range]))
            piece.foregroundColor = color.opacity(run.alpha)
            out += piece
            position = run.range.upperBound
        }
        if position < chars.count { out += AttributedString(String(chars[position...])) }
        return out
    }

    /// With translation on: the newest finished sentence that has its translation; until then the sentence itself.
    /// Thinking that isn't English (its finished sentences come back as themselves) shows as it streams.
    /// Decided by the finished sentences only: detecting the language of the sentence still streaming flips while it is
    /// a few letters long, and the line would swap between the translation and the English at every new sentence.
    private func displayed(_ sentence: ThoughtSentence) -> String {
        guard translate else { return sentence.text }
        for text in finished.reversed() {
            if let result = ThoughtTranslator.shared.result(for: text) { return result == text ? sentence.text : result }
        }
        return sentence.text
    }

    private func noteFinished(_ sentence: String) {
        // Plain, so a finished round's line (`MessageLayout.lastLine`) finds the same translation.
        let text = MessageLayout.plain(sentence)
        guard translate, !text.isEmpty, finished.last != text else { return }
        finished.append(text)
        if finished.count > 4 { finished.removeFirst(finished.count - 4) }
        ThoughtTranslator.shared.request(text)
    }

    private func apply(_ latest: ThoughtSentence?) {
        if let previous = lastLatest, previous.start != latest?.start { noteFinished(previous.text) }
        lastLatest = latest
        if let latest, ThoughtCompletion.isFinished(latest.text) { noteFinished(latest.text) }
        gate.update(latest: latest, now: Self.now)
        deadline = gate.nextSwitchAt
        guard let next = gate.displayed, next != shown else { return }
        if let shown, shown.start != next.start, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) { self.shown = next }
        } else {
            shown = next
        }
    }
}

/// Inline Markdown already turned into attributed text, for blocks that are closed (their text is final).
@MainActor
final class InlineCache {
    static let shared = InlineCache()
    struct Key: Hashable { var source: String; var conversation: UUID?; var sources: Int; var semibold: Bool; var chip: String }
    private var values: [Key: AttributedString] = [:]
    private var order: [Key] = []
    private let limit = 400

    func value(for key: Key) -> AttributedString? { values[key] }

    func store(_ value: AttributedString, for key: Key) {
        if values.updateValue(value, forKey: key) == nil { order.append(key) }
        if order.count > limit {
            let drop = order.prefix(order.count - limit)
            for k in drop { values.removeValue(forKey: k) }
            order.removeFirst(drop.count)
        }
    }

    func removeAll() { values.removeAll(); order.removeAll() }
}
