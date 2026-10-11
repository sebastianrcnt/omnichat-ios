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
            .table { c in c.label.markdownMargin(top: 0, bottom: 0) }
    }
}

/// Copy and regenerate under an answer.
struct MessageActionBar: View {
    @Environment(\.theme) private var theme
    let onCopy: () -> Void
    var onRegenerate: (() -> Void)?
    @State private var copied = false

    var body: some View {
        HStack(spacing: DS.Spacing.lg) {
            Button {
                onCopy()
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .contentTransition(.symbolEffect(.replace))
            }
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
    var pending: [PendingToolCall] = []
    var isStreaming = false
    var phase: ChatController.Phase = .idle
    var errorText: String?
    var stopped = false
    var canRegenerate = false
}

struct AssistantMessage: View {
    @Environment(\.theme) private var theme
    let content: AssistantContent
    let render: MessageRenderState
    var onOpenThinking: () -> Void = {}
    var onCopy: () -> Void = {}
    var onRegenerate: () -> Void = {}

    private var isThinkingLive: Bool {
        content.isStreaming && (content.phase == .thinking || content.phase == .waiting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if isThinkingLive || render.reasoning.hasContent {
                ThinkingRowHost(reasoning: render.reasoning, isLive: isThinkingLive,
                                seconds: content.thinkingSeconds, action: onOpenThinking)
            }
            if !content.calls.isEmpty || !content.pending.isEmpty {
                ToolActivityRow(calls: content.calls, pending: content.pending)
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
                    Text(error).font(DS.Typography.uiSmall).foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(DS.Spacing.md)
                .background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.md))
            }
            if !content.isStreaming && (render.markdown.hasContent || content.errorText != nil) {
                MessageActionBar(onCopy: onCopy, onRegenerate: content.canRegenerate ? onRegenerate : nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reads the reasoning model's last line in its own view, so per-tick changes stay local.
private struct ThinkingRowHost: View {
    let reasoning: ReasoningChunkModel
    let isLive: Bool
    let seconds: Double?
    let action: () -> Void

    var body: some View {
        ThinkingRow(state: isLive ? .live(preview: reasoning.lastLine) : .done(seconds: seconds ?? 0), action: action)
    }
}

#Preview("Light · Purple") { messagesPreview.previewStyle(.light) }
#Preview("Dark · Purple") { messagesPreview.previewStyle(.dark) }
#Preview("Dark · Orange") { messagesPreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }

@MainActor private var messagesPreview: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: DS.Spacing.xl) {
            MessageBubble(text: "Does Naver open an API for my order history?")
            AssistantMessage(
                content: .init(thinkingSeconds: 4,
                               calls: [.init(id: "1", name: "web_search", arguments: "{\"query\":\"naver api\"}", result: "", isError: false)],
                               canRegenerate: true),
                render: MessageRenderState(text: "No. Naver does **not** expose order history.\n\n- Login API\n- Blog API\n\n```swift\nlet x = 1\n```",
                                           reasoning: "Checking the docs."))
            AssistantMessage(content: .init(isStreaming: true, phase: .thinking),
                             render: MessageRenderState(reasoning: "Let me think about the plan"))
            AssistantMessage(content: .init(errorText: "HTTP 401: invalid API key"), render: MessageRenderState())
        }
        .padding()
    }
}
