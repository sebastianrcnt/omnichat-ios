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
                        .bubbleContextMenuShape()
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
    static func strata(_ t: DSTheme, scale: CGFloat = 1) -> MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text {
                FontFamily(.custom(DS.Typography.family))
                FontSize(17 * scale)
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
                c.label.fixedSize(horizontal: false, vertical: true).relativeLineSpacing(.em(DS.Leading.answer.em)).markdownMargin(top: 0, bottom: 0)
            }
            .listItem { c in c.label.markdownMargin(top: .em(0.35)) }
            .blockquote { c in
                // Same card as a top-level quote (`QuoteBlockView`), for quotes nested in lists or other quotes.
                c.label
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(t.quoteFill, in: UnevenRoundedRectangle(bottomTrailingRadius: DS.Radius.quote, topTrailingRadius: DS.Radius.quote))
                    .overlay(alignment: .leading) { Rectangle().fill(t.textSecondary).frame(width: 3) }
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
                        FontFamily(.custom(DS.Typography.family))
                        FontSize(.em(0.88))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, DS.Spacing.sm)
                    .padding(.horizontal, DS.Spacing.md)
                    .relativeLineSpacing(.em(DS.Leading.ui.em))
            }
    }
}

/// Text the model wrote to the person between tool rounds, set like the answer.
struct NoteText: View {
    @State private var model: StreamingMarkdownModel

    init(text: String) {
        _model = State(initialValue: StreamingMarkdownModel(text: text, smoothing: false))
    }

    var body: some View {
        MarkdownDocumentView(model: model)
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
    /// The run an early answer cut short, and the answer written after it.
    var cutForEarlyAnswer = false
    var answeredEarly = false
}

struct AssistantMessage: View {
    @Environment(\.theme) private var theme
    @Environment(\.citations) private var citations
    let content: AssistantContent
    let render: MessageRenderState
    /// The Timeline sheet (reasoning and every tool call), and the reasoning alone (the thought line).
    var onOpenTimeline: () -> Void = {}
    var onOpenReasoning: () -> Void = {}
    var onOpenSources: ([SourceInfo]) -> Void = { _ in }
    var onCopy: () -> Void = {}
    var onRegenerate: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onCopyRaw: (() -> Void)?
    /// Translates the answer, or flips between the translation and the original.
    var onTranslate: () -> Void = {}
    var onToggleTranslation: () -> Void = {}
    var branch: BranchPosition?
    var branchEnabled = true
    var onSwitchBranch: (Int) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var answerStarted: Bool {
        MessageLayout.answerStarted(isStreaming: content.isStreaming, pendingCount: content.pending.count,
                                    hasRoundText: render.markdown.hasContent)
    }

    /// The work before the answer in stream order: feeds of calls, and what the model wrote between them.
    private var parts: [MessageLayout.Part] {
        MessageLayout.parts(segments: content.segments,
                            hasLiveCalls: !content.roundRequested.isEmpty || !content.roundFinished.isEmpty)
    }

    /// Each feed's calls; the last feed ends with the running round in request order.
    private func feeds(_ parts: [MessageLayout.Part]) -> [[FeedCall]] {
        let groups = parts.compactMap { part -> [ToolCallRecord]? in if case .calls(let c) = part { c } else { nil } }
        return groups.enumerated().map { i, records in
            i == groups.count - 1
                ? FeedCall.ordered(finished: records, requested: content.roundRequested, roundFinished: content.roundFinished)
                : FeedCall.ordered(finished: records, requested: [], roundFinished: [])
        }
    }

    private func notes(_ parts: [MessageLayout.Part]) -> [Int: String] {
        var out: [Int: String] = [:]
        for case .note(let segment, let text) in parts { out[segment] = text }
        return out
    }

    private var hasThought: Bool {
        content.thinkingSeconds != nil || content.segments.contains { $0.kind == .thinking }
    }

    private func items(_ parts: [MessageLayout.Part]) -> [MessageLayout.Item] {
        MessageLayout.items(hasThought: hasThought, parts: parts, isStreaming: content.isStreaming,
                            isWorking: !answerStarted, hasAnswer: render.markdown.hasContent)
    }

    private func thoughtSeconds(_ parts: [MessageLayout.Part]) -> [Int: Double?] {
        var out: [Int: Double?] = [:]
        for case .thought(let segment, let seconds) in parts { out[segment] = seconds }
        return out
    }

    private var phaseLabel: String {
        switch content.phase {
        case .tool(let name, _):
            switch name {
            case ToolNames.webSearch: String(localized: "Searching")
            case ToolNames.runPython: String(localized: "Running Python")
            case ToolNames.viewImage: String(localized: "Looking at the image")
            case ToolNames.browserOpen: String(localized: "Browsing")
            case ToolNames.browserEval: String(localized: "Running a script")
            case ToolNames.loadSkill: String(localized: "Reading a skill")
            case ToolNames.saveSkill: String(localized: "Waiting for your answer")
            case ToolNames.showPlaces: String(localized: "Mapping places")
            case ToolNames.currentLocation: String(localized: "Finding your location")
            default: String(localized: "Reading")
            }
        case .compacting: String(localized: "Summarizing conversation…")
        default: String(localized: "Thinking")
        }
    }

    /// Visited pages plus cited results, for the "Sources" list.
    private var usedSources: [SourceInfo] {
        let text = MessageLayout.fullText(segments: content.segments, answer: render.markdown.text)
        return SourceUsage.ids(calls: content.calls, text: text, known: Set(citations.sources.keys))
            .compactMap { citations.sources[$0] }
    }

    @ViewBuilder
    private func itemView(_ item: MessageLayout.Item, feeds: [[FeedCall]], notes: [Int: String],
                          thoughts: [Int: Double?]) -> some View {
        switch item {
        case .thought:
            ThoughtLine(isWorking: false, seconds: content.thinkingSeconds, placeholder: phaseLabel,
                        action: onOpenReasoning, onDetails: onOpenTimeline)
        case .reasoning(let segment):
            ThoughtLine(isWorking: false, seconds: thoughts[segment] ?? nil, placeholder: phaseLabel,
                        action: onOpenReasoning, onDetails: onOpenTimeline)
        case .working:
            ThoughtLine(isWorking: true, reasoning: render.reasoning, placeholder: phaseLabel,
                        action: onOpenReasoning, onDetails: onOpenTimeline)
        case .feed(let n):
            // A feed with a note after it is done: it folds like a feed does once the answer starts.
            let isLast = n == feeds.count - 1
            ActivityFeedView(cards: ActivityFeed.cards(calls: feeds.indices.contains(n) ? feeds[n] : [], sources: citations.sources),
                             isStreaming: content.isStreaming, answerStarted: isLast ? answerStarted : true, onDetails: onOpenTimeline)
        case .note(let segment):
            if let text = notes[segment] { NoteText(text: text) }
        case .text:
            answerText
        }
    }

    /// The live text becomes a note in place when the model calls a tool after it, so neither animates.
    private func transition(_ item: MessageLayout.Item) -> AnyTransition {
        switch item {
        case .note: .asymmetric(insertion: .identity, removal: .enter(reduceMotion: reduceMotion))
        case .text: .asymmetric(insertion: .enter(reduceMotion: reduceMotion), removal: .identity)
        default: .enter(reduceMotion: reduceMotion)
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
            // Once the answer is done, the turn's figures it didn't place still show, so none hides in a folded card.
            if !content.isStreaming {
                let unplaced = FigureReference.unplaced(content.calls.flatMap { $0.figures ?? [] }, text: render.markdown.text)
                if !unplaced.isEmpty { UnplacedFigures(figures: unplaced) }
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.ease, value: showingTranslation)
        .animation(reduceMotion ? nil : DS.Motion.ease, value: tr.isTranslating)
        .modifier(TranslationMenu(translation: tr, onTranslate: onTranslate, onToggle: onToggleTranslation, onCopy: onCopy))
    }

    var body: some View {
        let parts = parts
        let feeds = feeds(parts)
        let notes = notes(parts)
        let thoughts = thoughtSeconds(parts)
        let items = items(parts)
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ForEach(items) { item in
                itemView(item, feeds: feeds, notes: notes, thoughts: thoughts)
                    .transition(transition(item))
            }
            .animation(reduceMotion ? nil : DS.Motion.enter, value: items)
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
            if !content.isStreaming { // also for an answer without tools that cites earlier sources
                let used = usedSources
                if !used.isEmpty { SourcesRow(count: used.count) { onOpenSources(used) } }
            }
            if !content.isStreaming && (render.markdown.hasContent || !notes.isEmpty || content.errorText != nil) {
                MessageActionBar(onCopy: onCopy, onCopyRaw: onCopyRaw, onRegenerate: content.canRegenerate ? onRegenerate : nil,
                                 translation: content.translation,
                                 onTranslate: content.translation.hasTranslation ? onToggleTranslation : onTranslate,
                                 branch: branch, branchEnabled: branchEnabled, onSwitchBranch: onSwitchBranch)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private extension View {
    /// The rounded outline the context menu lifts on iOS. (A Mac menu has no preview.)
    func bubbleContextMenuShape() -> some View {
        #if os(iOS)
        contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: DS.Radius.bubble))
        #else
        self
        #endif
    }
}
