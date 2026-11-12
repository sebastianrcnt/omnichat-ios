#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

extension DS {
    enum Layout {
        /// Widest the conversation and composer grow in a big window.
        static let readingWidth: CGFloat = 760
    }
}

extension View {
    /// Centers the view in a column of comfortable reading width.
    func readingColumn() -> some View {
        frame(maxWidth: DS.Layout.readingWidth).frame(maxWidth: .infinity)
    }
}

/// Image attachments on a Mac: a file panel (the composer's plus button), and images dragged onto the chat
/// (`ImageDropCatcher`). Files are resized to JPEG exactly as photos are on the phone.
struct MacImageAttaching: ViewModifier {
    @Environment(\.theme) private var theme
    @Binding var isPresented: Bool
    let onPick: ([Data]) -> Void
    /// An image is being dragged over the chat.
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { await attach(urls) }
            }
            .overlay {
                ImageDropCatcher(onTarget: { targeted = $0 }, onImages: { files in Task { await attach(files) } })
                    .allowsHitTesting(false)
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .strokeBorder(theme.accent, lineWidth: 2)
                        .padding(DS.Spacing.sm)
                        .allowsHitTesting(false)
                }
            }
    }

    private func attach(_ urls: [URL]) async {
        var files: [Data] = []
        for url in urls {
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: url)
            }.value
            if let data { files.append(data) }
        }
        await attach(files)
    }

    /// Image files as they were read; ones that aren't images after all are left out.
    private func attach(_ files: [Data]) async {
        var out: [Data] = []
        for file in files {
            if let jpeg = await Task.detached(priority: .userInitiated, operation: { ImageProcessor.jpegData(from: file) }).value {
                out.append(jpeg)
            }
        }
        if !out.isEmpty { onPick(out) }
    }
}

/// Catches images dragged onto the chat. Three kinds of drag bring one: image files (Finder), files the drag promises to
/// write (the floating thumbnail of a screenshot just taken, Photos, Mail), and the picture itself (a browser).
/// SwiftUI's own drop of file URLs sees only the first kind, so this is an AppKit view over the chat. A click goes
/// through it (`hitTest`); AppKit finds a drag's destination by the registered types instead, so the drag still lands.
struct ImageDropCatcher: NSViewRepresentable {
    let onTarget: @MainActor @Sendable (Bool) -> Void
    /// The files' bytes as dragged (not yet resized), as each one arrives.
    let onImages: @MainActor @Sendable ([Data]) -> Void

    func makeNSView(context: Context) -> ImageDropView { ImageDropView() }

    func updateNSView(_ view: ImageDropView, context: Context) {
        view.onTarget = onTarget
        view.onImages = onImages
    }
}

final class ImageDropView: NSView {
    var onTarget: (@MainActor @Sendable (Bool) -> Void)?
    var onImages: (@MainActor @Sendable ([Data]) -> Void)?

    private static let imageData: [NSPasteboard.PasteboardType] = [.png, .tiff]
    private static let imageFiles: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]
    /// Promised files are written and read here, off the main thread.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
                                + [.fileURL] + Self.imageData)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The promises of image files in the drag. A promise that doesn't say what it is counts: it is checked once read.
    private static func promises(_ board: NSPasteboard) -> [NSFilePromiseReceiver] {
        let receivers = board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        return receivers.filter { receiver in
            let types = receiver.fileTypes.compactMap { UTType($0) ?? UTType(filenameExtension: $0) }
            return types.isEmpty || types.contains { $0.conforms(to: .image) }
        }
    }

    private static func holdsImages(_ board: NSPasteboard) -> Bool {
        board.canReadObject(forClasses: [NSURL.self], options: imageFiles) || !promises(board).isEmpty
            || board.availableType(from: imageData) != nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard Self.holdsImages(sender.draggingPasteboard) else { return [] }
        onTarget?(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onTarget?(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { onTarget?(false) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let onImages = onImages
        onTarget?(false)
        if let urls = board.readObjects(forClasses: [NSURL.self], options: Self.imageFiles) as? [URL], !urls.isEmpty {
            queue.addOperation {
                let files = urls.compactMap { url -> Data? in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                }
                Task { @MainActor in onImages?(files) }
            }
            return true
        }
        let promises = Self.promises(board)
        if !promises.isEmpty {
            // Each promised file is written into a folder of its own drop, read, and removed again.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drop-" + UUID().uuidString, isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return false }
            for promise in promises {
                promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                    defer { try? FileManager.default.removeItem(at: url) }
                    guard error == nil, let file = try? Data(contentsOf: url) else { return }
                    Task { @MainActor in onImages?([file]) }
                }
            }
            return true
        }
        if let type = board.availableType(from: Self.imageData), let file = board.data(forType: type) {
            onImages?([file])
            return true
        }
        return false
    }
}

/// The window furniture the chat adds on a Mac: title, model subtitle, a toolbar with context usage and the chat's
/// menu, and image attaching. (On the phone these are the header and the attach sheet.)
struct MacChatChrome<MenuContent: View>: ViewModifier {
    @Environment(\.theme) private var theme
    let title: String
    /// The title request is running: the title shimmers (`TitlingText`).
    let isTitling: Bool
    let contextFraction: Double?
    @Binding var showContext: Bool
    @Binding var showAttach: Bool
    @Binding var showNoImageSupport: Bool
    let onPickImages: ([Data]) -> Void
    let onEnableImages: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    func body(content: Content) -> some View {
        content
            // The window keeps its title (Window menu, Mission Control); the toolbar draws it itself, so it can shimmer
            // while the chat is being named.
            .navigationTitle(title)
            .toolbar(removing: .title)
            // The chat scrolls under the title bar: give it a surface so answer text never shows through the title.
            .toolbarBackground(theme.background, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    TitlingText(title, isTitling: isTitling)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .padding(.leading, DS.Spacing.xs)
                }
                .sharedBackgroundVisibility(.hidden)
                // On a Mac `.primaryAction` sits at the leading edge, right after the title: push it to the trailing edge.
                ToolbarSpacer(.flexible, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    if let contextFraction { // nothing to show before the first reply
                        Button { showContext = true } label: { ContextRing(fraction: contextFraction) }
                            .help("Context usage")
                    }
                    Menu(content: menu) { Label("More", systemImage: "ellipsis") }
                        .menuIndicator(.hidden)
                        .help("More")
                }
            }
            .modifier(MacImageAttaching(isPresented: $showAttach, onPick: onPickImages))
            .alert("This model can't read images", isPresented: $showNoImageSupport) {
                Button("Turn on image support") { onEnableImages(); showAttach = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Turn on \"Supports images\" for it in Settings > Connections, or choose another model.")
            }
    }
}
#endif
