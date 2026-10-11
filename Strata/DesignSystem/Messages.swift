import SwiftUI
import MarkdownUI

/// Right-aligned user message bubble with optional image thumbnails.
struct MessageBubble: View {
    @Environment(\.theme) private var theme
    let text: String
    var images: [Data] = []

    var body: some View {
        HStack {
            Spacer(minLength: DS.Spacing.xxl * 2)
            VStack(alignment: .trailing, spacing: DS.Spacing.sm) {
                if !images.isEmpty {
                    HStack(spacing: DS.Spacing.sm) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                            AttachmentThumbnail(data: data, size: DS.IconSize.thumbnail * 1.5)
                        }
                    }
                }
                if !text.isEmpty {
                    Text(text)
                        .font(DS.Typography.ui)
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.md)
                        .background(theme.bubble, in: RoundedRectangle(cornerRadius: DS.Radius.bubble))
                }
            }
        }
    }
}

extension MarkdownUI.Theme {
    /// Markdown theme built from the design tokens.
    @MainActor
    static func strata(_ t: DSTheme) -> MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text {
                FontFamily(.system(.serif))
                FontSize(17)
                ForegroundColor(t.textPrimary)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                BackgroundColor(t.surfaceRaised)
            }
            .strong { FontWeight(.semibold) }
            .link { ForegroundColor(t.accent) }
            .heading1 { c in c.label.markdownMargin(top: 0, bottom: 0).markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.4)) } }
            .heading2 { c in c.label.markdownMargin(top: 0, bottom: 0).markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.25)) } }
            .heading3 { c in c.label.markdownMargin(top: 0, bottom: 0).markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.1)) } }
            .paragraph { c in
                c.label.fixedSize(horizontal: false, vertical: true).relativeLineSpacing(.em(0.25)).markdownMargin(top: 0, bottom: 0)
            }
            .listItem { c in c.label.markdownMargin(top: .em(0.25)) }
            .blockquote { c in
                c.label
                    .markdownTextStyle { ForegroundColor(t.textSecondary) }
                    .padding(.leading, DS.Spacing.md)
                    .overlay(alignment: .leading) { Rectangle().fill(t.separator).frame(width: 3) }
                    .markdownMargin(top: 0, bottom: 0)
            }
            .codeBlock { c in
                ScrollView(.horizontal) {
                    c.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.85))
                            ForegroundColor(t.textPrimary)
                        }
                        .padding(DS.Spacing.md)
                }
                .background(t.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
                .markdownMargin(top: 0, bottom: 0)
            }
            .table { c in
                // Natural-width columns, horizontally scrollable when wider than the screen.
                ScrollView(.horizontal) {
                    c.label
                        .fixedSize(horizontal: true, vertical: false)
                        .markdownTableBorderStyle(.init(.horizontalBorders, color: t.separator, width: 1))
                        .markdownTableBackgroundStyle(.alternatingRows(Color.clear, Color.clear, header: t.fillTertiary))
                }
                .scrollBounceBehavior(.basedOnSize)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                .overlay { RoundedRectangle(cornerRadius: DS.Radius.md).stroke(t.separator, lineWidth: 1) }
                .markdownMargin(top: 0, bottom: 0)
            }
            .tableCell { c in
                c.label
                    .markdownTextStyle {
                        if c.row == 0 { FontWeight(.semibold) }
                        FontFamily(.system(.default))
                        FontSize(.em(0.88))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, DS.Spacing.sm)
                    .padding(.horizontal, DS.Spacing.md)
                    .relativeLineSpacing(.em(0.2))
            }
    }
}

/// Copy and regenerate under an answer.
struct MessageActionBar: View {
    @Environment(\.theme) private var theme
    let onCopy: () -> Void
    var onCopyRaw: (() -> Void)?
    var onRegenerate: (() -> Void)?
    @State private var copied = false

    private func flash() {
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.lg) {
            Menu {
                Button("Copy", systemImage: "doc.on.doc") { onCopy(); flash() }
                if let onCopyRaw {
                    Button("Copy raw Markdown", systemImage: "chevron.left.forwardslash.chevron.right") { onCopyRaw(); flash() }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .contentTransition(.symbolEffect(.replace))
            } primaryAction: { onCopy(); flash() }
            .accessibilityLabel(Text("Copy"))
            if let onRegenerate {
                Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel(Text("Regenerate"))
            }
            Spacer()
        }
        .font(.system(size: DS.IconSize.md))
        .foregroundStyle(theme.textSecondary)
        .buttonStyle(.plain)
    }
}

/// View state for an assistant message, independent of SwiftData so it can be previewed.
/// Streamed text and reasoning live in `MessageRenderState`.
struct AssistantContent: Equatable {
    var thinkingSeconds: Double?
    var calls: [ToolCallRecord] = []
    /// Process segments before the final answer, in stream order.
    var segments: [ProcessSegment] = []
    var pending: [PendingToolCall] = []
    var isStreaming = false
    var phase: ChatController.Phase = .idle
    var turnStart: Date?
    var errorText: String?
    var errorNeedsSettings = false
    var stopped = false
    var canRegenerate = false
}

struct AssistantMessage: View {
    @Environment(\.theme) private var theme
    @Environment(\.citations) private var citations
    let content: AssistantContent
    let render: MessageRenderState
    var onOpenTimeline: () -> Void = {}
    var onOpenSources: ([SourceInfo]) -> Void = { _ in }
    var onCopy: () -> Void = {}
    var onRegenerate: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onCopyRaw: (() -> Void)?

    private var isLive: Bool { content.isStreaming && !render.markdown.hasContent }

    private var phaseLabel: String {
        switch content.phase {
        case .tool(let name, _): name == ToolNames.webSearch ? String(localized: "Searching") : String(localized: "Reading")
        default: String(localized: "Thinking")
        }
    }

    private var searches: Int { content.calls.filter { $0.name == ToolNames.webSearch }.count }
    private var pages: Int { content.calls.filter { $0.name == ToolNames.webFetch && $0.fetchOffset == 0 }.count }

    /// Visited pages plus cited results, for the "Sources" list.
    private var usedSources: [SourceInfo] {
        var ids: [Int] = content.calls.filter { $0.name == ToolNames.webFetch }.flatMap(\.sourceIDs)
        for id in CitationParser.citedIDs(in: render.markdown.text, known: Set(citations.sources.keys)) where !ids.contains(id) { ids.append(id) }
        return ids.compactMap { citations.sources[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if isLive {
                LiveActivityFeed(label: phaseLabel, start: content.turnStart ?? .now,
                                 entries: ActivityEntry.entries(calls: content.calls, pending: content.pending, sources: citations.sources),
                                 reasoning: render.reasoning, action: onOpenTimeline)
            } else if !content.segments.isEmpty {
                ProcessSegmentsView(segments: content.segments, onShowAll: onOpenTimeline)
                if render.markdown.hasContent { ProcessDivider() }
            } else if render.reasoning.hasContent || !content.calls.isEmpty {
                ActivitySummaryRow(seconds: render.reasoning.hasContent ? content.thinkingSeconds : nil,
                                   searches: searches, pages: pages, action: onOpenTimeline)
            }
            if render.markdown.hasContent {
                MarkdownDocumentView(model: render.markdown)
            }
            if content.stopped {
                Text("Stopped").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
            }
            if let error = content.errorText {
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Text(error).font(DS.Typography.uiSmall).foregroundStyle(theme.textPrimary)
                        if content.errorNeedsSettings {
                            Button("Open Settings", action: onOpenSettings).buttonStyle(.glass)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(DS.Spacing.md)
                .background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.md))
            }
            if !content.isStreaming, !content.calls.isEmpty {
                let used = usedSources
                if !used.isEmpty { SourcesRow(count: used.count) { onOpenSources(used) } }
            }
            if !content.isStreaming && (render.markdown.hasContent || content.errorText != nil) {
                MessageActionBar(onCopy: onCopy, onCopyRaw: onCopyRaw, onRegenerate: content.canRegenerate ? onRegenerate : nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Light · Purple") { messagesPreview.previewStyle(.light) }
#Preview("Dark · Purple") { messagesPreview.previewStyle(.dark) }
#Preview("Dark · Orange") { messagesPreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }

@MainActor private var messagesPreview: some View {
    let sources = [1: SourceInfo(id: 1, title: "Liquid Glass", url: "https://developer.apple.com/docs", snippet: "Docs."),
                   2: SourceInfo(id: 2, title: "HWS", url: "https://www.hackingwithswift.com/", snippet: "Learn.")]
    return ScrollView {
        VStack(alignment: .leading, spacing: DS.Spacing.xl) {
            MessageBubble(text: "Does Naver open an API for my order history?")
            AssistantMessage(
                content: .init(thinkingSeconds: 4,
                               calls: [.init(id: "1", name: "web_search", arguments: "{\"query\":\"naver api\"}", result: "", isError: false, sourceIDs: [1, 2])],
                               canRegenerate: true),
                render: MessageRenderState(text: "No. Naver does **not** expose order history [1][2].\n\n- Login API [1]\n- Blog API [9]\n\n```swift\nlet x = 1\n```",
                                           reasoning: "Checking the docs."))
            AssistantMessage(
                content: .init(segments: [
                    .init(index: 0, kind: .thinking, text: "Need current docs.", seconds: 7),
                    .init(index: 1, kind: .text, text: "Let me check the official guidance."),
                    .init(index: 2, kind: .toolRound, calls: [.init(id: "2", name: "web_search", arguments: "{\"query\":\"liquid glass\"}", result: "", isError: false, sourceIDs: [1, 2])]),
                ]),
                render: MessageRenderState(text: "Use glass on **controls** only [1]."))
            AssistantMessage(content: .init(isStreaming: true, phase: .thinking, turnStart: .now),
                             render: MessageRenderState(reasoning: "Let me think about the plan"))
            AssistantMessage(content: .init(errorText: "Add an API key for Strata in Settings.", errorNeedsSettings: true), render: MessageRenderState())
        }
        .padding()
    }
    .environment(\.citations, CitationContext(sources: sources))
}
