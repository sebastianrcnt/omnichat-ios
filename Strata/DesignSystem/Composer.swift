import SwiftUI

/// The composer's model-and-effort chip: the model's name and, when it takes one, the effort level in secondary text
/// ("GPT-5.5 High"), so both show at a glance. Tap opens the chat settings (models, then Effort). A long name gives way
/// first; the effort word stays whole.
struct ModelSettingsButton: View {
    @Environment(\.theme) private var theme
    let model: String
    /// Nil when the model does not support effort.
    let effort: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xs) {
                Text(verbatim: model).foregroundStyle(theme.textPrimary).lineLimit(1).truncationMode(.middle)
                if let effort {
                    Text(verbatim: effort).foregroundStyle(theme.textSecondary).lineLimit(1).fixedSize()
                }
            }
            .font(DS.Typography.uiCaption)
            .padding(.horizontal, DS.Spacing.md)
            .frame(height: DS.IconSize.compactControlDiameter)
            .background(theme.composerControl, in: Capsule()) // on the composer's glass: flat, no glass of its own
            .contentShape(Capsule().inset(by: -max(0, (DS.IconSize.minHitTarget - DS.IconSize.compactControlDiameter) / 2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(effort.map { "Model \(model), effort \($0)" } ?? "Model \(model)"))
        .accessibilityHint(Text("Choose the model and effort"))
        #if os(macOS)
        .help(Text("Model and reasoning effort"))
        #endif
    }
}

/// "Answer now": a small capsule floating just above the composer. It fades in once the running turn has searched
/// twice or gone on for a while (`AnswerNow.isOffered`) and fades out when the model starts writing.
struct AnswerNowCapsule: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let start: Date
    let completedToolRounds: Int
    let searches: Int
    let phase: ChatController.Phase
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let offered = AnswerNow.isOffered(elapsed: context.date.timeIntervalSince(start),
                                              completedToolRounds: completedToolRounds, searches: searches, phase: phase)
            ZStack {
                if offered {
                    Button(action: action) {
                        Label("Answer now", systemImage: "forward.end.fill")
                            .font(DS.Typography.capsule)
                            .labelIconToTitleSpacing(DS.Spacing.xs + 2)
                            .imageScale(.small)
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, DS.Spacing.md + 2)
                            .frame(minHeight: DS.IconSize.capsuleHeight)
                            // A floating control, like the composer below it, so the same glass.
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .contentShape(Capsule().inset(by: -DS.Spacing.sm))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Stops searching and answers from what has been found"))
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : DS.Motion.ease, value: offered)
        }
    }
}

struct ComposerAttachment: Identifiable, Equatable {
    let id: UUID
    let jpeg: Data
    /// Small preview, made off the main thread after the photo is added. Shown here and stored with the message.
    var thumbnail: Data?
}

/// A tool switch in the composer's "+" menu (the chat's own, or a new chat's defaults).
struct ComposerToolSwitch: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    var isOn: Bool
}

/// Floating glass composer, always two rows as in Claude's app: the text on top, then plus, the settings accessory
/// (the model and effort chip), the microphone and send (stop while a reply runs). The model and effort stay in
/// sight whether or not the keyboard is up.
///
/// Dictation turns the controls into cancel, a waveform, the time and a check; the words heard are appended to the
/// text, in the accent color until confirmed.
struct ComposerBar<Accessory: View>: View {
    @Environment(\.theme) private var theme

    @Binding var text: String
    var attachments: [ComposerAttachment] = []
    var placeholder: LocalizedStringKey = "Message"
    var isStreaming = false
    var canSend: Bool
    var plusDimmed = false
    var onAttach: () -> Void
    /// With switches, plus is a menu: Add photos, then a toggle per tool group. Without, it adds photos at once.
    var toolSwitches: [ComposerToolSwitch] = []
    var onToolSwitch: (ComposerToolSwitch, Bool) -> Void = { _, _ in }
    var onRemoveAttachment: (UUID) -> Void = { _ in }
    /// Set while a sent message is being edited: shows the "Editing message" bar.
    var onCancelEdit: (() -> Void)?
    /// Images pasted into the field (Mac).
    var onPasteImages: (([Data]) -> Void)?
    /// Why Send is off right now (another chat is answering), with a way there.
    var notice: LocalizedStringKey?
    var onNotice: (() -> Void)?
    var onSend: () -> Void
    var onStop: () -> Void
    /// Shown in the controls row, after plus.
    @ViewBuilder var accessory: () -> Accessory
    #if os(macOS)
    /// A Mac composer is an NSTextView, which SwiftUI's focus system does not drive: focus is plain state.
    var isFocused: Binding<Bool>
    #else
    @FocusState.Binding var isFocused: Bool
    #endif
    @State private var inputHandle = TextInputHandle()
    @Namespace private var controls
    @Environment(\.scenePhase) private var scenePhase
    @State private var dictation = DictationController(engine: ConfiguredDictationEngine())
    /// Dictation started with the keyboard up: it comes back afterwards.
    @State private var refocusAfterDictation = false

    var body: some View {
        // Spacing under the gap between controls: neighboring glass buttons stay separate shapes. Merged, the effort
        // gauge and the microphone were one interactive glass, and pressing the gauge could start dictation.
        GlassEffectContainer(spacing: DS.Spacing.xs) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                if let onCancelEdit {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "pencil").font(.system(size: DS.IconSize.sm, weight: .semibold))
                        Text("Editing · sends as a new version").font(DS.Typography.uiCaption)
                        Spacer(minLength: 0)
                        Button(action: onCancelEdit) {
                            Image(systemName: "xmark.circle.fill").font(.system(size: DS.IconSize.md))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Cancel editing"))
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, DS.Spacing.xs)
                    .transition(.opacity)
                }
                if let notice {
                    HStack(spacing: DS.Spacing.sm) {
                        ProgressView().controlSize(.mini)
                        Text(notice).font(DS.Typography.uiCaption)
                        Spacer(minLength: 0)
                        if let onNotice {
                            Button("Show", action: onNotice).font(DS.Typography.uiCaption).buttonStyle(.plain)
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, DS.Spacing.xs)
                    .transition(.opacity)
                }
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.sm) {
                            ForEach(attachments) { a in
                                AttachmentThumbnail(data: a.thumbnail ?? a.jpeg) { onRemoveAttachment(a.id) }
                            }
                        }
                    }
                }
                fieldArea
                HStack(spacing: DS.Spacing.sm) {
                    if dictation.isActive {
                        cancelDictationButton
                        if dictation.showsTranscript {
                            DictationWaveform(levels: dictation.levels)
                            Spacer(minLength: DS.Spacing.sm)
                            dictationTrailing
                        } else {
                            DictationStatusLine(phase: dictation.phase)
                        }
                    } else {
                        plusButton
                        accessory()
                        Spacer(minLength: DS.Spacing.sm)
                        micButton
                        sendButton.matchedGeometryEffect(id: "send", in: controls)
                    }
                }
                .padding(.top, DS.Spacing.sm) // the text field is the main area; buttons are a separate row
            }
            .padding(.top, DS.Spacing.sm + DS.Spacing.xs)
            .padding(.bottom, DS.Spacing.md)
            .padding(.horizontal, DS.Spacing.md)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.composer))
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.xs)
        .animation(DS.Motion.snappy, value: dictation.phase)
        .onChange(of: scenePhase) { _, phase in
            // Going to the background stops the microphone; what was heard so far is kept.
            if phase == .background, dictation.isActive { insert(dictation.stopKeepingText()) }
        }
        .onDisappear { dictation.cancel() }
        .task(id: dictation.failure) {
            guard dictation.failure != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            dictation.dismissFailure()
        }
    }

    /// The text field, hidden (but kept, with its identity) under the live words while dictating.
    private var fieldArea: some View {
        ZStack(alignment: .topLeading) {
            field
                .padding(.horizontal, DS.Spacing.xs)
                .opacity(dictation.isActive ? 0 : 1)
                .allowsHitTesting(!dictation.isActive)
                .accessibilityHidden(dictation.isActive)
            if dictation.isActive {
                appendedWords
                    .padding(.horizontal, DS.Spacing.xs)
                    .transition(.opacity)
            }
        }
    }

    /// The text with the words heard so far after it, in the accent color until they are confirmed.
    private var appendedWords: some View {
        let words = dictation.transcript
        var shown = AttributedString(text)
        shown.foregroundColor = theme.textPrimary
        if !words.isEmpty {
            var tail = AttributedString(dictation.separator(after: text) + words)
            tail.foregroundColor = theme.accent
            shown += tail
        }
        return Group {
            if text.isEmpty && words.isEmpty {
                Text(dictation.isTranscribing ? "Transcribing…" : dictation.showsTranscript ? "Listening…" : "Message")
                    .foregroundStyle(theme.textSecondary)
            } else {
                Text(shown)
            }
        }
        .font(DS.Typography.ui)
        .lineLimit(6)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Time, stop (while a reply runs, so it stays reachable) and confirm.
    @ViewBuilder
    private var dictationTrailing: some View {
        DictationElapsed(start: dictation.startedAt, end: dictation.endedAt)
        if isStreaming { sendButton }
        DictationConfirmButton(enabled: dictation.canConfirm, action: confirmDictation)
            .matchedGeometryEffect(id: "send", in: controls)
    }

    private var cancelDictationButton: some View {
        GlassIconButton(systemName: "xmark", label: dictation.failure == nil ? "Cancel dictation" : "Dismiss",
                        diameter: DS.IconSize.compactControlDiameter, iconSize: DS.IconSize.composerIcon,
                        flat: true, action: cancelDictation)
            .matchedGeometryEffect(id: "plus", in: controls)
    }

    private var micButton: some View {
        GlassIconButton(systemName: "mic", label: "Dictate", diameter: DS.IconSize.compactControlDiameter,
                        iconSize: DS.IconSize.composerIcon, flat: true, action: startDictation)
            .matchedGeometryEffect(id: "mic", in: controls)
            #if os(macOS)
            .help(Text("Dictate"))
            #endif
    }

    // MARK: Dictation

    private var focused: Bool {
        get {
            #if os(macOS)
            isFocused.wrappedValue
            #else
            isFocused
            #endif
        }
        nonmutating set {
            #if os(macOS)
            isFocused.wrappedValue = newValue
            #else
            isFocused = newValue
            #endif
        }
    }

    private func startDictation() {
        refocusAfterDictation = focused
        focused = false
        dictation.start(expanded: true)
    }

    private func confirmDictation() {
        Task {
            insert(await dictation.confirm())
            restoreFocus()
        }
    }

    private func cancelDictation() {
        dictation.cancel()
        dictation.dismissFailure()
        restoreFocus()
    }

    private func restoreFocus() {
        if refocusAfterDictation { focused = true }
        refocusAfterDictation = false
    }

    private func insert(_ words: String) {
        guard !words.isEmpty else { return }
        text = dictation.merge(words, into: text)
    }

    /// Sending ends any dictation first.
    private func send() {
        dictation.cancel()
        onSend()
    }

    @ViewBuilder
    private var field: some View {
        #if os(macOS)
        MacComposerField(text: $text, isFocused: isFocused,
                         textColor: theme.textPrimary, onReturn: { if canSend && !isStreaming && !dictation.isActive { send() } },
                         onPasteImages: onPasteImages)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(DS.Typography.ui).foregroundStyle(theme.textSecondary).allowsHitTesting(false)
                }
            }
        #else
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.textSecondary), axis: .vertical)
            .lineLimit(1...6)
            .font(DS.Typography.ui)
            .foregroundStyle(theme.textPrimary)
            .unbezeledField()
            .focused($isFocused)
            .withoutInputAssistantBar(handle: inputHandle)
            .returnSends(handle: inputHandle) { // Mac only; same rules as the send button
                if canSend && !isStreaming && !dictation.isActive { send() }
            }
        #endif
    }

    @ViewBuilder
    private var plusButton: some View {
        if toolSwitches.isEmpty {
            GlassIconButton(systemName: "plus", label: "Add photo", diameter: DS.IconSize.compactControlDiameter,
                            iconSize: DS.IconSize.composerIcon, flat: true, action: onAttach)
                .opacity(plusDimmed ? 0.45 : 1)
                .matchedGeometryEffect(id: "plus", in: controls)
        } else {
            plusMenu.matchedGeometryEffect(id: "plus", in: controls)
        }
    }

    private func toggle(_ item: ComposerToolSwitch) -> some View {
        Toggle(isOn: Binding(get: { item.isOn }, set: { onToolSwitch(item, $0) })) {
            Label { Text(verbatim: item.title) } icon: { Image(systemName: item.systemImage) }
        }
        #if os(iOS)
        .menuActionDismissBehavior(.disabled)
        #endif
    }

    /// Add photos, then the chat's tools as toggles; a toggle leaves the menu open, so several can be flipped.
    private var plusMenu: some View {
        let d = DS.IconSize.compactControlDiameter
        return Menu {
            Button("Add photos", systemImage: "photo.on.rectangle", action: onAttach)
            Section("Tools in this chat") {
                ForEach(toolSwitches.filter { !$0.id.hasPrefix(ToolSwitch.packagePrefix) }) { toggle($0) }
            }
            let packages = toolSwitches.filter { $0.id.hasPrefix(ToolSwitch.packagePrefix) }
            if !packages.isEmpty {
                Section("Packages") {
                    ForEach(packages) { toggle($0) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: DS.IconSize.composerIcon, weight: .medium))
                .frame(width: d, height: d)
                .modifier(ControlSurface(flat: true))
                .contentShape(Circle().inset(by: -max(0, (DS.IconSize.minHitTarget - d) / 2)))
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add photos and tools"))
        #if os(macOS)
        .help(Text("Add photos, or turn tools on or off for this chat"))
        #endif
    }

    @ViewBuilder
    private var sendButton: some View {
        let d = DS.IconSize.compactControlDiameter
        if isStreaming {
            Button(action: onStop) {
                Image(systemName: "stop.fill").font(.system(size: DS.IconSize.composerIcon, weight: .semibold))
                    .foregroundStyle(theme.onAccent)
                    .frame(width: d, height: d)
                    .background(theme.accent, in: Circle())
                    .contentShape(Circle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Stop"))
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: DS.IconSize.composerIcon, weight: .bold))
                    .foregroundStyle(canSend ? theme.onAccent : theme.textSecondary)
                    .frame(width: d, height: d)
                    .background {
                        if canSend {
                            Circle().fill(theme.accent)
                        } else {
                            Circle().fill(theme.fillTertiary)
                        }
                    }
                    .contentShape(Circle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Text("Send"))
        }
    }
}

#Preview("Light · Purple") { ComposerPreview().previewStyle(.light) }
#Preview("Dark · Purple") { ComposerPreview().previewStyle(.dark) }
#Preview("Dark · Orange · Streaming") { ComposerPreview(streaming: true).previewStyle(.dark, accent: Color(hex: "#F97316")) }

private struct ComposerPreview: View {
    var streaming = false
    @State private var text = "Hello there"
    #if os(macOS)
    @State private var focused = false
    #else
    @FocusState private var focused: Bool
    #endif
    var body: some View {
        VStack {
            Spacer()
            ComposerBar(text: $text, isStreaming: streaming, canSend: true, onAttach: {},
                        toolSwitches: ToolGroup.supported.map { ComposerToolSwitch(id: $0.rawValue, title: $0.title, systemImage: $0.systemImage, isOn: $0 != .python) },
                        onSend: {}, onStop: {},
                        accessory: {
                            ModelSettingsButton(model: "GPT-5.5", effort: "Medium", action: {})
                        },
                        isFocused: $focused)
        }
    }
}
