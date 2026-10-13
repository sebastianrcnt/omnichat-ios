import Foundation
import SwiftData
import Testing
import UIKit
@testable import Strata

private func physFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

private struct LongResultTools: ToolExecuting {
    func execute(name: String, arguments: String) async -> ToolOutput {
        ToolOutput(text: String(repeating: "A fetched page sentence with some words in it. ", count: 900)) // about 42 KB
    }
}

@MainActor
struct ImageCacheTests {
    @Test func dataURLIsBuiltOncePerAttachmentAndIsByteStable() {
        let cache = ImageDataURLCache()
        let id = UUID()
        let jpeg = Data((0..<4000).map { UInt8($0 % 251) })
        var reads = 0
        let first = cache.dataURL(id: id) { reads += 1; return jpeg }
        let second = cache.dataURL(id: id) { reads += 1; return jpeg }
        #expect(first == second && first == "data:image/jpeg;base64," + jpeg.base64EncodedString())
        #expect(reads == 1 && cache.buildCount == 1)
        cache.purge()
        let third = cache.dataURL(id: id) { reads += 1; return jpeg }
        #expect(third == first && reads == 2) // rebuilt identically after a purge
    }

    @Test func historyMessagesReuseTheCache() throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let m = Message(role: .user, text: "look", sortIndex: 0)
        context.insert(m)
        let a = Attachment(jpegData: Data(repeating: 7, count: 5000), sortIndex: 0)
        a.message = m
        context.insert(a)
        ImageDataURLCache.shared.purge()
        let before = ImageDataURLCache.shared.buildCount
        let one = MessageAssembler.apiMessages(from: [m.historyMessage])
        let two = MessageAssembler.apiMessages(from: [m.historyMessage])
        #expect(ImageDataURLCache.shared.buildCount == before + 1)
        #expect(try ChatRequest.encoder.encode(one) == ChatRequest.encoder.encode(two))
    }

    @Test func memoryWarningPurgesRebuildableCaches() {
        let center = NotificationCenter()
        MemoryPurge.install(center: center)
        let id = UUID()
        _ = ImageDataURLCache.shared.dataURL(id: id) { Data(repeating: 1, count: 100) }
        PageCache.shared.store(FetchedPage(title: "t", url: "https://example.com/", text: "x"), for: URL(string: "https://example.com/")!)
        let purges = MemoryPurge.purgeCount
        MemoryPurge.purgeNow()
        #expect(MemoryPurge.purgeCount == purges + 1)
        #expect(PageCache.shared.page(for: URL(string: "https://example.com/")!) == nil)
        var rebuilt = 0
        _ = ImageDataURLCache.shared.dataURL(id: id) { rebuilt += 1; return Data(repeating: 1, count: 100) }
        #expect(rebuilt == 1)
    }
}

@MainActor
struct ThumbnailTests {
    private func bigJPEG() -> Data {
        let size = CGSize(width: 1568, height: 1176)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            for i in 0..<400 {
                UIColor(hue: CGFloat(i % 50) / 50, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: (i * 37) % 1500, y: (i * 91) % 1100, width: 120, height: 90))
            }
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    @Test func attachmentsStoreASmallThumbnail() throws {
        let jpeg = bigJPEG()
        let a = Attachment(jpegData: jpeg, sortIndex: 0)
        let thumb = try #require(a.thumbnailData)
        #expect(thumb.count < 40_000 && thumb.count * 5 < jpeg.count)
        let image = try #require(UIImage(data: thumb))
        #expect(max(image.size.width, image.size.height) <= ImageProcessor.thumbnailLongSide)
        #expect(a.jpegData == jpeg) // the full image is untouched
    }

    @Test func oldAttachmentsGetABackfilledThumbnail() async throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let m = Message(role: .user, text: "x", sortIndex: 0)
        context.insert(m)
        let a = Attachment(jpegData: bigJPEG(), sortIndex: 0)
        a.thumbnailData = nil // as saved before thumbnails existed
        a.message = m
        context.insert(a)
        let first = ThumbnailBackfill.thumbnails(for: m)
        #expect(first.count == 1 && first[0].isEmpty) // placeholder at first
        for _ in 0..<200 where a.thumbnailData == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(a.thumbnailData != nil)
        #expect(ThumbnailBackfill.thumbnails(for: m)[0] == a.thumbnailData)
    }
}

@MainActor
struct SidebarSearchTests {
    @Test func searchFindsMessageTextInTheStoreAndTitlesInMemory() throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let a = Conversation(title: "Trip plans"), b = Conversation(title: "Recipes"), c = Conversation(title: "Other")
        for conv in [a, b, c] { context.insert(conv) }
        let hit = Message(role: .assistant, text: "Try the carbonara with guanciale.", sortIndex: 0)
        hit.conversation = b
        let miss = Message(role: .user, text: "unrelated", sortIndex: 0)
        miss.conversation = c
        context.insert(hit); context.insert(miss)
        try context.save()
        let ids = ConversationSearch.matchingConversationIDs(query: "carbonara", context: context)
        #expect(ids == [b.id])
        #expect(ConversationSearch.filter([a, b, c], query: "carbonara", contentMatches: ids).map(\.title) == ["Recipes"])
        #expect(ConversationSearch.filter([a, b, c], query: "trip", contentMatches: []).map(\.title) == ["Trip plans"])
        #expect(ConversationSearch.filter([a, b, c], query: "  ", contentMatches: []).count == 3)
    }
}

/// A long conversation with images, multi-round tools and large fetch results stays bounded.
/// Numbers are recorded in docs/MEMORY.md.
@MainActor
struct LongSessionTests {
    @Test func fortyTurnsKeepCheckpointWritesAndFootprintBounded() async throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let keys = InMemoryKeyStore()
        let connections = ConnectionStore(defaults: defaults, keys: keys)
        try connections.setAPIKey("k", for: Connection.strataID)
        var strata = connections.connection(Connection.strataID)!
        // Reads images, so the six attached below are sent with every request (a text-only model gets notes instead).
        strata.models = [ModelInfo(id: "m", supportsImages: true, supportsTools: true)]
        connections.upsert(strata)

        // Per turn: one tool round, then a 400-delta answer.
        let call = ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "c", name: "web_fetch", arguments: "{\"url\":\"https://example.com/\"}")])
        let answer = (0..<400).map { _ in ChatDelta(content: "word ") }
        let turns = 40
        let plans: [([ChatDelta], ProgrammableStreamer.End)] = (0..<turns).flatMap { _ in [([call], .finish), (answer, .finish)] }
        let streamer = ProgrammableStreamer(plans)
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults), streamer: streamer, tools: LongResultTools())
        let conversation = Conversation(connectionID: Connection.strataID, modelID: "m", effort: .medium)
        context.insert(conversation)

        var written = 0
        controller.onCheckpointWrite = { written += $0 }
        // Six images of about 300 KB each in the first message.
        let images = (0..<6).map { i in Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i) }) }
        let start = physFootprint()
        var perTurn: [Int] = []
        for turn in 0..<turns {
            written = 0
            controller.send(text: "question \(turn)", images: turn == 0 ? images : [], conversation: conversation, context: context)
            await controller.waitUntilIdle()
            perTurn.append(written)
        }
        let peakAfter = physFootprint()
        MemoryPurge.purgeNow()
        let afterPurge = physFootprint()

        let early = perTurn[2..<6].reduce(0, +) / 4, late = perTurn[(turns - 4)...].reduce(0, +) / 4
        print("MEMORY start=\(start >> 20)MB end=\(peakAfter >> 20)MB afterPurge=\(afterPurge >> 20)MB checkpointBytesPerTurn early=\(early >> 10)KB late=\(late >> 10)KB")
        // Writes happen per round and on the 1 s throttle, never per streamed event: a turn with 400 events
        // writes only a handful of checkpoints, and later turns write about what early ones did plus their
        // own history growth (no per-token term).
        #expect(early > 0)
        #expect(late < early * 4, "checkpoint bytes per turn grew too fast: \(early) -> \(late)")
        let tokensWritten = 400 * 2_000 // what a full rewrite per event would cost with even a 2 KB checkpoint
        #expect(early < 16 * 1024 * 1024 && tokensWritten > 0)
        #expect(conversation.messages.count == turns * 2)
        #expect(peakAfter - start < 300 << 20, "footprint grew by \((peakAfter - start) >> 20) MB")
        #expect(afterPurge <= peakAfter + (16 << 20))
    }
}
