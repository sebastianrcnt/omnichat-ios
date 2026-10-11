import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(ConnectionStore.self) private var connections
    @Environment(ChatController.self) private var controller

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
    @State private var showAttach = false
    @State private var showModelPicker = false
    @State private var showUsage = false
    @State private var showDetails = false
    #if DEBUG
    @State private var branchDebugDone = false
    #endif
    /// The sent message being edited, and what the composer held before editing began.
    @State private var editing: Message?
    @State private var savedDraft: (text: String, attachments: [ComposerAttachment])?
    @State private var timelineMessage: Message?
    @State private var compactionNotes: CompactionRecord?
    @State private var citationItem: SourceListItem?
    @State private var sourcesItem: SourceListItem?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @FocusState private var composerFocused: Bool
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

    private var isStreamingHere: Bool {
        conversation.map { controller.isStreaming($0) } ?? false
    }

    // MARK: Body

    var body: some View {
        messages
            .safeAreaBar(edge: .top) { header }
            .safeAreaBar(edge: .bottom) { composer }
            .overlay(alignment: .bottom) { jumpButton }
            .sheet(isPresented: $showAttach) {
                AttachSheet(supportsImages: selectedModel?.supportsImages ?? false, modelName: selection.modelID,
                            onPick: addAttachments,
                            onEnableImages: enableImagesForSelectedModel)
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(
                    selectedConnectionID: selection.connectionID,
                    selectedModelID: selection.modelID,
                    effort: selection.effort,
                    onSelectModel: apply(connectionID:modelID:),
                    onSelectEffort: apply(effort:),
                    onOpenSettings: { showModelPicker = false; onOpenSettings() })
            }
            .sheet(isPresented: $showDetails) {
                if let conversation {
                    ConversationDetailsSheet(conversation: conversation, contextLength: contextLength)
                        .environment(\.theme, theme)
                }
            }
            .sheet(isPresented: $showUsage) {
                UsageSheet(conversation: conversation, contextLength: contextLength,
                           connection: connections.connection(selection.connectionID))
            }
            .sheet(item: $timelineMessage) { message in
                let active = controller.activeMessageID == message.id
                TimelineSheet(reasoning: controller.renderState(for: message).reasoning,
                              steps: message.steps,
                              pending: active ? controller.pendingCalls : [],
                              sources: citationContext.sources,
                              isLive: active,
                              seconds: message.thinkingSeconds)
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
                SourcesSheet(title: "Sources", sources: item.sources)
            }
            #if DEBUG
            .fullScreenCover(isPresented: $debugViewer) {
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
            .onChange(of: atBottom) { _, now in
                if !now && isStreamingHere { controller.revealAllNow() } // user scrolled away: show everything now
            }
            .onChange(of: showAttach) { _, on in if on { composerFocused = false } }
            .onChange(of: showModelPicker) { _, on in if on { composerFocused = false } }
            .onChange(of: showUsage) { _, on in if on { composerFocused = false } }
            .onChange(of: composerFocused) { _, focused in
                // Keep the latest message visible when the keyboard opens.
                if focused && atBottom { withAnimation(DS.Motion.spring) { position.scrollTo(edge: .bottom) } }
            }
            .task(id: focusToken) {
                guard focusToken > 0 else { return }
                try? await Task.sleep(for: .milliseconds(150))
                composerFocused = true
            }
            .task(id: conversation?.id) { // opening a chat: link one saved before branching; leaving one ends an edit
                cancelEdit()
                conversation?.ensureTree()
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

    private var header: some View {
        GlassEffectContainer(spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                GlassIconButton(systemName: "line.3.horizontal", label: "Sidebar") { composerFocused = false; onOpenSidebar() }
                VStack(alignment: .leading, spacing: 0) {
                    Text(conversation?.displayTitle ?? String(localized: "New chat"))
                        .font(DS.Typography.title)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(DS.Motion.ease, value: conversation?.title)
                    if let model = selection.modelID {
                        Text(model).font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                ContextRingButton(fraction: conversation?.lastUsage == nil ? nil : contextFraction) {
                    composerFocused = false
                    showUsage = true
                }
                GlassIconMenu(systemName: "ellipsis", label: "More") { menuContent }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm) // 8pt below the 44pt buttons, clear of the blur edge
        }
        // A real surface behind the title: answer text scrolling underneath must never show through it.
        .background(alignment: .top) { HeaderBacking() }
    }

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
            Button("Rename automatically", systemImage: "wand.and.stars") {
                controller.autoRename(conversation: c, context: context, force: true)
            }
            .disabled(controller.isStreaming)
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
                    let items = conversation.activePath
                    let summaries = conversation.compactions(anchoredIn: items)
                    ForEach(items) { message in
                        row(message, isLast: message.id == items.last?.id, branch: tree.branch(of: message.id))
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
            }
            .padding(.horizontal, DS.Spacing.page)
            .padding(.top, DS.Spacing.md)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges) // growing content keeps the pinned bottom in step with its animation
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
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
                          onCopy: { UIPasteboard.general.string = message.text },
                          onEdit: controller.isStreaming ? nil : { beginEdit(message) })
        case .assistant:
            let active = controller.activeMessageID == message.id
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
                    canRegenerate: isLast && !controller.isStreaming),
                render: controller.renderState(for: message),
                onOpenTimeline: { timelineMessage = message },
                onOpenSources: { sourcesItem = SourceListItem(sources: $0) },
                onCopy: { UIPasteboard.general.string = MarkdownPlain.text(from: message.text) },
                onRegenerate: {
                    if let c = conversation { controller.regenerate(conversation: c, context: context) }
                },
                onOpenSettings: onOpenSettings,
                onCopyRaw: { UIPasteboard.general.string = message.text },
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
                GlassIconButton(systemName: "arrow.down", label: "Jump to bottom", diameter: DS.IconSize.compactControlDiameter + 4) {
                    withAnimation(DS.Motion.spring) { position.scrollTo(edge: .bottom) }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.bottom, DS.Spacing.composerClearance)
        .animation(DS.Motion.snappy, value: atBottom)
    }

    // MARK: Composer

    private var composer: some View {
        ComposerHost(
            draft: draft,
            isStreaming: isStreamingHere,
            isBusy: controller.isStreaming,
            plusDimmed: !(selectedModel?.supportsImages ?? false),
            onAttach: { composerFocused = false; showAttach = true },
            onSend: send,
            onStop: { controller.stop() },
            onCancelEdit: editing == nil ? nil : { withAnimation(DS.Motion.snappy) { cancelEdit() } },
            chip: {
                ModelEffortChip(
                    modelName: selection.modelID ?? String(localized: "Select model"),
                    effortTitle: (selectedModel?.supportsEffort ?? false) ? selection.effort.title : nil) {
                    composerFocused = false
                    showModelPicker = true
                }
            },
            isFocused: $composerFocused)
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
        withAnimation(DS.Motion.spring) { position.scrollTo(edge: .bottom) }
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
        guard let sheet = DebugHooks.openSheet, sheet.hasPrefix("timeline") || ["usage", "rename", "details", "compaction", "summarize"].contains(sheet) else { return }
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
        if sheet == "usage" {
            if controller.activeMessageID == nil, conversation?.messages.contains(where: { $0.role == .assistant }) == true { showUsage = true }
            return
        }
        if sheet == "timelinelive" {
            guard let id = controller.activeMessageID else { return }
            try? await Task.sleep(for: .seconds(2.5))
            timelineMessage = conversation?.messages.first { $0.id == id }
        } else if controller.activeMessageID == nil {
            timelineMessage = conversation?.messages.filter { $0.role == .assistant }.max { $0.sortIndex < $1.sortIndex }
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
            case "usage" where conversation != nil: showUsage = true
            case "model": showModelPicker = true
            case "settings", "diagnostics": onOpenSettings()
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
        if let text = DebugHooks.autoSend, conversation == nil {
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
        #endif
    }
}

struct SourceListItem: Identifiable {
    let sources: [SourceInfo]
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
private struct ComposerHost<Chip: View>: View {
    @Bindable var draft: ComposerDraft
    let isStreaming: Bool
    let isBusy: Bool
    let plusDimmed: Bool
    let onAttach: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    var onCancelEdit: (() -> Void)?
    @ViewBuilder let chip: () -> Chip
    var isFocused: FocusState<Bool>.Binding

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
            onSend: onSend,
            onStop: onStop,
            chip: chip,
            isFocused: isFocused)
    }
}
