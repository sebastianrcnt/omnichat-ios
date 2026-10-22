import SwiftUI

// The in-chat activity feed (see reference/mockups/feed.html and fetchblocks.html): one thought line, then the cards in
// call order: one per web search, and one per run of page reads. Built from `ActivityFeed` values; the full history is
// the Timeline sheet.

// MARK: - Thought line

/// One line above the feed. Working: a pulsing dot and the sentence being thought (crossfading between sentences).
/// Done: "✦ Thought for 31s ›". Tapping it opens the full reasoning.
struct ThoughtLine: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appSettings) private var settings
    let isWorking: Bool
    /// The last line of the finished thinking (done only).
    var line: String?
    var seconds: Double?
    /// The live reasoning (working only).
    var reasoning: ReasoningChunkModel?
    /// Shown until the first sentence arrives ("Thinking", "Searching").
    var placeholder: String
    let action: () -> Void
    var onDetails: (() -> Void)?
    /// What the live line was showing when this round's line took its place (a translation whose sentence the round's
    /// last line isn't translated yet): kept until that translation comes, so the English doesn't flash in between.
    @State private var carried: String?

    /// - Parameter takesOverLive: this round's line is replacing the live one now (its message is streaming).
    init(isWorking: Bool, line: String? = nil, seconds: Double? = nil, reasoning: ReasoningChunkModel? = nil,
         placeholder: String, takesOverLive: Bool = false, action: @escaping () -> Void, onDetails: (() -> Void)? = nil) {
        self.isWorking = isWorking
        self.line = line
        self.seconds = seconds
        self.reasoning = reasoning
        self.placeholder = placeholder
        self.action = action
        self.onDetails = onDetails
        let untranslated = line.map { ThoughtTranslator.shared.result(for: $0) == nil } ?? false
        _carried = State(initialValue: takesOverLive && untranslated ? ThoughtTranslator.shared.recentlyShown(within: 1.5) : nil)
    }

    var body: some View {
        Button(action: action) {
            // Live and done share one geometry (the mark's slot, the text's width, the chevron's room), so when the
            // live line becomes a round's line its words stay where they were.
            HStack(alignment: .firstTextBaseline, spacing: DS.Feed.iconGap) {
                ZStack {
                    Text(verbatim: "✦").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
                        .opacity(isWorking ? 0 : 1)
                    if isWorking { PulsingDot() }
                }
                .frame(width: DS.Feed.iconColumn)
                if isWorking {
                    // A new preview per state: after a tool, the slot starts from the placeholder, not the old thought.
                    ReasoningLinePreview(model: reasoning, font: DS.Typography.thought, color: theme.textSecondary,
                                         placeholder: placeholder, lines: settings.thinkingLines,
                                         translate: settings.translateThinking)
                        .id(reasoning == nil ? "placeholder" : "reasoning")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(doneTitle).font(DS.Typography.thought).foregroundStyle(theme.textSecondary)
                        .lineLimit(settings.thinkingLines).truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(doneTitle) // a translation arriving rises in
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .quickExit))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.Feed.mark, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    .opacity(isWorking ? 0 : 1)
                Spacer(minLength: 0)
            }
            // A feed line's height and padding, so the thought and the feed under it read as one list.
            .padding(.vertical, DS.Spacing.xs)
            .frame(minHeight: DS.Feed.lineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onDetails { Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails) }
        }
        .accessibilityHint(Text("Shows the full reasoning"))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: doneTitle)
        .task(id: settings.translateThinking ? line : nil) {
            if settings.translateThinking, let line { ThoughtTranslator.shared.request(line) }
        }
    }

    private var doneTitle: String {
        if let line {
            guard settings.translateThinking else { return line }
            // Until the last sentence is translated, what the live line showed stays.
            return ThoughtTranslator.shared.result(for: line) ?? carried ?? line
        }
        guard let seconds else { return String(localized: "Thoughts") }
        return String(localized: "Thought for \(ProcessSummary.duration(seconds))")
    }
}

/// The accent dot that breathes while the model works.
struct PulsingDot: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(theme.textSecondary) // neutral: green is for "live" (the browser view) and the send/stop button
            .frame(width: 8, height: 8)
            .scaleEffect(dim && !reduceMotion ? 0.7 : 1)
            .opacity(dim && !reduceMotion ? 0.3 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Feed

// MARK: - Quiet lines

/// One quiet line of the feed: an icon in the shared column, the title (secondary, like Claude's "Searched the web ›"),
/// small print, and a chevron right after the text that turns down while the line is open (`expanded` nil: none).
struct FeedLine<Icon: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var meta: String?
    var color: Color?
    var expanded: Bool?
    var lineLimit = 1
    @ViewBuilder let icon: () -> Icon
    /// From the title's baseline up to the middle of its lowercase letters: the icon centers there, on the first line.
    @ScaledMetric(relativeTo: .subheadline) private var midline: CGFloat = 5

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Feed.iconGap) {
            icon()
                .frame(width: DS.Feed.iconColumn, height: DS.Feed.iconColumn)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + midline }
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs + DS.Spacing.xxs) {
                Text(title)
                    .font(DS.Typography.thought)
                    .foregroundStyle(color ?? theme.textSecondary)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: lineLimit > 1)
                if let meta, !meta.isEmpty {
                    Text(meta)
                        .font(DS.Typography.feedMeta)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let expanded {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DS.Feed.mark, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Spacing.xs)
        .frame(minHeight: DS.Feed.lineHeight)
        .contentShape(Rectangle())
    }
}

/// A line's SF Symbol, in the secondary color unless told otherwise (the robot check's warning).
struct FeedSymbol: View {
    @Environment(\.theme) private var theme
    let name: String
    var color: Color?

    var body: some View {
        Image(systemName: name)
            .font(.system(size: DS.Feed.icon, weight: .medium))
            .foregroundStyle(color ?? theme.textSecondary)
            .accessibilityHidden(true)
    }
}

/// The small spinner a working line has in its icon column.
struct FeedSpinner: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ProgressView().controlSize(.mini).tint(theme.textSecondary)
    }
}

// MARK: - Feed

/// The cards of one message, as quiet lines; a run of browser calls is one block (`BrowserRun`). Folding follows
/// `FeedCollapse`; a tap opens or folds a line in place.
struct ActivityFeedView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Its chat: the robot checks shown are that chat's own.
    @Environment(\.citations) private var citations
    let cards: [FeedCard]
    let isStreaming: Bool
    let answerStarted: Bool
    /// The site the reply's earlier feeds left the browser on (`BrowserRun.earlierHost`).
    var earlierHost: String?
    var onDetails: () -> Void = {}
    @State private var overrides: [String: FeedCollapse.Override] = [:]
    @State private var showingAll: Set<String> = []
    @State private var stagger = StaggerClock()

    var body: some View {
        let epoch = FeedCollapse.epoch(cardCount: cards.count, isStreaming: isStreaming, answerStarted: answerStarted)
        let live = ActivityFeed.liveBrowserCard(cards, isStreaming: isStreaming, answerStarted: answerStarted)
        let items = BrowserRun.items(cards, earlierHost: earlierHost)
        let indices = Dictionary(cards.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let working = isStreaming && !answerStarted
        VStack(alignment: .leading, spacing: MessageLayout.lineGap) {
            ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                Group {
                    switch item {
                    case .run(let run):
                        // Open while it is the newest thing the reply does; folded otherwise.
                        let auto = !(working && position == items.count - 1)
                        let collapsed = FeedCollapse.isCollapsed(auto: auto, override: overrides[run.id], epoch: epoch)
                        BrowserRunView(run: run, collapsed: collapsed,
                                       live: run.steps.contains { $0.id == live } ? live : nil,
                                       stepCollapsed: { FeedCollapse.isCollapsed(auto: true, override: overrides[$0.id], epoch: epoch) },
                                       onToggleStep: { step in
                                           let current = FeedCollapse.isCollapsed(auto: true, override: overrides[step.id], epoch: epoch)
                                           withAnimation(reduceMotion ? nil : Self.fold) {
                                               overrides[step.id] = FeedCollapse.toggled(auto: true, current: current, epoch: epoch)
                                           }
                                       },
                                       onToggle: { toggle(run.id, auto: auto, current: collapsed, epoch: epoch) },
                                       onDetails: onDetails)
                    case .card(let card):
                        let auto = FeedCollapse.autoCollapsed(index: indices[card.id] ?? 0, cards: cards, isStreaming: isStreaming,
                                                              answerStarted: answerStarted)
                        let collapsed = FeedCollapse.isCollapsed(auto: auto, override: overrides[card.id], epoch: epoch)
                        cardView(card, collapsed: collapsed,
                                 toggle: { toggle(card.id, auto: auto, current: collapsed, epoch: epoch) })
                    }
                }
                .modifier(StaggerIn(animates: isStreaming && !reduceMotion, clock: stagger))
            }
            // A tool of this reply stopped at a robot check (another chat's check waits in that chat).
            if working {
                ForEach(RobotCheckRequests.shared.pending(for: citations.conversationID)) { request in
                    RobotCheckPromptCard(request: request)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: String, auto: Bool, current: Bool, epoch: Int) {
        withAnimation(reduceMotion ? nil : Self.fold) {
            overrides[id] = FeedCollapse.toggled(auto: auto, current: current, epoch: epoch)
        }
    }

    @ViewBuilder
    private func cardView(_ card: FeedCard, collapsed: Bool, toggle: @escaping () -> Void) -> some View {
        switch card.kind {
        case .python, .image:
            PythonFeedCard(card: card, collapsed: collapsed, onToggle: toggle, onDetails: onDetails)
        case .browser, .script, .browserAction:
            // Always inside a run; kept for completeness.
            BrowserRunView(run: BrowserRun(steps: [card]), collapsed: collapsed, onToggle: toggle, onDetails: onDetails)
        case .note:
            ToolNoteFeedCard(card: card, onDetails: onDetails)
        case .places:
            PlacesFeedCard(card: card, onDetails: onDetails)
        case .artifact:
            ArtifactFeedCard(card: card, onDetails: onDetails)
        case .ssh:
            SSHFeedCard(card: card, collapsed: collapsed, onToggle: toggle, onDetails: onDetails)
        case .health:
            HealthFeedCard(card: card, collapsed: collapsed, onToggle: toggle, onDetails: onDetails)
        case .search, .pages, .transcripts:
            FeedCardView(card: card, collapsed: collapsed, showAll: showingAll.contains(card.id), staggerRows: isStreaming,
                         onToggle: toggle,
                         onShowAll: { // toggles: "+N more" expands, "Show less" folds back
                             withAnimation(reduceMotion ? nil : Self.fold) {
                                 if showingAll.remove(card.id) == nil { showingAll.insert(card.id) }
                             }
                         },
                         onDetails: onDetails)
        }
    }

    /// Height change when a card opens or folds (the mockup's 0.45 s ease-out).
    static let fold = Animation.timingCurve(0.3, 0.8, 0.3, 1, duration: 0.45)
}

/// One search (or "Read") card: header line, then result rows revealed one by one.
struct FeedCardView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: FeedCard
    let collapsed: Bool
    let showAll: Bool
    let onToggle: () -> Void
    let onShowAll: () -> Void
    var onDetails: () -> Void
    /// Rows shown so far; they appear one at a time while the turn streams.
    @State private var revealed: Int
    private let staggerRows: Bool

    static let rowStagger: Duration = .milliseconds(150)

    init(card: FeedCard, collapsed: Bool, showAll: Bool, staggerRows: Bool, onToggle: @escaping () -> Void,
         onShowAll: @escaping () -> Void, onDetails: @escaping () -> Void) {
        self.card = card
        self.collapsed = collapsed
        self.showAll = showAll
        self.staggerRows = staggerRows
        self.onToggle = onToggle
        self.onShowAll = onShowAll
        self.onDetails = onDetails
        _revealed = State(initialValue: staggerRows ? 0 : Int.max)
    }

    private var rows: [FeedRow] { card.visibleResults(expanded: showAll) + card.extras }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed && !card.rows.isEmpty {
                rowList
                    .padding(.leading, DS.Feed.textInset)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : ActivityFeedView.fold, value: collapsed)
        .contextMenu {
            Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails)
        }
        .task(id: rows.count) { await revealRows() }
    }

    // MARK: Header

    private var header: some View {
        Button(action: onToggle) {
            FeedLine(title: title, meta: summary, expanded: card.isRunning || card.isError ? nil : !collapsed) {
                if card.isRunning || (collapsed && card.hasLoadingRow) { FeedSpinner() }
                else { FeedSymbol(name: symbol) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(Text(collapsed ? "Collapsed" : "Expanded"))
        .accessibilityHint(Text(collapsed ? "Shows the results" : "Hides the results"))
    }

    private var symbol: String {
        switch card.kind {
        case .pages: "doc.text"
        case .transcripts: "captions.bubble"
        default: "magnifyingglass"
        }
    }

    private var title: String {
        switch card.kind {
        case .search(let query): query
        case .pages:
            card.hasLoadingRow
                ? (card.extras.count == 1 ? String(localized: "Reading 1 page…") : String(localized: "Reading \(card.extras.count) pages…"))
                : (card.extras.count == 1 ? String(localized: "Read 1 page") : String(localized: "Read \(card.extras.count) pages"))
        case .transcripts:
            card.hasLoadingRow
                ? (card.extras.count == 1 ? String(localized: "Reading transcript…") : String(localized: "Reading \(card.extras.count) transcripts…"))
                : (card.extras.count == 1 ? String(localized: "Read transcript") : String(localized: "Read \(card.extras.count) transcripts"))
        case .python: String(localized: "Ran Python")
        case .image(let id): String(localized: "Viewed \(id)")
        case .browser, .script, .browserAction, .note, .places, .artifact, .ssh, .health: ""
        }
    }

    private var accessibilityTitle: String {
        switch card.kind {
        case .search(let query): String(localized: "Search: \(query)")
        case .pages: String(localized: "Pages read")
        case .transcripts: String(localized: "Transcripts read")
        case .python: String(localized: "Ran Python")
        case .image(let id): String(localized: "Viewed \(id)")
        case .browser, .script, .browserAction, .note, .places, .artifact, .ssh, .health: ""
        }
    }

    /// "Bing · 8 results"; for pages and transcripts, "1 failed" (the title already counts them).
    private var summary: String {
        if card.isError && !card.isRunning { return String(localized: "Failed") }
        if card.isRunning { return "" }
        switch card.kind {
        case .pages, .transcripts:
            return card.failedCount > 0 ? String(localized: "\(card.failedCount) failed") : ""
        case .python, .image, .browser, .script, .browserAction, .note, .places, .artifact, .ssh, .health:
            return ""
        case .search:
            let count = card.results.count == 1 ? String(localized: "1 result") : String(localized: "\(card.results.count) results")
            guard let engine = card.engine else { return count }
            return String(localized: "\(engine) · \(count)")
        }
    }

    // MARK: Rows

    private var rowList: some View {
        let results = card.visibleResults(expanded: showAll)
        let visible = min(revealed, results.count + card.extras.count)
        let hidden = card.hiddenCount(expanded: showAll)
        let foldable = showAll && card.hiddenCount(expanded: false) > 0
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(results.prefix(visible)) { row in
                FeedRowView(row: row).transition(rowTransition)
            }
            if (hidden > 0 || foldable) && visible >= results.count {
                Button(action: onShowAll) {
                    Text(foldable ? "Show less" : "+\(hidden) more")
                }
                .buttonStyle(.quietLink(.secondary))
                .padding(.vertical, -(DS.IconSize.minHitTarget - DS.Feed.lineHeight) / 2)
                .transition(.opacity)
            }
            // A "Read pages" card's rows; a failed one whose page was kept can open it.
            ForEach(card.extras.prefix(max(0, visible - results.count))) { row in
                VStack(alignment: .leading, spacing: 0) {
                    FeedRowView(row: row)
                    if row.read == .failed, let callID = row.callID {
                        KeptPageLink(callID: callID)
                            .padding(.leading, FeedRowView.textInset)
                            .padding(.vertical, -(DS.IconSize.minHitTarget - DS.Feed.lineHeight) / 2)
                    }
                }
                .transition(rowTransition)
            }
        }
        .padding(.bottom, DS.Spacing.xs)
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 5))
    }

    /// Reveals rows one by one (150 ms apart) while the turn streams; finished messages show them all at once.
    private func revealRows() async {
        let total = rows.count
        guard revealed < total else { return }
        guard staggerRows, !reduceMotion else { revealed = Int.max; return }
        while revealed < total {
            withAnimation(.easeOut(duration: 0.4)) { revealed += 1 }
            try? await Task.sleep(for: Self.rowStagger)
            if Task.isCancelled { return }
        }
    }
}

/// A result row: favicon, title, domain. Rows the model read keep the primary text color while the others are dimmed;
/// a read in progress ends in a ring, and one that failed in a gray cross.
struct FeedRowView: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    let row: FeedRow

    static let favicon: CGFloat = DS.IconSize.sm
    static let gap: CGFloat = DS.Spacing.sm
    /// Where a row's title starts, from the row's leading edge.
    static let textInset: CGFloat = favicon + gap

    var body: some View {
        let read = row.read == .read || row.read == .thin
        let failed = row.read == .failed
        Button {
            if let url = URL(string: row.url) { openURL(url) }
        } label: {
            HStack(spacing: Self.gap) {
                FaviconView(host: row.host, size: Self.favicon, square: true)
                    .opacity(read ? 1 : 0.6)
                Text(row.title)
                    .font(DS.Typography.feed)
                    .foregroundStyle(read || row.read?.isFinished == false ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A failed read says why in place of the domain.
                Text(failed ? (row.failure ?? .failed).label : DomainFormatter.short(row.host))
                    .font(DS.Typography.feedMeta)
                    .foregroundStyle(read ? theme.textSecondary : theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 92, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                if let mark = row.read, !mark.isFinished || failed { ReadStatusMark(read: mark) }
            }
            .opacity(failed ? 0.7 : 1)
            .padding(.vertical, DS.Spacing.xs + DS.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(row.title))
        .accessibilityValue(Text(statusLabel))
        .animation(.easeOut(duration: 0.25), value: row.read)
    }

    private var statusLabel: String {
        switch row.read {
        case nil: DomainFormatter.short(row.host)
        case .loading?: String(localized: "Reading")
        case .read?: String(localized: "Read")
        case .thin?: String(localized: "Little content")
        case .failed?: String(localized: "Couldn't read") + ": " + (row.failure ?? .failed).label
        }
    }
}

/// The mark at a read row's end: progress while loading, a quiet gray cross when the page could not be read. A page
/// that was read needs no mark; its row simply stays undimmed.
struct ReadStatusMark: View {
    @Environment(\.theme) private var theme
    let read: FeedRead

    var body: some View {
        Group {
            switch read {
            case .loading(let id):
                ReadProgressRing(callID: id)
            case .read, .thin:
                EmptyView()
            case .failed:
                Image(systemName: "xmark").font(.system(size: DS.IconSize.feedStatus - 4, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .font(.system(size: DS.IconSize.feedStatus))
        .frame(width: DS.IconSize.feedStatus, height: DS.IconSize.feedStatus)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .id(read.isFinished)
    }
}

/// A small ring: the fetch's own progress when it reports one, otherwise spinning.
struct ReadProgressRing: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.citations) private var citations
    let callID: String
    @State private var spin = false

    var body: some View {
        let progress = ToolProgress.shared.value(for: callID, conversation: citations.conversationID)
        ZStack {
            Circle().stroke(theme.textTertiary.opacity(0.35), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.18, progress ?? 0.25))
                .stroke(theme.textSecondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .rotationEffect(.degrees(progress == nil && spin ? 360 : 0))
                .animation(.linear(duration: 0.18), value: progress)
        }
        .frame(width: DS.IconSize.feedStatus - 1, height: DS.IconSize.feedStatus - 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

// MARK: - Previews

#Preview("Dark · Purple") { feedPreview.previewStyle(.dark) }
#Preview("Light · Purple") { feedPreview.previewStyle(.light) }
#Preview("Dark · Orange") { feedPreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }

@MainActor private var feedPreview: some View {
    let sources: [Int: SourceInfo] = [
        1: .init(id: 1, title: "2024년 출생통계(확정) 보도자료", url: "https://kostat.go.kr/a", snippet: ""),
        2: .init(id: 2, title: "출산율 9년 만에 반등… 원인은 혼인 증가", url: "https://www.hani.co.kr/b", snippet: ""),
        3: .init(id: 3, title: "합계출산율 0.75명, 바닥 찍었나", url: "https://www.chosun.com/c", snippet: ""),
        4: .init(id: 4, title: "저출산 원인 분석 - 위키백과", url: "https://ko.wikipedia.org/d", snippet: ""),
        5: .init(id: 5, title: "2024 출생아 수 그래프 한눈에 보기", url: "https://naver.com/e", snippet: ""),
        6: .init(id: 6, title: "합계출산율 국가별 비교", url: "https://oecd.org/f", snippet: ""),
        7: .init(id: 7, title: "South Korea's birth rate rises for first time in nine years", url: "https://www.reuters.com/g", snippet: ""),
    ]
    let calls: [FeedCall] = [
        .init(id: "s1", isSearch: true, argument: "2024 합계출산율 반등 원인", status: .done, sourceIDs: [1, 2, 3, 4, 5, 6], engine: "Naver"),
        .init(id: "f1", isSearch: false, argument: "https://kostat.go.kr/a", status: .done),
        .init(id: "f2", isSearch: false, argument: "https://hani.co.kr/b", status: .running),
        .init(id: "f3", isSearch: false, argument: "https://chosun.com/c", status: .failed),
        .init(id: "s2", isSearch: true, argument: "South Korea fertility rate 2024 rebound marriages", status: .done, sourceIDs: [7], engine: "Bing"),
    ]
    return ScrollView {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ThoughtLine(isWorking: false, seconds: 31, placeholder: "Thinking", action: {})
            ActivityFeedView(cards: ActivityFeed.cards(calls: calls, sources: sources), isStreaming: true, answerStarted: false)
        }
        .padding()
    }
}

/// Hands out start times so cards that appear together (a round asking for three searches) rise one after another.
@MainActor
final class StaggerClock {
    static let step = 0.08
    private var next = Date.distantPast

    /// The delay for a card appearing now: none if the last one came a step ago or more.
    func claim() -> Double {
        let now = Date()
        let start = max(now, next)
        next = start.addingTimeInterval(Self.step)
        return start.timeIntervalSince(now)
    }
}

/// A live card rises into place after the cards that appeared just before it (`StaggerClock`). Cards of a finished
/// message are simply there.
private struct StaggerIn: ViewModifier {
    let animates: Bool
    let clock: StaggerClock
    @State private var shown: Bool

    init(animates: Bool, clock: StaggerClock) {
        self.animates = animates
        self.clock = clock
        _shown = State(initialValue: !animates)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                withAnimation(DS.Motion.enter.delay(clock.claim())) { shown = true }
            }
    }
}
