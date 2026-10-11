import SwiftUI
import MarkdownUI

/// Right-aligned user message bubble with optional image thumbnails.
struct MessageBubble: View {
    @Environment(\.theme) private var theme
    let text: String
    var images: [Data] = []
    var branch: BranchPosition?
    var branchEnabled = true
    var onSwitchBranch: (Int) -> Void = { _ in }
    var onCopy: (() -> Void)?
    /// Nil hides Edit (while a reply is streaming).
    var onEdit: (() -> Void)?

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
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.md)
                        .background(theme.bubble, in: RoundedRectangle(cornerRadius: DS.Radius.bubble))
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: DS.Radius.bubble))
                        .contextMenu {
                            if let onCopy { Button("Copy", systemImage: "doc.on.doc", action: onCopy) }
                            if let onEdit { Button("Edit", systemImage: "pencil", action: onEdit) }
                        }
                }
                if let branch {
                    BranchSwitcher(position: branch, isEnabled: branchEnabled, onSwitch: onSwitchBranch)
                }
            }
        }
    }
}

/// `‹ 1 / 2 ›`: which version of a message is showing, with arrows to the others.
struct BranchSwitcher: View {
    @Environment(\.theme) private var theme
    let position: BranchPosition
    var isEnabled = true
    let onSwitch: (Int) -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Button { onSwitch(-1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                .disabled(!isEnabled || position.index <= 1)
                .accessibilityLabel(Text("Previous version"))
            Text("\(position.index) / \(position.count)")
                .font(DS.Typography.uiCaption)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            Button { onSwitch(1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28) }
                .disabled(!isEnabled || position.index >= position.count)
                .accessibilityLabel(Text("Next version"))
        }
        .font(.system(size: DS.IconSize.sm, weight: .semibold))
        .foregroundStyle(theme.textSecondary)
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text("\(position.index) of \(position.count)"))
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
    var translation = TranslationUI.none
    var onTranslate: () -> Void = {}
    var branch: BranchPosition?
    var branchEnabled = true
    var onSwitchBranch: (Int) -> Void = { _ in }
    @State private var copied = false

    private func flash() {
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.lg) {
            if let branch { BranchSwitcher(position: branch, isEnabled: branchEnabled, onSwitch: onSwitchBranch) }
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
            if translation.offered {
                Button(action: onTranslate) {
                    if translation.isTranslating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "translate")
                            .foregroundStyle(translation.showing ? theme.accent : theme.textSecondary)
                    }
                }
                .disabled(translation.isTranslating)
                .accessibilityLabel(Text(translation.hasTranslation
                                         ? (translation.showing ? "Show original" : "Show translation") : "Translate"))
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
    /// The running round's calls in request order, and the ones that finished, for the live tool rows.
    var roundRequested: [PendingToolCall] = []
    var roundFinished: [ToolCallRecord] = []
    var isStreaming = false
    var phase: ChatController.Phase = .idle
    var turnStart: Date?
    var errorText: String?
    var errorNeedsSettings = false
    var stopped = false
    var canRegenerate = false
    var translation = TranslationUI.none
    /// "Answer now" can be offered for this running turn (the pill still waits for its timing), and how many tool
    /// rounds have finished.
    var canAnswerNow = false
    var completedToolRounds = 0
    /// The run an early answer cut short, and the answer written after it.
    var cutForEarlyAnswer = false
    var answeredEarly = false
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
    /// Translates the answer, or flips between the translation and the original.
    var onTranslate: () -> Void = {}
    var onToggleTranslation: () -> Void = {}
    var onAnswerNow: () -> Void = {}
    var branch: BranchPosition?
    var branchEnabled = true
    var onSwitchBranch: (Int) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tail: MessageLayout.Tail {
        MessageLayout.tail(isStreaming: content.isStreaming, pendingCount: content.pending.count,
                           hasRoundText: render.markdown.hasContent)
    }

    private var items: [MessageLayout.Item] {
        MessageLayout.items(segmentCount: content.segments.count, tail: tail, isStreaming: content.isStreaming,
                            hasAnswer: render.markdown.hasContent)
    }

    private var phaseLabel: String {
        switch content.phase {
        case .tool(let name, _): name == ToolNames.webSearch ? String(localized: "Searching") : String(localized: "Reading")
        case .compacting: String(localized: "Summarizing conversation…")
        default: String(localized: "Thinking")
        }
    }

    /// Visited pages plus cited results, for the "Sources" list.
    private var usedSources: [SourceInfo] {
        var ids: [Int] = content.calls.filter { $0.name == ToolNames.webFetch }.flatMap(\.sourceIDs)
        for id in CitationParser.citedIDs(in: render.markdown.text, known: Set(citations.sources.keys)) where !ids.contains(id) { ids.append(id) }
        return ids.compactMap { citations.sources[$0] }
    }

    @ViewBuilder
    private func itemView(_ item: MessageLayout.Item) -> some View {
        switch item {
        case .summary:
            ActivitySummaryRow(summary: ProcessSummary(segments: content.segments, fallbackSeconds: content.thinkingSeconds),
                               action: onOpenTimeline)
        case .liveThinking:
            LiveThinkingTail(label: phaseLabel, start: content.turnStart ?? .now, reasoning: render.reasoning, action: onOpenTimeline)
        case .liveTools:
            LiveToolsTail(label: phaseLabel, start: content.turnStart ?? .now,
                          entries: ActivityEntry.roundEntries(requested: content.roundRequested, finished: content.roundFinished,
                                                              sources: citations.sources),
                          action: onOpenTimeline)
        case .text:
            answerText
        case .divider:
            ProcessDivider()
        }
    }

    /// The answer, or its translation with a way back. The two crossfade.
    @ViewBuilder
    private var answerText: some View {
        let tr = content.translation
        let showingTranslation = tr.showing && tr.translatedText != nil
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if tr.hasTranslation || tr.isTranslating || tr.error != nil {
                TranslationBanner(translation: tr, onToggle: onToggleTranslation)
                    .transition(.opacity)
            }
            Group {
                if showingTranslation, let text = tr.translatedText {
                    MarkdownDocumentView(model: render.translatedMarkdown(text)).id("translated")
                } else {
                    MarkdownDocumentView(model: render.markdown).id("original")
                }
            }
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : DS.Motion.ease, value: showingTranslation)
        .animation(reduceMotion ? nil : DS.Motion.ease, value: tr.isTranslating)
        .modifier(TranslationMenu(translation: tr, onTranslate: onTranslate, onToggle: onToggleTranslation, onCopy: onCopy))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ForEach(items) { item in
                itemView(item)
                    .transition(.enter(reduceMotion: reduceMotion))
            }
            .animation(reduceMotion ? nil : DS.Motion.enter, value: items)
            if content.isStreaming && content.canAnswerNow {
                AnswerNowPill(start: content.turnStart ?? .now, completedToolRounds: content.completedToolRounds,
                              phase: content.phase, action: onAnswerNow)
            }
            if content.stopped && !content.cutForEarlyAnswer {
                Text("Stopped").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
            }
            if content.answeredEarly && !content.isStreaming {
                Text("Answered early").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
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
                MessageActionBar(onCopy: onCopy, onCopyRaw: onCopyRaw, onRegenerate: content.canRegenerate ? onRegenerate : nil,
                                 translation: content.translation,
                                 onTranslate: content.translation.hasTranslation ? onToggleTranslation : onTranslate,
                                 branch: branch, branchEnabled: branchEnabled, onSwitchBranch: onSwitchBranch)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Offers to cut a long run short. Appears once the run has gone on for a while (or has searched a couple of times).
struct AnswerNowPill: View {
    @Environment(\.theme) private var theme
    let start: Date
    let completedToolRounds: Int
    let phase: ChatController.Phase
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if AnswerNow.isOffered(elapsed: context.date.timeIntervalSince(start), completedToolRounds: completedToolRounds, phase: phase) {
                Button(action: action) {
                    Label("Answer now", systemImage: "forward.end.fill")
                        .font(DS.Typography.uiSmall)
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.sm)
                }
                .buttonStyle(.glass)
                .foregroundStyle(theme.textPrimary)
                .transition(.opacity)
                .accessibilityHint(Text("Stops searching and answers from what has been found"))
            }
        }
    }
}

/// The long-press menu of an answer that can be translated. Answers that cannot be get no menu at all, so nothing
/// competes with text selection there.
private struct TranslationMenu: ViewModifier {
    let translation: TranslationUI
    let onTranslate: () -> Void
    let onToggle: () -> Void
    let onCopy: () -> Void

    func body(content: Content) -> some View {
        if translation.offered {
            content.contextMenu {
                if translation.hasTranslation {
                    Button(translation.showing ? "Show original" : "Show translation", systemImage: "translate", action: onToggle)
                } else {
                    Button("Translate", systemImage: "translate", action: onTranslate).disabled(translation.isTranslating)
                }
                Button("Copy", systemImage: "doc.on.doc", action: onCopy)
            }
        } else {
            content
        }
    }
}

/// "Translated · Show original" above a translated answer; progress while it is being translated; the reason when it failed.
struct TranslationBanner: View {
    @Environment(\.theme) private var theme
    let translation: TranslationUI
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            if translation.isTranslating {
                ProgressView().controlSize(.mini)
                Text("Translating…")
            } else if let error = translation.error, !translation.hasTranslation {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                Text(error)
            } else {
                Button(action: onToggle) {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: "translate")
                        Text(translation.showing ? "Translated" : "Original")
                        Text("·")
                        Text(translation.showing ? "Show original" : "Show translation").foregroundStyle(theme.accent)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .font(DS.Typography.uiCaption)
        .foregroundStyle(theme.textSecondary)
        .accessibilityElement(children: .combine)
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
