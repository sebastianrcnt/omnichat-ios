import SwiftUI

/// Composer chip: model name plus effort.
struct ModelEffortChip: View {
    @Environment(\.theme) private var theme
    let modelName: String
    var effortTitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xs) {
                Text(modelName).font(DS.Typography.chip).foregroundStyle(theme.textPrimary).lineLimit(1)
                if let effortTitle {
                    Text(effortTitle).font(DS.Typography.chip).foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .frame(height: DS.IconSize.compactControlDiameter)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule().inset(by: -4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Model and effort"))
    }
}

struct ComposerAttachment: Identifiable, Equatable {
    let id: UUID
    let jpeg: Data
    /// Small preview, made off the main thread after the photo is added. Shown here and stored with the message.
    var thumbnail: Data?
}

/// Floating glass composer: attachments, text field, plus button, chip slot, send/stop.
struct ComposerBar<Chip: View>: View {
    @Environment(\.theme) private var theme

    @Binding var text: String
    var attachments: [ComposerAttachment] = []
    var placeholder: LocalizedStringKey = "Message"
    var isStreaming = false
    var canSend: Bool
    var plusDimmed = false
    var onAttach: () -> Void
    var onRemoveAttachment: (UUID) -> Void = { _ in }
    /// Set while a sent message is being edited: shows the "Editing message" bar.
    var onCancelEdit: (() -> Void)?
    var onSend: () -> Void
    var onStop: () -> Void
    @ViewBuilder var chip: () -> Chip
    @FocusState.Binding var isFocused: Bool
    @State private var inputHandle = TextInputHandle()

    var body: some View {
        GlassEffectContainer(spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                if let onCancelEdit {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "pencil").font(.system(size: DS.IconSize.sm, weight: .semibold))
                        Text("Editing message").font(DS.Typography.uiCaption)
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
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.sm) {
                            ForEach(attachments) { a in
                                AttachmentThumbnail(data: a.thumbnail ?? a.jpeg) { onRemoveAttachment(a.id) }
                            }
                        }
                    }
                }
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.textSecondary), axis: .vertical)
                    .lineLimit(1...6)
                    .font(DS.Typography.ui)
                    .foregroundStyle(theme.textPrimary)
                    .unbezeledField()
                    .focused($isFocused)
                    .withoutInputAssistantBar(handle: inputHandle)
                    .returnSends(handle: inputHandle) { // Mac only; same rules as the send button
                        if canSend && !isStreaming { onSend() }
                    }
                    .padding(.horizontal, DS.Spacing.xs)
                HStack(spacing: DS.Spacing.sm) {
                    GlassIconButton(systemName: "plus", label: "Add photo", diameter: DS.IconSize.compactControlDiameter,
                                    iconSize: DS.IconSize.composerIcon, action: onAttach)
                        .opacity(plusDimmed ? 0.45 : 1)
                    chip()
                    Spacer(minLength: DS.Spacing.sm)
                    sendButton
                }
                .padding(.top, DS.Spacing.sm) // the text field is the main area; buttons are a separate row
            }
            .padding(.top, DS.Spacing.sm + DS.Spacing.xs)
            .padding([.horizontal, .bottom], DS.Spacing.md)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.composer))
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.xs)
    }

    @ViewBuilder
    private var sendButton: some View {
        let d = DS.IconSize.compactControlDiameter
        if isStreaming {
            Button(action: onStop) {
                Image(systemName: "stop.fill").font(.system(size: DS.IconSize.composerIcon, weight: .semibold))
                    .foregroundStyle(theme.onAccent)
                    .frame(width: d, height: d)
                    .glassEffect(.regular.tint(theme.accent).interactive(), in: Circle())
                    .contentShape(Circle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Stop"))
        } else {
            Button(action: onSend) {
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
    @FocusState private var focused: Bool
    var body: some View {
        VStack {
            Spacer()
            ComposerBar(text: $text, isStreaming: streaming, canSend: true, onAttach: {}, onSend: {}, onStop: {},
                        chip: { ModelEffortChip(modelName: "strata-1", effortTitle: "Medium") {} },
                        isFocused: $focused)
        }
    }
}
