import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.theme) var theme
    @Environment(\.modelContext) var context
    @Environment(\.appSettings) var settings
    @Environment(\.connectionStore) var connections
    @Environment(\.chatController) var controller

    @Binding var conversation: Conversation?
    let onOpenSidebar: () -> Void
    let onOpenSettings: () -> Void
    var onNewChat: () -> Void = {}
    /// Bumped by the root to ask for composer focus (New Chat).
    var focusToken = 0

    /// Reference-typed so typing never invalidates this view: only `ComposerHost` reads the text.
    @State var draft = ComposerDraft()
    @State var position = ScrollPosition(edge: .bottom)
    @State var atBottom = true
    /// The question being answered, held at the top of the screen from its send until the next send or until the user
    /// scrolls the room reserved under it out of view. Nil when nothing is pinned (a chat just opened).
    @State var pinnedID: UUID?
    /// Set by the jump button: the view then sticks to the end while the answer grows, until the user scrolls or sends.
    @State var followsBottom = false
    /// The question just sent: its bubble flies up from the composer once (`SendFlyIn`).
    @State var flyingID: UUID?
    @State var jumpRetry: Task<Void, Never>?
    /// Heights for the room under the pinned question; read only by `PinReserve`, so scrolling and streaming never
    /// re-evaluate this view.
    @State var pin = PinLayout()
    @State var showAttach = false
    /// The "+" menu's tool switches of a new chat before its first message creates it (nil: the defaults in Settings).
    @State var newChatTools: Set<ToolGroup>?
    /// A new chat's package switches, once changed in the "+" menu (the defaults until then).
    @State var newChatPackages: Set<String>?
    #if os(macOS)
    @State var showNoImageSupport = false
    #endif
    /// "Select model" (models, effort, search engine): a sheet on the phone, a popover from the gauge on a Mac.
    @State var showChatSettings = false
    /// The composer's height, so the floating "Answer now" capsule sits just above it.
    @State var composerHeight: CGFloat = 0
    @State var showContext = false
    @State var showDetails = false
    #if DEBUG
    @State var branchDebugDone = false
    #endif
    /// The sent message being edited, and what the composer held before editing began.
    @State var editing: Message?
    @State var savedDraft: (text: String, attachments: [ComposerAttachment])?
    @State var timeline: TimelineRequest?
    @State var compactionNotes: CompactionRecord?
    @State var citationItem: SourceListItem?
    @State var sourcesItem: SourceListItem?
    @State var showRename = false
    @State var loadingModels = false
    /// The model fetch a send is waiting on; cancelled when this chat view goes away.
    @State var modelFetch: Task<Void, Never>?
    /// The add-connection sheet, from the empty chat shown while there is no connection: on the presets, or straight
    /// into a new connection's editor (first-run shortcuts).
    @State var addConnectionRequest: ConnectionSetupSheet.Request?
    #if DEBUG
    @State var debugSelection: String?
    @State var debugArtifact: ArtifactRef?
    #endif
    @State var renameText = ""
    @State var confirmDelete = false
    #if os(macOS)
    @State var composerFocused = false
    #else
    @FocusState var composerFocused: Bool
    #endif
    #if DEBUG
    @State var debugViewer = false
    #endif

    // MARK: Selection

    struct Selection {
        var connectionID: UUID?
        var modelID: String?
        var effort: Effort
    }

    var selection: Selection {
        if let c = conversation { return Selection(connectionID: c.connectionID, modelID: c.modelID, effort: c.effort) }
        let choice = ModelSelection.resolve(connections: connections.connections,
                                            preferredConnectionID: settings.lastConnectionID,
                                            preferredModelID: settings.lastModelID)
        return Selection(connectionID: choice?.connectionID, modelID: choice?.modelID, effort: settings.lastEffort)
    }

    /// Persist the auto-selected model so it survives relaunch.
    func persistAutoSelection() {
        guard conversation == nil, let cid = selection.connectionID, let mid = selection.modelID else { return }
        if settings.lastConnectionID != cid { settings.lastConnectionID = cid }
        if settings.lastModelID != mid { settings.lastModelID = mid }
    }

    var selectedModel: ModelInfo? {
        let s = selection
        return connections.connection(s.connectionID)?.models.first { $0.id == s.modelID }
    }

    /// The selected model as the user sees it: its alias when set, else the real id (requests always use the id).
    var selectedModelTitle: String? {
        let s = selection
        return connections.displayName(connectionID: s.connectionID, modelID: s.modelID)
    }

    func apply(connectionID: UUID, modelID: String) {
        settings.lastConnectionID = connectionID
        settings.lastModelID = modelID
        conversation?.connectionID = connectionID
        conversation?.modelID = modelID
    }

    func enableImagesForSelectedModel() {
        let sel = selection
        guard var c = connections.connection(sel.connectionID), let i = c.models.firstIndex(where: { $0.id == sel.modelID }) else { return }
        c.models[i].supportsImages = true
        c.models[i].supportsImagesUserSet = true
        connections.upsert(c)
    }

    func apply(effort: Effort) {
        settings.lastEffort = effort
        conversation?.effort = effort
    }

    var contextLength: Int {
        (selectedModel?.effectiveContextLength(default: settings.defaultContextLength)) ?? settings.defaultContextLength
    }

    var contextFraction: Double {
        guard let used = conversation?.lastUsage?.totalTokens, contextLength > 0 else { return 0 }
        return min(1, Double(used) / Double(contextLength))
    }

    var citationContext: CitationContext {
        let list = run.map(\.liveSources) ?? conversation?.allSources ?? []
        return CitationContext(sources: Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) }), conversationID: conversation?.id)
    }

    /// The chat's citations as one message reads them: its own calls' numbering first (`SourceSnapshots.overlay`).
    static func citations(_ context: CitationContext, for message: Message) -> CitationContext {
        guard message.role == .assistant else { return context }
        let calls = message.segments.flatMap(\.calls)
        guard calls.contains(where: { $0.sources != nil }) else { return context }
        var out = context
        out.sources = SourceSnapshots.overlay(context.sources, calls: calls)
        return out
    }

    /// Every source an answer on the active path read or cited, in order: the Sources sheet's "All" list.
    var conversationUsedSources: [SourceInfo] {
        guard let conversation else { return [] }
        let byID = citationContext.sources
        let known = Set(byID.keys)
        var ids: [Int] = []
        for message in conversation.activePath where message.role == .assistant {
            for id in SourceUsage.ids(calls: message.segments.flatMap(\.calls),
                                          text: MessageLayout.fullText(segments: message.segments, answer: message.text), known: known)
            where !ids.contains(id) { ids.append(id) }
        }
        return ids.compactMap { byID[$0] }
    }

    /// This chat's running (or queued) reply. Other chats' runs are theirs: this view never reads them.
    var run: ChatRun? { controller.run(for: conversation) }

    var isStreamingHere: Bool { run != nil }

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
                .padding(.bottom, composerHeight + Self.floatingGap)
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
            .sheet(item: Binding(get: { SkillApprovals.shared.pending(for: conversation?.id) }, set: { _ in })) { request in
                SkillApprovalSheet(request: request) { SkillApprovals.shared.answer(request.id, approved: $0) }
                    .environment(\.theme, theme)
                    #if DEBUG
                    .task { await DebugHooks.autoAnswerSheet { SkillApprovals.shared.answer(request.id, approved: true) } }
                    #endif
            }
            .sheet(item: Binding(get: { BrowserShowRequests.shared.pending(for: conversation?.id) },
                                 set: { if $0 == nil, let open = BrowserShowRequests.shared.pending(for: conversation?.id) { BrowserShowRequests.shared.answer(open.id, done: false) } })) { request in
                BrowserShowSheet(request: request) { BrowserShowRequests.shared.answer(request.id, done: $0) }
                    .environment(\.theme, theme)
                    #if DEBUG
                    .task { await DebugHooks.autoAnswerSheet { BrowserShowRequests.shared.answer(request.id, done: true) } }
                    #endif
            }
            .sheet(item: $addConnectionRequest) { request in
                ConnectionSetupSheet(start: request.start)
                    .inAppLinks()
                    .environment(\.theme, theme)
            }
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
                let active = run?.messageID == message.id
                TimelineSheet(reasoning: controller.renderState(for: message).reasoning,
                              steps: message.steps,
                              pending: active ? run?.pendingCalls ?? [] : [],
                              sources: citationContext.sources,
                              isLive: active,
                              seconds: message.thinkingSeconds,
                              showsTools: request.showsTools)
                    .environment(\.theme, theme)
                    .environment(\.citations, citationContext)
            }
            .sheet(item: $compactionNotes) { record in
                CompactionNotesSheet(notes: record.notes, tokensBefore: record.tokensBefore, tokensAfter: record.tokensAfter,
                                     date: record.createdAt, isAutomatic: record.isAutomatic)
                    .environment(\.theme, theme)
            }
            .alert("Couldn't summarize", isPresented: Binding(get: { controller.compactionError(for: conversation) != nil },
                                                               set: { if !$0 { controller.clearCompactionError(for: conversation) } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(controller.compactionError(for: conversation) ?? "") }
            .sheet(item: $citationItem) { item in
                SourcesSheet(title: item.sources.count == 1 ? "Source" : "Sources", sources: item.sources)
            }
            .sheet(item: $sourcesItem) { item in
                SourcesSheet(title: "Sources", sources: item.sources, all: item.all)
            }
            #if DEBUG
            .modifier(DebugSheets(viewer: $debugViewer, selection: $debugSelection, artifact: $debugArtifact))
            #endif
            .alert("Couldn't make a title",
                   isPresented: Binding(get: { controller.titleFailedConversationID != nil },
                                        set: { if !$0 { controller.titleFailedConversationID = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The model didn't answer. Check its connection and try again.")
            }
            .renameChat(isPresented: $showRename, text: $renameText) { title in
                conversation?.setUserTitle(title)
                try? context.save()
            }
            .confirmationDialog("Delete this chat?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let c = conversation {
                        conversation = nil
                        ConversationDeletion.delete(c, context: context, controller: controller)
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
            .intentDraft(draft, isNewChat: conversation == nil)
            .task(id: focusToken) {
                guard focusToken > 0 else { return }
                try? await Task.sleep(for: .milliseconds(150))
                composerFocused = true
            }
            .task(id: conversation?.id) { // opening a chat: link one saved before branching; leaving one ends an edit
                cancelEdit()
                if conversation == nil { newChatTools = nil; newChatPackages = nil } // a new chat starts from the defaults
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
            .task(id: run?.messageID) { await debugTimeline() }
            #endif
            .onChange(of: connections.allModels.count) { _, _ in persistAutoSelection() }
            .onDisappear { modelFetch?.cancel() }
            #if os(macOS)
            .onChange(of: conversation?.activePath.last?.id, initial: true) { _, _ in installMenuActions() }
            .onChange(of: isStreamingHere) { _, _ in installMenuActions() }
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
