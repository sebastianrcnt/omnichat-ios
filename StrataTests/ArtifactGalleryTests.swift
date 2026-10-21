import Foundation
import ImageIO
import Testing
@testable import Strata

private func item(_ title: String, chat: UUID, chatTitle: String? = "Chat", chatUpdated: Date? = nil, updated: Double,
                  id: String = "a1") -> ArtifactGalleryItem {
    let date = Date(timeIntervalSince1970: updated)
    return ArtifactGalleryItem(entry: ArtifactStore.Entry(conversationID: chat,
                                                          artifact: Artifact(id: id, title: title, version: 1, created: date, updated: date)),
                               chatTitle: chatTitle, chatUpdated: chatUpdated)
}

struct ArtifactGalleryTests {
    let budget = UUID(), trip = UUID()

    var items: [ArtifactGalleryItem] {
        [item("Mortgage calculator", chat: budget, chatTitle: "Budget planning", chatUpdated: Date(timeIntervalSince1970: 50), updated: 10),
         item("Trip itinerary", chat: trip, chatTitle: "Weekend in Busan", chatUpdated: Date(timeIntervalSince1970: 90), updated: 30, id: "a1"),
         item("savings tracker", chat: budget, chatTitle: "Budget planning", chatUpdated: Date(timeIntervalSince1970: 50), updated: 40, id: "a2"),
         item("Café map", chat: trip, chatTitle: "Weekend in Busan", chatUpdated: Date(timeIntervalSince1970: 90), updated: 20, id: "a2")]
    }

    @Test func searchMatchesTitleOrChatTitleIgnoringCaseAndAccents() {
        #expect(ArtifactGallery.filter(items, query: "  ").count == 4)
        #expect(ArtifactGallery.filter(items, query: "SAVINGS").map(\.artifact.title) == ["savings tracker"])
        #expect(ArtifactGallery.filter(items, query: "busan").count == 2, "the chat's title matches too")
        #expect(ArtifactGallery.filter(items, query: "cafe").map(\.artifact.title) == ["Café map"])
        #expect(ArtifactGallery.filter(items, query: "busan map").map(\.artifact.title) == ["Café map"], "every word must match")
        #expect(ArtifactGallery.filter(items, query: "nothing").isEmpty)
    }

    @Test func sortsByLastUpdatedOrTitle() {
        #expect(ArtifactGallery.sorted(items, by: .updated).map(\.artifact.title)
                == ["savings tracker", "Trip itinerary", "Café map", "Mortgage calculator"])
        #expect(ArtifactGallery.sorted(items, by: .title).map(\.artifact.title)
                == ["Café map", "Mortgage calculator", "savings tracker", "Trip itinerary"])
    }

    @Test func tiesKeepAStableOrder() {
        let chat = UUID()
        let same = [item("B", chat: chat, updated: 5, id: "a2"), item("A", chat: chat, updated: 5, id: "a1"),
                    item("A", chat: chat, updated: 9, id: "a3")]
        #expect(ArtifactGallery.sorted(same, by: .updated).map(\.artifact.id) == ["a3", "a1", "a2"])
        #expect(ArtifactGallery.sorted(same, by: .title).map(\.artifact.id) == ["a3", "a1", "a2"], "same title: newest first")
    }

    @Test func groupsByChatNewestChatFirstKeepingTheOrderWithin() {
        let groups = ArtifactGallery.grouped(ArtifactGallery.sorted(items, by: .updated))
        #expect(groups.map(\.chatTitle) == ["Weekend in Busan", "Budget planning"])
        #expect(groups[0].items.map(\.artifact.title) == ["Trip itinerary", "Café map"])
        #expect(groups[1].items.map(\.artifact.title) == ["savings tracker", "Mortgage calculator"])
    }

    @Test func withoutTheChatsDateGroupsGoByTheirNewestArtifact() {
        let a = UUID(), b = UUID()
        let groups = ArtifactGallery.grouped([item("Old", chat: a, chatUpdated: nil, updated: 10),
                                              item("New", chat: b, chatUpdated: nil, updated: 20),
                                              item("Newest", chat: a, chatUpdated: nil, updated: 30, id: "a2")])
        #expect(groups.map(\.conversationID) == [a, b])
    }

    @Test func theViewerPagesThroughWhatIsShown() {
        let grid = ArtifactGallery.ordered(items, query: "", sort: .updated, mode: .grid)
        #expect(grid.map(\.artifact.title) == ["savings tracker", "Trip itinerary", "Café map", "Mortgage calculator"])
        let byChat = ArtifactGallery.ordered(items, query: "", sort: .updated, mode: .byChat)
        #expect(byChat.map(\.artifact.title) == ["Trip itinerary", "Café map", "savings tracker", "Mortgage calculator"])
        #expect(ArtifactGallery.ordered(items, query: "budget", sort: .title, mode: .list).map(\.artifact.title)
                == ["Mortgage calculator", "savings tracker"])
    }

    @Test func itemsLeaveOutUnknownChats() {
        let known = UUID()
        let entries = [ArtifactStore.Entry(conversationID: known, artifact: Artifact(id: "a1", title: "X", version: 1, created: .now, updated: .now)),
                       ArtifactStore.Entry(conversationID: UUID(), artifact: Artifact(id: "a1", title: "Y", version: 1, created: .now, updated: .now))]
        let result = ArtifactGallery.items(entries, chats: [known: ("Known chat", .now)])
        #expect(result.map(\.artifact.title) == ["X"] && result.first?.chatTitle == "Known chat")
    }

    @Test func modesAndSortsSurviveAsRawValues() {
        for mode in ArtifactGalleryMode.allCases { #expect(ArtifactGalleryMode(rawValue: mode.rawValue) == mode) }
        for sort in ArtifactGallerySort.allCases { #expect(ArtifactGallerySort(rawValue: sort.rawValue) == sort) }
    }
}

struct ArtifactThumbnailCacheTests {
    private func tempCache() -> ArtifactThumbnailCache {
        ArtifactThumbnailCache(root: FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func theKeyChangesWithTheUpdateAndAppearance() {
        let chat = UUID()
        let date = Date(timeIntervalSince1970: 1_760_000_000.123)
        let light = ArtifactThumbnailKey(conversationID: chat, artifactID: "a3", updated: date, dark: false)
        #expect(light.fileName == chat.uuidString + "-a3-1760000000123-light.png")
        #expect(ArtifactThumbnailKey(conversationID: chat, artifactID: "a3", updated: date, dark: true).fileName != light.fileName)
        #expect(ArtifactThumbnailKey(conversationID: chat, artifactID: "a3", updated: date + 1, dark: false).fileName != light.fileName)
        #expect(light.identity == chat.uuidString + "-a3-")
        #expect(!ArtifactThumbnailKey(conversationID: chat, artifactID: "a31", updated: date, dark: false).fileName.hasPrefix(light.identity),
                "a3's identity does not cover a31")
        #expect(ArtifactThumbnailKey.identity(conversationID: chat, artifactID: "../a1") == chat.uuidString + "-a1-", "never a path")
    }

    @Test func anUpdatedArtifactMissesAndItsNewThumbnailReplacesTheOld() {
        let cache = tempCache()
        let chat = UUID()
        let old = ArtifactThumbnailKey(conversationID: chat, artifactID: "a1", updated: Date(timeIntervalSince1970: 100), dark: false)
        let oldDark = ArtifactThumbnailKey(conversationID: chat, artifactID: "a1", updated: Date(timeIntervalSince1970: 100), dark: true)
        let other = ArtifactThumbnailKey(conversationID: chat, artifactID: "a2", updated: Date(timeIntervalSince1970: 100), dark: false)
        cache.store(Data([1]), for: old)
        cache.store(Data([2]), for: oldDark)
        cache.store(Data([3]), for: other)
        #expect(cache.data(for: old) == Data([1]))

        var new = old
        new.updated = Date(timeIntervalSince1970: 200)
        #expect(cache.data(for: new) == nil, "an updated artifact has no thumbnail yet")
        cache.store(Data([4]), for: new)
        #expect(cache.data(for: new) == Data([4]))
        #expect(cache.data(for: old) == nil, "the stale one is removed")
        #expect(cache.data(for: oldDark) == Data([2]), "the other appearance stays until it is rendered again")
        #expect(cache.data(for: other) == Data([3]))
        #expect(cache.names().count == 3)
    }

    @Test func pruningRemovesArtifactsThatAreGone() {
        let cache = tempCache()
        let kept = UUID(), gone = UUID()
        let keep = ArtifactThumbnailKey(conversationID: kept, artifactID: "a1", updated: .now, dark: false)
        cache.store(Data([1]), for: keep)
        cache.store(Data([2]), for: ArtifactThumbnailKey(conversationID: kept, artifactID: "a2", updated: .now, dark: true))
        cache.store(Data([3]), for: ArtifactThumbnailKey(conversationID: gone, artifactID: "a1", updated: .now, dark: false))
        cache.prune(keeping: [keep.identity])
        #expect(cache.names() == [keep.fileName])
    }

    @Test func thePNGIsTheTopOfThePageAtTwiceTheSize() throws {
        // A 4x6 snapshot: red on top, blue below. The thumbnail keeps the top, filled to the width.
        let context = try #require(CGContext(data: nil, width: 4, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 3, width: 4, height: 3))
        let snapshot = try #require(context.makeImage())
        let png = try #require(ArtifactThumbnails.png(from: snapshot, size: CGSize(width: 4, height: 3),
                                                      background: CGColor(gray: 1, alpha: 1)))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 8 && image.height == 6)
        let data = try #require(image.dataProvider?.data as Data?)
        #expect(data[0] > 200 && data[2] < 50, "the top left pixel is red: the page's top is kept")
    }
}
