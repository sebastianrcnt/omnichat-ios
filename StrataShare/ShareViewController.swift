import UIKit
import SwiftUI
import UniformTypeIdentifiers
import LinkPresentation
@preconcurrency import UserNotifications

/// The share extension: shows `ShareComposeView` for what another app shared, saves the share into the App Group
/// (`ShareInbox`) on Send and opens OpenChat, which starts the chat.
///
/// Opening the app: a share extension has no supported API for it (`NSExtensionContext.open` works for widgets only),
/// so the request goes up the responder chain to the UIApplication, which works on iOS 26 but is not promised. When it
/// fails, the share is still saved: the sheet says to open OpenChat, a notification (if allowed) leads there, and the
/// app picks the share up whenever it comes to the foreground.
final class ShareViewController: UIViewController {
    private let inbox = ShareInbox.shared
    private lazy var model = ShareComposeModel(context: inbox?.readContext())

    /// Images a share takes (the activation rule allows the same).
    static let maxImages = 4
    /// Larger files are left out.
    static let maxFileBytes: Int64 = 50_000_000

    override func viewDidLoad() {
        super.viewDidLoad()
        ShareFonts.register()
        let root = ShareComposeView(model: model,
                                    onCancel: { [weak self] in self?.cancel() },
                                    onSend: { [weak self] in self?.send() },
                                    onDone: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        Task { await load() }
    }

    // MARK: Loading

    private func load() async {
        defer { model.isLoading = false }
        guard let inbox, let folder = try? inbox.makeIncoming(model.id) else {
            model.phase = .failed(String(localized: "OpenChat's shared storage isn't available. Open OpenChat once, then try again."))
            return
        }
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        var loader = ShareItemLoader(folder: folder, maxImages: Self.maxImages, maxFileBytes: Self.maxFileBytes)
        for item in items {
            for provider in item.attachments ?? [] { await loader.load(provider) }
            // Some apps put the page title or the selected text on the item rather than in an attachment.
            if let text = item.attributedContentText?.string { loader.addText(text) }
        }
        loader.finish()
        model.links = loader.links
        model.texts = loader.texts
        model.images = loader.images
        model.files = loader.files
        model.skipped = loader.skipped
        if let first = loader.links.first { Task { await fetchMetadata(first.url) } }
    }

    /// The page's title (when the app didn't give one) and its icon, from LinkPresentation.
    private func fetchMetadata(_ url: URL) async {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return }
        if let i = model.links.firstIndex(where: { $0.url == url }), model.links[i].title?.isEmpty != false,
           let title = metadata.title, !title.isEmpty {
            model.links[i].title = title
        }
        if let iconProvider = metadata.iconProvider, iconProvider.canLoadObject(ofClass: UIImage.self) {
            let image: UIImage? = await withCheckedContinuation { c in
                iconProvider.loadObject(ofClass: UIImage.self) { object, _ in c.resume(returning: object as? UIImage) }
            }
            model.linkIcon = image?.cgImage
        }
    }

    // MARK: Actions

    private func cancel() {
        inbox?.discardIncoming(model.id)
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func send() {
        guard let inbox, model.canSend else { return }
        model.phase = .sending
        let payload = model.payload
        do {
            try inbox.commit(payload)
        } catch {
            model.phase = .failed(error.localizedDescription)
            return
        }
        openApp(ShareURL.url(for: payload.id)) { [weak self] opened in
            guard let self else { return }
            if opened {
                extensionContext?.completeRequest(returningItems: nil)
            } else {
                model.phase = .saved
                Self.notifyReady()
            }
        }
    }

    /// Asks the UIApplication in the responder chain to open the app (see the type's note). `open(_:options:)` is
    /// marked unavailable to extensions, so it is called through the Objective-C runtime.
    private func openApp(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                open(application, selector, url as NSURL, NSDictionary()) { opened in Task { @MainActor in completion(opened) } }
                return
            }
            responder = current.next
        }
        completion(false)
    }

    /// When the app couldn't be opened: a notification that opens it, if notifications are allowed.
    private static func notifyReady() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Ready in OpenChat")
            content.body = String(localized: "Tap to start the chat with what you shared.")
            center.add(UNNotificationRequest(identifier: "share-ready", content: content, trigger: nil))
        }
    }
}
