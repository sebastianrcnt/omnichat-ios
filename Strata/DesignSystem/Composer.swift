import SwiftUI

/// A small dial: a track, an accent arc filled to `fraction` (0...1) and a needle. Drawn with shapes, so it shows any
/// number of effort levels.
struct EffortGaugeIcon: View {
    @Environment(\.theme) private var theme
    var fraction: Double
    var size: CGFloat = DS.IconSize.gauge

    var body: some View {
        let line = max(1.5, size * 0.12)
        ZStack {
            GaugeArc(progress: 1).stroke(theme.textSecondary.opacity(0.35), style: StrokeStyle(lineWidth: line, lineCap: .round))
            GaugeArc(progress: fraction).stroke(theme.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
            GaugeNeedle(progress: fraction).stroke(theme.textPrimary, style: StrokeStyle(lineWidth: line * 0.85, lineCap: .round))
            Circle().fill(theme.textPrimary).frame(width: line * 1.6, height: line * 1.6)
                .offset(y: size * GaugeArc.centerDrop)
        }
        .frame(width: size, height: size)
        .animation(DS.Motion.spring, value: fraction)
        .accessibilityHidden(true)
    }
}

/// The dial's arc: 270 degrees, open at the bottom, from lower left clockwise to lower right.
struct GaugeArc: Shape {
    var progress: Double
    /// The dial sits a little low in its square, since the open bottom is empty.
    static let centerDrop: CGFloat = 0.08
    static let start = 135.0
    static let sweep = 270.0

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    static func geometry(in rect: CGRect) -> (center: CGPoint, radius: CGFloat) {
        let r = min(rect.width, rect.height) * 0.42
        return (CGPoint(x: rect.midX, y: rect.midY + rect.height * centerDrop), r)
    }

    func path(in rect: CGRect) -> Path {
        let p = min(1, max(0, progress))
        var path = Path()
        guard p > 0 else { return path }
        let g = Self.geometry(in: rect)
        path.addArc(center: g.center, radius: g.radius, startAngle: .degrees(Self.start),
                    endAngle: .degrees(Self.start + Self.sweep * p), clockwise: false)
        return path
    }
}

/// The dial's needle, pointing at `progress` along the arc.
struct GaugeNeedle: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let g = GaugeArc.geometry(in: rect)
        let angle = Angle.degrees(GaugeArc.start + GaugeArc.sweep * min(1, max(0, progress))).radians
        let length = g.radius * 0.62
        var path = Path()
        path.move(to: g.center)
        path.addLine(to: CGPoint(x: g.center.x + cos(angle) * length, y: g.center.y + sin(angle) * length))
        return path
    }
}

/// The composer's model-and-effort control. Tap opens the chat settings; when the model takes an effort, a long press
/// offers the levels as a quick switch and the dial shows the current one. Otherwise a plain model icon.
struct ModelSettingsButton<QuickMenu: View>: View {
    /// The effort's place on the dial, or nil when the model does not support effort.
    let effortFraction: Double?
    /// Spoken after "Model and reasoning effort": the effort level, or the model name.
    let valueDescription: String
    let action: () -> Void
    @ViewBuilder var quickMenu: () -> QuickMenu

    private var label: some View {
        let d = DS.IconSize.compactControlDiameter
        return Group {
            if let effortFraction {
                EffortGaugeIcon(fraction: effortFraction)
            } else {
                Image(systemName: "cpu").font(.system(size: DS.IconSize.composerIcon, weight: .medium))
            }
        }
        .frame(width: d, height: d)
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(Circle().inset(by: -max(0, (DS.IconSize.minHitTarget - d) / 2)))
    }

    var body: some View {
        Group {
            if effortFraction != nil {
                Menu(content: quickMenu) { label } primaryAction: { action() }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Model and reasoning effort, \(valueDescription)"))
                    .accessibilityHint(Text("Opens settings. Touch and hold to change the effort."))
            } else {
                Button(action: action) { label }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Model, \(valueDescription)"))
                    .accessibilityHint(Text("Opens settings."))
            }
        }
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
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, DS.Spacing.md + 2)
                            .frame(minHeight: DS.IconSize.capsuleHeight)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
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

/// Floating glass composer. Idle (empty, not focused) it is a one-line pill: plus, the placeholder, and stop while a
/// reply runs. Focused or holding a draft it grows to two rows: the text on top, then plus, the settings accessory
/// (the model and effort gauge) and send. On a Mac it always shows both rows: there is room, and no keyboard to make.
struct ComposerBar<Accessory: View>: View {
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
    /// Images pasted into the field (Mac).
    var onPasteImages: (([Data]) -> Void)?
    var onSend: () -> Void
    var onStop: () -> Void
    /// Shown in the expanded row, between plus and send.
    @ViewBuilder var accessory: () -> Accessory
    #if os(macOS)
    /// A Mac composer is an NSTextView, which SwiftUI's focus system does not drive: focus is plain state.
    var isFocused: Binding<Bool>
    #else
    @FocusState.Binding var isFocused: Bool
    #endif
    @State private var inputHandle = TextInputHandle()
    @Namespace private var controls

    /// Two rows (text, then controls) rather than the one-line pill.
    static func isExpanded(focused: Bool, text: String, hasAttachments: Bool, isEditing: Bool) -> Bool {
        #if os(macOS)
        return true
        #else
        return focused || !text.isEmpty || hasAttachments || isEditing
        #endif
    }

    private var expanded: Bool {
        #if os(macOS)
        Self.isExpanded(focused: isFocused.wrappedValue, text: text, hasAttachments: !attachments.isEmpty, isEditing: onCancelEdit != nil)
        #else
        Self.isExpanded(focused: isFocused, text: text, hasAttachments: !attachments.isEmpty, isEditing: onCancelEdit != nil)
        #endif
    }

    var body: some View {
        let expanded = expanded
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
                // One row in both states, so the text field keeps its identity (and its focus) while the bar grows.
                HStack(spacing: DS.Spacing.sm) {
                    if !expanded { plusButton }
                    field
                        .padding(.horizontal, DS.Spacing.xs)
                        .frame(minHeight: expanded ? nil : DS.IconSize.compactControlDiameter)
                    if !expanded && isStreaming { sendButton.matchedGeometryEffect(id: "send", in: controls) }
                }
                if expanded {
                    HStack(spacing: DS.Spacing.sm) {
                        plusButton
                        Spacer(minLength: DS.Spacing.sm)
                        accessory()
                        sendButton.matchedGeometryEffect(id: "send", in: controls)
                    }
                    .padding(.top, DS.Spacing.sm) // the text field is the main area; buttons are a separate row
                    .transition(.opacity)
                }
            }
            .padding(.top, expanded ? DS.Spacing.sm + DS.Spacing.xs : DS.Spacing.sm)
            .padding(.bottom, expanded ? DS.Spacing.md : DS.Spacing.sm)
            .padding(.horizontal, expanded ? DS.Spacing.md : DS.Spacing.sm)
            // Idle, the bar is 52pt tall, so this radius makes it a capsule.
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.composer))
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.xs)
        .animation(DS.Motion.spring, value: expanded)
    }

    @ViewBuilder
    private var field: some View {
        #if os(macOS)
        MacComposerField(text: $text, isFocused: isFocused,
                         textColor: theme.textPrimary, onReturn: { if canSend && !isStreaming { onSend() } },
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
                if canSend && !isStreaming { onSend() }
            }
        #endif
    }

    private var plusButton: some View {
        GlassIconButton(systemName: "plus", label: "Add photo", diameter: DS.IconSize.compactControlDiameter,
                        iconSize: DS.IconSize.composerIcon, action: onAttach)
            .opacity(plusDimmed ? 0.45 : 1)
            .matchedGeometryEffect(id: "plus", in: controls)
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
    #if os(macOS)
    @State private var focused = false
    #else
    @FocusState private var focused: Bool
    #endif
    var body: some View {
        VStack {
            Spacer()
            ComposerBar(text: $text, isStreaming: streaming, canSend: true, onAttach: {}, onSend: {}, onStop: {},
                        accessory: {
                            ModelSettingsButton(effortFraction: 0.6, valueDescription: "Medium", action: {}) {
                                Button("Low") {}
                            }
                        },
                        isFocused: $focused)
        }
    }
}
