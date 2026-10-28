import SwiftUI
import SwiftData

extension ChatView {
    // MARK: Messages

    var messages: some View {
        messageList
            .overlay {
                if conversation == nil && connections.connections.isEmpty {
                    NoConnectionState(onChatGPT: { addConnection(preset: .chatGPT) },
                                      onAdd: { addConnection() },
                                      onUseOnDevice: OnDevice.system.availability.isSupported
                                          ? { connections.addOnDeviceConnection() } : nil)
                }
            }
            .overlay(alignment: .bottom) {
                if conversation == nil, !connections.connections.isEmpty,
                   connections.connection(selection.connectionID)?.isAppleOnDevice != true {
                    StarterPrompts(draft: draft) { composerFocused = true }
                }
            }
            .overlay(alignment: .top) { readyBanner }
    }

    /// "Reply ready · <chat>" when a reply finishes in a chat that isn't this one.
    @ViewBuilder
    var readyBanner: some View {
        Group {
            if let notice = controller.readyNotice, notice.conversationID != conversation?.id {
                ReplyReadyBanner(title: notice.title) {
                    controller.dismissReadyNotice(notice.id)
                    open(notice.conversationID)
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.top, DS.Spacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: notice.id) {
                    try? await Task.sleep(for: ReplyReadyBanner.lifetime)
                    guard !Task.isCancelled else { return }
                    withAnimation(DS.Motion.snappy) { controller.dismissReadyNotice(notice.id) }
                }
            }
        }
        .animation(DS.Motion.spring, value: controller.readyNotice?.id)
    }

    var messageList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    if let conversation {
                        let tree = conversation.treeIndex
                        let items = conversation.activePath.filter { !$0.isHiddenInTranscript }
                        let summaries = conversation.compactions(anchoredIn: items)
                        let citations = citationContext
                        ForEach(items) { message in
                            row(message, isLast: message.id == items.last?.id, branch: tree.branch(of: message.id))
                                .environment(\.citations, Self.citations(citations, for: message))
                                .id(message.id)
                                .modifier(PinTopReader(isPinned: message.id == pinnedID, pin: pin))
                            ForEach(summaries[message.id] ?? []) { record in
                                CompactionDivider { compactionNotes = record }
                            }
                        }
                        if let run, run.isCompaction {
                            CompactionStatusRow(start: run.turnStart ?? .now)
                        }
                    }
                }
                // Outside the lazy stack, so it always exists: scrolling to it from far above works even before the
                // rows near the end are laid out (a lazy child that far away isn't found, and the scroll did nothing).
                // The end of the chat sits one gap above the composer, or above "Answer now" while it can show.
                Color.clear.frame(height: Self.floatingGap + (reservesAnswerNowRoom ? DS.IconSize.capsuleHeight + Self.floatingGap : 0))
                    .id("bottom")
                    .onScrollVisibilityChange(threshold: 0.01) { atBottom = $0 } // true scroll position: is the end of the chat on screen?
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(PinLayout.space)).minY } action: {
                        pin.contentEnd = $0
                        if followsBottom { scrollToEnd() }
                    }
                if pinnedID != nil { PinReserve(pin: pin) }
            }
            .padding(.horizontal, DS.Spacing.page)
            .padding(.top, DS.Spacing.md)
            .coordinateSpace(.named(PinLayout.space))
            #if os(macOS)
            .readingColumn()
            #endif
        }
        .scrollPosition($position)
        // A chat opens at its latest messages. Nothing follows the bottom afterwards: a new answer grows under its
        // pinned question, and the jump button offers the end once it runs past the screen.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: PinLayout.Viewport.self) { g in
            PinLayout.Viewport(height: g.containerSize.height - g.contentInsets.top - g.contentInsets.bottom,
                               visibleBottom: g.visibleRect.maxY - g.contentInsets.bottom)
        } action: { _, v in
            pin.viewport = v.height
            pin.visibleBottom = v.visibleBottom
        }
        .onScrollPhaseChange { old, new in
            if new == .interacting { followsBottom = false; jumpRetry?.cancel() } // a drag hands the position back to the user
            // The user scrolled: once the room under the answer is out of view it can go without moving anything.
            guard pinnedID != nil, new == .idle, old == .interacting || old == .decelerating else { return }
            if pin.reserveOutOfView { pinnedID = nil }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        #if os(iOS)
        .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
        #endif
        .background(theme.background.ignoresSafeArea())
        .environment(\.citations, citationContext)
        .environment(\.openURL, OpenURLAction { url in
            let ids = CitationParser.ids(from: url)
            guard !ids.isEmpty else {
                guard InAppBrowser.isWeb(url) else { return .systemAction }
                InAppBrowser.present(url)
                return .handled
            }
            let known = citationContext.sources
            let list = ids.compactMap { known[$0] }
            if !list.isEmpty { citationItem = SourceListItem(sources: list) }
            return .handled
        })
    }

    /// Saved calls plus calls finished in the running round, each id once.
    static func liveCalls(_ saved: [ToolCallRecord], inRound: [ToolCallRecord]) -> [ToolCallRecord] {
        let known = Set(saved.map(\.id))
        return saved + inRound.filter { !known.contains($0.id) }
    }

    @ViewBuilder
    func row(_ message: Message, isLast: Bool, branch: BranchPosition?) -> some View {
        switch message.role {
        case .user:
            MessageBubble(text: message.text, images: ThumbnailBackfill.thumbnails(for: message),
                          branch: branch, branchEnabled: !isStreamingHere,
                          onSwitchBranch: { switchBranch(message, by: $0) },
                          onCopy: { Pasteboard.copy(message.text) },
                          onEdit: isStreamingHere ? nil : { beginEdit(message) },
                          isEditing: editing?.id == message.id)
                .modifier(SendFlyIn(active: message.id == flyingID))
        case .assistant:
            let live = run.flatMap { $0.messageID == message.id ? $0 : nil }
            let active = live != nil
            let translation = controller.translation.ui(for: message, isStreaming: active)
            let shownText = translation.showing ? (translation.translatedText ?? message.text) : message.text
            let segments = message.segments // decoded once per stored value
            AssistantMessage(
                content: AssistantContent(
                    thinkingSeconds: message.thinkingSeconds,
                    calls: Self.liveCalls(segments.flatMap(\.calls), inRound: live?.roundRecords ?? []),
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
                    canRegenerate: isLast && !isStreamingHere,
                    translation: translation,
                    cutForEarlyAnswer: message.cutForEarlyAnswer,
                    answeredEarly: message.answeredEarly,
                    offersSkill: isLast && controller.skillOfferMessageID(for: conversation) == message.id),
                render: controller.renderState(for: message),
                onOpenTimeline: { timeline = TimelineRequest(message: message, showsTools: true) },
                onOpenReasoning: { timeline = TimelineRequest(message: message, showsTools: true) },
                onOpenSources: { sourcesItem = SourceListItem(sources: $0, all: conversationUsedSources) },
                onCopy: { Pasteboard.copy(MarkdownPlain.text(from: MessageLayout.fullText(segments: segments, answer: shownText))) },
                onRegenerate: {
                    if let c = conversation { controller.regenerate(conversation: c, context: context); pinLatestQuestion() }
                },
                onOpenSettings: onOpenSettings,
                onCopyRaw: { Pasteboard.copy(MessageLayout.fullText(segments: segments, answer: shownText)) },
                textForSelection: { MarkdownPlain.text(from: MessageLayout.fullText(segments: segments, answer: shownText)) },
                onTranslate: { controller.translation.translate(message, context: context, isStreaming: active) },
                onToggleTranslation: { controller.translation.toggle(message, context: context) },
                branch: branch,
                branchEnabled: !isStreamingHere,
                onSwitchBranch: { switchBranch(message, by: $0) },
                onSaveSkill: {
                    if let c = conversation { controller.saveAsSkill(conversation: c, context: context) }
                },
                onDismissSkillOffer: { if let c = conversation { controller.dismissSkillOffer(c) } })
            .environment(\.openUIHost, OpenUIHost(
                messageID: message.id,
                isInteractive: OpenUIChat.isInteractive(isLast: isLast, conversation: conversation, controller: controller),
                isStreaming: active, saved: message.openUIStates,
                send: { block, submission in sendFromView(message, block: block, submission: submission) }))
            .modifier(AfterSendFlyIn(active: message.parentID != nil && message.parentID == flyingID))
        }
    }

    /// Adds photos to the composer and makes their thumbnails in the background.
    func addAttachments(_ jpegs: [Data]) {
        for jpeg in jpegs {
            let attachment = ComposerAttachment(id: UUID(), jpeg: jpeg)
            draft.attachments.append(attachment)
            Task {
                let thumbnail = await Task.detached(priority: .utility) { ImageProcessor.thumbnailData(from: jpeg) }.value
                if let i = draft.attachments.firstIndex(where: { $0.id == attachment.id }) { draft.attachments[i].thumbnail = thumbnail }
            }
        }
    }

    // MARK: Branches and editing

    func switchBranch(_ message: Message, by offset: Int) {
        guard !isStreamingHere, let conversation else { return }
        cancelEdit()
        if conversation.switchBranch(of: message, by: offset) { try? context.save() }
    }

    /// Puts a sent message back into the composer; sending creates a sibling and leaves the old branch in place.
    func beginEdit(_ message: Message) {
        guard !isStreamingHere else { return }
        if editing == nil { savedDraft = (draft.text, draft.attachments) }
        editing = message
        draft.text = message.text
        draft.attachments = message.sortedAttachments.map { ComposerAttachment(id: UUID(), jpeg: $0.jpegData, thumbnail: $0.thumbnailData) }
        composerFocused = true
    }

    /// Leaves edit mode and puts back what was in the composer before it began.
    func cancelEdit() {
        guard editing != nil else { return }
        editing = nil
        if let saved = savedDraft { draft.text = saved.text; draft.attachments = saved.attachments }
        savedDraft = nil
    }

    /// One gap between the chat, the floating controls ("Answer now", the jump button) and the composer.
    static let floatingGap = DS.Spacing.lg

    /// "Answer now" can appear for this chat's running turn: the end of the chat leaves it room.
    var reservesAnswerNowRoom: Bool {
        run?.canAnswerNow ?? false
    }

    var jumpButton: some View {
        Group {
            if !atBottom && conversation != nil {
                GlassIconButton(systemName: "arrow.down", label: "Jump to bottom", diameter: DS.IconSize.compactControlDiameter,
                                iconSize: DS.IconSize.composerIcon) {
                    jumpToBottom()
                }
                .padding(.bottom, Self.floatingGap)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(DS.Motion.snappy, value: atBottom)
    }

    /// Scrolls to the end and keeps it there while the answer grows. Rows above the end are laid out lazily from
    /// estimated heights, so one scroll can stop short: it tries again until the end is on screen.
    func jumpToBottom() {
        // The end isn't on screen, so neither is the room under a pinned question: dropping it moves nothing.
        pinnedID = nil
        followsBottom = true
        // A short way animates; a long one jumps, since an animated scroll across rows the lazy stack hasn't laid out
        // draws them blank on the way.
        if pin.contentEnd - pin.visibleBottom < pin.viewport * 2 {
            withAnimation(DS.Motion.spring) { scrollToEnd() }
        } else {
            scrollToEnd()
        }
        jumpRetry?.cancel()
        jumpRetry = Task { @MainActor in
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, followsBottom, !atBottom else { return }
                scrollToEnd()
            }
        }
    }

    /// The end of the chat. The same scroll asked twice is the same `ScrollPosition` value, which SwiftUI may ignore,
    /// so the anchor alternates by a hair. (Scrolling to the bottom edge instead jumps past rows the lazy stack hasn't
    /// laid out yet, and the screen stays blank until the next scroll.)
    func scrollToEnd() {
        pin.endAnchorFlip.toggle()
        position.scrollTo(id: "bottom", anchor: pin.endAnchorFlip ? .bottom : UnitPoint(x: 0.5, y: 0.999))
    }

    /// Holds the question being answered at the top: room is reserved under it, then one animated scroll puts it there.
    /// Used for a send, an edit and a regenerate.
    func pinLatestQuestion() {
        guard let id = conversation?.activePath.last(where: { $0.role == .user && !$0.isHiddenInTranscript })?.id else { return }
        pinnedID = id
        followsBottom = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60)) // the row and the room under it are laid out first
            guard pinnedID == id else { return }
            withAnimation(DS.Motion.spring) { position.scrollTo(id: id, anchor: .top) }
        }
    }
}
