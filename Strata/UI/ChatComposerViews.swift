import SwiftUI
import SwiftData

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

/// Things to try, over the first new chat: tapping one puts it in the composer. Gone once there is a chat, or while
/// the composer has text. Reads the draft itself, like the composer, so `ChatView` doesn't re-render per keystroke.
struct StarterPrompts: View {
    @Environment(\.theme) private var theme
    @Bindable var draft: ComposerDraft
    let onPick: () -> Void
    @Query(Self.anyChat) private var chats: [Conversation]

    private static var anyChat: FetchDescriptor<Conversation> {
        var descriptor = FetchDescriptor<Conversation>()
        descriptor.fetchLimit = 1
        return descriptor
    }

    private static let prompts: [LocalizedStringResource] = [
        "Weather in Lisbon vs Athens next week",
        "Chart $500 a month at 6% for 30 years",
        "Quiet cafés near me, on a map",
        "Find flights to Tokyo next month",
    ]

    var body: some View {
        if chats.isEmpty && draft.text.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Try asking")
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.textSecondary)
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    ForEach(Self.prompts.indices, id: \.self) { i in
                        let prompt = Self.prompts[i]
                        Button {
                            draft.text = String(localized: prompt)
                            onPick()
                        } label: {
                            Text(prompt)
                                .font(DS.Typography.ui)
                                .foregroundStyle(theme.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, DS.Spacing.md)
                                .padding(.vertical, DS.Spacing.sm)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Capsule())
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.page)
            .padding(.bottom, DS.Spacing.md)
            .transition(.opacity)
        }
    }
}

/// Reads the draft so `ChatView` does not: a keystroke re-renders only the composer.
struct ComposerHost<Accessory: View>: View {
    @Bindable var draft: ComposerDraft
    let isStreaming: Bool
    let isBusy: Bool
    /// The model list is being fetched before a send (`ChatView.send`).
    var loadingModels = false
    let plusDimmed: Bool
    let onAttach: () -> Void
    var toolSwitches: [ComposerToolSwitch] = []
    var onToolSwitch: (ComposerToolSwitch, Bool) -> Void = { _, _ in }
    /// Package commands, offered while the draft is a `/` word.
    var commands: [PackageCommandItem] = []
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
        VStack(spacing: DS.Spacing.sm) {
            let matches = PackageCommandItem.matches(commands, draft: draft.text)
            if !matches.isEmpty {
                PackageCommandList(commands: matches) { draft.text = $0.template.expanded() }
                    .transition(.opacity)
            }
            composer
        }
    }

    private var composer: some View {
        ComposerBar(
            text: $draft.text,
            attachments: draft.attachments,
            placeholder: "Message",
            isStreaming: isStreaming,
            canSend: draft.canSend && !isBusy,
            plusDimmed: plusDimmed,
            onAttach: onAttach,
            toolSwitches: toolSwitches,
            onToolSwitch: onToolSwitch,
            onRemoveAttachment: { id in draft.attachments.removeAll { $0.id == id } },
            onCancelEdit: onCancelEdit,
            onPasteImages: onPasteImages,
            notice: loadingModels ? "Loading models…" : nil,
            onSend: onSend,
            onStop: onStop,
            accessory: accessory,
            isFocused: isFocused)
    }
}
