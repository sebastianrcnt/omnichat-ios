import Foundation
import UIKit
import CryptoKit

/// Finds the `<link rel=icon>` targets in a page's HTML.
enum FaviconLinkParser {
    /// Icon URLs in document order, resolved against `base`; `apple-touch-icon` ranks after plain icons.
    static func iconURLs(in html: String, base: URL) -> [URL] {
        var plain: [URL] = []
        var touch: [URL] = []
        let head = String(html.prefix(200_000))
        guard let tags = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        let ns = head as NSString
        for match in tags.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let rel = attribute("rel", in: tag)?.lowercased(), let href = attribute("href", in: tag),
                  let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http" else { continue }
            let words = rel.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if words.contains("icon") { plain.append(url) }
            else if words.contains("apple-touch-icon") || words.contains("apple-touch-icon-precomposed") { touch.append(url) }
        }
        return plain + touch
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for i in 1...3 where m.range(at: i).location != NSNotFound { return (tag as NSString).substring(with: m.range(at: i)) }
        return nil
    }
}

/// Real site icons for source chips, fetched straight from the site (no third-party service).
///
/// - `https://<domain>/favicon.ico` first, then the `<link rel=icon>` targets of the home page.
/// - One small PNG per domain on disk for 30 days (a failed lookup is remembered for a day).
/// - At most four fetches at once; an ephemeral session, so no cookies and no shared cache.
actor FaviconStore {
    typealias Fetcher = @Sendable (URL) async -> Data?
    typealias Validator = @Sendable (URL) async -> Bool

    static let shared = FaviconStore()
    static let ttl: TimeInterval = 30 * 24 * 3600
    static let failureTTL: TimeInterval = 24 * 3600
    static let maxConcurrent = 4
    static let maxBytes = 512 * 1024
    static let pixelSize = 32 // 16 pt at 2x

    private let directory: URL
    nonisolated var cacheDirectory: URL { directory }
    private let fetcher: Fetcher
    private let validator: Validator
    private let now: @Sendable () -> Date
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Highest number of simultaneous fetches seen (tests).
    private(set) var peakConcurrency = 0

    init(directory: URL? = nil, fetcher: Fetcher? = nil, validator: Validator? = nil, now: @escaping @Sendable () -> Date = { .now }) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("favicons", isDirectory: true)
        self.fetcher = fetcher ?? Self.networkFetcher
        self.validator = validator ?? { url in
            do { try await URLGuard.validate(url); return true } catch { return false }
        }
        self.now = now
    }

    /// Normalized cache key: lowercase host without a leading "www.". Nil for hosts that must not be contacted.
    nonisolated static func key(for host: String) -> String? {
        var h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if h.hasPrefix("www.") { h.removeFirst(4) }
        guard h.contains("."), !URLGuard.isBlockedHostname(h),
              h.unicodeScalars.allSatisfy({ $0.isASCII || $0.value > 127 }),
              !h.contains("/"), !h.contains(" "), h.count <= 253 else { return nil }
        return h
    }

    /// PNG data for the domain's icon, or nil when it has none.
    func iconData(for host: String) async -> Data? {
        guard let key = Self.key(for: host) else { return nil }
        if let cached = readCache(key) { return cached.data }
        if let task = inFlight[key] { return await task.value }
        let task = Task<Data?, Never> { [self] in
            await acquire()
            let data = await lookUp(key)
            release()
            return data
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    // MARK: Lookup

    private func lookUp(_ key: String) async -> Data? {
        if let cached = readCache(key) { return cached.data } // another caller finished meanwhile
        var candidates: [URL] = []
        if let u = URL(string: "https://\(key)/favicon.ico") { candidates.append(u) }
        var tried = 0
        var png: Data?
        var pageChecked = false
        while png == nil, tried < 4 {
            guard !candidates.isEmpty else {
                guard !pageChecked, let home = URL(string: "https://\(key)/") else { break }
                pageChecked = true
                if await validator(home), let html = await fetcher(home), let text = String(data: html, encoding: .utf8) ?? String(data: html, encoding: .isoLatin1) {
                    candidates = Array(FaviconLinkParser.iconURLs(in: text, base: home).prefix(2))
                }
                continue
            }
            let url = candidates.removeFirst()
            tried += 1
            guard await validator(url), let data = await fetcher(url), let normalized = Self.normalize(data) else { continue }
            png = normalized
        }
        write(png, key: key)
        return png
    }

    // MARK: Concurrency limit

    private func acquire() async {
        if running < Self.maxConcurrent { running += 1; peakConcurrency = max(peakConcurrency, running); return }
        await withCheckedContinuation { waiters.append($0) }
        peakConcurrency = max(peakConcurrency, running)
    }

    private func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() } // hand the slot over
    }

    // MARK: Disk cache

    private func path(_ key: String, ext: String) -> URL {
        // Hash the name: domains are attacker-influenced and must never shape a path.
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        return directory.appendingPathComponent("\(digest).\(ext)")
    }

    private struct Cached { var data: Data? } // data == nil: a remembered failure

    private func readCache(_ key: String) -> Cached? {
        let fm = FileManager.default
        for (ext, ttl) in [("png", Self.ttl), ("none", Self.failureTTL)] {
            let url = path(key, ext: ext)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path), let modified = attrs[.modificationDate] as? Date else { continue }
            if now().timeIntervalSince(modified) > ttl { try? fm.removeItem(at: url); continue }
            if ext == "png" { if let data = try? Data(contentsOf: url) { return Cached(data: data) } } else { return Cached(data: nil) }
        }
        return nil
    }

    private func write(_ png: Data?, key: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp: [FileAttributeKey: Any] = [.modificationDate: now()]
        if let png {
            let url = path(key, ext: "png")
            try? png.write(to: url, options: .atomic)
            try? fm.setAttributes(stamp, ofItemAtPath: url.path)
        } else {
            let url = path(key, ext: "none")
            try? Data().write(to: url, options: .atomic)
            try? fm.setAttributes(stamp, ofItemAtPath: url.path)
        }
    }

    /// Remove every cached icon (tests, and a future "clear cache" action).
    func clear() { try? FileManager.default.removeItem(at: directory) }

    // MARK: Image handling

    /// Decode (ICO, PNG, JPEG, GIF) and re-encode as a small square PNG; nil when it is not an image.
    nonisolated static func normalize(_ data: Data) -> Data? {
        guard data.count > 16, data.count <= maxBytes, let image = UIImage(data: data),
              image.size.width >= 1, image.size.height >= 1 else { return nil }
        let side = CGFloat(pixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let scale = max(side / image.size.width, side / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return renderer.pngData { _ in
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
    }

    // MARK: Network

    /// Ephemeral session: no cookies, no cache, no credentials; redirects only to public https hosts.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    private static let networkFetcher: Fetcher = { url in
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("image/*,text/html;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { break } // an icon (or a home page head) this large is not wanted
            }
            return data
        } catch { return nil }
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, url.scheme == "https", let host = url.host(percentEncoded: false),
                  !URLGuard.isBlockedHostname(host), FaviconStore.key(for: host) != nil else { return nil }
            return request
        }
    }
}
