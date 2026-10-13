import SwiftUI

// The in-chat activity feed (see reference/mockups/feed.html): one thought line, then a card per web search whose
// result rows show the pages the model read. Built from `ActivityFeed` values; the full history is the Timeline sheet.

// MARK: - Thought line

/// One line above the feed. Working: a pulsing dot and the sentence being thought (crossfading between sentences).
/// Done: "✦ Thought for 31s ›". Tapping it opens the full reasoning.
struct ThoughtLine: View {
    @Environment(\.theme) private var theme
    let isWorking: Bool
    var seconds: Double?
    /// The live reasoning (working only).
    var reasoning: ReasoningChunkModel?
    /// Shown until the first sentence arrives ("Thinking", "Searching").
    var placeholder: String
    let action: () -> Void
    var onDetails: (() -> Void)?

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                if isWorking {
                    PulsingDot()
                    ReasoningLinePreview(model: reasoning, font: DS.Typography.thought, color: theme.textSecondary,
                                         placeholder: placeholder)
                } else {
                    Text(verbatim: "✦").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
                    Text(doneTitle).font(DS.Typography.thought).foregroundStyle(theme.textSecondary).lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: DS.IconSize.sm - 3, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    Spacer(minLength: 0)
                }
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onDetails { Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails) }
        }
        .accessibilityHint(Text("Shows the full reasoning"))
    }

    private var doneTitle: String {
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
            .fill(theme.accent)
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

/// The cards of one message. Folding follows `FeedCollapse`; a tap opens or folds a card in place.
struct ActivityFeedView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let cards: [FeedCard]
    let isStreaming: Bool
    let answerStarted: Bool
    var onDetails: () -> Void = {}
    @State private var overrides: [String: FeedCollapse.Override] = [:]
    @State private var showingAll: Set<String> = []

    var body: some View {
        let epoch = FeedCollapse.epoch(cardCount: cards.count, isStreaming: isStreaming, answerStarted: answerStarted)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                let auto = FeedCollapse.autoCollapsed(index: index, cards: cards, isStreaming: isStreaming, answerStarted: answerStarted)
                let collapsed = FeedCollapse.isCollapsed(auto: auto, override: overrides[card.id], epoch: epoch)
                FeedCardView(card: card, collapsed: collapsed, showAll: showingAll.contains(card.id), staggerRows: isStreaming,
                             onToggle: {
                                 withAnimation(reduceMotion ? nil : Self.fold) {
                                     overrides[card.id] = FeedCollapse.toggled(auto: auto, current: collapsed, epoch: epoch)
                                 }
                             },
                             onShowAll: { // toggles: "+N more" expands, "Show less" folds back
                                 withAnimation(reduceMotion ? nil : Self.fold) {
                                     if showingAll.remove(card.id) == nil { showingAll.insert(card.id) }
                                 }
                             },
                             onDetails: onDetails)
                    .transition(.enter(reduceMotion: reduceMotion))
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.enter, value: cards.map(\.id))
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .task(id: rows.count) { await revealRows() }
    }

    // MARK: Header

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: card.kind == .pages ? "doc.text" : "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(DS.Typography.feedEmphasis)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: DS.Spacing.sm)
                trailing.fixedSize()
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(Text(collapsed ? "Collapsed" : "Expanded"))
        .accessibilityHint(Text(collapsed ? "Shows the results" : "Hides the results"))
    }

    private var title: String {
        switch card.kind {
        case .search(let query): query
        case .pages: String(localized: "Read pages · \(card.extras.count)")
        }
    }

    private var accessibilityTitle: String {
        switch card.kind {
        case .search(let query): String(localized: "Search: \(query)")
        case .pages: String(localized: "Pages read")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if card.isRunning {
            ProgressView().controlSize(.mini)
        } else if card.isError {
            Text("Failed").font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
        } else if collapsed {
            HStack(spacing: DS.Spacing.xs + 2) {
                if card.hasLoadingRow { ProgressView().controlSize(.mini) }
                Text(summary).font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary).lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
        } else if card.isReading || card.engine != nil {
            HStack(spacing: DS.Spacing.xs + 2) {
                // "2 read · 8" once the card's pages are being read.
                if card.isReading {
                    Text("\(card.readCount) read · \(card.results.count)")
                        .font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary).lineLimit(1)
                }
                if let engine = card.engine { engineBadge(engine) }
            }
        }
    }

    private func engineBadge(_ engine: String) -> some View {
        Text(engine)
            .font(DS.Typography.feedBadge)
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(theme.separator, lineWidth: 1) }
    }

    /// "Naver · 2 read", "Bing · 8 results", "2 pages".
    private var summary: String {
        let read = card.readCount
        switch card.kind {
        case .pages:
            return card.rows.count == 1 ? String(localized: "1 page") : String(localized: "\(card.rows.count) pages")
        case .search:
            let count = read > 0 ? String(localized: "\(read) read")
                : (card.results.count == 1 ? String(localized: "1 result") : String(localized: "\(card.results.count) results"))
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
                    Text(foldable ? "Show less" : card.isReading ? "+ \(hidden) more results" : "+\(hidden) more")
                        .font(DS.Typography.feed)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, DS.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            // A "Read pages" card's rows.
            ForEach(card.extras.prefix(max(0, visible - results.count))) { row in
                FeedRowView(row: row).transition(rowTransition)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, DS.Spacing.sm)
        // Reading starts: the read rows move up once (and later reads slide in after them).
        .animation(reduceMotion ? nil : Self.reorder, value: results.map(\.id))
    }

    static let reorder = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.35)

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

    var body: some View {
        let read = row.read == .read || row.read == .thin
        let failed = row.read == .failed
        Button {
            if let url = URL(string: row.url) { openURL(url) }
        } label: {
            HStack(spacing: 9) {
                FaviconView(host: row.host, size: DS.IconSize.feedFavicon, square: true)
                    .opacity(read ? 1 : 0.6)
                Text(row.title)
                    .font(DS.Typography.feed)
                    .foregroundStyle(read || row.read?.isFinished == false ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(DomainFormatter.short(row.host))
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
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
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
        case .failed?: String(localized: "Couldn't read")
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
    let callID: String
    @State private var spin = false

    var body: some View {
        let progress = ToolProgress.shared.value(for: callID)
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
