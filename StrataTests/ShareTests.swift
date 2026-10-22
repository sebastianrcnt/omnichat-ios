import Foundation
import SwiftData
import Testing
import UIKit
@testable import Strata

/// Sharing into OpenChat: the payload the share extension writes, the message made from it, the inbox in the App
/// Group, the `openchat://share` link, and the import that sends it in a chat.
@MainActor
struct ShareTests {
    // MARK: Payload and message

    @Test func payloadRoundTripsThroughJSON() throws {
        var p = SharePayload()
        p.action = .translate
        p.translateLanguage = "Korean"
        p.note = "keep it short"
        p.links = [.init(url: URL(string: "https://example.com/a")!, title: "A page")]
        p.texts = ["hello"]
        p.images = ["image-1.jpg"]
        p.files = [.init(name: "r.pdf", storedName: "file-1.pdf", kind: .pdf)]
        p.destination = .conversation(UUID())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var back = try decoder.decode(SharePayload.self, from: encoder.encode(p))
        #expect(abs(back.createdAt.timeIntervalSince(p.createdAt)) < 1)
        back.createdAt = p.createdAt
        #expect(back == p)
    }

    @Test func messagePutsTheRequestFirstThenTheSharedThings() {
        var p = SharePayload()
        p.action = .summarize
        p.note = "  focus on the numbers \n"
        p.links = [.init(url: URL(string: "https://example.com/post")!, title: "A post")]
        p.texts = ["  a quote  "]
        p.files = [.init(name: "report.pdf", storedName: "file-1.pdf", kind: .pdf),
                   .init(name: "photo.raw", storedName: "file-2.raw", kind: .other)]
        let text = p.messageText(fileTexts: ["file-1.pdf": "[Page 1]\nRevenue up"])
        #expect(text == """
        Summarize this.
        focus on the numbers

        A post
        https://example.com/post

        a quote

        [report.pdf]
        [Page 1]
        Revenue up

        [photo.raw: no readable text]
        """)
    }

    @Test func eachActionHasItsInstruction() {
        #expect(SharePayload.instruction(.translate, language: "Korean") == "Translate this into Korean.")
        #expect(SharePayload.instruction(.translate, language: nil) == "Translate this into English.")
        #expect(SharePayload.instruction(.explain, language: nil) == "Explain this.")
        #expect(SharePayload.instruction(.transcript, language: nil).contains("transcript"))
    }

    @Test func aBareLinkIsJustTheLinkAndLongTextIsCut() {
        var p = SharePayload()
        p.links = [.init(url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!, title: nil)]
        #expect(p.messageText() == "https://youtu.be/dQw4w9WgXcQ")
        p.links[0].title = "https://youtu.be/dQw4w9WgXcQ"
        #expect(p.messageText() == "https://youtu.be/dQw4w9WgXcQ", "a title that is the link isn't repeated")

        let long = String(repeating: "x", count: SharePayload.maxItemCharacters + 10)
        let cut = SharePayload.capped(long)
        #expect(cut.hasPrefix(String(repeating: "x", count: SharePayload.maxItemCharacters)))
        #expect(cut.contains("too long") && cut.count < long.count + 80)
    }

    @Test func titleComesFromWhatWasShared() {
        var p = SharePayload()
        p.action = .summarize
        p.links = [.init(url: URL(string: "https://www.example.com/x")!, title: nil)]
        #expect(p.titleBasis == "www.example.com")
        p.files = [.init(name: "notes.txt", storedName: "file-1.txt", kind: .text)]
        #expect(p.titleBasis == "notes.txt")
        p.links[0].title = "Page title"
        #expect(p.titleBasis == "Page title")
    }

    @Test func emptyMeansNothingToSend() {
        var p = SharePayload()
        #expect(p.isEmpty)
        p.texts = ["   "]
        #expect(p.isEmpty)
        p.note = "hi"
        #expect(!p.isEmpty)
    }

    // MARK: Links

    @Test func shareLinkCarriesTheShareID() throws {
        let id = UUID()
        let url = ShareURL.url(for: id)
        #expect(url.absoluteString == "openchat://share?id=\(id.uuidString)")
        #expect(ShareURL.isShareURL(url) && ShareURL.id(in: url) == id)
        #expect(ShareURL.isShareURL(URL(string: "OPENCHAT://share")!))
        #expect(ShareURL.id(in: URL(string: "openchat://share?id=nope")!) == nil)
        #expect(!ShareURL.isShareURL(URL(string: "openchat://add-connection?name=a&url=https://x")!))
        #expect(!AddConnectionLink.isAddLink(url), "the add-connection handler leaves share links alone")
    }

    @Test func videoLinksMatchWhatTheTranscriptToolReads() {
        let links = ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ?si=abc",
                     "https://m.youtube.com/shorts/dQw4w9WgXcQ", "https://www.youtube.com/live/dQw4w9WgXcQ",
                     "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ", "https://www.youtube.com/@channel",
                     "https://www.youtube.com/", "https://vimeo.com/123", "https://example.com/watch?v=dQw4w9WgXcQ"]
        for link in links {
            let url = URL(string: link)!
            #expect(ShareVideoLink.isVideo(url) == (YouTubeURL.videoID(in: url) != nil), "\(link)")
        }
    }

    @Test func transcriptIsOfferedOnlyForVideoLinks() {
        let model = ShareComposeModel(translateLanguage: "Korean")
        model.links = [.init(url: URL(string: "https://example.com")!, title: nil)]
        #expect(!model.actions.contains(.transcript))
        model.links.append(.init(url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!, title: nil))
        #expect(model.actions.contains(.transcript))
        model.action = .translate
        #expect(model.payload.translateLanguage == "Korean")
        model.action = .summarize
        #expect(model.payload.translateLanguage == nil)
    }

    // MARK: Inbox

    private func tempInbox() -> ShareInbox {
        ShareInbox(root: FileManager.default.temporaryDirectory.appending(path: "share-tests-\(UUID().uuidString)"))
    }

    @Test func committedSharesAreListedOldestFirstAndHalfWrittenOnesAreNot() throws {
        let inbox = tempInbox()
        defer { try? FileManager.default.removeItem(at: inbox.root) }
        var older = SharePayload()
        older.note = "older"
        older.createdAt = .now.addingTimeInterval(-60)
        var newer = SharePayload()
        newer.note = "newer"
        let incoming = try inbox.makeIncoming(newer.id)
        try Data("jpeg".utf8).write(to: incoming.appending(path: "image-1.jpg"))
        let unfinished = SharePayload()
        _ = try inbox.makeIncoming(unfinished.id)

        try inbox.commit(newer)
        try inbox.commit(older)
        inbox.writeContext(ShareContext(modelTitle: "m", hasConnection: true))
        #expect(inbox.pending().map(\.note) == ["older", "newer"])
        #expect(FileManager.default.fileExists(atPath: inbox.fileURL("image-1.jpg", in: newer.id).path(percentEncoded: false)),
                "files written while loading move with the share")
        #expect(inbox.readContext()?.modelTitle == "m")

        inbox.remove(older.id)
        #expect(inbox.pending().map(\.note) == ["newer"])
        inbox.discardIncoming(unfinished.id)
        #expect(!FileManager.default.fileExists(atPath: inbox.incomingFolder(unfinished.id).path(percentEncoded: false)))
    }

    @Test func oldSharesAreDroppedUnopened() throws {
        let inbox = tempInbox()
        defer { try? FileManager.default.removeItem(at: inbox.root) }
        var old = SharePayload()
        old.note = "old"
        old.createdAt = .now.addingTimeInterval(-ShareInbox.maxAge - 60)
        try inbox.commit(old)
        #expect(inbox.pending().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: inbox.folder(old.id).path(percentEncoded: false)))
    }

    // MARK: Loading what was shared

    @Test func loaderSortsProvidersIntoLinksTextsImagesAndFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "share-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdfURL = folder.appending(path: "source report.pdf")
        try Self.pdf("hello").write(to: pdfURL)
        let textURL = folder.appending(path: "notes.md")
        try Data("# notes".utf8).write(to: textURL)
        let photo = UIImage(data: Self.jpeg())!

        var loader = ShareItemLoader(folder: folder, maxImages: 1, maxFileBytes: 1_000_000)
        for provider in [NSItemProvider(object: URL(string: "https://example.com/a")! as NSURL),
                         NSItemProvider(object: "https://example.com/b" as NSString),
                         NSItemProvider(object: "  some words  " as NSString),
                         NSItemProvider(object: "some words" as NSString),
                         NSItemProvider(object: photo),
                         NSItemProvider(object: photo),
                         NSItemProvider(contentsOf: pdfURL)!,
                         NSItemProvider(contentsOf: textURL)!] {
            await loader.load(provider)
        }
        loader.finish()
        #expect(loader.links.map(\.url.absoluteString) == ["https://example.com/a", "https://example.com/b"])
        #expect(loader.texts == ["some words"], "a repeat is dropped")
        #expect(loader.images.count == 1 && loader.skipped == 1, "past the image limit")
        #expect(loader.images.first?.thumbnail != nil)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "image-1.jpg").path(percentEncoded: false)))
        #expect(loader.files.map(\.file.kind) == [.pdf, .text])
        #expect(loader.files.first?.file.name.hasSuffix(".pdf") == true)
        for file in loader.files {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: file.file.storedName).path(percentEncoded: false)))
        }
    }

    @Test func aShortLineNextToOneLinkIsItsTitle() async {
        var loader = ShareItemLoader(folder: FileManager.default.temporaryDirectory, maxImages: 4, maxFileBytes: 1)
        await loader.load(NSItemProvider(object: URL(string: "https://example.com/a")! as NSURL))
        loader.addText("A page title")
        loader.finish()
        #expect(loader.links.first?.title == "A page title" && loader.texts.isEmpty)
    }

    // MARK: Import

    private struct Rig {
        let container: ModelContainer
        let controller: ChatController
        let context: ModelContext
        let streamer: ManualStreamer
        let connections: ConnectionStore
        let settings: AppSettings
    }

    private func rig() throws -> Rig {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.testID)
        var gateway = connections.testGateway()
        gateway.models = [ModelInfo(id: "m", supportsImages: true, supportsTools: true)]
        connections.upsert(gateway)
        let settings = AppSettings(defaults: defaults)
        let streamer = ManualStreamer()
        let controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
        return Rig(container: container, controller: controller, context: container.mainContext, streamer: streamer,
                   connections: connections, settings: settings)
    }

    private func importPending(_ r: Rig, _ inbox: ShareInbox) async -> Conversation? {
        await ShareImporter.shared.importPending(from: inbox, controller: r.controller, connections: r.connections,
                                                 settings: r.settings, context: r.context)
    }

    private static func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.jpegData(compressionQuality: 0.8)!
    }

    private static func pdf(_ text: String) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 200)).pdfData { ctx in
            ctx.beginPage()
            (text as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
    }

    @Test func aShareBecomesANewChatWithItsImagesAndFileTextAndStartsTheReply() async throws {
        let r = try rig()
        let inbox = tempInbox()
        defer { try? FileManager.default.removeItem(at: inbox.root) }
        var p = SharePayload()
        p.action = .summarize
        p.links = [.init(url: URL(string: "https://example.com/post")!, title: "A post")]
        p.images = ["image-1.jpg"]
        p.files = [.init(name: "report.pdf", storedName: "file-1.pdf", kind: .pdf),
                   .init(name: "notes.txt", storedName: "file-2.txt", kind: .text)]
        let folder = try inbox.makeIncoming(p.id)
        try Self.jpeg().write(to: folder.appending(path: "image-1.jpg"))
        try Self.pdf("Quarterly revenue grew").write(to: folder.appending(path: "file-1.pdf"))
        try Data("plain notes".utf8).write(to: folder.appending(path: "file-2.txt"))
        try inbox.commit(p)

        let chat = try #require(await importPending(r, inbox))
        #expect(chat.title == "A post")
        #expect(chat.connectionID == Connection.testID && chat.modelID == "m")
        let user = try #require(chat.sortedMessages.first { $0.role == .user })
        #expect(user.text.hasPrefix("Summarize this.\n\nA post\nhttps://example.com/post"))
        #expect(user.text.contains("[report.pdf]\n[Page 1]\nQuarterly revenue grew"))
        #expect(user.text.contains("[notes.txt]\nplain notes"))
        #expect(user.attachments.count == 1 && user.attachments.first?.thumbnailData != nil)
        #expect(r.controller.isStreaming(chat), "the reply starts")
        #expect(inbox.pending().isEmpty, "the share is used up")

        r.controller.stop()
        await r.controller.waitUntilIdle()
    }

    @Test func addedToTheCurrentChatItGoesThereUnlessThatChatIsBusy() async throws {
        let r = try rig()
        let inbox = tempInbox()
        defer { try? FileManager.default.removeItem(at: inbox.root) }
        let existing = Conversation(connectionID: Connection.testID, modelID: "m")
        existing.titleIsUserSet = true
        existing.autoRenameDone = true
        r.context.insert(existing)

        var p = SharePayload()
        p.note = "what about this?"
        p.texts = ["shared words"]
        p.destination = .conversation(existing.id)
        try inbox.commit(p)
        let first = try #require(await importPending(r, inbox))
        #expect(first === existing)
        #expect(existing.sortedMessages.first?.text == "what about this?\n\nshared words")

        // Still replying: the next share can't go in, so it starts a new chat.
        var q = SharePayload()
        q.note = "and this"
        q.destination = .conversation(existing.id)
        try inbox.commit(q)
        let second = try #require(await importPending(r, inbox))
        #expect(second !== existing)
        #expect(second.sortedMessages.first?.text == "and this")

        r.controller.stop()
        await r.controller.waitUntilIdle()
    }

    @Test func overlappingImportsSendEachShareOnce() async throws {
        let r = try rig()
        let inbox = tempInbox()
        defer { try? FileManager.default.removeItem(at: inbox.root) }
        var p = SharePayload()
        p.note = "once"
        try inbox.commit(p)
        let a = Task { @MainActor in await importPending(r, inbox) != nil }
        let b = Task { @MainActor in await importPending(r, inbox) != nil }
        let results = [await a.value, await b.value].filter { $0 }
        #expect(results.count == 1)
        let chats = try r.context.fetch(FetchDescriptor<Conversation>())
        #expect(chats.count == 1)

        r.controller.stop()
        await r.controller.waitUntilIdle()
    }

    @Test func contextNamesTheNewChatModelAndTheChatOnScreen() throws {
        let r = try rig()
        let empty = ShareImporter.context(connections: r.connections, settings: r.settings, current: nil)
        #expect(empty.modelTitle == "m" && empty.hasConnection && empty.currentChat == nil)
        #expect(empty.connectionName == r.connections.connection(Connection.testID)?.name)

        let chat = Conversation(title: "Kyoto", connectionID: Connection.testID, modelID: "m")
        r.context.insert(chat)
        #expect(ShareImporter.context(connections: r.connections, settings: r.settings, current: chat).currentChat == nil,
                "an empty chat is not offered")
        let message = Message(role: .user, text: "hi", sortIndex: 0)
        r.context.insert(message)
        chat.attach(message, parent: nil)
        #expect(ShareImporter.context(connections: r.connections, settings: r.settings, current: chat).currentChat
                == ShareContext.Chat(id: chat.id, title: "Kyoto"))
    }
}
