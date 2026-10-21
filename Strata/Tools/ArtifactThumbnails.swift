import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Thumbnails of artifacts for the gallery: the top of the page, rendered once off screen in a locked-down web view and
// kept as a PNG under Caches. A thumbnail is named after its artifact, the artifact's last update and the appearance, so
// an updated artifact (or the other appearance) simply has no file yet and is rendered again; the stale one is removed
// when its replacement is written.

/// Which thumbnail: one artifact as last updated, in light or dark.
struct ArtifactThumbnailKey: Hashable, Sendable {
    var conversationID: UUID
    var artifactID: String
    var updated: Date
    var dark: Bool

    init(conversationID: UUID, artifactID: String, updated: Date, dark: Bool) {
        self.conversationID = conversationID
        self.artifactID = artifactID
        self.updated = updated
        self.dark = dark
    }

    init(entry: ArtifactStore.Entry, dark: Bool) {
        self.init(conversationID: entry.conversationID, artifactID: entry.artifact.id, updated: entry.artifact.updated, dark: dark)
    }

    /// "<chat>-a3-": every thumbnail of the artifact starts with it, whatever its date or appearance.
    var identity: String { Self.identity(conversationID: conversationID, artifactID: artifactID) }

    static func identity(conversationID: UUID, artifactID: String) -> String {
        // Ids are "a<n>"; anything else is reduced to letters and digits so it never names a path.
        let safe = String(artifactID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
        return conversationID.uuidString + "-" + safe + "-"
    }

    var appearance: String { dark ? "dark" : "light" }

    /// "<chat>-a3-1760000000000-dark.png" (the update time in milliseconds).
    var fileName: String {
        identity + String(Int64((updated.timeIntervalSince1970 * 1000).rounded())) + "-" + appearance + ".png"
    }
}

/// The PNG files of the thumbnails. Safe to use from any thread.
final class ArtifactThumbnailCache: @unchecked Sendable {
    static let shared = ArtifactThumbnailCache()

    let root: URL
    private let lock = NSLock()

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.root = caches.appendingPathComponent("ArtifactThumbnails", isDirectory: true)
        }
    }

    func url(for key: ArtifactThumbnailKey) -> URL { root.appendingPathComponent(key.fileName) }

    /// The PNG for exactly this key; nil when the artifact changed since (or was never rendered).
    func data(for key: ArtifactThumbnailKey) -> Data? {
        lock.withLock { try? Data(contentsOf: url(for: key)) }
    }

    /// Writes the PNG and removes the artifact's older thumbnails of the same appearance.
    func store(_ png: Data, for key: ArtifactThumbnailKey) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard (try? png.write(to: url(for: key), options: .atomic)) != nil else { return }
            let suffix = "-" + key.appearance + ".png"
            for name in names() where name.hasPrefix(key.identity) && name.hasSuffix(suffix) && name != key.fileName {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    /// Removes the thumbnails of every artifact not in `identities` (`ArtifactThumbnailKey.identity`): deleted chats.
    func prune(keeping identities: Set<String>) {
        lock.withLock {
            for name in names() where !identities.contains(where: { name.hasPrefix($0) }) {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    /// The file names in the folder (for tests and pruning).
    func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasSuffix(".png") }
    }
}

/// Hands out thumbnails: from memory, from the disk cache, or rendered. At most `maxRendering` pages render at once,
/// the most recently asked for first (what just scrolled into view); a request whose cell went away before its turn is
/// dropped without rendering.
@MainActor
final class ArtifactThumbnails {
    static let shared = ArtifactThumbnails()

    /// Points of page the thumbnail shows: a phone-width layout, cut to 4:3.
    nonisolated static let pageSize = CGSize(width: 400, height: 300)
    /// The stored image, in points (drawn at 2x).
    nonisolated static let imageSize = CGSize(width: 300, height: 225)
    static let maxRendering = 2

    let cache: ArtifactThumbnailCache
    let store: ArtifactStore
    private let memory = NSCache<NSString, PlatformImage>()
    private var inFlight: [ArtifactThumbnailKey: (task: Task<PlatformImage?, Never>, waiting: Int)] = [:]
    /// Pages that could not be rendered this session, so they are not tried again on every scroll.
    private var failed: Set<ArtifactThumbnailKey> = []
    private var rendering = 0
    private var queue: [CheckedContinuation<Void, Never>] = []

    init(cache: ArtifactThumbnailCache = .shared, store: ArtifactStore = .shared) {
        self.cache = cache
        self.store = store
        memory.countLimit = 60
    }

    /// The thumbnail if it is in memory now (so a cell scrolled back into view draws it at once).
    func cached(_ key: ArtifactThumbnailKey) -> PlatformImage? { memory.object(forKey: key.fileName as NSString) }

    /// The thumbnail for `key`, rendering it if needed; nil when the page can't be read or rendered.
    func image(for key: ArtifactThumbnailKey) async -> PlatformImage? {
        if let image = cached(key) { return image }
        guard !failed.contains(key) else { return nil }
        let task: Task<PlatformImage?, Never>
        if let running = inFlight[key] {
            task = running.task
            inFlight[key]?.waiting += 1
        } else {
            task = Task { await self.load(key) }
            inFlight[key] = (task, 1)
        }
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in self.giveUp(key) }
        }
        if inFlight[key]?.task == task, !task.isCancelled { inFlight[key] = nil }
        return image
    }

    /// One fewer cell is waiting for `key`; with none left, a render that has not started is dropped.
    private func giveUp(_ key: ArtifactThumbnailKey) {
        guard var entry = inFlight[key] else { return }
        entry.waiting -= 1
        if entry.waiting <= 0 {
            entry.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = entry
        }
    }

    private func load(_ key: ArtifactThumbnailKey) async -> PlatformImage? {
        let cache = cache, store = store
        if let data = await Task.detached(operation: { cache.data(for: key) }).value, let image = Self.decode(data) {
            memory.setObject(image, forKey: key.fileName as NSString)
            return image
        }
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        guard let html = await Task.detached(operation: { store.html(id: key.artifactID, conversationID: key.conversationID) }).value
        else { failed.insert(key); return nil }
        let snapshot = await ArtifactSnapshotter.snapshot(html: ArtifactHTML.prepared(html), dark: key.dark, size: Self.pageSize)
        guard !Task.isCancelled else { return nil }
        let background = Self.backgroundColor(dark: key.dark)
        let size = Self.imageSize
        guard let snapshot, let png = await Task.detached(operation: { Self.png(from: snapshot, size: size, background: background) }).value,
              let image = Self.decode(png) else { failed.insert(key); return nil }
        Task.detached { cache.store(png, for: key) }
        memory.setObject(image, forKey: key.fileName as NSString)
        return image
    }

    private func acquire() async {
        if rendering < Self.maxRendering { rendering += 1; return }
        await withCheckedContinuation { queue.append($0) } // the slot is handed over by `release`
    }

    private func release() {
        if queue.isEmpty { rendering -= 1 } else { queue.removeLast().resume() }
    }

    // MARK: Images

    /// The page background the viewer shows behind a transparent page, in the given appearance.
    static func backgroundColor(dark: Bool) -> CGColor {
        let color = PlatformColor(DSTheme().background)
        #if canImport(UIKit)
        return color.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)).cgColor
        #else
        var cg = CGColor(gray: dark ? 0.07 : 1, alpha: 1)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
        #endif
    }

    /// The snapshot scaled to `size` at 2x over `background`, as PNG.
    nonisolated static func png(from snapshot: CGImage, size: CGSize, background: CGColor) -> Data? {
        let width = Int(size.width * 2), height = Int(size.height * 2)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(background)
        context.fill(rect)
        context.interpolationQuality = .high
        // Fill the width; keep the top of the page (CoreGraphics' origin is bottom left).
        let scale = CGFloat(width) / CGFloat(max(snapshot.width, 1))
        let drawn = CGFloat(snapshot.height) * scale
        context.draw(snapshot, in: CGRect(x: 0, y: CGFloat(height) - drawn, width: CGFloat(width), height: drawn))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A stored PNG as an image of `imageSize` points.
    nonisolated static func decode(_ png: Data) -> PlatformImage? {
        #if canImport(UIKit)
        return UIImage(data: png, scale: 2)?.preparingForDisplay()
        #else
        guard let image = NSImage(data: png) else { return nil }
        image.size = imageSize
        return image
        #endif
    }
}

// MARK: - Rendering

/// Renders one artifact page off screen and snapshots it. The web view has what the viewer's has, and less: its own
/// throwaway data store, the local-network rules, no bridge into the app, no file access, no navigation away from the
/// page, no new windows, no media playback. It is torn down as soon as the snapshot is taken.
@MainActor
enum ArtifactSnapshotter {
    /// Longest wait for the page to finish loading; past it, whatever has drawn is taken.
    static let loadTimeout: Duration = .seconds(6)
    /// Time after loading for scripts, fonts and charts to draw.
    static let settle: Duration = .milliseconds(700)

    static func snapshot(html: String, dark: Bool, size: CGSize) async -> CGImage? {
        // Nothing loads before the local-network rules are in place.
        guard let rules = await LocalNetworkRules.rules() else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.add(rules)
        #if canImport(UIKit)
        config.allowsInlineMediaPlayback = true
        #endif
        let delegate = SnapshotNavigation()
        let view = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        #if canImport(UIKit)
        view.overrideUserInterfaceStyle = dark ? .dark : .light
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        // No safe-area inset from the window's edge: the page starts at the top of the snapshot.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isUserInteractionEnabled = false
        // In a window, so WebKit lays the page out and draws it; fully opaque (a snapshot keeps the view's alpha) but
        // outside the window's bounds and behind everything, so it is never seen.
        view.frame.origin = CGPoint(x: -size.width - 1_000, y: 0)
        HiddenWebView.keyWindow?.insertSubview(view, at: 0)
        #else
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.underPageBackgroundColor = .clear
        OffscreenWebHost.shared.attach(view)
        #endif
        defer {
            view.stopLoading()
            view.navigationDelegate = nil
            view.uiDelegate = nil
            view.configuration.userContentController.removeAllContentRuleLists()
            view.removeFromSuperview()
        }

        view.loadHTMLString(html, baseURL: nil)
        await delegate.waitForLoad(timeout: loadTimeout)
        try? await Task.sleep(for: settle)
        guard !Task.isCancelled else { return nil }
        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = CGRect(origin: .zero, size: size)
        snapshotConfig.afterScreenUpdates = true
        guard let image = try? await view.takeSnapshot(configuration: snapshotConfig) else { return nil }
        return image.cgImageRepresentation
    }
}

/// The page stays the page: only its own load (and in-page anchors) and web subframes go through; nothing opens outside.
@MainActor
private final class SnapshotNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func waitForLoad(timeout: Duration) async {
        guard !finished else { return }
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish()
        }
        await withCheckedContinuation { waiter = $0 }
        timer.cancel()
    }

    private func finish() {
        finished = true
        waiter?.resume()
        waiter = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "blob" || scheme == "data" { return .allow }
        if let frame = action.targetFrame, !frame.isMainFrame { return InAppBrowser.isWeb(url) ? .allow : .cancel }
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish() }
}
