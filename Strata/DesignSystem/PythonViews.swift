import SwiftUI
#if os(macOS)
import AppKit
#endif

// The feed and Timeline views of `run_python` and `view_image`: the code (folded when long), what it printed, and the
// figures it saved; a figure opens full size on a tap.

// MARK: - Images

/// Decoded tool images for the session.
@MainActor
enum ToolImageCache {
    private static let cache = NSCache<NSString, PlatformImage>()

    static func image(for image: ToolImage, store: ToolImageStore = .shared) async -> PlatformImage? {
        let key = image.file as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let file = image.file
        let decoded = await Task.detached(priority: .userInitiated) { store.data(file: file).flatMap { PlatformImage(data: $0) } }.value
        if let decoded { cache.setObject(decoded, forKey: key) }
        return decoded
    }

    static func purge() { cache.removeAllObjects() }
}

/// A figure as a small rounded tile; a tap opens it full size.
struct ToolImageThumbnail: View {
    @Environment(\.theme) private var theme
    let image: ToolImage
    var height: CGFloat = 96
    @State private var loaded: PlatformImage?
    @State private var showFull = false

    var body: some View {
        let aspect = image.width > 0 && image.height > 0 ? CGFloat(image.width) / CGFloat(image.height) : 4.0 / 3.0
        Button { showFull = true } label: {
            ZStack {
                theme.surfaceRaised
                if let loaded {
                    Image(platformImage: loaded).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(theme.textTertiary)
                }
            }
            .frame(width: height * aspect, height: height)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).strokeBorder(theme.separator, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: image.id))
        .accessibilityHint(Text("Shows the image full size"))
        .task(id: image.file) { loaded = await ToolImageCache.image(for: image) }
        .sheet(isPresented: $showFull) { ToolImageViewer(image: image) }
    }
}

/// A figure in an answer: the answer's width (never upscaled past its pixels), a caption under it, full size on a
/// tap, and Copy / Share on a long press. A reference to a figure that isn't stored shows nothing.
struct AnswerFigure: View {
    @Environment(\.theme) private var theme
    let image: ToolImage
    var caption = ""
    var store: ToolImageStore = .shared
    @State private var loaded: PlatformImage?
    @State private var missing = false
    @State private var showFull = false

    var body: some View {
        if !missing {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Button { showFull = true } label: { picture }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: caption.isEmpty ? image.id : caption))
                    .accessibilityHint(Text("Shows the image full size"))
                    .contextMenu {
                        if let loaded {
                            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(loaded) }
                        }
                        ShareLink(item: store.root.appendingPathComponent(image.file)) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                    }
                if !caption.isEmpty {
                    Text(verbatim: caption).font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                }
            }
            .task(id: image.file) {
                loaded = await ToolImageCache.image(for: image, store: store)
                missing = loaded == nil
            }
            .sheet(isPresented: $showFull) { ToolImageViewer(image: image) }
        }
    }

    @ViewBuilder private var picture: some View {
        if let loaded {
            let pixels = loaded.size
            Image(platformImage: loaded).resizable().interpolation(.high).scaledToFit()
                .frame(maxWidth: pixels.width > 0 ? pixels.width : nil)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(theme.separator, lineWidth: 1) }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(theme.surfaceRaised)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay { ProgressView().controlSize(.small) }
        }
    }
}

/// Figures from the turn that the answer didn't place with `![caption](figure-N)`: one or two at full width, more as
/// a strip of tiles.
struct UnplacedFigures: View {
    let figures: [ToolImage]

    var body: some View {
        if figures.count <= 2 {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                ForEach(figures, id: \.file) { AnswerFigure(image: $0) }
            }
        } else {
            ToolImageStrip(images: figures)
        }
    }
}

/// One figure, full size: fits the sheet and zooms with a pinch. Save (to Photos on the phone, a file on a Mac) and Share
/// sit in the header.
struct ToolImageViewer: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let image: ToolImage
    var store: ToolImageStore = .shared
    @State private var loaded: PlatformImage?
    @State private var saved = false
    @State private var saveError: String?

    private var fileURL: URL { store.root.appendingPathComponent(image.file) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(verbatim: image.id).font(DS.Typography.title).foregroundStyle(theme.textPrimary)
                HStack(spacing: DS.Spacing.sm) {
                    GlassIconButton(systemName: "xmark", label: "Close") { dismiss() }
                    Spacer()
                    if loaded != nil {
                        GlassIconButton(systemName: saved ? "checkmark" : "square.and.arrow.down",
                                        label: saved ? "Saved" : "Save") { Task { await save() } }
                        ShareLink(item: fileURL) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: DS.IconSize.headerIcon, weight: .medium))
                                .frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Share"))
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.top, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.md)

            Group {
                if let loaded {
                    ZoomableImage(image: loaded)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Group {
                if let saveError {
                    Text(saveError).foregroundStyle(theme.destructive)
                } else if let loaded {
                    let size = pixelSize(loaded)
                    Text(verbatim: "\(Int(size.width)) × \(Int(size.height))").foregroundStyle(theme.textTertiary)
                }
            }
            .font(DS.Typography.uiCaption)
            .padding(.vertical, DS.Spacing.sm)
        }
        .background(theme.background.ignoresSafeArea())
        .presentationBackground(theme.background)
        .presentationDetents([.large])
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 760, minHeight: 440, idealHeight: 620)
        .background { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        #endif
        .task(id: image.file) { loaded = await ToolImageCache.image(for: image, store: store) }
    }

    private func save() async {
        saveError = nil
        do {
            #if canImport(UIKit)
            try await PhotoLibrarySaver.save(fileURL: fileURL)
            #else
            let panel = NSSavePanel()
            panel.nameFieldStringValue = image.id + "." + (fileURL.pathExtension.isEmpty ? "png" : fileURL.pathExtension)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: fileURL, to: url)
            #endif
            saved = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// The recorded size, else the decoded image's: a figure placed in an answer is opened by id, before its size is known.
    private func pixelSize(_ loaded: PlatformImage) -> CGSize {
        if image.width > 0 && image.height > 0 { return CGSize(width: image.width, height: image.height) }
        #if canImport(UIKit)
        if let cg = loaded.cgImage { return CGSize(width: cg.width, height: cg.height) }
        #else
        if let rep = loaded.representations.first, rep.pixelsWide > 0 { return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        #endif
        return loaded.size
    }
}

/// A row of figure tiles that scrolls sideways.
struct ToolImageStrip: View {
    let images: [ToolImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(images, id: \.file) { ToolImageThumbnail(image: $0) }
            }
        }
    }
}

// MARK: - Output

/// What a run printed, in monospace; long output folds to its first lines with a toggle.
struct PythonOutputView: View {
    @Environment(\.theme) private var theme
    let text: String
    var isError = false
    @State private var expanded = false

    static let foldedLines = 12

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let long = lines.count > Self.foldedLines + 3
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(verbatim: long && !expanded ? lines.prefix(Self.foldedLines).joined(separator: "\n") : text)
                .font(DS.Typography.monoSmall)
                .foregroundStyle(isError ? theme.warning : theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if long {
                Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(DS.Typography.feedMeta)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(DS.Spacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
    }
}

/// Code, output and figures of one run (inside the feed card and the Timeline card).
struct PythonRunDetail: View {
    let code: String
    let output: String
    let figures: [ToolImage]
    var isRunning = false
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            CodeBlockView(content: CodeBlockContent(language: "python", code: code))
            if !isRunning && !displayedOutput.isEmpty {
                PythonOutputView(text: displayedOutput, isError: isError)
            }
            if !figures.isEmpty { ToolImageStrip(images: figures) }
        }
    }

    /// The output without the line that lists the figures (they are shown as images).
    private var displayedOutput: String {
        output.components(separatedBy: "\n\n")
            .filter { !$0.hasPrefix("Figure saved: ") && !$0.hasPrefix("Figures saved: ") }
            .joined(separator: "\n\n")
    }
}

// MARK: - Feed cards

/// "Ran Python" in the feed: a header line like the other cards; open, the code, output and figures.
/// `view_image` gets a one-line card with the image's tile.
struct PythonFeedCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: FeedCard
    let collapsed: Bool
    let onToggle: () -> Void
    var onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if case .python(let code) = card.kind, !collapsed {
                PythonRunDetail(code: code, output: card.output, figures: card.figures, isRunning: card.isRunning,
                                isError: card.isError)
                    .padding(.leading, DS.Feed.textInset)
                    .padding(.vertical, DS.Spacing.xs)
                    .transition(.opacity)
            }
            if isImage, !card.isRunning, let image = card.figures.first {
                ToolImageThumbnail(image: image, height: DS.IconSize.thumbnail)
                    .padding(.leading, DS.Feed.textInset)
                    .padding(.vertical, DS.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : ActivityFeedView.fold, value: collapsed)
        .contextMenu {
            Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails)
        }
    }

    private var isImage: Bool { if case .image = card.kind { true } else { false } }

    private var header: some View {
        let line = FeedLine(title: title, meta: meta, expanded: isImage || card.isRunning ? nil : !collapsed) {
            if card.isRunning { FeedSpinner() }
            else { FeedSymbol(name: isImage ? "photo" : "chevron.left.forwardslash.chevron.right") }
        }
        return Group {
            if isImage {
                line.accessibilityElement(children: .combine)
            } else {
                Button(action: onToggle) { line }
                    .buttonStyle(.plain)
                    .accessibilityValue(Text(collapsed ? "Collapsed" : "Expanded"))
                    .accessibilityHint(Text(collapsed ? "Shows the code and output" : "Hides the code and output"))
            }
        }
    }

    private var meta: String? {
        if card.isRunning { return nil }
        if card.isError { return (card.pythonFailure ?? .failed).label }
        if !isImage, collapsed, !card.figures.isEmpty {
            return card.figures.count == 1 ? String(localized: "1 figure") : String(localized: "\(card.figures.count) figures")
        }
        return nil
    }

    private var title: String {
        switch card.kind {
        case .image(let id): card.isRunning ? String(localized: "Viewing \(id)…") : String(localized: "Viewed \(id)")
        default: card.isRunning ? String(localized: "Running Python…") : String(localized: "Ran Python")
        }
    }
}
