import SwiftUI

// The share extension's sheet. Lives with the app's sources so the app's debug gallery (`-StrataShareGallery`) shows
// the same view; the extension fills the model from its NSItemProviders.

/// What the sheet shows and what the person picked. Built by the extension as the shared items load.
@MainActor
@Observable
final class ShareComposeModel {
    struct SharedImage: Identifiable {
        let id = UUID()
        /// The JPEG in the share's folder.
        let storedName: String
        let thumbnail: CGImage?
    }

    struct SharedFile: Identifiable {
        let id = UUID()
        let file: SharePayload.File
        let byteCount: Int64?
    }

    enum Phase: Equatable {
        case composing
        /// Saving to the App Group inbox.
        case sending
        /// Saved; the user opens the app to continue.
        case saved
        case failed(String)
    }

    let id: UUID
    var links: [SharePayload.Link] = []
    /// The first link's site icon, when the page has one.
    var linkIcon: CGImage?
    var texts: [String] = []
    var images: [SharedImage] = []
    var files: [SharedFile] = []
    /// Items that could not be read ("1 item couldn't be read").
    var skipped = 0
    var isLoading = true

    var action: SharePayload.Action?
    var note = ""
    var destination: SharePayload.Destination = .newChat
    var context: ShareContext?
    var phase: Phase = .composing
    /// `translate` goes into the language the device prefers, named in English ("Korean").
    let translateLanguage: String

    init(id: UUID = UUID(), context: ShareContext? = nil, translateLanguage: String = ShareComposeModel.preferredLanguageName()) {
        self.id = id
        self.context = context
        self.translateLanguage = translateLanguage
    }

    /// Transcript is offered for video links only.
    var actions: [SharePayload.Action] {
        SharePayload.Action.allCases.filter { $0 != .transcript || links.contains { ShareVideoLink.isVideo($0.url) } }
    }

    var canSend: Bool { !isLoading && phase == .composing && !payload.isEmpty }

    var recipient: ShareRecipient? {
        switch destination {
        case .newChat: context?.recipient
        case .conversation(let id): context?.currentChat.flatMap { $0.id == id ? $0.recipient : nil }
        }
    }

    var payload: SharePayload {
        var p = SharePayload(id: id)
        p.action = action
        p.translateLanguage = action == .translate ? translateLanguage : nil
        p.note = note
        p.links = links
        p.texts = texts
        p.images = images.map(\.storedName)
        p.files = files.map(\.file)
        p.destination = destination
        p.recipient = recipient
        return p
    }

    func title(of action: SharePayload.Action) -> String {
        switch action {
        case .summarize: String(localized: "Summarize")
        case .translate: String(localized: "Translate to \(translateLanguage)")
        case .explain: String(localized: "Explain")
        case .transcript: String(localized: "Transcript")
        }
    }

    nonisolated static func preferredLanguageName() -> String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? $0 } ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}

/// The sheet: what is being shared, quick actions, a note, where it goes and with which model.
struct ShareComposeView: View {
    @Bindable var model: ShareComposeModel
    let onCancel: () -> Void
    let onSend: () -> Void
    var onDone: () -> Void = {}
    @FocusState private var noteFocused: Bool

    private var theme: DSTheme { DSTheme(accent: model.context?.accentHex.map { Color(hex: $0) } ?? Color(hex: AccentPreset.defaultHex)) }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .composing, .sending: compose
                case .saved: saved
                case .failed(let message): failed(message)
                }
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("OpenChat")
            .inlineNavigationTitle()
            .toolbar { toolbar }
        }
        .environment(\.theme, theme)
        .tint(theme.accent)
        .font(DS.Typography.ui)
        .dsLeading(.ui)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch model.phase {
        case .composing, .sending:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark", action: onCancel)
                    .tint(theme.textPrimary)
                    .disabled(model.phase == .sending)
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.phase == .sending {
                    ProgressView()
                } else {
                    Button("Send", systemImage: "arrow.up", action: onSend)
                        .buttonStyle(.glassProminent)
                        .tint(theme.accent)
                        .disabled(!model.canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        case .saved, .failed:
            ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
        }
    }

    // MARK: Compose

    private var compose: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                preview
                actions
                noteField
                if let chat = model.context?.currentChat { destination(chat) }
                modelLine
            }
            .padding(DS.Spacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .disabled(model.phase == .sending)
    }

    @ViewBuilder
    private var preview: some View {
        if model.isLoading {
            HStack(spacing: DS.Spacing.sm) {
                ProgressView()
                Text("Reading what you shared…").foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                ForEach(Array(model.links.enumerated()), id: \.offset) { index, link in
                    ShareLinkCard(link: link, icon: index == 0 ? model.linkIcon : nil)
                }
                ForEach(Array(model.texts.enumerated()), id: \.offset) { _, text in ShareTextCard(text: text) }
                if !model.images.isEmpty { imageStrip }
                ForEach(model.files) { ShareFileRow(file: $0) }
                if model.skipped > 0 {
                    Label(model.skipped == 1 ? String(localized: "1 item couldn't be read.")
                                             : String(localized: "\(model.skipped) items couldn't be read."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Typography.uiSmall)
                        .foregroundStyle(theme.warning)
                }
            }
        }
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(model.images) { image in
                    Group {
                        if let cg = image.thumbnail {
                            Image(decorative: cg, scale: 1).resizable().scaledToFill()
                        } else {
                            theme.surfaceRaised
                        }
                    }
                    .frame(width: DS.IconSize.thumbnail * 1.5, height: DS.IconSize.thumbnail * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.thumbnail))
                }
            }
        }
        .accessibilityLabel(Text(model.images.count == 1 ? String(localized: "1 photo") : String(localized: "\(model.images.count) photos")))
    }

    private var actions: some View {
        FlowLayout(spacing: DS.Spacing.sm) {
            ForEach(model.actions) { action in
                let on = model.action == action
                Button {
                    withAnimation(DS.Motion.snappy) { model.action = on ? nil : action }
                } label: {
                    Label(model.title(of: action), systemImage: Self.symbol(action))
                        .font(DS.Typography.uiSmall.weight(.medium))
                        .labelIconToTitleSpacing(DS.Spacing.xs + 2)
                        .foregroundStyle(on ? theme.accentOnTint : theme.textPrimary)
                        .padding(.horizontal, DS.Spacing.md)
                        .frame(minHeight: DS.IconSize.compactControlDiameter)
                        .background(on ? theme.accentMuted : theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? theme.accent.opacity(0.5) : theme.separator, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    static func symbol(_ action: SharePayload.Action) -> String {
        switch action {
        case .summarize: "text.alignleft"
        case .translate: "translate"
        case .explain: "lightbulb"
        case .transcript: "captions.bubble"
        }
    }

    private var noteField: some View {
        TextField(model.action == nil ? "Ask anything about this" : "Add details (optional)", text: $model.note, axis: .vertical)
            .lineLimit(3...8)
            .focused($noteFocused)
            .unbezeledField()
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.md)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    }

    private func destination(_ chat: ShareContext.Chat) -> some View {
        HStack {
            Text("Send to").foregroundStyle(theme.textSecondary)
            Spacer(minLength: DS.Spacing.md)
            Picker("Send to", selection: $model.destination) {
                Text("New chat").tag(SharePayload.Destination.newChat)
                Text(verbatim: chat.title).tag(SharePayload.Destination.conversation(chat.id))
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(theme.textPrimary)
        }
        .padding(.leading, DS.Spacing.lg)
        .padding(.trailing, DS.Spacing.sm)
        .frame(minHeight: DS.IconSize.minHitTarget)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    }

    @ViewBuilder
    private var modelLine: some View {
        if let context = model.context {
            if let recipient = model.recipient {
                HStack(spacing: DS.Spacing.xs + 2) {
                    Image(systemName: "cpu").imageScale(.small)
                    Text(verbatim: recipient.modelTitle).foregroundStyle(theme.textSecondary)
                    Text(verbatim: "· \(recipient.connectionName)" + (recipient.serviceHost.map { " (" + $0 + ")" } ?? "")).foregroundStyle(theme.textTertiary)
                }
                .font(DS.Typography.uiCaption)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, DS.Spacing.lg)
                .accessibilityElement(children: .combine)
            } else {
                Label(context.hasConnection ? "No model yet: open OpenChat to load the model list."
                                            : "No connection yet: add one in OpenChat to get a reply.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typography.uiCaption)
                    .foregroundStyle(theme.warning)
                    .padding(.horizontal, DS.Spacing.lg)
            }
        }
    }

    // MARK: After Send

    private var saved: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: DS.IconSize.lg * 2))
                .foregroundStyle(theme.accent)
            Text("Ready in OpenChat").font(DS.Typography.title).foregroundStyle(theme.textPrimary)
            Text("Open OpenChat to continue. If the destination changed, you’ll be asked before anything is sent.")
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DS.IconSize.lg * 2))
                .foregroundStyle(theme.destructive)
            Text("Couldn't share to OpenChat").font(DS.Typography.title).foregroundStyle(theme.textPrimary)
            Text(verbatim: message).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview cards

/// A shared link: site icon, page title and host.
private struct ShareLinkCard: View {
    @Environment(\.theme) private var theme
    let link: SharePayload.Link
    let icon: CGImage?

    private var host: String { link.url.host(percentEncoded: false).map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? link.url.absoluteString }

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            let size = DS.IconSize.controlDiameter - 4
            let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            Group {
                if let icon {
                    Image(decorative: icon, scale: 1).resizable().scaledToFill()
                        .frame(width: size, height: size)
                        .background(theme.faviconBackdrop)
                        .clipShape(shape)
                } else {
                    Image(systemName: ShareVideoLink.isVideo(link.url) ? "play.rectangle.fill" : "link")
                        .font(.system(size: DS.IconSize.md, weight: .medium))
                        .foregroundStyle(theme.accentOnTint)
                        .frame(width: size, height: size)
                        .background(theme.accentMuted, in: shape)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(verbatim: link.title?.isEmpty == false ? link.title! : host)
                    .font(DS.Typography.uiEmphasis)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                Text(verbatim: host)
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.md)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .accessibilityElement(children: .combine)
    }
}

/// Shared text: the first lines, quoted.
private struct ShareTextCard: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            Capsule().fill(theme.accent.opacity(0.6)).frame(width: 3)
            Text(verbatim: text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(DS.Typography.uiSmall)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(DS.Spacing.md)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }
}

/// A shared file: its kind, name and size.
private struct ShareFileRow: View {
    @Environment(\.theme) private var theme
    let file: ShareComposeModel.SharedFile

    private var symbol: String {
        switch file.file.kind {
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        case .other: "doc"
        case .package: "shippingbox"
        }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: DS.IconSize.md, weight: .medium))
                .foregroundStyle(theme.accentOnTint)
                .frame(width: DS.IconSize.controlDiameter - 4, height: DS.IconSize.controlDiameter - 4)
                .background(theme.accentMuted, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(verbatim: file.file.name)
                    .font(DS.Typography.uiEmphasis)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: detail)
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.md)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let kind: String = switch file.file.kind {
        case .pdf: String(localized: "PDF · its text is sent")
        case .text: String(localized: "Text file")
        case .other: String(localized: "Only the name is sent")
        case .package: String(localized: "Package · OpenChat opens it for review")
        }
        guard let bytes = file.byteCount else { return kind }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " · " + kind
    }
}

// MARK: - Sample (debug gallery, previews)

extension ShareComposeModel {
    static func gallerySample() -> ShareComposeModel {
        let recipient = ShareRecipient(connectionID: UUID(), modelID: "gpt-5.1", routeDigest: "gallery",
                                       modelTitle: "gpt-5.1", connectionName: "OpenAI", serviceHost: "api.openai.com")
        let model = ShareComposeModel(context: ShareContext(recipient: recipient, accentHex: nil, modelTitle: "gpt-5.1", connectionName: "OpenAI",
                                                            hasConnection: true,
                                                            currentChat: .init(id: UUID(), title: "Trip to Kyoto", recipient: recipient)))
        model.links = [.init(url: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!,
                             title: "How Liquid Glass works: a deep dive into the new design")]
        model.texts = ["Liquid Glass is a translucent material that reflects and refracts its surroundings, while dynamically transforming to help bring greater focus to content."]
        model.images = [0.08, 0.55, 0.75].map { SharedImage(storedName: "", thumbnail: sampleImage(hue: $0)) }
        model.files = [SharedFile(file: .init(name: "Quarterly report 2026 Q3.pdf", storedName: "", kind: .pdf), byteCount: 2_480_000)]
        model.action = .summarize
        model.isLoading = false
        return model
    }

    /// A soft two-color gradient, standing in for a photo.
    static func sampleImage(hue: CGFloat) -> CGImage? {
        let size = 160
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let a = PlatformColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor
        let b = PlatformColor(hue: hue + 0.1, saturation: 0.8, brightness: 0.6, alpha: 1).cgColor
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [a, b] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
        }
        return ctx.makeImage()
    }
}

#Preview("Share · Light") { ShareComposeView(model: .gallerySample(), onCancel: {}, onSend: {}).preferredColorScheme(.light) }
#Preview("Share · Dark") { ShareComposeView(model: .gallerySample(), onCancel: {}, onSend: {}).preferredColorScheme(.dark) }
