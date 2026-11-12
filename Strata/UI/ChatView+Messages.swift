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
                    StarterPrompts(draft: draft) { focus.isFocused = true }
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
        ChatMessageList(scroll: scroll, pin: pin, run: run) {
            if let conversation, let transcript {
                MessageRows(conversation: conversation, transcript: transcript, run: run, isStreaming: isStreamingHere,
                            editingID: editing?.id, cache: transcriptCache, scroll: scroll, pin: pin, actions: rowActions)
                    .equatable()
            }
        }
        #if os(iOS)
        .simultaneousGesture(TapGesture().onEnded { focus.isFocused = false })
        #endif
        .background(theme.background.ignoresSafeArea())
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

    /// What the rows ask of this view. Closures only: the rows compare everything else (`MessageRows.==`).
    var rowActions: MessageRowActions {
        MessageRowActions(
            switchBranch: { switchBranch($0, by: $1) },
            beginEdit: { beginEdit($0) },
            openTimeline: { timeline = TimelineRequest(message: $0, showsTools: true) },
            openDraft: { openDraftPreview(of: $0) },
            openSources: { sourcesItem = SourceListItem(sources: $0, all: conversationUsedSources) },
            openCompaction: { compactionNotes = $0 },
            regenerate: {
                if let c = conversation { controller.regenerate(conversation: c, context: context); pinLatestQuestion() }
            },
            openSettings: onOpenSettings,
            sendFromView: { sendFromView($0, block: $1, submission: $2) },
            saveSkill: { if let c = conversation { controller.saveAsSkill(conversation: c, context: context) } },
            dismissSkillOffer: { if let c = conversation { controller.dismissSkillOffer(c) } })
    }

    /// Saved calls plus calls finished in the running round, each id once.
    static func liveCalls(_ saved: [ToolCallRecord], inRound: [ToolCallRecord]) -> [ToolCallRecord] {
        let known = Set(saved.map(\.id))
        return saved + inRound.filter { !known.contains($0.id) }
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
        focus.isFocused = true
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

    /// Scrolls to the end and keeps it there while the answer grows (`ChatScroll.followsBottom`).
    func jumpToBottom() {
        // The end isn't on screen, so neither is the room under a pinned question: dropping it moves nothing.
        scroll.pinnedID = nil
        scroll.followsBottom = true
        scroll.jumping = true
        // A short way animates; a long one jumps, since an animated scroll across rows the lazy stack hasn't laid out
        // draws them blank on the way.
        if pin.contentEnd - pin.visibleBottom < pin.viewport * 2 {
            withAnimation(DS.Motion.spring) { scroll.scrollToEnd() }
        } else {
            scroll.scrollToEnd()
        }
    }

    /// Holds the question being answered at the top: room is reserved under it, then one animated scroll puts it there.
    /// Used for a send, an edit and a regenerate.
    func pinLatestQuestion() {
        guard let id = conversation?.activePath.last(where: { $0.role == .user && !$0.isHiddenInTranscript })?.id else { return }
        scroll.pinnedID = id
        scroll.followsBottom = false
        scroll.jumping = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60)) // the row and the room under it are laid out first
            guard scroll.pinnedID == id else { return }
            withAnimation(DS.Motion.spring) { scroll.position.scrollTo(id: id, anchor: .top) }
        }
    }
}

extension ChatView {
    /// The page of the artifact this run's model is writing: in the panel beside the chat on a Mac, over the chat
    /// elsewhere.
    func openDraftPreview(of run: ChatRun) {
        let request = ArtifactDraftRequest(feed: run.artifactDraft)
        if let artifactPanel { artifactPanel.openDraft(request) } else { draftPreview = request }
    }
}
