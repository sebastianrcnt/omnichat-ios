#if DEBUG
import SwiftUI

/// `-StrataActivityGallery 1`: instead of the app, one scrolling page with the activity feed's states (a browser run at
/// work with its live view, a robot check, a failed page that was kept, searches, page reads and other tools) built
/// from sample cards, for simulator screenshots in light and dark. Nothing here runs a tool or touches the network.
struct ActivityGallery: View {
    @Environment(\.theme) private var theme

    static var isRequested: Bool { UserDefaults.standard.integer(forKey: "StrataActivityGallery") > 0 }
    /// `-StrataActivityGallery 2` starts at the second half (failed page, other tools).
    private var secondHalf: Bool { UserDefaults.standard.integer(forKey: "StrataActivityGallery") == 2 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                if !secondHalf { firstHalf }
                secondPart
            }
            .padding(.horizontal, DS.Spacing.page)
            .padding(.vertical, DS.Spacing.xl)
        }
        .background(theme.background)
    }

    @ViewBuilder private var firstHalf: some View {
                section("Working")
                MessageBubble(text: "성수동 조용한 카페 3곳, 네이버 지도 기준")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                ThoughtLine(isWorking: false, seconds: 4, placeholder: "Thinking", action: {})
                VStack(alignment: .leading, spacing: 0) {
                    BrowserRunView(run: BrowserRun(steps: Self.workingSteps), collapsed: false, onToggle: {}, onDetails: {})
                    BrowserLiveStrip(onWatch: {}, onTakeOver: {}, onStop: {}) { SamplePage() }
                        .padding(.top, DS.Spacing.sm)
                        .padding(.leading, DS.Feed.textInset)
                }

                section("Robot check")
                RobotCheckPrompt(host: "blog.naver.com", onOpen: {}, onSkip: {})

    }

    @ViewBuilder private var secondPart: some View {
                section("Failed, page kept")
                VStack(alignment: .leading, spacing: 0) {
                    BrowserRunView(run: BrowserRun(steps: Self.failedSteps), collapsed: true, onToggle: {}, onDetails: {})
                    BrowserStep(card: Self.failedSteps[0], current: false)
                        .padding(.leading, DS.Feed.textInset)
                    // `KeptPageLink` needs a kept page; this is its look.
                    Button("Open this page") {}
                        .buttonStyle(.quietLink(.primary, chevron: true))
                        .padding(.leading, DS.Feed.textInset + DS.Feed.markColumn + DS.Spacing.xs)
                }

                section("Other tools")
                ActivityFeedView(cards: ActivityFeed.cards(calls: Self.otherCalls, sources: Self.sources),
                                 isStreaming: true, answerStarted: false)
                Text("Seongsu has a few quiet cafes that fit: …")
                    .font(DS.Typography.answer)
                    .foregroundStyle(theme.textPrimary)
                section("Pages, open")
                if let pages = ActivityFeed.cards(calls: Self.otherCalls, sources: Self.sources).first(where: { $0.kind == .pages }) {
                    FeedCardView(card: pages, collapsed: false, showAll: false, staggerRows: false, onToggle: {}, onShowAll: {},
                                 onDetails: {})
                }
                if let search = ActivityFeed.cards(calls: Self.otherCalls, sources: Self.sources).first {
                    FeedCardView(card: search, collapsed: false, showAll: false, staggerRows: false, onToggle: {}, onShowAll: {},
                                 onDetails: {})
                }
                section("Folded (finished message)")
                ActivityFeedView(cards: ActivityFeed.cards(calls: Self.otherCalls, sources: Self.sources),
                                 isStreaming: false, answerStarted: true)
                BrowserRunView(run: BrowserRun(steps: Self.workingSteps.map { var c = $0; c.isRunning = false; return c }),
                               collapsed: true, onToggle: {}, onDetails: {})
    }

    private func section(_ title: String) -> some View {
        Text(verbatim: title.uppercased())
            .font(DS.Typography.feedMeta)
            .foregroundStyle(theme.textTertiary)
            .padding(.top, DS.Spacing.sm)
    }

    static var workingSteps: [FeedCard] {
        let skill = FeedCard(id: "k", kind: .note(tool: ToolNames.loadSkill, argument: "naver-places"))
        let open = FeedCard(id: "o", kind: .browser(url: "https://map.naver.com/p/search/%EC%84%B1%EC%88%98"))
        var type = FeedCard(id: "t", kind: .browserAction(tool: ToolNames.browserType, argument: "[5] \u{201C}성수 카페\u{201D}"))
        type.output = "Typed \u{201C}성수 카페\u{201D} into [5] Search places"
        var click = FeedCard(id: "c", kind: .browserAction(tool: ToolNames.browserClick, argument: "[12]"))
        click.output = "Clicked [12] Search"
        let state = FeedCard(id: "s", kind: .browserAction(tool: ToolNames.browserState, argument: ""), isRunning: true)
        return [skill, open, type, click, state]
    }

    static var failedSteps: [FeedCard] {
        var failed = FeedCard(id: "f", kind: .browser(url: "https://www.letskorail.com/ebizprd/EbizPrdTicketpr21100W_pr21110.do"),
                              isError: true)
        failed.pageFailure = .noText
        return [failed]
    }

    static let sources: [Int: SourceInfo] = [
        1: .init(id: 1, title: "성수동 조용한 카페 BEST 7", url: "https://blog.naver.com/cafe/1", snippet: ""),
        2: .init(id: 2, title: "Seongsu cafe guide 2026", url: "https://www.timeout.com/seoul/seongsu", snippet: ""),
        3: .init(id: 3, title: "성수 작업하기 좋은 카페", url: "https://www.mangoplate.com/top_lists/seongsu", snippet: ""),
    ]

    static var otherCalls: [FeedCall] {
        var python = FeedCall(id: "p", isSearch: false, argument: "print(sum(range(10)))", status: .done)
        python.tool = ToolNames.runPython
        python.output = "45"
        return [
            .init(id: "q", isSearch: true, argument: "성수동 조용한 카페", status: .done, sourceIDs: [1, 2, 3], engine: "Naver"),
            .init(id: "r1", isSearch: false, argument: "https://blog.naver.com/cafe/1", status: .done, sourceIDs: [1]),
            .init(id: "r2", isSearch: false, argument: "https://www.mangoplate.com/top_lists/seongsu", status: .failed),
            python,
        ]
    }
}

/// A stand-in for a map page in the live thumbnail.
private struct SamplePage: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(red: 0.01, green: 0.78, blue: 0.35)).frame(height: 12)
            ZStack {
                Color(red: 0.91, green: 0.94, blue: 0.88)
                ForEach(0..<3) { i in
                    Circle().fill(Color(red: 0.01, green: 0.78, blue: 0.35)).frame(width: 6, height: 6)
                        .offset(x: CGFloat(i * 26 - 26), y: CGFloat((i % 2) * 14 - 6))
                }
            }
            .frame(height: 50)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<6) { i in
                    RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(i % 2 == 0 ? 0.55 : 0.2))
                        .frame(width: i % 2 == 0 ? 70 : 90, height: 4)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .background(Color.white)
    }
}
#endif
