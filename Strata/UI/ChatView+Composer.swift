import SwiftUI
import SwiftData

extension ChatView {
    // MARK: Composer

    /// Opens another chat (the "Reply ready" banner).
    func open(_ id: UUID) {
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        if let other = try? context.fetch(descriptor).first { conversation = other }
    }

    var composer: some View {
        ComposerHost(
            draft: draft,
            isStreaming: isStreamingHere,
            isBusy: isStreamingHere || loadingModels,
            loadingModels: loadingModels,
            plusDimmed: !(selectedModel?.supportsImages ?? false),
            onAttach: attach,
            toolSwitches: toolSwitchItems,
            onToolSwitch: setTool,
            commands: PackageCommandItem.all(controller.packages),
            onSend: { send() },
            onStop: { if let c = conversation { controller.stop(c) } },
            onCancelEdit: editing == nil ? nil : { withAnimation(DS.Motion.snappy) { cancelEdit() } },
            onPasteImages: pasteHandler,
            accessory: { settingsButton },
            isFocused: $composerFocused)
        #if os(macOS)
        .readingColumn()
        #endif
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
    }

    /// The "+" menu's toggles: this chat's switches, or a new chat's (the defaults until changed). Only the views for
    /// a model without tools; only the web for Apple's on-device model, whose tools are web search and fetch.
    var toolSwitchItems: [ComposerToolSwitch] {
        let groups: [ToolGroup] = if connections.connection(selection.connectionID)?.isAppleOnDevice == true { [.web] }
            else if selectedModel?.supportsTools ?? true { ToolGroup.supported }
            else { [.views] }
        let on = conversation.map { controller.toolSwitches($0) } ?? newChatTools ?? settings.defaultToolGroups
        let items = groups.map { ComposerToolSwitch(id: $0.rawValue, title: $0.title, systemImage: $0.systemImage, isOn: on.contains($0)) }
        // Packages that add something to chats, by name, below the groups (not for a model without tools or on device).
        guard groups.count > 1 else { return items }
        let _ = PackagesVersion.shared.value
        let packagesOn = conversation.map { controller.packageSwitches($0) } ?? newChatPackages ?? controller.defaultPackages(groups: on)
        let packages = controller.packages.all.filter(\.addsToChats).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        return items + packages.map {
            ComposerToolSwitch(id: ToolSwitch.packagePrefix + $0.id, title: $0.name, systemImage: PackageToolNames.icon, isOn: packagesOn.contains($0.id))
        }
    }

    /// Applies from the next message.
    func setTool(_ item: ComposerToolSwitch, on: Bool) {
        if item.id.hasPrefix(ToolSwitch.packagePrefix) {
            let id = String(item.id.dropFirst(ToolSwitch.packagePrefix.count))
            if let conversation {
                controller.setPackage(id, on: on, conversation: conversation)
                try? context.save()
            } else {
                var tools = newChatTools ?? settings.defaultToolGroups
                var packages = newChatPackages ?? controller.defaultPackages(groups: tools)
                controller.applyPackage(id, on: on, groups: &tools, packages: &packages)
                newChatTools = tools
                newChatPackages = packages
            }
            return
        }
        guard let group = ToolGroup(rawValue: item.id) else { return }
        if let conversation {
            controller.setTool(group, on: on, conversation: conversation)
            try? context.save()
        } else {
            var tools = newChatTools ?? settings.defaultToolGroups
            if on { tools.insert(group) } else { tools.remove(group) }
            newChatTools = tools
        }
    }

    /// "Answer now", floating just above the composer while this chat's turn runs tool rounds. An overlay, so feed
    /// cards arriving never move it.
    @ViewBuilder
    var answerNowCapsule: some View {
        if let conversation, let run, run.canAnswerNow,
           let message = conversation.messages.first(where: { $0.id == run.messageID }) {
            let saved = message.segments.flatMap(\.calls).filter { $0.name == ToolNames.webSearch }.count
            let running = run.roundRequested.filter { $0.name == ToolNames.webSearch }.count
            AnswerNowCapsule(start: run.turnStart ?? .now, completedToolRounds: run.completedToolRounds,
                             searches: saved + running, phase: run.phase) { controller.answerNow(conversation) }
        }
    }

    /// The model and effort chip: tap for the chat settings (models, then Effort).
    var settingsButton: some View {
        let style = connections.connection(selection.connectionID)?.effortStyle ?? .tokenCaps
        let levels = selectedModel?.effortLevels(style) ?? []
        return ModelSettingsButton(
            model: selectedModelTitle ?? String(localized: "Choose a model"),
            effort: levels.isEmpty ? nil : selection.effort.resolved(in: levels).title,
            action: { composerFocused = false; showChatSettings = true })
        #if os(macOS)
        .popover(isPresented: $showChatSettings, arrowEdge: .top) { chatSettings }
        #endif
    }

    var chatSettings: some View {
        let s = selection
        return ModelPickerSheet(
            selectedConnectionID: s.connectionID, selectedModelID: s.modelID, effort: s.effort,
            onSelectModel: apply(connectionID:modelID:),
            onSelectEffort: apply(effort:),
            onOpenSettings: { showChatSettings = false; onOpenSettings() },
            onAddConnection: { showChatSettings = false; addConnection() })
    }

    /// Opens "Add a connection": on the presets, or with `preset` already picked and its editor open (nothing is saved
    /// before the editor's Add).
    func addConnection(preset: ConnectionPreset? = nil) {
        composerFocused = false
        addConnectionRequest = ConnectionSetupSheet.Request(start: preset.map { .editor($0.makeConnection()) } ?? .presets)
    }

    var pasteHandler: (([Data]) -> Void)? {
        #if os(macOS)
        pasteImages
        #else
        nil
        #endif
    }

    #if os(macOS)
    /// Images pasted into the composer (Mac): resized like any other attachment, if the model can read them.
    func pasteImages(_ images: [Data]) {
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

    func attach() {
        composerFocused = false
        #if os(macOS)
        if selectedModel?.supportsImages ?? false { showAttach = true } else { showNoImageSupport = true }
        #else
        showAttach = true
        #endif
    }

    #if os(macOS)
    /// The Chat menu's Regenerate and Copy Last Answer act on this chat.
    func installMenuActions() {
        guard let c = conversation, let last = c.activePath.last, last.role == .assistant else {
            WindowActions.shared.regenerate = nil
            WindowActions.shared.copyLastAnswer = nil
            return
        }
        WindowActions.shared.regenerate = { [controller, context] in
            guard !controller.isStreaming(c) else { return }
            controller.regenerate(conversation: c, context: context)
        }
        WindowActions.shared.copyLastAnswer = { Pasteboard.copy(MarkdownPlain.text(from: last.text)) }
    }
    #endif

    /// No model to send with while a connection that can list models has none yet (right after install, before the
    /// launch fetch is back, or after it failed).
    var needsModelList: Bool {
        guard (conversation == nil ? selection.modelID : conversation?.modelID) == nil else { return false }
        return connections.connections.contains { c in
            c.models.isEmpty && (connections.apiKey(for: c.id) != nil || connections.isChatGPTSignedIn(c.id)
                                 || connections.isOpenCodeSignedIn(c.id))
        }
    }

    func send(afterFetch: Bool = false) {
        // Nothing is cleared or created unless the controller will take it. Other chats' replies don't matter: with
        // every slot taken, this one waits its turn.
        guard !isStreamingHere, !loadingModels, draft.canSend else { return }
        // Fetch the model list first, then send: the draft stays in the composer meanwhile. If no model comes, the
        // send goes on and the chat says what's missing.
        if !afterFetch, needsModelList {
            loadingModels = true
            let origin = conversation?.id
            modelFetch = Task { @MainActor in
                for c in connections.connections where c.models.isEmpty {
                    _ = try? await connections.refreshModels(for: c.id)
                }
                loadingModels = false
                // The binding follows the sidebar: a draft typed here never goes into a chat opened meanwhile.
                guard !Task.isCancelled, conversation?.id == origin else { return }
                send(afterFetch: true)
            }
            return
        }
        let sel = selection
        let target: Conversation
        if let existing = conversation {
            target = existing
            // A chat made while there was no model takes the one there is now.
            if existing.modelID == nil, let choice = ModelSelection.resolve(connections: connections.connections,
                                                                         preferredConnectionID: settings.lastConnectionID,
                                                                         preferredModelID: settings.lastModelID) {
                existing.connectionID = choice.connectionID
                existing.modelID = choice.modelID
            }
        } else {
            target = Conversation(connectionID: sel.connectionID, modelID: sel.modelID, effort: sel.effort)
            if let newChatPackages {
                target.setSwitches(groups: newChatTools ?? settings.defaultToolGroups, packages: newChatPackages)
            } else {
                target.toolSwitches = newChatTools
            }
            newChatTools = nil
            newChatPackages = nil
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
        let sent = target.activePath.last { $0.role == .user && !$0.isHiddenInTranscript }?.id
        flyingID = sent
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if flyingID == sent { flyingID = nil } // a row laid out again later doesn't fly a second time
        }
        pinLatestQuestion()
    }

    /// A button, choice or form in an answer's interactive view: what was chosen is saved on the answer, and the
    /// follow-up goes out like a typed message (the composer's draft stays as it is).
    func sendFromView(_ message: Message, block: Int, submission: OUISubmission) {
        guard let conversation,
              OpenUIChat.send(submission, block: block, from: message, in: conversation, controller: controller, context: context)
        else { return }
        pinLatestQuestion()
    }
}
