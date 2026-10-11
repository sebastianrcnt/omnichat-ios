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
                Text(modelName).font(DS.Typography.uiSmall).foregroundStyle(theme.textPrimary).lineLimit(1)
                if let effortTitle {
                    Text(effortTitle).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .frame(height: DS.IconSize.compactControlDiameter)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(Text("Model and effort"))
    }
}

struct ComposerAttachment: Identifiable, Equatable {
    let id: UUID
    let jpeg: Data
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
    var onSend: () -> Void
    var onStop: () -> Void
    @ViewBuilder var chip: () -> Chip
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        GlassEffectContainer(spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.sm) {
                            ForEach(attachments) { a in
                                AttachmentThumbnail(data: a.jpeg) { onRemoveAttachment(a.id) }
                            }
                        }
                        .padding(.horizontal, DS.Spacing.xs)
                    }
                }
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.textTertiary), axis: .vertical)
                    .lineLimit(1...6)
                    .font(DS.Typography.ui)
                    .foregroundStyle(theme.textPrimary)
                    .focused($isFocused)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.top, DS.Spacing.xs)
                HStack(spacing: DS.Spacing.sm) {
                    GlassIconButton(systemName: "plus", label: "Add photo", diameter: DS.IconSize.compactControlDiameter + 4, action: onAttach)
                        .opacity(plusDimmed ? 0.45 : 1)
                    chip()
                    Spacer(minLength: DS.Spacing.sm)
                    sendButton
                }
            }
            .padding(DS.Spacing.md)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.xl))
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.xs)
    }

    @ViewBuilder
    private var sendButton: some View {
        if isStreaming {
            Button(action: onStop) {
                Image(systemName: "stop.fill").font(.system(size: DS.IconSize.md, weight: .semibold))
                    .frame(width: DS.IconSize.compactControlDiameter + 4, height: DS.IconSize.compactControlDiameter + 4)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(theme.accent)
            .accessibilityLabel(Text("Stop"))
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up").font(.system(size: DS.IconSize.md, weight: .bold))
                    .frame(width: DS.IconSize.compactControlDiameter + 4, height: DS.IconSize.compactControlDiameter + 4)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(theme.accent)
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
