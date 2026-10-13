import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(\.appSettings) private var settings
    @Environment(\.connectionStore) private var connections
    @Environment(\.chatController) private var controller

    @Binding var conversation: Conversation?
    let onOpenSidebar: () -> Void
    let onOpenSettings: () -> Void
    var onNewChat: () -> Void = {}
    /// Bumped by the root to ask for composer focus (New Chat).
    var focusToken = 0

    /// Reference-typed so typing never invalidates this view: only `ComposerHost` reads the text.
    @State private var draft = ComposerDraft()
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    /// The question being answered, held at the top of the screen from its send until the next send or until the user
    /// scrolls the room reserved under it out of view. Nil when nothing is pinned (a chat just opened).
    @State private var pinnedID: UUID?
    /// Set by the jump button: the view then sticks to the end while the answer grows, until the user scrolls or sends.
    @State private var followsBottom = false
    /// Heights for the room under the pinned question; read only by `PinReserve`, so scrolling and streaming never
    /// re-evaluate this view.
    @State private var pin = PinLayout()
    @State private var showAttach = false
    #if os(macOS)
    @State private var showNoImageSupport = false
    #endif
    /// "Select model" (models, effort, search engine): a sheet on the phone, a popover from the gauge on a Mac.
    @State private var showChatSettings = false
    /// The composer's height, so the floating "Answer now" capsule sits just above it.
    @State private var composerHeight: CGFloat = 0
    @State private var showContext = false
    @State private var showDetails = false
    #if DEBUG
    @State private var branchDebugDone = false
    #endif
    /// The sent message being edited, and what the composer held before editing began.
    @State private var editing: Message?
    @State private var savedDraft: (text: String, attachments: [ComposerAttachment])?
    @State private var timeline: TimelineRequest?
    @State private var compactionNotes: CompactionRecord?
    @State private var citationItem: SourceListItem?
    @State private var sourcesItem: SourceListItem?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    #if os(macOS)
    @State private var composerFocused = false
    #else
    @FocusState private var composerFocused: Bool
    #endif
    #if DEBUG
    @State private var debugViewer = false
    #endif

    // MARK: Selection

    private struct Selection {
        var connectionID: UUID?
        var modelID: String?
        var effort: Effort
    }

    private var selection: Selection {
        if let c = conversation { return Selection(connectionID: c.connectionID, modelID: c.modelID, effort: c.effort) }
        let choice = ModelSelection.resolve(connections: connections.connections,
                                            preferredConnectionID: settings.lastConnectionID,
                                            preferredModelID: settings.lastModelID)
        return Selection(connectionID: choice?.connectionID, modelID: choice?.modelID, effort: settings.lastEffort)
    }

    /// Persist the auto-selected model so it survives relaunch.
    private func persistAutoSelection() {
        guard conversation == nil, let cid = selection.connectionID, let mid = selection.modelID else { return }
        if settings.lastConnectionID != cid { settings.lastConnectionID = cid }
        if settings.lastModelID != mid { settings.lastModelID = mid }
    }

    private var selectedModel: ModelInfo? {
        let s = selection
        return connections.connection(s.connectionID)?.models.first { $0.id == s.modelID }
    }

    /// The selected model as the user sees it: its alias when set, else the real id (requests always use the id).
    private var selectedModelTitle: String? {
        let s = selection
        return connections.displayName(connectionID: s.connectionID, modelID: s.modelID)
    }

    private func apply(connectionID: UUID, modelID: String) {
        settings.lastConnectionID = connectionID
        settings.lastModelID = modelID
        conversation?.connectionID = connectionID
        conversation?.modelID = modelID
    }

    private func enableImagesForSelectedModel() {
        let sel = selection
        guard var c = connections.connection(sel.connectionID), let i = c.models.firstIndex(where: { $0.id == sel.modelID }) else { return }
        c.models[i].supportsImages = true
        c.models[i].supportsImagesUserSet = true
        connections.upsert(c)
    }

    private func apply(effort: Effort) {
        settings.lastEffort = effort
        conversation?.effort = effort
    }

    private var contextLength: Int {
        (selectedModel?.effectiveContextLength(default: settings.defaultContextLength)) ?? settings.defaultContextLength
    }

    private var contextFraction: Double {
        guard let used = conversation?.lastUsage?.totalTokens, contextLength > 0 else { return 0 }
        return min(1, Double(used) / Double(contextLength))
    }

    private var citationContext: CitationContext {
        let list = (conversation.map { controller.isStreaming($0) } ?? false) ? controller.liveSources : (conversation?.sources ?? [])
        return CitationContext(sources: Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) }))
    }

    /// Every source an answer on the active path read or cited, in order: the Sources sheet's "All" list.
    private var conversationUsedSources: [SourceInfo] {
        guard let conversation else { return [] }
        let byID = citationContext.sources
        let known = Set(byID.keys)
        var ids: [Int] = []
        for message in conversation.activePath where message.role == .assistant {
            for id in SourceUsage.ids(calls: message.segments.flatMap(\.calls), text: message.text, known: known)
            where !ids.contains(id) { ids.append(id) }
        }
        return ids.compactMap { byID[$0] }
    }

    private var isStreamingHere: Bool {
        conversation.map { controller.isStreaming($0) } ?? false
    }

    // MARK: Body

    var body: some View {
        messages
            #if os(iOS)
            .safeAreaBar(edge: .top) { header }
            #endif
            .safeAreaBar(edge: .bottom) { composer }
            .ignoresKeyboardOnMac()
            #if os(macOS)
            .modifier(MacChatChrome(
                title: conversation?.displayTitle ?? String(localized: "New chat"),
                isTitling: controller.isTitling(conversation?.id),
                contextFraction: conversation?.lastUsage == nil ? nil : contextFraction,
                showContext: $showContext, showAttach: $showAttach, showNoImageSupport: $showNoImageSupport,
                onPickImages: addAttachments, onEnableImages: enableImagesForSelectedModel,
                menu: { menuContent }))
            #endif
            .overlay(alignment: .bottom) {
                // Stacked, so the jump button and "Answer now" never overlap.
                VStack(spacing: 0) {
                    jumpButton
                    answerNowCapsule
                }
                .padding(.bottom, composerHeight + DS.Spacing.sm)
            }
            // Where a language that is not installed yet is downloaded and the answer translated.
            .translationTask(controller.translation.configuration) { session in
                let translator = SessionTranslator(session)
                await controller.translation.fulfill(translator)
            }
            #if os(iOS)
            .sheet(isPresented: $showAttach) {
                AttachSheet(supportsImages: selectedModel?.supportsImages ?? false, modelName: selectedModelTitle,
                            onPick: addAttachments,
                            onEnableImages: enableImagesForSelectedModel)
            }
            #endif
            #if os(iOS)
            .sheet(isPresented: $showChatSettings) { chatSettings }
            #endif
            .sheet(isPresented: $showDetails) {
                if let conversation {
                    ConversationDetailsSheet(conversation: conversation, contextLength: contextLength)
                        .environment(\.theme, theme)
                }
            }
            .sheet(isPresented: $showContext) {
                ContextSheet(conversation: conversation, window: contextLength, maxOutput: selectedModel?.maxOutputTokens,
                             connection: connections.connection(selection.connectionID))
                    .environment(\.theme, theme)
            }
            .sheet(item: $timeline) { request in
                let message = request.message
                let active = controller.activeMessageID == message.id
                TimelineSheet(reasoning: controller.renderState(for: message).reasoning,
                              steps: message.steps,
                              pending: active ? controller.pendingCalls : [],
                              sources: citationContext.sources,
                              isLive: active,
                              seconds: message.thinkingSeconds,
                              showsTools: request.showsTools)
                    .environment(\.theme, theme)
            }
            .sheet(item: $compactionNotes) { record in
                CompactionNotesSheet(notes: record.notes, tokensBefore: record.tokensBefore, tokensAfter: record.tokensAfter,
                                     date: record.createdAt, isAutomatic: record.isAutomatic)
                    .environment(\.theme, theme)
            }
            .alert("Couldn't summarize", isPresented: Binding(get: { controller.compactionError != nil },
                                                               set: { if !$0 { controller.compactionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(controller.compactionError ?? "") }
            .sheet(item: $citationItem) { item in
                SourcesSheet(title: item.sources.count == 1 ? "Source" : "Sources", sources: item.sources)
            }
            .sheet(item: $sourcesItem) { item in
                SourcesSheet(title: "Sources", sources: item.sources, all: item.all)
            }
            #if DEBUG
            .fullScreenCoverOrSheet(isPresented: $debugViewer) {
                CodeViewer(content: .init(language: "swift", code: (1...60).map { "let step\($0) = configure(glassEffect: .regular, id: \($0)) // long line to scroll" }.joined(separator: "\n"))).inAppLinks()
            }
            #endif
            .alert("Rename chat", isPresented: $showRename) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { conversation?.setUserTitle(t); try? context.save() }
                }
            }
            .confirmationDialog("Delete this chat?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let c = conversation {
                        conversation = nil
                        Diagnostics.forget(c.id)
                        context.delete(c)
                        try? context.save()
                    }
                }
            }
            .onChange(of: showAttach) { _, on in if on { composerFocused = false } }
            .onChange(of: showChatSettings) { _, on in if on { composerFocused = false } }
            .onChange(of: showContext) { _, on in if on { composerFocused = false } }
            .onChange(of: composerFocused) { _, focused in
                // Keep the latest message visible when the keyboard opens.
                // A pinned question stays where it is when the keyboard opens.
                if focused && atBottom && pinnedID == nil { withAnimation(DS.Motion.spring) { position.scrollTo(edge: .bottom) } }
            }
            .task(id: focusToken) {
                guard focusToken > 0 else { return }
                try? await Task.sleep(for: .milliseconds(150))
                composerFocused = true
            }
            .task(id: conversation?.id) { // opening a chat: link one saved before branching; leaving one ends an edit
                cancelEdit()
                conversation?.ensureTree()
                #if os(macOS)
                try? await Task.sleep(for: .milliseconds(250)) // the window has to exist before it can focus anything
                composerFocused = true // there is no keyboard to summon: the cursor is always ready
                #endif
            }
            .task {
                persistAutoSelection()
                await debugActions()
            }
            #if DEBUG
            // The view is recreated when the first chat is created, so timeline debugging runs from the live view.
            .task(id: controller.activeMessageID) { await debugTimeline() }
            #endif
            .onChange(of: connections.allModels.count) { _, _ in persistAutoSelection() }
    }

    // MARK: Header

    #if os(iOS)
    private var header: some View {
        GlassEffectContainer(spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                GlassIconButton(systemName: "line.3.horizontal", label: "Sidebar") { composerFocused = false; onOpenSidebar() }
                VStack(alignment: .leading, spacing: 0) {
                    TitlingText(conversation?.displayTitle ?? String(localized: "New chat"),
                                isTitling: controller.isTitling(conversation?.id))
                        .font(DS.Typography.title)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ContextRingButton(fraction: conversation?.lastUsage == nil ? nil : contextFraction) {
                    composerFocused = false
                    showContext = true
                }
                GlassIconMenu(systemName: "ellipsis", label: "More") { menuContent }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm) // 8pt below the 44pt buttons, clear of the blur edge
        }
        // A real surface behind the title: answer text scrolling underneath must never show through it.
        .background(alignment: .top) { HeaderBacking() }
    }
    #endif

    @ViewBuilder
    private var menuContent: some View {
        Button("New Chat", systemImage: "square.and.pencil", action: onNewChat)
        Divider()
        if let c = conversation {
            Button(c.isPinned ? "Unpin" : "Pin", systemImage: c.isPinned ? "pin.slash" : "pin") {
                c.isPinned.toggle()
                try? context.save()
            }
            Button("Rename", systemImage: "pencil") {
                renameText = c.title
                showRename = true
            }
            Button("Regenerate title", systemImage: "wand.and.stars") {
                controller.autoRename(conversation: c, context: context, force: true)
            }
            .disabled(controller.isStreaming(c) || controller.isTitling(c.id))
            ShareLink(item: c.transcript) { Label("Share as text", systemImage: "square.and.arrow.up") }
            Button("Summarize now", systemImage: "text.line.first.and.arrowtriangle.forward") {
                controller.compactNow(conversation: c, context: context)
            }
            .disabled(controller.isStreaming || c.activePath.isEmpty)
            Button("Conversation details", systemImage: "info.circle") { showDetails = true }
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            Divider()
        }
        Button("Settings", systemImage: "gearshape", action: onOpenSettings)
    }

    // MARK: Messages

    private var messages: some View { messageList }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.xl) {
                if let conversation {
                    let tree = conversation.treeIndex
                    let items = conversation.activePath.filter { !$0.isHiddenInTranscript }
                    let summaries = conversation.compactions(anchoredIn: items)
                    ForEach(items) { message in
                        row(message, isLast: message.id == items.last?.id, branch: tree.branch(of: message.id))
                            .id(message.id)
                            .modifier(PinTopReader(isPinned: message.id == pinnedID, pin: pin))
                        ForEach(summaries[message.id] ?? []) { record in
                            CompactionDivider { compactionNotes = record }
                        }
                    }
                    if controller.compactingConversationID == conversation.id {
                        CompactionStatusRow(start: controller.turnStart ?? .now)
                    }
                }
                Color.clear.frame(height: DS.Spacing.lg).id("bottom")
                    .onScrollVisibilityChange(threshold: 0.01) { atBottom = $0 } // true scroll position: is the end of the chat on screen?
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(PinLayout.space)).minY } action: {
                        pin.contentEnd = $0
                        if followsBottom { position.scrollTo(id: "bottom", anchor: .bottom) }
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
            if new == .interacting { followsBottom = false } // a drag hands the position back to the user
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
    private func row(_ message: Message, isLast: Bool, branch: BranchPosition?) -> some View {
        switch message.role {
        case .user:
            MessageBubble(text: message.text, images: ThumbnailBackfill.thumbnails(for: message),
                          branch: branch, branchEnabled: !controller.isStreaming,
                          onSwitchBranch: { switchBranch(message, by: $0) },
                          onCopy: { Pasteboard.copy(message.text) },
                          onEdit: controller.isStreaming ? nil : { beginEdit(message) })
        case .assistant:
            let active = controller.activeMessageID == message.id
            let translation = controller.translation.ui(for: message, isStreaming: active)
            let shownText = translation.showing ? (translation.translatedText ?? message.text) : message.text
            let segments = message.segments // decoded once per stored value
            AssistantMessage(
                content: AssistantContent(
                    thinkingSeconds: message.thinkingSeconds,
                    calls: Self.liveCalls(segments.flatMap(\.calls), inRound: active ? controller.roundRecords : []),
                    segments: segments,
                    pending: active ? controller.pendingCalls : [],
                    roundRequested: active ? controller.roundRequested : [],
                    roundFinished: active ? controller.roundRecords : [],
                    isStreaming: active,
                    phase: active ? controller.phase : .idle,
                    turnStart: active ? controller.turnStart : nil,
                    errorText: message.errorText,
                    errorNeedsSettings: message.errorNeedsSettings,
                    stopped: message.stoppedByUser,
                    canRegenerate: isLast && !controller.isStreaming,
                    translation: translation,
                    cutForEarlyAnswer: message.cutForEarlyAnswer,
                    answeredEarly: message.answeredEarly),
                render: controller.renderState(for: message),
                onOpenTimeline: { timeline = TimelineRequest(message: message, showsTools: true) },
                onOpenReasoning: { timeline = TimelineRequest(message: message, showsTools: true) },
                onOpenSources: { sourcesItem = SourceListItem(sources: $0, all: conversationUsedSources) },
                onCopy: { Pasteboard.copy(MarkdownPlain.text(from: shownText)) },
                onRegenerate: {
                    if let c = conversation { controller.regenerate(conversation: c, context: context); pinLatestQuestion() }
                },
                onOpenSettings: onOpenSettings,
                onCopyRaw: { Pasteboard.copy(shownText) },
                onTranslate: { controller.translation.translate(message, context: context, isStreaming: active) },
                onToggleTranslation: { controller.translation.toggle(message, context: context) },
                branch: branch,
                branchEnabled: !controller.isStreaming,
                onSwitchBranch: { switchBranch(message, by: $0) })
        }
    }

    /// Adds photos to the composer and makes their thumbnails in the background.
    private func addAttachments(_ jpegs: [Data]) {
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

    private func switchBranch(_ message: Message, by offset: Int) {
        guard !controller.isStreaming, let conversation else { return }
        cancelEdit()
        if conversation.switchBranch(of: message, by: offset) { try? context.save() }
    }

    /// Puts a sent message back into the composer; sending creates a sibling and leaves the old branch in place.
    private func beginEdit(_ message: Message) {
        guard !controller.isStreaming else { return }
        if editing == nil { savedDraft = (draft.text, draft.attachments) }
        editing = message
        draft.text = message.text
        draft.attachments = message.sortedAttachments.map { ComposerAttachment(id: UUID(), jpeg: $0.jpegData, thumbnail: $0.thumbnailData) }
        composerFocused = true
    }

    /// Leaves edit mode and puts back what was in the composer before it began.
    private func cancelEdit() {
        guard editing != nil else { return }
        editing = nil
        if let saved = savedDraft { draft.text = saved.text; draft.attachments = saved.attachments }
        savedDraft = nil
    }

    private var jumpButton: some View {
        Group {
            if !atBottom && conversation != nil {
                GlassIconButton(systemName: "arrow.down", label: "Jump to bottom", diameter: DS.IconSize.compactControlDiameter,
                                iconSize: DS.IconSize.composerIcon) {
                    followsBottom = true
                    withAnimation(DS.Motion.spring) { position.scrollTo(id: "bottom", anchor: .bottom) }
                }
                .padding(.bottom, DS.Spacing.sm)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(DS.Motion.snappy, value: atBottom)
    }

    /// Holds the question being answered at the top: room is reserved under it, then one animated scroll puts it there.
    /// Used for a send, an edit and a regenerate.
    private func pinLatestQuestion() {
        guard let id = conversation?.activePath.last(where: { $0.role == .user && !$0.isHiddenInTranscript })?.id else { return }
        pinnedID = id
        followsBottom = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60)) // the row and the room under it are laid out first
            guard pinnedID == id else { return }
            withAnimation(DS.Motion.spring) { position.scrollTo(id: id, anchor: .top) }
        }
    }

    // MARK: Composer

    private var composer: some View {
        ComposerHost(
            draft: draft,
            isStreaming: isStreamingHere,
            isBusy: controller.isStreaming,
            plusDimmed: !(selectedModel?.supportsImages ?? false),
            onAttach: attach,
            onSend: send,
            onStop: { controller.stop() },
            onCancelEdit: editing == nil ? nil : { withAnimation(DS.Motion.snappy) { cancelEdit() } },
            onPasteImages: pasteHandler,
            accessory: { settingsButton },
            isFocused: $composerFocused)
        #if os(macOS)
        .readingColumn()
        #endif
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
    }

    /// "Answer now", floating just above the composer while this chat's turn runs tool rounds. An overlay, so feed
    /// cards arriving never move it.
    @ViewBuilder
    private var answerNowCapsule: some View {
        if let conversation, controller.canAnswerNow, controller.activeConversationID == conversation.id,
           let message = conversation.messages.first(where: { $0.id == controller.activeMessageID }) {
            let saved = message.segments.flatMap(\.calls).filter { $0.name == ToolNames.webSearch }.count
            let running = controller.roundRequested.filter { $0.name == ToolNames.webSearch }.count
            AnswerNowCapsule(start: controller.turnStart ?? .now, completedToolRounds: controller.completedToolRounds,
                             searches: saved + running, phase: controller.phase) { controller.answerNow() }
        }
    }

    /// The gauge: tap for the chat settings, touch and hold for the effort levels.
    private var settingsButton: some View {
        let levels = selectedModel?.effortLevels ?? []
        let effort = selection.effort
        return ModelSettingsButton(
            effortFraction: levels.isEmpty ? nil : EffortScale.fraction(of: effort, in: levels),
            valueDescription: levels.isEmpty ? (selectedModelTitle ?? String(localized: "None")) : effort.title,
            action: { composerFocused = false; showChatSettings = true }) {
            EffortMenuItems(levels: levels, selected: effort, onSelect: apply(effort:))
        }
        #if os(macOS)
        .popover(isPresented: $showChatSettings, arrowEdge: .top) { chatSettings }
        #endif
    }

    private var chatSettings: some View {
        let s = selection
        return ModelPickerSheet(
            selectedConnectionID: s.connectionID, selectedModelID: s.modelID, effort: s.effort,
            onSelectModel: apply(connectionID:modelID:),
            onSelectEffort: apply(effort:),
            onOpenSettings: { showChatSettings = false; onOpenSettings() })
    }

    private var pasteHandler: (([Data]) -> Void)? {
        #if os(macOS)
        pasteImages
        #else
        nil
        #endif
    }

    #if os(macOS)
    /// Images pasted into the composer (Mac): resized like any other attachment, if the model can read them.
    private func pasteImages(_ images: [Data]) {
        guard selectedModel?.supportsImages ?? false else { showNoImageSupport = true; return }
        Task {
            var out: [Data] = []
            for data in images {
                if let jpeg = await Task.detached(operation: { ImageProcessor.jpegData(from: data) }).value { out.append(jpeg) }
            }
            if !out.isEmpty { addAttachments(out) }
        }
    }
    #endif

    private func attach() {
        composerFocused = false
        #if os(macOS)
        if selectedModel?.supportsImages ?? false { showAttach = true } else { showNoImageSupport = true }
        #else
        showAttach = true
        #endif
    }

    private func send() {
        let sel = selection
        let target: Conversation
        if let existing = conversation {
            target = existing
        } else {
            target = Conversation(connectionID: sel.connectionID, modelID: sel.modelID, effort: sel.effort)
            context.insert(target)
            conversation = target
        }
        let text = draft.text
        let images = draft.attachments.map(\.jpeg)
        let thumbnails = draft.attachments.map(\.thumbnail)
        let edited = editing
        draft.text = ""
        draft.attachments = []
        if edited != nil { // the composer goes back to what it held before the edit
            editing = nil
            if let saved = savedDraft { draft.text = saved.text; draft.attachments = saved.attachments }
            savedDraft = nil
        }
        controller.send(text: text, images: images, thumbnails: thumbnails, conversation: target, context: context, editing: edited)
        pinLatestQuestion()
    }

    #if DEBUG
    private func debugTimeline() async {
        if DebugHooks.value("StrataDebugBranch") != nil {
            if controller.activeMessageID == nil, !branchDebugDone, conversation?.leafMessage?.role == .assistant {
                branchDebugDone = true
                Task { await debugBranching() } // not tied to this task: it is cancelled when the turn starts
            }
            return
        }
        guard let sheet = DebugHooks.openSheet, sheet.hasPrefix("timeline") || ["usage", "context", "rename", "details", "compaction", "summarize", "translate"].contains(sheet) else { return }
        if sheet == "translate" { // translates the first answer once it is in
            if controller.activeMessageID == nil, !branchDebugDone, let m = conversation?.leafMessage, m.role == .assistant {
                branchDebugDone = true
                controller.translation.translate(m, context: context)
            }
            return
        }
        if sheet == "compaction" {
            if controller.activeMessageID == nil, let r = conversation?.sortedCompactions.last { compactionNotes = r }
            return
        }
        if sheet == "summarize" { // "Summarize now" once the first answer is in
            if controller.activeMessageID == nil, !branchDebugDone, let c = conversation, c.leafMessage?.role == .assistant {
                branchDebugDone = true
                controller.compactNow(conversation: c, context: context)
            }
            return
        }
        if sheet == "rename" {
            if controller.activeMessageID == nil, let c = conversation, c.messages.contains(where: { $0.role == .assistant }) {
                renameText = "score가 NULL인 행은 어떻게 처리되는지 SQL 집계 함수 동작 정리"
                showRename = true
            }
            return
        }
        if sheet == "details" {
            if controller.activeMessageID == nil, conversation != nil { showDetails = true }
            return
        }
        if sheet == "usage" || sheet == "context" {
            if controller.activeMessageID == nil, conversation?.messages.contains(where: { $0.role == .assistant }) == true { showContext = true }
            return
        }
        if sheet == "timelinelive" {
            guard let id = controller.activeMessageID else { return }
            try? await Task.sleep(for: .seconds(2.5))
            timeline = conversation?.messages.first { $0.id == id }.map { TimelineRequest(message: $0, showsTools: true) }
        } else if controller.activeMessageID == nil {
            timeline = conversation?.messages.filter { $0.role == .assistant }.max { $0.sortIndex < $1.sortIndex }
                .map { TimelineRequest(message: $0, showsTools: sheet != "timelinereasoning") }
        }
    }
    #endif

    /// `-StrataDebugBranch switch`: edits the first question and regenerates the answer, so the switchers show.
    /// `-StrataDebugBranch editbar`: puts the first question into the composer in edit mode.
    private func debugBranching() async {
        guard let mode = DebugHooks.value("StrataDebugBranch"), let c = conversation,
              let first = c.activePath.first(where: { $0.role == .user }) else { return }
        func settle() async {
            for _ in 0..<200 {
                try? await Task.sleep(for: .milliseconds(200))
                if !controller.isStreaming { break }
            }
        }
        if mode == "editbar" { beginEdit(first); return }
        controller.send(text: "An edited version of the first question", images: [], conversation: c, context: context, editing: first)
        await settle()
        controller.regenerate(conversation: c, context: context)
        await settle()
    }

    private func debugActions() async {
        #if DEBUG
        func openRequestedSheet() {
            switch DebugHooks.openSheet {
            case "usage" where conversation != nil: showContext = true
            case "model", "chatsettings": showChatSettings = true
            case "settings", "diagnostics", "licenses", "connection": onOpenSettings()
            case "attach": showAttach = true
            case "code": debugViewer = true
            default: break
            }
        }
        if DebugHooks.autoPickRecent {
            showAttach = true
            try? await Task.sleep(for: .seconds(4)) // the strip picks a photo and the sheet closes
            if let text = DebugHooks.autoSend { draft.text = text; send() }
            return
        }
        if let text = DebugHooks.autoSend, conversation == nil, !DebugHooks.autoSendFired {
            DebugHooks.autoSendFired = true // New Chat later must not send it again
            try? await Task.sleep(for: .seconds(1.5))
            draft.text = text
            send()
            for _ in 0..<200 {
                try? await Task.sleep(for: .milliseconds(200))
                if !controller.isStreaming { break }
            }
            try? await Task.sleep(for: .seconds(1))
        } else if DebugHooks.autoSend != nil {
            return
        } else {
            try? await Task.sleep(for: .seconds(1))
        }
        openRequestedSheet()
        if let text = DebugHooks.value("StrataDraft") { draft.text = text }
        #if os(iOS)
        if let n = DebugHooks.value("StrataOpenMenu").flatMap(Int.init) {
            try? await Task.sleep(for: .seconds(1.5))
            DebugHooks.presentMenu(index: n)
        }
        #endif
        #endif
    }
}

/// The Timeline sheet for a message: everything, or the reasoning alone.
struct TimelineRequest: Identifiable {
    let message: Message
    let showsTools: Bool
    var id: String { "\(message.id)-\(showsTools)" }
}

struct SourceListItem: Identifiable {
    let sources: [SourceInfo]
    /// The whole conversation's sources, when the sheet offers them.
    var all: [SourceInfo] = []
    var id: String { sources.map { String($0.id) }.joined(separator: ",") }
}

/// The composer's text and attachments. Observable and separate from `ChatView` on purpose.
@MainActor
@Observable
final class ComposerDraft {
    var text = ""
    var attachments: [ComposerAttachment] = []

    /// Sending is allowed whenever there is something to send; missing key or model is reported inline.
    var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
}

/// Reads the draft so `ChatView` does not: a keystroke re-renders only the composer.
private struct ComposerHost<Accessory: View>: View {
    @Bindable var draft: ComposerDraft
    let isStreaming: Bool
    let isBusy: Bool
    let plusDimmed: Bool
    let onAttach: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    var onCancelEdit: (() -> Void)?
    var onPasteImages: (([Data]) -> Void)?
    @ViewBuilder let accessory: () -> Accessory
    #if os(macOS)
    var isFocused: Binding<Bool>
    #else
    var isFocused: FocusState<Bool>.Binding
    #endif

    var body: some View {
        ComposerBar(
            text: $draft.text,
            attachments: draft.attachments,
            placeholder: "Message",
            isStreaming: isStreaming,
            canSend: draft.canSend && !isBusy,
            plusDimmed: plusDimmed,
            onAttach: onAttach,
            onRemoveAttachment: { id in draft.attachments.removeAll { $0.id == id } },
            onCancelEdit: onCancelEdit,
            onPasteImages: onPasteImages,
            onSend: onSend,
            onStop: onStop,
            accessory: accessory,
            isFocused: isFocused)
    }
}

/// Geometry for pinning a question to the top while its answer streams. A reference type written from geometry
/// callbacks and read only by `PinReserve`, so neither scrolling nor a growing answer re-evaluates the chat.
@MainActor
@Observable
final class PinLayout {
    static let space = "chatContent"

    struct Viewport: Equatable { var height: CGFloat; var visibleBottom: CGFloat }

    /// Top of the pinned question and end of the transcript, in content coordinates.
    var pinnedTop: CGFloat = 0
    var contentEnd: CGFloat = 0
    /// The visible height (between the header and the composer).
    var viewport: CGFloat = 0
    @ObservationIgnored var visibleBottom: CGFloat = 0

    /// Room under the transcript so the pinned question can sit at the top of the screen.
    var reserve: CGFloat { Self.reserve(viewport: viewport, pinnedTop: pinnedTop, contentEnd: contentEnd) }

    nonisolated static func reserve(viewport: CGFloat, pinnedTop: CGFloat, contentEnd: CGFloat) -> CGFloat {
        max(0, viewport - (contentEnd - pinnedTop))
    }

    /// Nothing of the reserved room is on screen, so dropping it moves nothing.
    var reserveOutOfView: Bool { reserve <= 0 || visibleBottom <= contentEnd + 1 }
}

/// Measures the pinned question's top.
private struct PinTopReader: ViewModifier {
    let isPinned: Bool
    let pin: PinLayout

    func body(content: Content) -> some View {
        if isPinned {
            content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(PinLayout.space)).minY } action: { pin.pinnedTop = $0 }
        } else {
            content
        }
    }
}

/// The room under a pinned question's answer. It shrinks as the answer grows into it, never by a jump.
private struct PinReserve: View {
    let pin: PinLayout
    var body: some View { Color.clear.frame(height: pin.reserve).accessibilityHidden(true) }
}
