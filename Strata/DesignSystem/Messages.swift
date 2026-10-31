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
    /// This is the message the composer is editing: outlined, with a label under it.
    var isEditing = false
    @State private var copies = 0
    @State private var selecting = false

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
                        .overlay {
                            RoundedRectangle(cornerRadius: DS.Radius.bubble)
                                .strokeBorder(theme.accent, lineWidth: 1.5)
                                .opacity(isEditing ? 1 : 0)
                        }
                        .bubbleContextMenuShape()
                        .contextMenu {
                            if let onCopy { Button("Copy", systemImage: "doc.on.doc") { onCopy(); copies += 1 } }
                            Button("Select Text", systemImage: "selection.pin.in.out") { selecting = true }
                            if let onEdit { Button("Edit", systemImage: "pencil", action: onEdit) }
                        }
                        .sensoryFeedback(.success, trigger: copies)
                        .sheet(isPresented: $selecting) { SelectableTextSheet(text: text) }
                }
                if isEditing {
                    Label("Editing", systemImage: "pencil")
                        .font(DS.Typography.uiCaption)
                        .foregroundStyle(theme.accent)
                        .transition(.opacity)
                } else if let branch {
                    BranchSwitcher(position: branch, isEnabled: branchEnabled, onSwitch: onSwitchBranch)
                }
            }
            .animation(DS.Motion.snappy, value: isEditing)
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
            Button { onSwitch(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 28, height: 28)
                    .frame(width: 44, height: 44).contentShape(Rectangle()) // a finger-sized target around the small arrow
            }
                .disabled(!isEnabled || position.index <= 1)
                .accessibilityLabel(Text("Previous version"))
            Text("\(position.index) / \(position.count)")
                .font(DS.Typography.uiCaption)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            Button { onSwitch(1) } label: {
                Image(systemName: "chevron.right").frame(width: 28, height: 28)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
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
                c.label.fixedSize(horizontal: false, vertical: true).relativeLineSpacing(.em(DS.Leading.answer.em))
                    .markdownMargin(top: 0, bottom: DS.Spacing.md) // only between blocks nested in a list or quote
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
                    .markdownMargin(top: DS.Spacing.md, bottom: DS.Spacing.md)
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
                // Room above and below when it sits among a list's items or paragraphs in one block (MarkdownUI
                // spaces blocks by these margins; a top-level block's own spacing comes from `DS.blockSpacing`).
                .markdownMargin(top: DS.Spacing.md, bottom: DS.Spacing.md)
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
                .markdownMargin(top: DS.Spacing.md, bottom: DS.Spacing.md)
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

/// Copy, share and regenerate under an answer.
struct MessageActionBar: View {
    @Environment(\.theme) private var theme
    let onCopy: () -> Void
    var onCopyRaw: (() -> Void)?
    /// The answer as text for the share sheet (`AnswerShare`); nil hides Share.
    var shareText: (() -> String)?
    var onRegenerate: (() -> Void)?
    var translation = TranslationUI.none
    var onTranslate: () -> Void = {}
    var branch: BranchPosition?
    var branchEnabled = true
    var onSwitchBranch: (Int) -> Void = { _ in }
    /// The answer as plain text, for "Select Text" (part of it copied). Made only when asked for.
    var textForSelection: (() -> String)?
    @State private var copied = false
    @State private var selection: SelectionText?

    struct SelectionText: Identifiable { let id = UUID(); let text: String }

    private func flash() {
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    var body: some View {
        HStack(spacing: 0) {
            if let branch { BranchSwitcher(position: branch, isEnabled: branchEnabled, onSwitch: onSwitchBranch) }
            Menu {
                Button("Copy", systemImage: "doc.on.doc") { onCopy(); flash() }
                if let onCopyRaw {
                    Button("Copy raw Markdown", systemImage: "chevron.left.forwardslash.chevron.right") { onCopyRaw(); flash() }
                }
                if let textForSelection {
                    Button("Select Text", systemImage: "selection.pin.in.out") { selection = SelectionText(text: textForSelection()) }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .contentTransition(.symbolEffect(.replace))
                    .actionTarget()
            } primaryAction: { onCopy(); flash() }
            .accessibilityLabel(Text("Copy"))
            if let shareText {
                ShareLink(item: shareText()) { Image(systemName: "square.and.arrow.up").actionTarget() }
                    .accessibilityLabel(Text("Share"))
            }
            if let onRegenerate {
                Button(action: onRegenerate) { Image(systemName: "arrow.clockwise").actionTarget() }
                    .accessibilityLabel(Text("Regenerate"))
            }
            if translation.offered {
                Button(action: onTranslate) {
                    Group {
                        if translation.isTranslating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "translate")
                                .foregroundStyle(translation.showing ? theme.accent : theme.textSecondary)
                        }
                    }
                    .actionTarget()
                }
                .disabled(translation.isTranslating)
                .accessibilityLabel(Text(translation.hasTranslation
                                         ? (translation.showing ? "Show original" : "Show translation") : "Translate"))
            }
            Spacer()
        }
        .padding(.leading, -DS.Spacing.sm - 2) // the first glyph lines up with the answer, its touch target reaches past
        .sheet(item: $selection) { SelectableTextSheet(text: $0.text) }
        .font(.system(size: DS.IconSize.md))
        .foregroundStyle(theme.textSecondary)
        .buttonStyle(.plain)
    }
}

/// A sent message's text, selectable: the bubble's long press is its menu, so part of a long prompt is copied here.
/// SwiftUI's own selectable text copies only the whole text on iPhone; a UIKit text view selects a range by dragging.
struct SelectableTextSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select Text").font(DS.Typography.uiEmphasis).foregroundStyle(theme.textPrimary)
                Spacer()
                Button("Done") { dismiss() }.fontWeight(.semibold)
            }
            .padding(DS.Spacing.lg)
            RangeSelectableText(text: text, color: theme.textPrimary)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(theme.background)
    }
}

#if canImport(UIKit)
private struct RangeSelectableText: UIViewRepresentable {
    let text: String
    let color: Color

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 0, left: 16, bottom: 24, right: 16)
        view.adjustsFontForContentSizeCategory = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        view.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: DS.Typography.regularFontName, size: 17) ?? .systemFont(ofSize: 17)),
            .foregroundColor: UIColor(color),
            .paragraphStyle: style,
        ])
    }
}
#else
private struct RangeSelectableText: View {
    let text: String
    let color: Color
    var body: some View {
        ScrollView {
            Text(verbatim: text).textSelection(.enabled).foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, DS.Spacing.lg)
        }
    }
}
#endif

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
    /// A running call waits for what another chat is using (the browser, Python).
    var waiting: ToolWaits.Reason?
    var turnStart: Date?
    var errorText: String?
    var errorNeedsSettings = false
    var errorManagesUsage = false
    var stopped = false
    var canRegenerate = false
    var translation = TranslationUI.none
    /// The run an early answer cut short, and the answer written after it.
    var cutForEarlyAnswer = false
    var answeredEarly = false
    /// "Save as skill" under the answer (`SkillOffer`).
    var offersSkill = false
}

struct AssistantMessage: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
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
    /// The answer as plain text for "Select Text", made only when asked for.
    var textForSelection: (() -> String)?
    /// The answer's Markdown as shown (the translation when that is showing), for Share.
    var shareMarkdown: (() -> String)?
    @State private var selectionText: MessageActionBar.SelectionText?
    /// Translates the answer, or flips between the translation and the original.
    var onTranslate: () -> Void = {}
    var onToggleTranslation: () -> Void = {}
    var branch: BranchPosition?
    var branchEnabled = true
    var onSwitchBranch: (Int) -> Void = { _ in }
    var onSaveSkill: () -> Void = {}
    var onDismissSkillOffer: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The mode the fold line was tapped open in (`ProcessFold`); nil while folded.
    @State private var expandedFold: ProcessFold.Mode? = Self.debugOpenFold

    /// `-StrataOpenFold 1` (Debug builds): finished messages start with their work open, for screenshots.
    private static var debugOpenFold: ProcessFold.Mode? {
        #if DEBUG
        if DebugHooks.value("StrataOpenFold") != nil { return .summary }
        #endif
        return nil
    }

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

    private func thoughtLines(_ parts: [MessageLayout.Part]) -> [Int: (line: String, seconds: Double?)] {
        var out: [Int: (line: String, seconds: Double?)] = [:]
        for case .thought(let segment, let seconds, let line) in parts { out[segment] = (line, seconds) }
        return out
    }

    /// The work's rows and how much of them shows (`ProcessFold`), with each feed's cards and the fold line's title.
    struct FoldState {
        var cards: [[FeedCard]]
        var rows: [ProcessFold.Row]
        var plan: ProcessFold.Plan
        var title: String
    }

    private func foldState(items: [MessageLayout.Item], feeds: [[FeedCall]], notes: [Int: String],
                           parts: [MessageLayout.Part]) -> FoldState {
        let cards = feeds.map { ActivityFeed.cards(calls: $0, sources: citations.sources) }
        var feedItems: [Int: [BrowserRun.Item]] = [:]
        var attention: Set<String> = []
        for (n, feed) in cards.enumerated() {
            let entries = BrowserRun.items(feed)
            feedItems[n] = entries
            for entry in entries where waitsForPerson(entry) { attention.insert(entry.id) }
        }
        let rows = ProcessFold.rows(items: items, feedItems: feedItems, notes: notes, attention: attention)
        let working = ProcessFold.isWorking(isStreaming: content.isStreaming, answerStarted: answerStarted,
                                            answerText: render.markdown.text)
        let plan = ProcessFold.plan(rows: rows, working: working, hasAnswer: render.markdown.hasContent)
        let title = switch plan.mode {
        case .earlier: ProcessFold.earlierTitle(plan)
        case .summary, .open:
            ProcessFold.Summary(cards: cards.flatMap { $0 },
                                thinkingSeconds: ProcessFold.thinkingSeconds(segments: content.segments, whole: content.thinkingSeconds)).title
        }
        return FoldState(cards: cards, rows: rows, plan: plan, title: title)
    }

    /// A running call of this entry has a card asking the person (an approval): it never folds away.
    private func waitsForPerson(_ entry: BrowserRun.Item) -> Bool {
        let steps = switch entry {
        case .card(let card): [card]
        case .run(let run): run.steps
        }
        return steps.contains { card in
            card.isRunning && (ToolApprovals.shared.request(forCall: card.id, conversation: citations.conversationID) != nil
                               || HealthRequests.shared.request(forCall: card.id, conversation: citations.conversationID) != nil)
        }
    }

    /// The fold line was tapped open in its current mode (opening "earlier steps" doesn't open the summary later).
    private func foldExpanded(_ plan: ProcessFold.Plan) -> Bool { plan.mode != .open && expandedFold == plan.mode }

    /// A tool is running: the live line says what it does, not the thought from before the call. So does a reply waiting
    /// for its turn.
    private var toolRunning: Bool {
        if case .tool = content.phase { return true }
        if case .drafting = content.phase { return true }
        if content.phase == .queued { return true }
        return !content.pending.isEmpty
    }

    private var phaseLabel: String {
        if let waiting = content.waiting { return waiting.label }
        switch content.phase {
        case .queued: return String(localized: "Waiting for another chat to finish")
        case .drafting(let name, let title, let bytes): return Self.draftingLabel(name: name, title: title, bytes: bytes)
        default: return toolPhaseLabel
        }
    }

    /// "Making “Mortgage calculator” · 12 KB" while the model writes a long tool call; the size once there is a KB.
    static func draftingLabel(name: String, title: String, bytes: Int) -> String {
        let what = switch name {
        case ToolNames.showHTML where !title.isEmpty: String(localized: "Making “\(title)”")
        case ToolNames.showHTML: String(localized: "Making an artifact")
        case ToolNames.runPython: String(localized: "Writing code")
        default: String(localized: "Writing a skill")
        }
        guard bytes >= 1024 else { return what }
        return what + " · " + bytes.formatted(.byteCount(style: .file))
    }

    private var isDrafting: Bool {
        if case .drafting = content.phase { return true }
        return false
    }

    private var toolPhaseLabel: String {
        switch content.phase {
        case .tool(let name, _):
            switch name {
            case ToolNames.webSearch: String(localized: "Searching")
            case ToolNames.runPython: String(localized: "Running Python")
            case ToolNames.viewImage: String(localized: "Looking at the image")
            case ToolNames.browserOpen: String(localized: "Browsing")
            case _ where ToolNames.isBrowserAction(name): String(localized: "Browsing")
            case ToolNames.browserEval, ToolNames.runSkillScript: String(localized: "Running a script")
            case ToolNames.loadSkill: String(localized: "Reading a skill")
            case ToolNames.saveSkill: String(localized: "Waiting for your answer")
            case ToolNames.browserShow: String(localized: "Waiting for you in the browser")
            case ToolNames.showPlaces: String(localized: "Mapping places")
            case ToolNames.showHTML: String(localized: "Making an artifact")
            case ToolNames.currentLocation: String(localized: "Finding your location")
            case _ where SSHToolNames.connects(name): String(localized: "Working on a server")
            case ToolNames.videoTranscript: String(localized: "Reading the transcript")
            case ToolNames.healthQuery: String(localized: "Reading health data")
            case _ where PackageToolNames.covers(name): String(localized: "Using \(PackageToolNames.packageName(of: name))")
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
                          thoughts: [Int: (line: String, seconds: Double?)], fold: FoldState) -> some View {
        switch item {
        case .fold:
            let expanded = foldExpanded(fold.plan)
            ProcessFoldLine(title: fold.title, mode: fold.plan.mode, expanded: expanded,
                            onToggle: {
                                withAnimation(reduceMotion ? nil : ActivityFeedView.fold) {
                                    expandedFold = expanded ? nil : fold.plan.mode
                                }
                            },
                            onDetails: onOpenTimeline)
        case .thought:
            ThoughtLine(isWorking: false, line: MessageLayout.lastLine(of: render.reasoning.text), seconds: content.thinkingSeconds,
                        placeholder: phaseLabel, takesOverLive: content.isStreaming, action: onOpenReasoning, onDetails: onOpenTimeline)
        case .reasoning(let segment):
            ThoughtLine(isWorking: false, line: thoughts[segment]?.line, seconds: thoughts[segment]?.seconds ?? nil,
                        placeholder: phaseLabel, takesOverLive: content.isStreaming, action: onOpenReasoning, onDetails: onOpenTimeline)
        case .working:
            ThoughtLine(isWorking: true, reasoning: toolRunning ? nil : render.reasoning, placeholder: phaseLabel,
                        action: onOpenReasoning, onDetails: onOpenTimeline)
        case .feed(let n):
            // A feed with a note after it is done: it folds like a feed does once the answer starts.
            let isLast = n == feeds.count - 1
            ActivityFeedView(cards: fold.cards.indices.contains(n) ? fold.cards[n] : [],
                             isStreaming: content.isStreaming, answerStarted: isLast ? answerStarted : true,
                             earlierHost: n == 0 ? nil : BrowserRun.lastHost(ActivityFeed.cards(calls: feeds.prefix(n).flatMap { $0 }, sources: citations.sources)),
                             hidden: ProcessFold.hiddenFeedItems(feed: n, rows: fold.rows, plan: fold.plan, expanded: foldExpanded(fold.plan)),
                             onDetails: onOpenTimeline)
        case .note(let segment):
            if let text = notes[segment] { NoteText(text: text) }
        case .text:
            answerText
        }
    }

    /// The live text becomes a note in place when the model calls a tool after it, so neither animates. The live thought
    /// line becomes a round's line the same way: it stops where it is.
    private func transition(_ item: MessageLayout.Item) -> AnyTransition {
        switch item {
        case .note: .asymmetric(insertion: .identity, removal: .enter(reduceMotion: reduceMotion))
        case .text: .asymmetric(insertion: .enter(reduceMotion: reduceMotion), removal: .identity)
        case .thought, .reasoning: .asymmetric(insertion: .identity, removal: .quickExit)
        // Its round's line takes its place at once; an `.identity` removal kept it drawn over the answer meanwhile.
        case .working: .asymmetric(insertion: .enter(reduceMotion: reduceMotion), removal: .quickExit)
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
            // The turn's artifacts, as cards in the answer: the result the user asked for, not only a line in the work.
            let artifacts = ArtifactAnswerCard.latest(content.calls)
            if !artifacts.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    ForEach(artifacts, id: \.id) { ArtifactAnswerCard(ref: $0) }
                }
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.ease, value: showingTranslation)
        .animation(reduceMotion ? nil : DS.Motion.ease, value: tr.isTranslating)
        .modifier(TranslationMenu(translation: tr, onTranslate: onTranslate, onToggle: onToggleTranslation, onCopy: onCopy,
                                  onSelect: textForSelection.map { make in { selectionText = .init(text: make()) } }))
        .sheet(item: $selectionText) { SelectableTextSheet(text: $0.text) }
    }

    var body: some View {
        let parts = parts
        let feeds = feeds(parts)
        let notes = notes(parts)
        let thoughts = thoughtLines(parts)
        let all = items(parts)
        let fold = foldState(items: all, feeds: feeds, notes: notes, parts: parts)
        let items = ProcessFold.displayed(items: all, rows: fold.rows, plan: fold.plan, expanded: foldExpanded(fold.plan))
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    itemView(item, feeds: feeds, notes: notes, thoughts: thoughts, fold: fold)
                        .padding(.top, MessageLayout.gap(above: item, after: index > 0 ? items[index - 1] : nil))
                        .transition(transition(item))
                }
            }
            .animation(reduceMotion ? nil : DS.Motion.enter, value: items)
            // Text came before the call being written, so the work's live line has gone: say what is being made below it.
            if isDrafting && answerStarted {
                ThoughtLine(isWorking: true, reasoning: nil, placeholder: phaseLabel, action: onOpenReasoning, onDetails: onOpenTimeline)
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
                        if content.errorManagesUsage {
                            // OpenAI's guidelines: "Manage usage" is the primary action, and nothing retries the request.
                            Button("Manage usage") { openURL(ChatGPTOAuth.usageURL) }
                                .buttonStyle(.glassProminent)
                                .tint(theme.accent)
                        } else if content.errorNeedsSettings {
                            Button("Open Settings", action: onOpenSettings).buttonStyle(.glass)
                        } else if content.canRegenerate {
                            Button("Try again", systemImage: "arrow.clockwise", action: onRegenerate).buttonStyle(.glass)
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
                MessageActionBar(onCopy: onCopy, onCopyRaw: onCopyRaw,
                                 shareText: render.markdown.hasContent ? shareMarkdown.map { markdown in
                                     { AnswerShare.text(markdown: markdown(), sources: usedSources) }
                                 } : nil,
                                 onRegenerate: content.canRegenerate ? onRegenerate : nil,
                                 translation: content.translation,
                                 onTranslate: content.translation.hasTranslation ? onToggleTranslation : onTranslate,
                                 branch: branch, branchEnabled: branchEnabled, onSwitchBranch: onSwitchBranch,
                                 textForSelection: textForSelection)
            }
            if content.offersSkill && !content.isStreaming {
                SkillOfferChip(onSave: onSaveSkill, onDismiss: onDismissSkillOffer)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.enter, value: content.offersSkill)
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
    var onSelect: (() -> Void)?

    func body(content: Content) -> some View {
        if translation.offered {
            content.contextMenu {
                if translation.hasTranslation {
                    Button(translation.showing ? "Show original" : "Show translation", systemImage: "translate", action: onToggle)
                } else {
                    Button("Translate", systemImage: "translate", action: onTranslate).disabled(translation.isTranslating)
                }
                Button("Copy", systemImage: "doc.on.doc", action: onCopy)
                if let onSelect { Button("Select Text", systemImage: "selection.pin.in.out", action: onSelect) }
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
            AssistantMessage(content: .init(errorText: "Add an API key for My server in Settings.", errorNeedsSettings: true), render: MessageRenderState())
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

private extension View {
    /// An action-bar icon with a 44pt touch target; the bar's icons sit at their old spacing (16pt between glyphs).
    func actionTarget() -> some View {
        frame(width: 40, height: 40).contentShape(Rectangle())
    }
}

/// "Save as skill" under an answer that took hard-won web work (`SkillOffer`), with a button to close it.
struct SkillOfferChip: View {
    @Environment(\.theme) private var theme
    let onSave: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSave) {
                Label("Save as skill", systemImage: "wand.and.sparkles")
                    .font(DS.Typography.uiCaption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.leading, DS.Spacing.sm + 2)
                    .padding(.trailing, DS.Spacing.xs)
                    .padding(.vertical, DS.Spacing.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Asks the model to save what worked here as a skill. You approve it before it is saved.")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(DS.Typography.uiCaption.weight(.semibold))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.leading, DS.Spacing.xs)
                    .padding(.trailing, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Don't save as skill")
        }
        .background(theme.chipFill, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
