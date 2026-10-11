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

    @State private var draft = ""
    @State private var attachments: [ComposerAttachment] = []
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    @State private var showAttach = false
    @State private var showModelPicker = false
    @State private var showUsage = false
    @State private var thinkingMessage: Message?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false
    @FocusState private var composerFocused: Bool

    // MARK: Selection

    private struct Selection {
        var connectionID: UUID?
        var modelID: String?
        var effort: Effort
    }

    private var selection: Selection {
        if let c = conversation { return Selection(connectionID: c.connectionID, modelID: c.modelID, effort: c.effort) }
        var sel = Selection(connectionID: settings.lastConnectionID, modelID: settings.lastModelID, effort: settings.lastEffort)
        let valid = connections.connection(sel.connectionID)?.models.contains { $0.id == sel.modelID } ?? false
        if !valid, let first = connections.allModels.first {
            sel.connectionID = first.connection.id
            sel.modelID = first.model.id
        }
        return sel
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

    private var isStreamingHere: Bool {
        conversation.map { controller.isStreaming($0) } ?? false
    }

    private var canSend: Bool {
        guard selectedModel != nil || selection.modelID != nil else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    // MARK: Body

    var body: some View {
        messages
            .safeAreaBar(edge: .top) { header }
            .safeAreaBar(edge: .bottom) { composer }
            .overlay(alignment: .bottom) { jumpButton }
            .sheet(isPresented: $showAttach) {
                AttachSheet(supportsImages: selectedModel?.supportsImages ?? false) { jpegs in
                    attachments.append(contentsOf: jpegs.map { ComposerAttachment(id: UUID(), jpeg: $0) })
                }
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
            .sheet(isPresented: $showUsage) {
                UsageSheet(conversation: conversation, contextLength: contextLength,
                           connection: connections.connection(selection.connectionID))
            }
            .sheet(item: $thinkingMessage) { message in
                ThinkingSheet(model: controller.renderState(for: message).reasoning,
                              isStreaming: controller.activeMessageID == message.id && controller.phase == .thinking,
                              seconds: message.thinkingSeconds)
            }
            .alert("Rename chat", isPresented: $showRename) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { conversation?.title = t; try? context.save() }
                }
            }
            .confirmationDialog("Delete this chat?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let c = conversation {
                        conversation = nil
                        context.delete(c)
                        try? context.save()
                    }
                }
            }
            .onChange(of: atBottom) { _, now in
                if !now && isStreamingHere { controller.revealAllNow() } // user scrolled away: show everything now
            }
            .task { await debugActions() }
    }

    // MARK: Header

    private var header: some View {
        GlassEffectContainer(spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.md) {
                GlassIconButton(systemName: "line.3.horizontal", label: "Sidebar", action: onOpenSidebar)
                VStack(alignment: .leading, spacing: 0) {
                    Text(conversation?.displayTitle ?? String(localized: "New chat"))
                        .font(DS.Typography.title)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if let model = selection.modelID {
                        Text(model).font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if conversation != nil {
                    Button { showUsage = true } label: {
                        ContextRing(fraction: contextFraction)
                            .frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(Text("Usage"))
                    GlassIconMenu(systemName: "ellipsis", label: "More") { menuContent }
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.xs)
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if let c = conversation {
            Button(c.isPinned ? "Unpin" : "Pin", systemImage: c.isPinned ? "pin.slash" : "pin") {
                c.isPinned.toggle()
                try? context.save()
            }
            Button("Rename", systemImage: "pencil") {
                renameText = c.title
                showRename = true
            }
            ShareLink(item: c.transcript) { Label("Share as text", systemImage: "square.and.arrow.up") }
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
        }
    }

    // MARK: Messages

    private var messages: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.xl) {
                if let conversation {
                    let items = conversation.sortedMessages
                    ForEach(items) { message in
                        row(message, isLast: message.id == items.last?.id)
                    }
                } else {
                    emptyState
                }
                Color.clear.frame(height: DS.Spacing.lg).id("bottom")
            }
            .padding(.horizontal, DS.Spacing.page)
            .padding(.top, DS.Spacing.md)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentSize.height - (geo.contentOffset.y + geo.containerSize.height) < 80
        } action: { _, newValue in
            atBottom = newValue
        }
        .background(theme.background.ignoresSafeArea())
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.sm) {
            Text("How can I help?")
                .font(DS.Typography.largeTitle)
                .foregroundStyle(theme.textPrimary)
            if connections.allModels.isEmpty {
                Text("Add a connection and API key in Settings to start chatting.")
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Open Settings", action: onOpenSettings).buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    @ViewBuilder
    private func row(_ message: Message, isLast: Bool) -> some View {
        switch message.role {
        case .user:
            MessageBubble(text: message.text, images: message.sortedAttachments.map(\.jpegData))
        case .assistant:
            let active = controller.activeMessageID == message.id
            AssistantMessage(
                content: AssistantContent(
                    thinkingSeconds: message.thinkingSeconds,
                    calls: message.steps.flatMap(\.calls),
                    pending: active ? controller.pendingCalls : [],
                    isStreaming: active,
                    phase: active ? controller.phase : .idle,
                    errorText: message.errorText,
                    stopped: message.stoppedByUser,
                    canRegenerate: isLast && !controller.isStreaming),
                render: controller.renderState(for: message),
                onOpenThinking: { thinkingMessage = message },
                onCopy: { UIPasteboard.general.string = message.text },
                onRegenerate: {
                    if let c = conversation { controller.regenerate(conversation: c, context: context) }
                })
        }
    }

    private var jumpButton: some View {
        Group {
            if !atBottom {
                GlassIconButton(systemName: "arrow.down", label: "Jump to bottom", diameter: DS.IconSize.compactControlDiameter + 4) {
                    withAnimation(DS.Motion.spring) { position.scrollTo(edge: .bottom) }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.bottom, 150)
        .animation(DS.Motion.snappy, value: atBottom)
    }

    // MARK: Composer

    private var composer: some View {
        ComposerBar(
            text: $draft,
            attachments: attachments,
            placeholder: "Message",
            isStreaming: isStreamingHere,
            canSend: canSend && !controller.isStreaming,
            plusDimmed: !(selectedModel?.supportsImages ?? false),
            onAttach: { composerFocused = false; showAttach = true },
            onRemoveAttachment: { id in attachments.removeAll { $0.id == id } },
            onSend: send,
            onStop: { controller.stop() },
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
        guard let modelID = sel.modelID, let connectionID = sel.connectionID else { return }
        let target: Conversation
        if let existing = conversation {
            target = existing
        } else {
            target = Conversation(connectionID: connectionID, modelID: modelID, effort: sel.effort)
            context.insert(target)
            conversation = target
        }
        let text = draft
        let images = attachments.map(\.jpeg)
        draft = ""
        attachments = []
        controller.send(text: text, images: images, conversation: target, context: context)
        withAnimation(DS.Motion.spring) { position.scrollTo(edge: .bottom) }
    }

    private func debugActions() async {
        #if DEBUG
        func openRequestedSheet() {
            switch DebugHooks.openSheet {
            case "usage" where conversation != nil: showUsage = true
            case "model": showModelPicker = true
            case "settings": onOpenSettings()
            case "attach": showAttach = true
            default: break
            }
        }
        if let text = DebugHooks.autoSend, conversation == nil {
            try? await Task.sleep(for: .seconds(1.5))
            draft = text
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
