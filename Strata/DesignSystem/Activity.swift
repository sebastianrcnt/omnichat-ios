import SwiftUI

// MARK: - Source chips

/// Domain chip with a monogram circle (the host's first letter on an accent-tinted background).
struct SourceChip: View {
    @Environment(\.theme) private var theme
    let host: String
    var url: URL?

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
        .fixedSize() // a chip is one unit: it moves to the next line, it never wraps
        if let url { Link(destination: url) { chip } } else { chip }
    }
}

/// 16 pt circular site icon, loaded lazily; the host's monogram until (or unless) a real icon arrives.
struct FaviconView: View {
    @Environment(\.theme) private var theme
    let host: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: DS.IconSize.favicon, height: DS.IconSize.favicon)
                    .background(theme.faviconBackdrop)
                    .clipShape(Circle())
            } else {
                Text(String(host.first.map { Character($0.uppercased()) } ?? "?"))
                    .font(DS.Typography.monogram)
                    .foregroundStyle(theme.accentOnTint)
                    .frame(width: DS.IconSize.favicon, height: DS.IconSize.favicon)
                    .background(theme.accentMuted, in: Circle())
            }
        }
        .task(id: host) { image = await FaviconImages.image(for: host) }
        .accessibilityHidden(true)
    }
}

/// Decoded icons for the session, so scrolling back never flashes the monogram.
@MainActor
enum FaviconImages {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for host: String) async -> UIImage? {
        guard let key = FaviconStore.key(for: host) else { return nil }
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let data = await FaviconStore.shared.iconData(for: host), let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key as NSString)
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
    let entry: ActivityEntry
    /// Show every source chip (timeline) instead of a single scrolling line.
    var wrapsChips = false

    var body: some View {
        switch entry.kind {
        case .search(let query, let sources):
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.sm) {
                    icon("magnifyingglass")
                    Text("“\(query)”").font(DS.Typography.uiSmall).foregroundStyle(theme.textPrimary).lineLimit(1)
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
                        FlowLayout(spacing: DS.Spacing.xs) { ForEach(sources) { SourceChip(host: $0.host, url: URL(string: $0.url)) } }
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
        case .visit(let url, let host):
            HStack(spacing: DS.Spacing.sm) {
                icon("globe")
                if wrapsChips, let u = URL(string: url) {
                    Text(entry.isContinuation ? "Read more of" : "Visited").font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                    SourceChip(host: host, url: u)
                } else {
                    Text(entry.isContinuation ? "Read more of \(host)" : "Visited \(host)").font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                if entry.isRunning { ProgressView().controlSize(.mini) }
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

// MARK: - Live feed

/// "Thinking · 12s" with the animated mark.
struct ActivityStatusLine: View {
    @Environment(\.theme) private var theme
    let label: String
    let start: Date

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            StreamingIndicator()
            TimelineView(.periodic(from: start, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(start)))
                Text("\(label) · \(seconds)s")
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.accent)
                    .monospacedDigit()
            }
            Image(systemName: "chevron.right")
                .font(.system(size: DS.IconSize.sm, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Status line plus the latest two activity rows in a fixed-height area; older rows fade out upward.
struct LiveActivityFeed: View {
    let label: String
    let start: Date
    let entries: [ActivityEntry]
    /// Live reasoning, for the one-line preview of the latest thought.
    var reasoning: ReasoningChunkModel?
    let action: () -> Void

    /// Status line, the thought slot and two activity rows. The layout never depends on running state.
    static let height: CGFloat = 156
    static let visibleRows = 2

    /// The rows shown: always the latest two. Rows change only when an entry is added; a running entry that
    /// finishes keeps its id and position.
    static func visibleEntries(_ entries: [ActivityEntry]) -> [ActivityEntry] { Array(entries.suffix(visibleRows)) }

    /// The thought text hides while a tool runs, but its slot keeps its height.
    private var thoughtVisible: Bool { (reasoning?.hasContent ?? false) && !entries.contains(where: \.isRunning) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                ActivityStatusLine(label: label, start: start)
                ReasoningLinePreview(model: reasoning, isVisible: thoughtVisible)
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    ForEach(Self.visibleEntries(entries)) { entry in
                        ActivityRow(entry: entry)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)),
                                                    removal: .opacity.combined(with: .move(edge: .top))))
                    }
                }
                .animation(DS.Motion.snappy, value: Self.visibleEntries(entries).map(\.id))
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: Self.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Collapsed summary once the answer starts: "Thought for 4s · 2 searches, 3 pages ›".
struct ActivitySummaryRow: View {
    @Environment(\.theme) private var theme
    let seconds: Double?
    let searches: Int
    let pages: Int
    let action: () -> Void

    static func title(seconds: Double?, searches: Int, pages: Int) -> String {
        var parts: [String] = []
        if let seconds { parts.append(String(localized: "Thought for \(max(1, Int(seconds.rounded())))s")) }
        var counts: [String] = []
        if searches > 0 { counts.append(String(localized: "\(searches) searches")) }
        if pages > 0 { counts.append(String(localized: "\(pages) pages")) }
        if !counts.isEmpty { parts.append(counts.joined(separator: ", ")) }
        return parts.isEmpty ? String(localized: "Thoughts") : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: searches + pages > 0 ? "globe" : "clock")
                    .font(.system(size: DS.IconSize.md)).foregroundStyle(theme.textSecondary)
                Text(Self.title(seconds: seconds, searches: searches, pages: pages))
                    .font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary).lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.IconSize.sm, weight: .semibold)).foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// Sheet with the raw thinking interleaved with tool cards. While live it streams the reasoning with the
/// same reveal pipeline as answers and follows the bottom, until the user scrolls away.
struct TimelineSheet: View {
    @Environment(\.theme) private var theme
    let reasoning: ReasoningChunkModel
    let steps: [ToolStep]
    let pending: [PendingToolCall]
    let sources: [Int: SourceInfo]
    let isLive: Bool
    var seconds: Double?
    @State private var following = true

    /// Finalized paragraphs and tool cards only. The growing tail is a separate view, so streaming never
    /// rebuilds this list. (A tool round flushes the tail first, so the tail is always last.)
    private var items: [TimelineItem] {
        TimelineItem.build(chunks: reasoning.finalized.map(\.text), steps: steps, pending: pending, sources: sources)
    }

    var body: some View {
        SheetScaffold(title: titleKey, followsBottom: $following) {
            ScrollViewReader { proxy in
                let items = items
                if items.isEmpty && reasoning.tail.isEmpty {
                    Text("Waiting for the model to think…")
                        .font(DS.Typography.monoSmall).foregroundStyle(theme.textTertiary)
                }
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    ForEach(items) { item in
                        switch item {
                        case .thinking(let id, let text):
                            ReasoningChunkView(chunk: .init(id: Int(id.dropFirst()) ?? 0, text: text)).equatable()
                        case .activity(let entry):
                            ActivityRow(entry: entry, wrapsChips: true)
                                .padding(DS.Spacing.md)
                                .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
                        }
                    }
                    ReasoningTail(model: reasoning) { follow(proxy) }
                }
                Color.clear.frame(height: 1).id("end")
                    .onChange(of: items) { _, _ in follow(proxy) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func follow(_ proxy: ScrollViewProxy) {
        if isLive && following { proxy.scrollTo("end", anchor: .bottom) }
    }

    private var titleKey: LocalizedStringKey {
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

/// One source: title, domain, snippet, and an Open button.
struct SourceCard: View {
    @Environment(\.theme) private var theme
    let source: SourceInfo
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("[\(source.id)]").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
                Text(source.title).font(DS.Typography.uiEmphasis).foregroundStyle(theme.textPrimary).lineLimit(2)
            }
            SourceChip(host: source.host)
            if !source.snippet.isEmpty {
                Text(source.snippet).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary).lineLimit(6)
            }
            if let url = URL(string: source.url) {
                Button { onOpen(url) } label: {
                    Label("Open", systemImage: "safari").font(DS.Typography.uiSmall)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
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
            LiveActivityFeed(label: "Searching", start: .now.addingTimeInterval(-12), entries: entries) {}
            ActivitySummaryRow(seconds: 4, searches: 2, pages: 3) {}
            SourcesRow(count: 5) {}
            SourceCard(source: sources[0]) { _ in }
            FlowLayout { SourceChip(host: "github.com"); SourceChip(host: "developer.apple.com"); SourceChip(host: "example.org") }
        }
        .padding()
    }
}
