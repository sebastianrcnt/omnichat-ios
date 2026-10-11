import Testing
import Foundation
import UIKit
@testable import Strata

private final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var active = 0
    private(set) var peak = 0
    var requested: [URL] { lock.withLock { urls } }
    func begin(_ url: URL) { lock.withLock { urls.append(url); active += 1; peak = max(peak, active) } }
    func end() { lock.withLock { active -= 1 } }
}

private func samplePNG(color: UIColor = .systemBlue, side: CGFloat = 48) -> Data {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { ctx in
        color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("favicon-tests-\(UUID().uuidString)", isDirectory: true)
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { date } }
    func advance(days: Double) { lock.withLock { date = date.addingTimeInterval(days * 86400) } }
    func advance(hours: Double) { lock.withLock { date = date.addingTimeInterval(hours * 3600) } }
}

struct FaviconTests {
    private func store(dir: URL, log: FetchLog = FetchLog(), clock: Clock = Clock(), delay: Duration = .zero,
                       respond: @escaping @Sendable (URL) -> Data? = { _ in samplePNG() },
                       allow: @escaping @Sendable (URL) -> Bool = { _ in true }) -> FaviconStore {
        FaviconStore(directory: dir,
                     fetcher: { url in
                         log.begin(url); defer { log.end() }
                         if delay > .zero { try? await Task.sleep(for: delay) }
                         return respond(url)
                     },
                     validator: { allow($0) },
                     now: { clock.now })
    }

    @Test func keysAreNormalizedAndUnsafeHostsRejected() {
        #expect(FaviconStore.key(for: "www.Apple.com") == "apple.com")
        #expect(FaviconStore.key(for: "docs.github.com") == "docs.github.com")
        #expect(FaviconStore.key(for: "localhost") == nil)
        #expect(FaviconStore.key(for: "printer.local") == nil)
        #expect(FaviconStore.key(for: "intranet") == nil)
        #expect(FaviconStore.key(for: "a b.com") == nil)
        #expect(FaviconStore.key(for: "evil.com/../x") == nil)
    }

    @Test func linkParserFindsIconsInOrderAndResolvesRelativeHrefs() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="/a.css">
        <link rel="apple-touch-icon" href="/touch.png">
        <LINK REL='shortcut icon' HREF='/fav.ico'>
        <link href=https://cdn.example.org/i.png rel=icon>
        <link rel="icon" href="javascript:alert(1)">
        </head></html>
        """
        let urls = FaviconLinkParser.iconURLs(in: html, base: URL(string: "https://example.com/blog/post")!)
        #expect(urls.map(\.absoluteString) == ["https://example.com/fav.ico", "https://cdn.example.org/i.png", "https://example.com/touch.png"])
    }

    @Test func fetchesFaviconIcoOnceThenServesFromDisk() async {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = FetchLog()
        let s = store(dir: dir, log: log)
        let first = await s.iconData(for: "apple.com")
        #expect(first != nil)
        #expect(log.requested.map(\.absoluteString) == ["https://apple.com/favicon.ico"])
        // Normalized to a 32 px square PNG.
        let image = UIImage(data: first ?? Data())
        #expect(image?.size == CGSize(width: 32, height: 32))
        _ = await s.iconData(for: "www.apple.com")
        #expect(log.requested.count == 1, "second lookup is a cache hit, including the www alias")
        // A fresh store (a relaunch) reads the same disk cache.
        let relaunched = store(dir: dir, log: log)
        #expect(await relaunched.iconData(for: "apple.com") != nil)
        #expect(log.requested.count == 1)
    }

    @Test func cacheExpiresAfterThirtyDays() async {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = FetchLog(); let clock = Clock()
        let s = store(dir: dir, log: log, clock: clock)
        _ = await s.iconData(for: "example.org")
        clock.advance(days: 29)
        _ = await s.iconData(for: "example.org")
        #expect(log.requested.count == 1)
        clock.advance(days: 2)
        _ = await s.iconData(for: "example.org")
        #expect(log.requested.count == 2, "stale after 30 days: fetched again")
    }

    @Test func failuresAreRememberedForADay() async {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = FetchLog(); let clock = Clock()
        let s = store(dir: dir, log: log, clock: clock, respond: { _ in nil })
        #expect(await s.iconData(for: "no-icon.example") == nil)
        let afterFirst = log.requested.count
        #expect(afterFirst >= 1)
        #expect(await s.iconData(for: "no-icon.example") == nil)
        #expect(log.requested.count == afterFirst, "negative cache: no refetch")
        clock.advance(hours: 25)
        #expect(await s.iconData(for: "no-icon.example") == nil)
        #expect(log.requested.count > afterFirst, "negative entry expired")
    }

    @Test func fallsBackToTheLinkTagOfTheHomePage() async {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = FetchLog()
        let html = Data("<html><head><link rel=\"icon\" href=\"/static/site.png\"></head></html>".utf8)
        let s = store(dir: dir, log: log, respond: { url in
            switch url.absoluteString {
            case "https://site.example/favicon.ico": nil
            case "https://site.example/": html
            case "https://site.example/static/site.png": samplePNG(color: .systemRed)
            default: nil
            }
        })
        #expect(await s.iconData(for: "site.example") != nil)
        #expect(log.requested.map(\.absoluteString) == ["https://site.example/favicon.ico", "https://site.example/", "https://site.example/static/site.png"])
    }

    @Test func nonImageDataIsRejected() async {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = store(dir: dir, respond: { _ in Data("<html>not an icon, at all, really</html>".utf8) })
        #expect(await s.iconData(for: "weird.example") == nil)
    }

    @Test func blockedHostsAreNeverFetched() async {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = FetchLog()
        let s = store(dir: dir, log: log, allow: { _ in false })
        #expect(await s.iconData(for: "public.example") == nil)
        #expect(await s.iconData(for: "localhost") == nil)
        #expect(log.requested.isEmpty)
    }

    @Test func concurrentLookupsOfOneDomainShareOneFetch() async {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = FetchLog()
        let s = store(dir: dir, log: log, delay: .milliseconds(50))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { _ = await s.iconData(for: "same.example") } }
        }
        #expect(log.requested.count == 1)
    }

    @Test func atMostFourFetchesRunAtOnce() async {
        let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = FetchLog()
        let s = store(dir: dir, log: log, delay: .milliseconds(60))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<14 { group.addTask { _ = await s.iconData(for: "site\(i).example") } }
        }
        #expect(log.requested.count == 14)
        #expect(log.peak <= FaviconStore.maxConcurrent)
        #expect(log.peak >= 2, "the limit allows parallel fetches")
    }
}
