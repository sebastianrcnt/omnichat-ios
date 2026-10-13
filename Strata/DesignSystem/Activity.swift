import SwiftUI

// MARK: - Source chips

/// Domain chip with a monogram circle (the host's first letter on an accent-tinted background).
/// A subtle accent fill that grows from the leading edge of a capsule with `progress`, and an error tint when `isError`.
/// Nil progress draws no fill; going from a value to nil fades the fill out.
struct ProgressFill: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var progress: Double?
    var isError = false

    func body(content: Content) -> some View {
        content.background {
            ZStack(alignment: .leading) {
                if isError { Rectangle().fill(theme.warning.opacity(0.14)) }
                GeometryReader { geo in
                    Rectangle()
                        .fill(theme.accent.opacity(0.18))
                        .frame(width: geo.size.width * (progress ?? 0))
                        .animation(reduceMotion ? nil : .linear(duration: 0.18), value: progress)
                }
                .opacity(progress == nil ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: progress == nil)
            }
            .clipShape(Capsule())
        }
    }
}

extension View {
    func progressFill(_ progress: Double?, isError: Bool = false) -> some View {
        modifier(ProgressFill(progress: progress, isError: isError))
    }
}

struct SourceChip: View {
    @Environment(\.theme) private var theme
    let host: String
    var url: URL?
    /// Fetch progress (0...1) while the page loads.
    var progress: Double?
    var isError = false

    var body: some View {
        let chip = HStack(spacing: DS.Spacing.xs) {
            FaviconView(host: host)
            Text(DomainFormatter.short(host))
                .font(DS.Typography.uiCaption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.leading, DS.Spacing.xs)
        .padding(.trailing, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(theme.chipFill, in: Capsule())
        .progressFill(progress, isError: isError)
        .fixedSize() // a chip is one unit: it moves to the next line, it never wraps
        if let url { Link(destination: url) { chip } } else { chip }
    }
}

/// Site icon, loaded lazily; the host's monogram until (or unless) a real icon arrives. A 16 pt circle by default; the
/// feed's result rows use an 18 pt rounded square.
struct FaviconView: View {
    @Environment(\.theme) private var theme
    let host: String
    var size: CGFloat = DS.IconSize.favicon
    /// Rounded square instead of a circle.
    var square = false
    @State private var image: PlatformImage?

    private var shape: AnyShape {
        square ? AnyShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)) : AnyShape(Circle())
    }

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .background(theme.faviconBackdrop)
                    .clipShape(shape)
            } else {
                Text(String(host.first.map { Character($0.uppercased()) } ?? "?"))
                    .font(DS.Typography.monogram)
                    .foregroundStyle(theme.accentOnTint)
                    .frame(width: size, height: size)
                    .background(theme.accentMuted, in: shape)
            }
        }
        .task(id: host) { image = await FaviconImages.image(for: host) }
        .accessibilityHidden(true)
    }
}

/// Decoded icons for the session, so scrolling back never flashes the monogram.
@MainActor
enum FaviconImages {
    private static let cache = NSCache<NSString, PlatformImage>()
    /// Icons stored since the cache was last emptied (an upper bound: NSCache evicts silently).
    private(set) static var count = 0
    static func purge() { cache.removeAllObjects(); count = 0 }

    static func image(for host: String) async -> PlatformImage? {
        guard let key = FaviconStore.key(for: host) else { return nil }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let data = await FaviconStore.shared.iconData(for: host), let image = PlatformImage(data: data) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        count += 1
        return image
    }
}

// MARK: - Activity model

/// One row in the live feed or the timeline: a search or a page visit.
struct ActivityEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case search(query: String, sources: [SourceInfo])
        case visit(url: String, host: String)
    }
    let id: String
    var kind: Kind
    var isRunning: Bool
    var isError: Bool
    /// A `web_fetch` with an offset: shown as "Read more of <domain>".
    var isContinuation = false
    /// A finished page read: the page's length (the Timeline shows it; the feed shows only a status mark).
    var characters: Int?

    static func host(of url: String) -> String {
        guard let h = URL(string: url)?.host(percentEncoded: false) else { return url }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    init(call: ToolCallRecord, sources: [Int: SourceInfo]) {
        id = call.id
        isRunning = false
        isError = call.isError
        if call.name == ToolNames.webSearch {
            kind = .search(query: call.primaryArgument, sources: call.sourceIDs.compactMap { sources[$0] })
        } else {
            kind = .visit(url: call.primaryArgument, host: Self.host(of: call.primaryArgument))
            isContinuation = call.fetchOffset > 0
            characters = call.fetchedCharacters
        }
    }

    init(pending: PendingToolCall) {
        id = pending.id
        isRunning = true
        isError = false
        if pending.name == ToolNames.webSearch {
            kind = .search(query: pending.primaryArgument, sources: [])
        } else {
            kind = .visit(url: pending.primaryArgument, host: Self.host(of: pending.primaryArgument))
            isContinuation = pending.offset > 0
        }
    }

    /// The running round's calls in request order; a call keeps its place when it finishes.
    static func roundEntries(requested: [PendingToolCall], finished: [ToolCallRecord], sources: [Int: SourceInfo]) -> [ActivityEntry] {
        let done = Dictionary(finished.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return requested.compactMap { call in
            guard seen.insert(call.id).inserted else { return nil }
            if let record = done[call.id] { return ActivityEntry(call: record, sources: sources) }
            return ActivityEntry(pending: call)
        }
    }

    /// Finished calls then running ones. A call keeps the same id while running and when done, and an id
    /// that appears twice (a finished call still listed as running) is shown once.
    static func entries(calls: [ToolCallRecord], pending: [PendingToolCall], sources: [Int: SourceInfo]) -> [ActivityEntry] {
        var seen = Set<String>()
        var out: [ActivityEntry] = []
        for call in calls where seen.insert(call.id).inserted { out.append(ActivityEntry(call: call, sources: sources)) }
        for call in pending where seen.insert(call.id).inserted { out.append(ActivityEntry(pending: call)) }
        return out
    }
}

/// One activity row: search (magnifier, quoted query, result count, source chips) or visit (globe, "Visited domain").
struct ActivityRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: ActivityEntry
    /// Show every source chip (timeline) instead of a single scrolling line.
    var wrapsChips = false

    var body: some View {
        switch entry.kind {
        case .search(let query, let sources):
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.sm) {
                    icon("magnifyingglass")
                    Text(query).font(DS.Typography.uiSmall).foregroundStyle(theme.textPrimary).lineLimit(1)
                    if entry.isRunning {
                        ProgressView().controlSize(.mini)
                    } else if entry.isError {
                        Text("failed").font(DS.Typography.uiCaption).foregroundStyle(theme.warning)
                    } else {
                        Text("\(sources.count) results").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                if !sources.isEmpty {
                    if wrapsChips {
                        // Chips arrive one by one; the card grows with a spring instead of jumping.
                        FlowLayout(spacing: DS.Spacing.xs) {
                            ForEach(Array(sources.enumerated()), id: \.element.id) { i, source in
                                SourceChip(host: source.host, url: URL(string: source.url))
                                    .transition(.chipIn(index: i, reduceMotion: reduceMotion))
                            }
                        }
                        .padding(.top, DS.Spacing.sm)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DS.Spacing.xs) { ForEach(sources) { SourceChip(host: $0.host) } }
                        }
                        .scrollDisabled(true)
                        .mask(alignment: .leading) { TrailingFade() }
                        .padding(.leading, DS.Spacing.xl)
                    }
                }
            }
            .animation(reduceMotion ? nil : DS.Motion.enter, value: sources.count)
        case .visit(let url, let host):
            let progress = ToolProgress.shared.value(for: entry.id)
            HStack(spacing: DS.Spacing.sm) {
                icon("globe")
                if wrapsChips, let u = URL(string: url) {
                    Text(entry.isContinuation ? "Read more of" : "Visited").font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                    SourceChip(host: host, url: u, progress: progress, isError: entry.isError)
                    if let characters = entry.characters {
                        Text("\(characters.formatted()) chars")
                            .font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary).lineLimit(1)
                    }
                } else {
                    Text(entry.isContinuation ? "Read more of \(host)" : "Visited \(host)").font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary).lineLimit(1)
                        .padding(.horizontal, DS.Spacing.sm).padding(.vertical, DS.Spacing.xs)
                        .progressFill(progress, isError: entry.isError)
                        .padding(.horizontal, -DS.Spacing.sm).padding(.vertical, -DS.Spacing.xs)
                }
                if entry.isRunning, progress == nil { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
            }
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: DS.IconSize.sm))
            .foregroundStyle(entry.isError ? theme.warning : theme.textTertiary)
            .frame(width: DS.IconSize.md)
    }
}

/// Opaque mask with a short fade at the right edge, so a clipped chip row reads as scrollable.
struct TrailingFade: View {
    var width: CGFloat = 24
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: width)
        }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = DS.Spacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (i, origin) in result.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

// MARK: - Timeline

enum TimelineItem: Identifiable, Equatable {
    case thinking(id: String, text: String)
    case activity(ActivityEntry)

    var id: String {
        switch self {
        case .thinking(let id, _): id
        case .activity(let e): e.id
        }
    }

    /// Interleave raw thinking paragraphs with tool activity in stream order.
    /// A step's `reasoningParagraphs` is how many paragraphs came before it; running calls come last.
    static func build(chunks: [String], steps: [ToolStep], pending: [PendingToolCall], sources: [Int: SourceInfo]) -> [TimelineItem] {
        var items: [TimelineItem] = []
        var p = 0
        func emitChunks(upTo limit: Int) {
            while p < min(limit, chunks.count) { items.append(.thinking(id: "t\(p)", text: chunks[p])); p += 1 }
        }
        for step in steps {
            emitChunks(upTo: step.reasoningParagraphs)
            for call in step.calls { items.append(.activity(ActivityEntry(call: call, sources: sources))) }
        }
        emitChunks(upTo: chunks.count)
        for call in pending { items.append(.activity(ActivityEntry(pending: call))) }
        return items
    }
}

/// Consecutive thinking paragraphs form one block; tool calls are their own cards.
enum TimelineGroup: Identifiable, Equatable {
    case thinking(id: String, chunks: [ReasoningChunkModel.Chunk])
    case activity(ActivityEntry)

    var id: String {
        switch self {
        case .thinking(let id, _): id
        case .activity(let e): e.id
        }
    }

    static func group(_ items: [TimelineItem]) -> [TimelineGroup] {
        var out: [TimelineGroup] = []
        for item in items {
            switch item {
            case .thinking(let id, let text):
                let chunk = ReasoningChunkModel.Chunk(id: Int(id.dropFirst()) ?? 0, text: text)
                if case .thinking(let gid, let chunks)? = out.last { out[out.count - 1] = .thinking(id: gid, chunks: chunks + [chunk]) }
                else { out.append(.thinking(id: id, chunks: [chunk])) }
            case .activity(let entry):
                out.append(.activity(entry))
            }
        }
        return out
    }
}

/// At most one animated follow-scroll per interval, with a trailing one so the last growth is never missed.
struct FollowThrottle: Equatable {
    var minInterval: Double = 0.1
    private var last: Double?

    /// Returns 0 to follow now, or the delay after which to try again.
    mutating func request(now: Double) -> Double {
        guard let last else { self.last = now; return 0 }
        let wait = last + minInterval - now
        if wait <= 0 { self.last = now; return 0 }
        return wait
    }
}

/// A thinking block: the card the Timeline shows for a stretch of reasoning. While live, the growing tail sits inside it.
private struct ThinkingBlock: View {
    @Environment(\.theme) private var theme
    let chunks: [ReasoningChunkModel.Chunk]
    var live: ReasoningChunkModel?
    var onGrow: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "clock").font(.system(size: DS.IconSize.sm)).foregroundStyle(theme.textTertiary)
                Text("Thinking").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
            }
            ForEach(chunks) { ReasoningChunkView(chunk: $0).equatable() }
            if let live { ReasoningTail(model: live, onGrow: onGrow) }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }
}

/// Sheet with the raw thinking interleaved with tool cards. While live it streams the reasoning with the
/// same reveal pipeline as answers and follows the bottom, until the user scrolls away.
struct TimelineSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reasoning: ReasoningChunkModel
    let steps: [ToolStep]
    let pending: [PendingToolCall]
    let sources: [Int: SourceInfo]
    let isLive: Bool
    var seconds: Double?
    /// False: the reasoning alone (from the thought line); true: reasoning and every tool call.
    var showsTools = true
    @State private var following = true
    @State private var throttle = FollowThrottle()
    @State private var trailing: Task<Void, Never>?

    /// Finalized paragraphs and tool cards only. The growing tail is a separate view, so streaming never
    /// rebuilds this list. (A tool round flushes the tail first, so the tail is always last.)
    private var items: [TimelineItem] {
        TimelineItem.build(chunks: reasoning.finalized.map(\.text), steps: showsTools ? steps : [],
                           pending: showsTools ? pending : [], sources: sources)
    }

    var body: some View {
        SheetScaffold(title: titleKey, followsBottom: $following) {
            ScrollViewReader { proxy in
                let groups = TimelineGroup.group(items)
                let tailInLast: Bool = { if case .thinking? = groups.last { return true } else { return false } }()
                let visibleTail = ReasoningDisplay.isVisible(reasoning.tail)
                if groups.isEmpty && !visibleTail {
                    Text("Waiting for the model to think…")
                        .font(DS.Typography.uiSmall).foregroundStyle(theme.textTertiary)
                }
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        Group {
                            switch group {
                            case .thinking(_, let chunks):
                                ThinkingBlock(chunks: chunks, live: index == groups.count - 1 && tailInLast ? reasoning : nil) { follow(proxy) }
                            case .activity(let entry):
                                ActivityCard(entry: entry)
                            }
                        }
                        .transition(.enter(reduceMotion: reduceMotion))
                    }
                    if !tailInLast && visibleTail {
                        ThinkingBlock(chunks: [], live: reasoning) { follow(proxy) }
                            .transition(.enter(reduceMotion: reduceMotion))
                    }
                }
                .animation(reduceMotion ? nil : DS.Motion.enter, value: groups.map(\.id))
                Color.clear.frame(height: 1).id("end")
                    .onChange(of: groups.map(\.id)) { _, _ in follow(proxy) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { trailing?.cancel() }
    }

    /// Animated follow-scroll, coalesced to one per ~100 ms; Reduce Motion scrolls instantly.
    private func follow(_ proxy: ScrollViewProxy) {
        guard isLive && following else { return }
        let wait = throttle.request(now: ProcessInfo.processInfo.systemUptime)
        if wait <= 0 {
            withAnimation(reduceMotion ? nil : DS.Motion.follow) { proxy.scrollTo("end", anchor: .bottom) }
        } else if trailing == nil {
            trailing = Task { @MainActor in
                try? await Task.sleep(for: .seconds(wait))
                trailing = nil
                guard !Task.isCancelled else { return }
                follow(proxy)
            }
        }
    }

    private var titleKey: LocalizedStringKey {
        if !showsTools {
            if isLive { return "Thinking…" }
            if let seconds { return "Thought for \(max(1, Int(seconds.rounded())))s" }
            return "Thoughts"
        }
        if isLive { return "Working…" }
        if let seconds { return "Thought for \(max(1, Int(seconds.rounded())))s" }
        return "Timeline"
    }
}

// MARK: - Sources & citations

/// "Sources ›" row at the end of an answer that used tools.
struct SourcesRow: View {
    @Environment(\.theme) private var theme
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "link").font(.system(size: DS.IconSize.md)).foregroundStyle(theme.textSecondary)
                Text("Sources").font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                Text("\(count)").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.IconSize.sm, weight: .semibold)).foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One source: title, domain and snippet. The whole card opens the page (in-app browser on iPhone, default browser on a
/// Mac); its context menu copies the link or opens it in the system browser.
struct SourceCard: View {
    @Environment(\.theme) private var theme
    let source: SourceInfo
    let onOpen: (URL) -> Void

    var body: some View {
        let url = URL(string: source.url)
        let card = VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("[\(source.id)]").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
                Text(source.title).font(DS.Typography.uiEmphasis).foregroundStyle(theme.textPrimary).lineLimit(2)
            }
            SourceChip(host: source.host)
            if !source.snippet.isEmpty {
                Text(source.snippet).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary).lineLimit(6)
            }
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        if let url {
            Button { onOpen(url) } label: { card }
                .buttonStyle(SourceCardButtonStyle())
                .contextMenu {
                    Button("Copy Link", systemImage: "doc.on.doc") { Pasteboard.copy(url.absoluteString) }
                    #if os(iOS)
                    Button("Open in Safari", systemImage: "safari") { InAppBrowser.openExternally(url) }
                    #else
                    Button("Open in Browser", systemImage: "safari") { InAppBrowser.openExternally(url) }
                    #endif
                }
                .accessibilityHint(Text("Opens the page"))
        } else {
            card.background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
    }
}

/// The card's surface, a shade darker (and a little smaller) while pressed.
private struct SourceCardButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? theme.surfaceRaised : theme.surface,
                        in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
            #if os(iOS)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: DS.Radius.lg))
            #endif
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: configuration.isPressed)
    }
}

/// Sheet for tapped citation chips (title, domain, snippet, Open) and the answer's Sources list.
struct SourcesSheet: View {
    let title: LocalizedStringKey
    let sources: [SourceInfo]
    var body: some View {
        SheetScaffold(title: title) {
            ForEach(sources) { source in
                SourceCard(source: source) { InAppBrowser.present($0) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Previews

#Preview("Light · Purple") { activityPreview.previewStyle(.light) }
#Preview("Dark · Purple") { activityPreview.previewStyle(.dark) }
#Preview("Dark · Orange") { activityPreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }

@MainActor private var previewSources: [SourceInfo] {
    [SourceInfo(id: 1, title: "Applying Liquid Glass", url: "https://developer.apple.com/documentation/swiftui", snippet: "Configure, combine, and morph views."),
     SourceInfo(id: 2, title: "Hacking with Swift", url: "https://www.hackingwithswift.com/", snippet: "Learn SwiftUI.")]
}

#Preview("Timeline · Dark") { timelinePreview.previewStyle(.dark) }
#Preview("Timeline · Light · Orange") { timelinePreview.previewStyle(.light, accent: Color(hex: "#F97316")) }
#Preview("Sources sheet · Dark") { SourcesSheet(title: "Sources", sources: previewSources).previewStyle(.dark) }

@MainActor private var timelinePreview: some View {
    let sources = Dictionary(uniqueKeysWithValues: previewSources.map { ($0.id, $0) })
    let call = ToolCallRecord(id: "a", name: "web_search", arguments: "{\"query\":\"liquid glass\"}", result: "", isError: false, sourceIDs: [1, 2])
    return TimelineSheet(reasoning: ReasoningChunkModel(text: "The user wants current information.\n\nI should search first.\n\nNow compare the results"),
                         steps: [ToolStep(assistantContent: "", calls: [call], reasoningParagraphs: 2)],
                         pending: [.init(id: "b", name: "web_fetch", primaryArgument: "https://developer.apple.com/documentation/swiftui")],
                         sources: sources, isLive: true)
}

@MainActor private var activityPreview: some View {
    let sources = previewSources
    let entries = [
        ActivityEntry(call: .init(id: "a", name: "web_search", arguments: "{\"query\":\"liquid glass\"}", result: "", isError: false, sourceIDs: [1, 2]),
                      sources: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })),
        ActivityEntry(pending: .init(id: "b", name: "web_fetch", primaryArgument: "https://developer.apple.com/documentation/swiftui")),
    ]
    return ScrollView {
        VStack(alignment: .leading, spacing: DS.Spacing.xl) {
            ForEach(entries) { ActivityCard(entry: $0) }
            SourcesRow(count: 5) {}
            SourceCard(source: sources[0]) { _ in }
            FlowLayout { SourceChip(host: "github.com"); SourceChip(host: "developer.apple.com"); SourceChip(host: "example.org") }
        }
        .padding()
    }
}
