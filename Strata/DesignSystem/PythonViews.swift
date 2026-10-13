import SwiftUI

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

/// One figure, full size: fits the sheet, and zooms on a Mac/iPad-style pinch or a double tap.
struct ToolImageViewer: View {
    @Environment(\.theme) private var theme
    let image: ToolImage
    @State private var loaded: PlatformImage?
    @State private var zoomed = false

    var body: some View {
        SheetScaffold(title: LocalizedStringKey(image.id)) {
            Group {
                if let loaded {
                    let picture = Image(platformImage: loaded).resizable().interpolation(.high)
                    if zoomed {
                        ScrollView([.horizontal, .vertical]) {
                            picture.frame(width: CGFloat(image.width), height: CGFloat(image.height))
                        }
                    } else {
                        picture.scaledToFit().frame(maxWidth: .infinity)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .onTapGesture(count: 2) { zoomed.toggle() }
            Text(verbatim: "\(image.width) × \(image.height)")
                .font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
        }
        .presentationDetents([.large])
        .task(id: image.file) { loaded = await ToolImageCache.image(for: image) }
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
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(theme.separator, lineWidth: 1)
        }
        .animation(reduceMotion ? nil : ActivityFeedView.fold, value: collapsed)
        .contextMenu {
            Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails)
        }
    }

    private var isImage: Bool { if case .image = card.kind { true } else { false } }

    private var header: some View {
        let row = HStack(spacing: DS.Spacing.sm) {
            Image(systemName: isImage ? "photo" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 18)
            Text(title)
                .font(DS.Typography.feedEmphasis)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.sm)
            trailing.fixedSize()
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        return Group {
            if isImage {
                row.accessibilityElement(children: .combine)
            } else {
                Button(action: onToggle) { row }
                    .buttonStyle(.plain)
                    .accessibilityValue(Text(collapsed ? "Collapsed" : "Expanded"))
                    .accessibilityHint(Text(collapsed ? "Shows the code and output" : "Hides the code and output"))
            }
        }
    }

    private var title: String {
        switch card.kind {
        case .image(let id): card.isRunning ? String(localized: "Viewing \(id)…") : String(localized: "Viewed \(id)")
        default: card.isRunning ? String(localized: "Running Python…") : String(localized: "Ran Python")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if card.isRunning {
            ProgressView().controlSize(.mini)
        } else if card.isError {
            Text((card.pythonFailure ?? .failed).label).font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
        } else if isImage, let image = card.figures.first {
            ToolImageThumbnail(image: image, height: 28)
        } else {
            HStack(spacing: DS.Spacing.xs + 2) {
                if collapsed, !card.figures.isEmpty {
                    Text(card.figures.count == 1 ? String(localized: "1 figure") : String(localized: "\(card.figures.count) figures"))
                        .font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
        }
    }
}
