import SwiftUI
import SwiftData

/// The chat's scroll view: scrolling, following the end and the room under a pinned question. Its body is small and
/// reads only the scroll state; the rows are a stored `Equatable` value (`MessageRows`, which holds the lazy stack), so
/// a change here (the end coming into view, following switched on or off) never re-evaluates them.
struct ChatMessageList<Rows: View>: View {
    let scroll: ChatScroll
    let pin: PinLayout
    let run: ChatRun?
    @ViewBuilder let rows: Rows

    var body: some View {
        @Bindable var scroll = scroll
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                rows
                // Outside the lazy stack, so it always exists: scrolling to it from far above works even before the
                // rows near the end are laid out (a lazy child that far away isn't found, and the scroll did nothing).
                EndMarker(run: run)
                    .id(ChatScroll.endID)
                    .onScrollVisibilityChange(threshold: 0.01) { scroll.setAtBottom($0) } // true scroll position: is the end of the chat on screen?
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(PinLayout.space)).minY } action: {
                        pin.contentEnd = $0
                        scroll.endMoved()
                    }
                if scroll.pinnedID != nil { PinReserve(pin: pin) }
            }
            .padding(.horizontal, DS.Spacing.page)
            .padding(.top, DS.Spacing.md)
            .coordinateSpace(.named(PinLayout.space))
            #if os(macOS)
            .readingColumn()
            #endif
        }
        .scrollPosition($scroll.position)
        // A chat opens at its latest messages.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // While following, growth (a streaming answer, rows laid out at their real heights) keeps the end in place, in
        // step with the layout: no scroll is asked per change. Off, growth extends below and nothing on screen moves
        // (a pinned answer grows into the room under its question; a reader who scrolled up stays where they are).
        .defaultScrollAnchor(scroll.followsBottom ? .bottom : nil, for: .sizeChanges)
        .onScrollGeometryChange(for: PinLayout.Viewport.self) { g in
            PinLayout.Viewport(height: g.containerSize.height - g.contentInsets.top - g.contentInsets.bottom,
                               visibleBottom: g.visibleRect.maxY - g.contentInsets.bottom)
        } action: { _, v in
            pin.viewport = v.height
            pin.visibleBottom = v.visibleBottom
        }
        .onScrollPhaseChange { old, new in
            if new == .interacting { scroll.userBeganScrolling() }
            guard new == .idle, old == .interacting || old == .decelerating else { return }
            scroll.userEndedScrolling(reserveOutOfView: pin.reserveOutOfView)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }
}

/// The end of the chat: it sits one gap above the composer, or above "Answer now" while it can show.
private struct EndMarker: View {
    let run: ChatRun?

    var body: some View {
        let answerNowRoom = (run?.canAnswerNow ?? false) ? DS.IconSize.capsuleHeight + ChatView.floatingGap : 0
        Color.clear.frame(height: ChatView.floatingGap + answerNowRoom)
    }
}

struct CompactionStatus: View {
    let run: ChatRun?

    var body: some View {
        if let run, run.isCompaction {
            CompactionStatusRow(start: run.turnStart ?? .now)
        }
    }
}

/// What a row asks of the chat view.
struct MessageRowActions {
    var switchBranch: (Message, Int) -> Void
    var beginEdit: (Message) -> Void
    var openTimeline: (Message) -> Void
    var openDraft: (ChatRun) -> Void
    var openSources: ([SourceInfo]) -> Void
    var openCompaction: (CompactionRecord) -> Void
    var regenerate: () -> Void
    var openSettings: () -> Void
    var sendFromView: (Message, Int, OUISubmission) -> Void
    var saveSkill: () -> Void
    var dismissSkillOffer: () -> Void
}

/// The transcript's rows. Equal (and so not re-evaluated) while the transcript's version, the running reply and the
/// edit stay the same: focus, the composer's height, scrolling and a streaming reply's phase change none of them.
/// The lazy stack is inside, so only the rows on screen are built (an `Equatable` view around a lazy stack's rows would
/// be one child to it, built whole), each its own view: a long chat costs what its visible rows cost.
struct MessageRows: View, Equatable {
    let conversation: Conversation
    let transcript: ChatTranscript
    let run: ChatRun?
    let isStreaming: Bool
    let editingID: UUID?
    let cache: ChatTranscriptCache
    let scroll: ChatScroll
    let pin: PinLayout
    let actions: MessageRowActions

    nonisolated static func == (a: MessageRows, b: MessageRows) -> Bool {
        a.transcript.version == b.transcript.version && a.run === b.run && a.isStreaming == b.isStreaming
            && a.editingID == b.editingID && a.cache === b.cache
    }

    #if DEBUG
    /// Body evaluations, for tests that check what re-evaluates the rows.
    @MainActor static var evaluations = 0
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.evaluations += 1
        #endif
        let citations = CitationContext(sources: ChatView.sourceMap(run.map(\.liveSources) ?? cache.allSources(for: conversation)),
                                        conversationID: conversation.id)
        LazyVStack(alignment: .leading, spacing: DS.Spacing.xl) {
            rows(citations: citations, liveID: run?.messageID)
            CompactionStatus(run: run)
        }
    }

    private func rows(citations: CitationContext, liveID: UUID?) -> some View {
        let lastID = transcript.rows.last?.id
        return ForEach(transcript.rows) { row in
            let message = row.message
            MessageRow(message: message, conversation: conversation, isLast: row.id == lastID,
                       branch: transcript.tree.branch(of: row.id), live: row.id == liveID ? run : nil,
                       isStreaming: isStreaming, isEditing: row.id == editingID, citations: citations,
                       actions: actions)
                .equatable()
                .modifier(FlyInReader(id: row.id, parentID: message.parentID, isReply: message.role == .assistant, scroll: scroll))
                .id(row.id)
                .modifier(PinTopReader(id: row.id, scroll: scroll, pin: pin))
            ForEach(transcript.compactions[row.id] ?? []) { record in
                CompactionDivider { actions.openCompaction(record) }
            }
        }
    }
}

/// One message of the transcript. The running reply's row is the one that reads the run (its phase, its pending
/// calls), so a streaming reply re-evaluates that row alone.
struct MessageRow: View, Equatable {
    @Environment(\.modelContext) private var context
    @Environment(\.chatController) private var controller
    let message: Message
    let conversation: Conversation
    let isLast: Bool
    let branch: BranchPosition?
    /// The run writing this message; nil for every other row.
    let live: ChatRun?
    /// This chat is replying (no branch switching, editing or regenerating meanwhile).
    let isStreaming: Bool
    let isEditing: Bool
    let citations: CitationContext
    let actions: MessageRowActions

    nonisolated static func == (a: MessageRow, b: MessageRow) -> Bool {
        a.message === b.message && a.isLast == b.isLast && a.branch == b.branch && a.live === b.live
            && a.isStreaming == b.isStreaming && a.isEditing == b.isEditing && a.citations == b.citations
    }

    #if DEBUG
    @MainActor static var evaluations = 0
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.evaluations += 1
        #endif
        switch message.role {
        case .user:
            MessageBubble(text: message.text, images: ThumbnailBackfill.thumbnails(for: message),
                          fullImage: { index in
                              let attachments = message.sortedAttachments
                              return attachments.indices.contains(index) ? attachments[index].jpegData : nil
                          },
                          branch: branch, branchEnabled: !isStreaming,
                          onSwitchBranch: { actions.switchBranch(message, $0) },
                          onCopy: { Pasteboard.copy(message.text) },
                          onEdit: isStreaming ? nil : { actions.beginEdit(message) },
                          isEditing: isEditing)
                .environment(\.citations, citations)
        case .assistant:
            assistant
                .environment(\.citations, ChatView.citations(citations, for: message))
        }
    }

    private var assistant: some View {
        let live = live
        let active = live != nil
        let message = message
        let translation = controller.translation.ui(for: message, isStreaming: active)
        let shownText = translation.showing ? (translation.translatedText ?? message.text) : message.text
        let segments = message.segments // decoded once per stored value
        return AssistantMessage(
            content: AssistantContent(
                thinkingSeconds: message.thinkingSeconds,
                calls: ChatView.liveCalls(segments.flatMap(\.calls), inRound: live?.roundRecords ?? []),
                segments: segments,
                pending: live?.pendingCalls ?? [],
                roundRequested: live?.roundRequested ?? [],
                roundFinished: live?.roundRecords ?? [],
                isStreaming: active,
                phase: live?.phase ?? .idle,
                waiting: live.flatMap { ToolWaits.shared.reason(among: $0.pendingCalls.map(\.id), conversation: $0.conversationID) },
                turnStart: live?.turnStart,
                errorText: message.errorText,
                errorNeedsSettings: message.errorNeedsSettings,
                errorManagesUsage: message.errorManagesUsage,
                stopped: message.stoppedByUser,
                canRegenerate: isLast && !isStreaming,
                translation: translation,
                cutForEarlyAnswer: message.cutForEarlyAnswer,
                answeredEarly: message.answeredEarly,
                offersSkill: isLast && controller.skillOfferMessageID(for: conversation) == message.id),
            render: controller.renderState(for: message),
            onOpenTimeline: { actions.openTimeline(message) },
            onOpenReasoning: { actions.openTimeline(message) },
            onOpenDraft: live.map { run in { actions.openDraft(run) } },
            onOpenSources: { actions.openSources($0) },
            onCopy: { Pasteboard.copy(MarkdownPlain.text(from: MessageLayout.fullText(segments: segments, answer: shownText))) },
            onRegenerate: actions.regenerate,
            onOpenSettings: actions.openSettings,
            onCopyRaw: { Pasteboard.copy(MessageLayout.fullText(segments: segments, answer: shownText)) },
            textForSelection: { MarkdownPlain.text(from: MessageLayout.fullText(segments: segments, answer: shownText)) },
            shareMarkdown: { MessageLayout.fullText(segments: segments, answer: shownText) },
            onTranslate: { controller.translation.translate(message, context: context, isStreaming: active) },
            onToggleTranslation: { controller.translation.toggle(message, context: context) },
            branch: branch,
            branchEnabled: !isStreaming,
            onSwitchBranch: { actions.switchBranch(message, $0) },
            onSaveSkill: actions.saveSkill,
            onDismissSkillOffer: actions.dismissSkillOffer)
        .environment(\.openUIHost, OpenUIHost(
            messageID: message.id,
            isInteractive: OpenUIChat.isInteractive(isLast: isLast, conversation: conversation, controller: controller),
            isStreaming: active, saved: message.openUIStates,
            send: { block, submission in actions.sendFromView(message, block, submission) }))
    }
}

/// The jump button and "Answer now", stacked just above the composer so they never overlap. Overlays, so feed cards
/// arriving never move them; they read the composer's height, the end's visibility and the run here, not in the chat.
struct FloatingControls: View {
    @Environment(\.chatController) private var controller
    let scroll: ChatScroll
    let conversation: Conversation?
    let run: ChatRun?
    /// The running reply's message, looked up only while "Answer now" shows.
    let message: (UUID) -> Message?
    let onJump: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            jumpButton
            answerNow
        }
        .padding(.bottom, scroll.composerHeight + ChatView.floatingGap)
    }

    private var jumpButton: some View {
        Group {
            if !scroll.atBottom && conversation != nil {
                GlassIconButton(systemName: "arrow.down", label: "Jump to bottom", diameter: DS.IconSize.compactControlDiameter,
                                iconSize: DS.IconSize.composerIcon, action: onJump)
                .padding(.bottom, ChatView.floatingGap)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(DS.Motion.snappy, value: scroll.atBottom)
    }

    /// "Answer now", while this chat's turn runs tool rounds.
    @ViewBuilder
    private var answerNow: some View {
        if let conversation, let run, run.canAnswerNow, let id = run.messageID, let message = message(id) {
            let saved = message.segments.flatMap(\.calls).filter { $0.name == ToolNames.webSearch }.count
            let running = run.roundRequested.filter { $0.name == ToolNames.webSearch }.count
            AnswerNowCapsule(start: run.turnStart ?? .now, completedToolRounds: run.completedToolRounds,
                             searches: saved + running, phase: run.phase) { controller.answerNow(conversation) }
        }
    }
}

/// Owns the composer's focus, so focusing or leaving it re-evaluates this and the composer, not the chat. The chat
/// asks for a change through `ComposerFocus`; the keyboard opening keeps the end of the chat in view (`ChatScroll`).
struct FocusedComposer<Content: View>: View {
    let focus: ComposerFocus
    let scroll: ChatScroll
    #if os(macOS)
    @State private var focused = false
    @ViewBuilder let content: (Binding<Bool>) -> Content
    #else
    @FocusState private var focused: Bool
    @ViewBuilder let content: (FocusState<Bool>.Binding) -> Content
    #endif

    var body: some View {
        content($focused)
            .onChange(of: focus.isFocused, initial: true) { _, on in if focused != on { focused = on } }
            .onChange(of: focused) { _, on in
                if focus.isFocused != on { focus.isFocused = on }
                if on { scroll.composerFocused() }
            }
    }
}

/// The composer's focus as the chat asks for it (a sheet opening clears it, New Chat sets it). Written by the chat,
/// read only by `FocusedComposer`.
@MainActor
@Observable
final class ComposerFocus {
    var isFocused = false
}
