import SwiftUI
import SwiftData
import PDFKit

/// Turns shares waiting in the App Group (`ShareInbox`) into chats: each becomes a user message, sent like one typed in
/// the composer, in a new chat or in the chat it was added to.
@MainActor
final class ShareImporter {
    static let shared = ShareImporter()

    /// Shares being imported, so a launch that sees the share link and the launch itself doesn't send one twice.
    private var claimed: Set<UUID> = []

    /// What a share holds once read from its folder (the folder is gone by then).
    struct Contents {
        var payload: SharePayload
        var images: [Data]
        /// Extracted text of each file, by stored name.
        var fileTexts: [String: String]
    }

    /// Imports every waiting share, oldest first. Returns the chat of the last one, for the root to open.
    @discardableResult
    func importPending(from inbox: ShareInbox?, controller: ChatController, connections: ConnectionStore,
                       settings: AppSettings, context: ModelContext) async -> Conversation? {
        guard let inbox else { return nil }
        let waiting = inbox.pending().filter { !claimed.contains($0.id) }
        guard !waiting.isEmpty else { return nil }
        var last: Conversation?
        for payload in waiting {
            claimed.insert(payload.id)
            let contents = await Task.detached(priority: .userInitiated) { Self.read(payload, from: inbox) }.value
            inbox.remove(payload.id)
            if let conversation = await send(contents, controller: controller, connections: connections,
                                             settings: settings, context: context) {
                last = conversation
            }
            claimed.remove(payload.id)
        }
        return last
    }

    /// Reads a share's images and files from its folder. PDFs and text files become text; other files are named only.
    nonisolated static func read(_ payload: SharePayload, from inbox: ShareInbox) -> Contents {
        let images = payload.images.compactMap { try? Data(contentsOf: inbox.fileURL($0, in: payload.id)) }
        var texts: [String: String] = [:]
        for file in payload.files {
            let url = inbox.fileURL(file.storedName, in: payload.id)
            switch file.kind {
            case .pdf: texts[file.storedName] = pdfText(url)
            case .text: texts[file.storedName] = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            case .other: break
            }
        }
        return Contents(payload: payload, images: images, fileTexts: texts)
    }

    /// A PDF's text, page by page (`[Page n]` headers like `web_fetch` reads PDFs).
    nonisolated static func pdfText(_ url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var parts: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !page.isEmpty else { continue }
            parts.append("[Page \(index + 1)]\n" + page)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Sends one share. The chat it was added to takes it unless that chat is gone or still replying; otherwise a new chat
    /// with the model a new chat in the composer would use.
    func send(_ contents: Contents, controller: ChatController, connections: ConnectionStore, settings: AppSettings,
              context: ModelContext) async -> Conversation? {
        let payload = contents.payload
        let text = payload.messageText(fileTexts: contents.fileTexts)
        guard !text.isEmpty || !contents.images.isEmpty else { return nil }

        var target: Conversation?
        if case .conversation(let id) = payload.destination {
            let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
            if let existing = try? context.fetch(descriptor).first, !controller.isStreaming(existing) { target = existing }
        }
        if target == nil {
            var choice = Self.newChatModel(connections: connections, settings: settings)
            if choice == nil {
                // Right after install the model lists may not be back yet: fetch them first, as the composer does.
                for c in connections.connections where c.models.isEmpty {
                    _ = try? await connections.refreshModels(for: c.id)
                }
                choice = Self.newChatModel(connections: connections, settings: settings)
            }
            let new = Conversation(connectionID: choice?.connectionID, modelID: choice?.modelID, effort: settings.lastEffort)
            new.title = Conversation.autoTitle(from: payload.titleBasis)
            context.insert(new)
            target = new
        }
        guard let target else { return nil }
        let images = contents.images
        let thumbnails = await Task.detached(priority: .userInitiated) {
            images.map { ImageProcessor.thumbnailData(from: $0) }
        }.value
        controller.send(text: text, images: images, thumbnails: thumbnails, conversation: target, context: context)
        try? context.save()
        return target
    }

    static func newChatModel(connections: ConnectionStore, settings: AppSettings) -> ModelSelection.Choice? {
        ModelSelection.resolve(connections: connections.connections, preferredConnectionID: settings.lastConnectionID,
                               preferredModelID: settings.lastModelID)
    }

    /// What the share sheet shows: the model a new chat would use, the accent, and the chat on screen.
    static func context(connections: ConnectionStore, settings: AppSettings, current: Conversation?) -> ShareContext {
        let choice = newChatModel(connections: connections, settings: settings)
        var chat: ShareContext.Chat?
        if let current, current.modelContext != nil, !current.isDeleted, !current.messages.isEmpty {
            chat = ShareContext.Chat(id: current.id, title: current.displayTitle)
        }
        return ShareContext(accentHex: settings.accentHex,
                            modelTitle: choice.flatMap { connections.displayName(connectionID: $0.connectionID, modelID: $0.modelID) },
                            connectionName: choice.flatMap { connections.connection($0.connectionID)?.name },
                            hasConnection: !connections.connections.isEmpty,
                            currentChat: chat)
    }
}

/// Picks up shares at launch, on coming to the foreground and from `openchat://share` links, and opens the chat they
/// start. Keeps the sheet's `ShareContext` current whenever the app leaves the foreground.
private struct ShareImportHandler: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @Environment(\.connectionStore) private var connections
    @Environment(\.appSettings) private var settings
    @Environment(\.chatController) private var controller
    @Binding var selected: Conversation?
    #if DEBUG
    @State private var gallery = ShareComposeModel.gallerySample()
    @State private var showGallery = UserDefaults.standard.bool(forKey: "StrataShareGallery")
    #endif

    func body(content: Content) -> some View {
        content
            .task {
                writeContext()
                await importPending()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: Task { await importPending() }
                default: writeContext()
                }
            }
            .onOpenURL { url in
                guard ShareURL.isShareURL(url) else { return }
                Task { await importPending() }
            }
            #if DEBUG
            // `-StrataShareGallery 1`: the share extension's sheet with sample content, for screenshots.
            .sheet(isPresented: $showGallery) {
                ShareComposeView(model: gallery, onCancel: { showGallery = false }, onSend: { showGallery = false })
            }
            #endif
    }

    private func importPending() async {
        if let conversation = await ShareImporter.shared.importPending(from: .shared, controller: controller,
                                                                       connections: connections, settings: settings,
                                                                       context: context) {
            selected = conversation
        }
    }

    private func writeContext() {
        ShareInbox.shared?.writeContext(ShareImporter.context(connections: connections, settings: settings, current: selected))
    }
}

extension View {
    /// Starts chats from what was shared into OpenChat (see `ShareImportHandler`).
    func shareImports(selected: Binding<Conversation?>) -> some View {
        modifier(ShareImportHandler(selected: selected))
    }
}
