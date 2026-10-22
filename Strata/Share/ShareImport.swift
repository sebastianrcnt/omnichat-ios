import SwiftUI
import SwiftData
import PDFKit
import CryptoKit

/// Turns shares waiting in the App Group (`ShareInbox`) into chats: each becomes a user message, sent like one typed in
/// the composer, in a new chat or in the chat it was added to.
@MainActor
@Observable
final class ShareImporter {
    static let shared = ShareImporter()

    /// Shares being imported, so a launch that sees the share link and the launch itself doesn't send one twice.
    private var claimed: Set<UUID> = []

    struct Review: Identifiable {
        var id: UUID { contents.payload.id }
        var contents: Contents
        var inbox: ShareInbox
    }
    private var confirming: Set<UUID> = []
    private(set) var reviews: [Review] = []

    /// What a share holds once read from its folder (kept on disk until sent or discarded).
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
        // Claim the complete snapshot before the first await; another activation can otherwise steal a later item.
        claimed.formUnion(waiting.map(\.id))
        var last: Conversation?
        for payload in waiting {
            let contents = await Task.detached(priority: .userInitiated) { Self.read(payload, from: inbox) }.value
            // A shared package opens in its review sheet (never installed from here); the rest of the share is a chat.
            for file in payload.files where file.kind == .package {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ocpkg")
                if (try? FileManager.default.copyItem(at: inbox.fileURL(file.storedName, in: payload.id), to: copy)) != nil {
                    PackageLinks.shared.receive(copy)
                    try? FileManager.default.removeItem(at: copy)
                }
            }
            if let conversation = await send(contents, controller: controller, connections: connections,
                                             settings: settings, context: context) {
                last = conversation
                inbox.remove(payload.id)
                claimed.remove(payload.id)
            } else if !payload.messageText(fileTexts: contents.fileTexts).isEmpty || !contents.images.isEmpty {
                reviews.append(Review(contents: contents, inbox: inbox))
            } else {
                inbox.remove(payload.id)
                claimed.remove(payload.id)
            }
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
            case .other, .package: break
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

    /// A changed/missing recipient or an unusable destination never silently falls back to another service.
    func send(_ contents: Contents, controller: ChatController, connections: ConnectionStore, settings: AppSettings,
              context: ModelContext, approved: ShareRecipient? = nil) async -> Conversation? {
        let payload = contents.payload
        let text = payload.messageText(fileTexts: contents.fileTexts)
        guard !text.isEmpty || !contents.images.isEmpty else { return nil }
        let images = contents.images
        let thumbnails = await Task.detached(priority: .userInitiated) {
            images.map { ImageProcessor.thumbnailData(from: $0) }
        }.value
        // Resolve after the await, immediately before send, so settings/chat edits during decoding are checked too.
        let candidate = candidate(for: payload, controller: controller, connections: connections, settings: settings, context: context)
        guard let recipient = candidate.recipient, recipient == (approved ?? payload.recipient),
              approved != nil || candidate.destinationAvailable else { return nil }
        let target: Conversation
        if let existing = candidate.chat {
            target = existing
        } else {
            target = Conversation(connectionID: recipient.connectionID, modelID: recipient.modelID, effort: settings.lastEffort)
            target.title = Conversation.autoTitle(from: payload.titleBasis)
            context.insert(target)
        }
        controller.send(text: text, images: images, thumbnails: thumbnails, conversation: target, context: context)
        try? context.save()
        return target
    }

    func candidate(for payload: SharePayload, controller: ChatController, connections: ConnectionStore,
                   settings: AppSettings, context: ModelContext) -> (recipient: ShareRecipient?, chat: Conversation?, destinationAvailable: Bool) {
        if case .conversation(let id) = payload.destination {
            let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
            if let chat = try? context.fetch(descriptor).first, !controller.isStreaming(chat),
               let recipient = Self.recipient(connectionID: chat.connectionID, modelID: chat.modelID, connections: connections) {
                return (recipient, chat, true)
            }
        }
        let choice = Self.newChatModel(connections: connections, settings: settings)
        return (Self.recipient(connectionID: choice?.connectionID, modelID: choice?.modelID, connections: connections),
                nil, payload.destination == .newChat)
    }

    func postpone(_ review: Review) {
        claimed.remove(review.id)
        reviews.removeAll { $0.id == review.id }
    }

    func discard(_ review: Review) {
        review.inbox.remove(review.id)
        postpone(review)
    }

    func confirm(_ review: Review, recipient: ShareRecipient, controller: ChatController, connections: ConnectionStore,
                 settings: AppSettings, context: ModelContext) async -> Conversation? {
        guard reviews.contains(where: { $0.id == review.id }), confirming.insert(review.id).inserted else { return nil }
        defer { confirming.remove(review.id) }
        guard let chat = await send(review.contents, controller: controller, connections: connections, settings: settings,
                                    context: context, approved: recipient) else { return nil }
        discard(review)
        return chat
    }

    static func recipient(connectionID: UUID?, modelID: String?, connections: ConnectionStore) -> ShareRecipient? {
        guard let connectionID, let modelID, let connection = connections.connection(connectionID),
              let endpoint = connections.endpoint(connectionID: connectionID, modelID: modelID) else { return nil }
        let route = connection.kind.rawValue + "\n" + endpoint.baseURL.absoluteString
        let digest = SHA256.hash(data: Data(route.utf8)).map { String(format: "%02x", $0) }.joined()
        return ShareRecipient(connectionID: connectionID, modelID: modelID, routeDigest: digest,
                              modelTitle: connections.displayName(connectionID: connectionID, modelID: modelID) ?? modelID,
                              connectionName: connection.name, serviceHost: endpoint.baseURL.host())
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
            chat = ShareContext.Chat(id: current.id, title: current.displayTitle,
                                     recipient: recipient(connectionID: current.connectionID, modelID: current.modelID, connections: connections))
        }
        return ShareContext(recipient: recipient(connectionID: choice?.connectionID, modelID: choice?.modelID, connections: connections),
                            accentHex: settings.accentHex,
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
    @State private var importer = ShareImporter.shared
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
            .sheet(item: Binding(get: { importer.reviews.first }, set: { _ in })) { review in
                let candidate = importer.candidate(for: review.contents.payload, controller: controller, connections: connections,
                                                   settings: settings, context: context)
                NavigationStack {
                    Form {
                        Section("Intended recipient") {
                            Text(review.contents.payload.recipient?.displayName ?? String(localized: "Unknown recipient"))
                        }
                        Section {
                            Text("The recipient changed or the destination is unavailable. Nothing has been sent. Confirm the recipient below, or keep the share for later and check your connection settings.")
                        }
                        if let recipient = candidate.recipient {
                            Section(candidate.chat == nil ? "New chat" : "Destination chat") {
                                Text(verbatim: recipient.displayName)
                                Button("Send") {
                                    Task {
                                        if let chat = await importer.confirm(review, recipient: recipient, controller: controller,
                                                                             connections: connections, settings: settings, context: context) {
                                            selected = chat
                                        }
                                    }
                                }
                            }
                        }
                        Section {
                            Button("Keep for later") { importer.postpone(review) }
                            Button("Discard share", role: .destructive) { importer.discard(review) }
                        }
                    }
                    .navigationTitle("Confirm recipient")
                }
                .interactiveDismissDisabled()
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
