import Foundation
import UIKit

/// Base64 data URLs of history images, keyed by attachment id. Building one costs a full JPEG read plus a base64 pass,
/// and every request and tool round needs the same bytes again, so they are built once. The bytes never change for a
/// given attachment, which keeps the request prefix identical (prompt cache). Evicted entries rebuild to the same string.
final class ImageDataURLCache: @unchecked Sendable {
    static let shared = ImageDataURLCache()
    private let cache = NSCache<NSUUID, NSString>()
    private let lock = NSLock()
    private var builds = 0

    init(costLimit: Int = 96 * 1024 * 1024) { cache.totalCostLimit = costLimit }

    /// Number of data URLs actually built (cache misses).
    var buildCount: Int { lock.withLock { builds } }

    func dataURL(id: UUID, jpeg: () -> Data) -> String {
        if let hit = cache.object(forKey: id as NSUUID) { return hit as String }
        let url = ContentPart.dataURLString(jpeg: jpeg())
        lock.withLock { builds += 1 }
        cache.setObject(url as NSString, forKey: id as NSUUID, cost: url.utf8.count)
        return url
    }

    func purge() { cache.removeAllObjects() }
}

/// Everything that can be rebuilt is dropped on a memory warning. Running-turn state is not touched.
@MainActor
enum MemoryPurge {
    private static var observer: NSObjectProtocol?
    private(set) static var purgeCount = 0
    /// Extra caches (for example the syntax-highlight cache) register themselves here.
    private static var extra: [@MainActor () -> Void] = []

    static func register(_ purge: @escaping @MainActor () -> Void) { extra.append(purge) }

    static func purgeNow() {
        purgeCount += 1
        PageCache.shared.removeAll()
        ImageDataURLCache.shared.purge()
        FaviconImages.purge()
        for purge in extra { purge() }
    }

    static func install(center: NotificationCenter = .default) {
        guard observer == nil else { return }
        observer = center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { purgeNow() }
        }
    }
}

/// Bubbles read only `thumbnailData`. Attachments saved before thumbnails existed get one made lazily, once.
@MainActor
enum ThumbnailBackfill {
    private static var inflight = Set<UUID>()

    /// Thumbnails for a message's attachments, in order. A missing one is empty `Data` (a placeholder) until backfilled.
    static func thumbnails(for message: Message) -> [Data] {
        message.sortedAttachments.map { a in
            if let t = a.thumbnailData { return t }
            request(a)
            return Data()
        }
    }

    static func request(_ attachment: Attachment) {
        guard attachment.thumbnailData == nil, inflight.insert(attachment.id).inserted else { return }
        let id = attachment.id
        let full = attachment.jpegData // the only place a bubble ever faults the full image, once per old attachment
        Task { @MainActor in
            let thumb = await Task.detached { ImageProcessor.thumbnailData(from: full) }.value
            inflight.remove(id)
            guard let thumb, attachment.modelContext != nil else { return }
            attachment.thumbnailData = thumb
            try? attachment.modelContext?.save()
        }
    }
}
