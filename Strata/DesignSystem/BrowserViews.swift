import SwiftUI

// The browser's part of the feed, in the quiet style (reference/mockups activity.html, variant A): a run of browser calls
// is one summary line ("Browsing map.naver.com ›") with its steps under it, then the live view as a small portrait
// thumbnail with text links beside it. Robot checks and failed pages are a line and text links too. Monochrome: the
// warning triangle and the live dot are the only colors, and every text starts at `DS.Feed.textInset`.

/// Consecutive browser calls of a feed (and the one-line notes among them, like "Loaded skill naver-places"), shown as
/// one block. Pure, built from the feed's cards on every render.
struct BrowserRun: Identifiable, Equatable {
    var steps: [FeedCard]
    /// The site an earlier run of the reply was on, for a run that names no page of its own (clicks only, or still
    /// running): it is still on that site, so it says "Browsing naver.com" rather than "Using the browser".
    var earlierHost: String?
    var id: String { "run-" + (steps.first?.id ?? "") }

    enum Item: Identifiable, Equatable {
        case card(FeedCard)
        case run(BrowserRun)
        var id: String {
            switch self {
            case .card(let card): card.id
            case .run(let run): run.id
            }
        }
    }

    static func isBrowser(_ card: FeedCard) -> Bool {
        switch card.kind {
        case .browser, .script, .browserAction: true
        default: false
        }
    }

    /// The feed's cards with each run of browser calls (notes may sit among them) folded into one item. A run of notes
    /// alone stays as single lines.
    static func items(_ cards: [FeedCard], earlierHost: String? = nil) -> [Item] {
        var items: [Item] = []
        var pending: [FeedCard] = []
        var host = earlierHost
        func flush() {
            if pending.contains(where: isBrowser) {
                let run = BrowserRun(steps: pending, earlierHost: host)
                host = run.host
                items.append(.run(run))
            }
            else { items += pending.map(Item.card) }
            pending = []
        }
        for card in cards {
            switch card.kind {
            case .browser, .script, .browserAction, .note: pending.append(card)
            default: flush(); items.append(.card(card))
            }
        }
        flush()
        return items
    }

    /// The site the run is on: the newest page a browser call names.
    var host: String? {
        for card in steps.reversed() {
            if let url = BrowserStep.pageURL(card) { return DomainFormatter.short(ActivityEntry.host(of: url)) }
        }
        return earlierHost
    }

    /// The site the last run in `cards` ended on.
    static func lastHost(_ cards: [FeedCard]) -> String? {
        items(cards).reversed().lazy.compactMap { if case .run(let run) = $0 { run.host } else { nil } }.first
    }

    var isRunning: Bool { steps.contains(where: \.isRunning) }
}

/// "Browsing map.naver.com ›", then the steps (finished ones dim with a check, the current one in the primary color),
/// then the live view while the reply works. A tap on the line folds the steps.
struct BrowserRunView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.citations) private var citations
    let run: BrowserRun
    let collapsed: Bool
    /// The step showing the model's page live (`ActivityFeed.liveBrowserCard`), when it is in this run.
    var live: String?
    /// Whether a script step's code is folded, and a tap on it.
    var stepCollapsed: (FeedCard) -> Bool = { _ in true }
    var onToggleStep: (FeedCard) -> Void = { _ in }
    let onToggle: () -> Void
    var onDetails: () -> Void
    @State private var showEarlier = false

    /// More steps than this and the older ones hide behind "N earlier steps".
    static let visibleSteps = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                FeedLine(title: title, meta: collapsed ? stepCount : nil, expanded: !collapsed) {
                    if active { FeedSpinner() } else { FeedSymbol(name: "globe") }
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(collapsed ? "Collapsed" : "Expanded"))
            .accessibilityHint(Text(collapsed ? "Shows the steps" : "Hides the steps"))
            VStack(alignment: .leading, spacing: 0) {
                if !collapsed {
                    steps.transition(.opacity)
                } else {
                    // Folded, a failed page that was kept can still be opened.
                    ForEach(run.steps.filter { $0.isError && !$0.isRunning && KeptPageLink.hasPage($0.id, conversation: citations.conversationID) }) { card in
                        BrowserStep(card: card, current: false)
                    }
                }
                if let live {
                    BrowserLivePreview(callID: live)
                        .padding(.top, DS.Spacing.sm)
                        .transition(.opacity)
                } else if !active {
                    SessionPageLink(callIDs: run.steps.map(\.id))
                }
            }
            .padding(.leading, DS.Feed.textInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : ActivityFeedView.fold, value: collapsed)
        .contextMenu {
            Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails)
        }
    }

    private var active: Bool { live != nil || run.isRunning }

    private var title: String {
        switch (active, run.host) {
        case (true, let host?): String(localized: "Browsing \(host)")
        case (false, let host?): String(localized: "Browsed \(host)")
        case (true, nil): String(localized: "Using the browser")
        case (false, nil): String(localized: "Used the browser")
        }
    }

    private var stepCount: String {
        run.steps.count == 1 ? String(localized: "1 step") : String(localized: "\(run.steps.count) steps")
    }

    private var steps: some View {
        let hidden = showEarlier ? 0 : max(0, run.steps.count - (Self.visibleSteps - 1))
        let shown = run.steps.count > Self.visibleSteps ? Array(run.steps.dropFirst(hidden)) : run.steps
        let current = run.steps.last { $0.isRunning }?.id
        return VStack(alignment: .leading, spacing: DS.Feed.stepSpacing) {
            if run.steps.count > Self.visibleSteps {
                Button {
                    withAnimation(reduceMotion ? nil : ActivityFeedView.fold) { showEarlier.toggle() }
                } label: {
                    Text(showEarlier ? String(localized: "Show fewer steps")
                         : hidden == 1 ? String(localized: "1 earlier step") : String(localized: "\(hidden) earlier steps"))
                }
                .buttonStyle(.quietLink(.secondary))
                .padding(.vertical, -(DS.IconSize.minHitTarget - DS.Feed.lineHeight) / 2)
            }
            ForEach(shown) { card in
                // While the page shows live below, an earlier screenshot of it is only a stale copy.
                BrowserStep(card: card, current: card.id == current, collapsed: stepCollapsed(card), showsScreenshot: live == nil,
                            onToggle: { onToggleStep(card) })
            }
        }
        .padding(.top, DS.Spacing.xxs)
    }
}

/// One step of a browser run: a check (or the current step's dot, or a failure mark) in a narrow column, then the line.
/// A script step unfolds to its code; a failed page that was kept offers "Open this page ›".
struct BrowserStep: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.citations) private var citations
    let card: FeedCard
    let current: Bool
    var collapsed = true
    var showsScreenshot = true
    var onToggle: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            line
            if !card.isRunning, card.isError, KeptPageLink.hasPage(card.id, conversation: citations.conversationID) {
                KeptPageLink(callID: card.id)
                    .padding(.leading, DS.Feed.markColumn + DS.Spacing.xs)
            }
            if showsScreenshot, case .browserAction = card.kind, !card.isRunning, let image = card.figures.first {
                ToolImageThumbnail(image: image, height: DS.Feed.liveHeight * 0.8)
                    .padding(.leading, DS.Feed.markColumn + DS.Spacing.xs)
            }
            if case .script(let code) = card.kind, !collapsed {
                BrowserScriptDetail(code: code, output: card.output, isRunning: card.isRunning, isError: card.isError)
                    .padding(.vertical, DS.Spacing.xs)
                    .transition(.opacity)
            }
        }
    }

    private var isScript: Bool { if case .script = card.kind { true } else { false } }

    @ViewBuilder
    private var line: some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            mark.frame(width: DS.Feed.markColumn, alignment: .leading)
            Text(title)
                .font(DS.Typography.feed)
                .foregroundStyle(current ? theme.textPrimary : theme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            if isScript {
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.Feed.mark - 1, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        if isScript {
            Button(action: onToggle) { row }
                .buttonStyle(.plain)
                .accessibilityValue(Text(collapsed ? "Collapsed" : "Expanded"))
                .accessibilityHint(Text(collapsed ? "Shows the script and its result" : "Hides the script and its result"))
        } else if case .browser = card.kind, let url = Self.pageURL(card).flatMap(URL.init(string:)) {
            Button { openURL(url) } label: { row }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the page"))
        } else {
            row.accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var mark: some View {
        if card.isRunning || current {
            Circle().fill(theme.textPrimary).frame(width: DS.Spacing.xs + 1, height: DS.Spacing.xs + 1)
                .accessibilityLabel(Text("Now"))
        } else if card.isError {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: DS.Feed.mark + 1, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .accessibilityLabel(Text("Failed"))
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: DS.Feed.mark, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
                .accessibilityLabel(Text("Done"))
        }
    }

    static func pageURL(_ card: FeedCard) -> String? {
        switch card.kind {
        case .browser(let url): url
        case .script: BrowserScript.url(inResult: card.output)
        case .browserAction: actionURL(card.output)
        default: nil
        }
    }

    /// The page an index tool left the browser on: its result's "URL:" line, or "The page is now …".
    static func actionURL(_ result: String) -> String? {
        for line in result.split(separator: "\n") {
            for prefix in ["URL: ", "The page is now "] where line.hasPrefix(prefix) {
                let url = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if url.hasPrefix("http") { return url }
            }
        }
        return nil
    }

    private var host: String? { Self.pageURL(card).map { DomainFormatter.short(ActivityEntry.host(of: $0)) } }

    private var title: String {
        switch card.kind {
        case .browserAction(let tool, let argument):
            let summary = card.isRunning || card.isError ? nil : BrowserActionLabel.summary(tool: tool, result: card.output)
            return ToolNote.title(tool: tool, argument: argument, running: card.isRunning, failed: card.isError, summary: summary)
        case .note(let tool, let argument):
            return ToolNote.title(tool: tool, argument: argument, running: card.isRunning, failed: card.isError)
        case .script:
            if card.isRunning { return String(localized: "Running a script…") }
            let base = host.map { String(localized: "Ran a script on \($0)") } ?? String(localized: "Ran a script")
            return card.isError ? base + " · " + String(localized: "Error") : base
        default:
            let site = host ?? ""
            if card.isRunning { return String(localized: "Opening \(site)…") }
            if card.isError { return site + " · " + (card.pageFailure ?? .failed).label }
            return String(localized: "Opened \(site)")
        }
    }
}

/// The model's page, live while the reply works: the browser's own web view as a portrait thumbnail (`WebStage`
/// preview, never touched; a tap watches), and beside it "● LIVE", Watch, Take over and Stop browsing as text links.
/// It goes back off screen when the run scrolls away or the reply stops working.
struct BrowserLivePreview: View {
    @Environment(\.theme) private var theme
    /// The chat the card is in: its own page, even when another chat's call has the same id.
    @Environment(\.citations) private var citations
    let callID: String

    var body: some View {
        let sessions = BrowserSessions.shared
        if let conversation = sessions.conversation(forCall: callID, conversation: citations.conversationID),
           let page = sessions.page(forCall: callID, conversation: conversation) {
            BrowserLiveStrip(onWatch: { PageHandover.watch(page, conversation: conversation) },
                             onTakeOver: { PageHandover.open(page) },
                             onStop: { sessions.stopBrowsing(conversation) }) {
                ZStack {
                    theme.background
                    // Seen only while the sheet has the page.
                    Text("Showing in the browser")
                        .font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center).padding(DS.Spacing.sm)
                    WebStage(page: page, kind: .preview, interactive: false)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// The live view's layout, apart from where the page comes from (so previews and the debug gallery can show it).
struct BrowserLiveStrip<Thumbnail: View>: View {
    @Environment(\.theme) private var theme
    let onWatch: () -> Void
    let onTakeOver: () -> Void
    let onStop: () -> Void
    @ViewBuilder let thumbnail: () -> Thumbnail

    var body: some View {
        HStack(alignment: .bottom, spacing: DS.Spacing.md) {
            Button(action: onWatch) {
                thumbnail()
                    .frame(width: DS.Feed.liveWidth, height: DS.Feed.liveHeight)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.thumbnail, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.thumbnail, style: .continuous)
                            .strokeBorder(theme.separator, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Live view of the page"))
            .accessibilityHint(Text("Opens the page to watch"))
            VStack(alignment: .leading, spacing: 0) {
                Label {
                    Text("LIVE").font(DS.Typography.feedCaption).tracking(0.6).foregroundStyle(theme.textSecondary)
                } icon: {
                    Circle().fill(theme.live).frame(width: DS.Feed.liveDot, height: DS.Feed.liveDot)
                }
                .labelStyle(QuietLinkLabelStyle())
                .accessibilityLabel(Text("Live"))
                Button("Watch", systemImage: "eye", action: onWatch)
                    .buttonStyle(.quietLink)
                Button("Take over", systemImage: "hand.point.up.left", action: onTakeOver)
                    .buttonStyle(.quietLink)
                    .accessibilityHint(Text("Lets you use the page; the model waits until you're done"))
                Button("Stop browsing", systemImage: "stop.circle", action: onStop)
                    .buttonStyle(.quietLink(.secondary))
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// After the reply, on the run with the conversation's latest browser call: "Open page ›" while its page is kept
/// (frozen) in `BrowserSessions`, which hands it to the user in the browser sheet; once the page is closed, "Page
/// closed · Reopen", which opens its last URL fresh. Nothing when there is neither (the app was relaunched).
struct SessionPageLink: View {
    @Environment(\.theme) private var theme
    @Environment(\.citations) private var citations
    let callIDs: [String]

    var body: some View {
        let sessions = BrowserSessions.shared
        if let conversation = sessions.conversation(lastCallIn: callIDs, of: citations.conversationID) {
            if let page = sessions.page(of: conversation) {
                Button("Open page") { PageHandover.browse(page, conversation: conversation) }
                    .buttonStyle(.quietLink(.primary, chevron: true))
                    .accessibilityHint(Text("Shows the page the browser was on, to use it yourself"))
            } else if sessions.closedURL(conversation) != nil {
                HStack(spacing: DS.Spacing.xs) {
                    Text("Page closed ·")
                        .font(DS.Typography.feed)
                        .foregroundStyle(theme.textTertiary)
                    Button("Reopen") { PageHandover.reopen(conversation) }
                        .buttonStyle(.quietLink)
                        .accessibilityHint(Text("Opens the page the browser was on again"))
                }
            }
        }
    }
}

/// "Open this page ›" under a failed call whose page was kept (`KeptPages`): hands that same page to the user.
struct KeptPageLink: View {
    @Environment(\.citations) private var citations
    let callID: String

    static func hasPage(_ callID: String, conversation: UUID?) -> Bool {
        KeptPages.shared.page(forCall: callID, conversation: conversation) is HiddenWebView
    }

    var body: some View {
        if let page = KeptPages.shared.page(forCall: callID, conversation: citations.conversationID) as? HiddenWebView {
            Button("Open this page") { PageHandover.open(page) }
                .buttonStyle(.quietLink(.primary, chevron: true))
                .accessibilityHint(Text("Shows the page the tool stopped on"))
        }
    }
}

/// A tool stopped at a robot check: the warning triangle and "<host> wants a robot check", what to do, then Open page
/// and Skip as text links. Open hands the same web view to the browser sheet; the tool goes on in it after Done.
struct RobotCheckPromptCard: View {
    let request: RobotCheckRequests.Request

    var body: some View {
        RobotCheckPrompt(host: request.host,
                         onOpen: { RobotCheckRequests.shared.answer(request.id, .open) },
                         onSkip: { RobotCheckRequests.shared.answer(request.id, .skip) })
    }
}

/// The robot check prompt's layout (previews and the debug gallery use it without a request).
struct RobotCheckPrompt: View {
    @Environment(\.theme) private var theme
    let host: String
    let onOpen: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedLine(title: String(localized: "\(host) wants a robot check"), color: theme.textPrimary, lineLimit: 2) {
                FeedSymbol(name: "exclamationmark.triangle", color: theme.warning)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Solve it on the page and OpenChat picks up where it stopped. A solved check is kept for later searches.")
                    .font(DS.Typography.feed)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Spacing.lg) {
                    Button("Open page", action: onOpen).buttonStyle(.quietLink(.accent))
                    Button("Skip", action: onSkip).buttonStyle(.quietLink(.secondary))
                }
            }
            .padding(.leading, DS.Feed.textInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// A browser script and what it returned (inside the feed card and the Timeline card).
struct BrowserScriptDetail: View {
    let code: String
    let output: String
    var isRunning = false
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            CodeBlockView(content: CodeBlockContent(language: "javascript", code: code))
            if !isRunning && !displayedOutput.isEmpty {
                PythonOutputView(text: displayedOutput, isError: isError)
            }
        }
    }

    /// The result without the "URL: …" line it starts with (the header names the site).
    private var displayedOutput: String {
        guard BrowserScript.url(inResult: output) != nil, let end = output.firstIndex(of: "\n") else { return output }
        return output[end...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Previews

#Preview("Dark · Purple") { browserPreview.previewStyle(.dark) }
#Preview("Light · Purple") { browserPreview.previewStyle(.light) }
#Preview("Dark · Orange") { browserPreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }

@MainActor private var browserPreview: some View {
    var skill = FeedCard(id: "k", kind: .note(tool: ToolNames.loadSkill, argument: "naver-places"))
    skill.isRunning = false
    let open = FeedCard(id: "o", kind: .browser(url: "https://map.naver.com/p/search/%EC%84%B1%EC%88%98"))
    var click = FeedCard(id: "c", kind: .browserAction(tool: ToolNames.browserClick, argument: "[12]"))
    click.output = "Clicked [12] Search"
    let typing = FeedCard(id: "t", kind: .browserAction(tool: ToolNames.browserType, argument: "[5] \u{201C}seongsu cafe\u{201D}"), isRunning: true)
    var failed = FeedCard(id: "f", kind: .browser(url: "https://www.letskorail.com/"), isError: true)
    failed.pageFailure = .blocked
    return ScrollView {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            BrowserRunView(run: BrowserRun(steps: [skill, open, click, typing]), collapsed: false, onToggle: {}, onDetails: {})
            BrowserLiveStrip(onWatch: {}, onTakeOver: {}, onStop: {}) { Color.gray.opacity(0.2) }
                .padding(.leading, DS.Feed.textInset)
            RobotCheckPrompt(host: "blog.naver.com", onOpen: {}, onSkip: {})
            BrowserRunView(run: BrowserRun(steps: [open, failed]), collapsed: true, onToggle: {}, onDetails: {})
        }
        .padding()
    }
}

// MARK: - One-line cards

/// The icon and line of a call shown as a single line (`load_skill` and the like), in the feed and the Timeline.
enum ToolNote {
    static func covers(_ tool: String) -> Bool {
        [ToolNames.browserShow, ToolNames.loadSkill, ToolNames.runSkillScript, ToolNames.saveSkill, ToolNames.showPlaces, ToolNames.currentLocation,
         ToolNames.showHTML, ToolNames.healthQuery].contains(tool) || ToolNames.isBrowserAction(tool)
    }

    static func icon(_ tool: String) -> String {
        switch tool {
        case ToolNames.browserState: "list.bullet.rectangle"
        case ToolNames.browserClick: "hand.tap"
        case ToolNames.browserType: "keyboard"
        case ToolNames.browserSelect: "filemenu.and.selection"
        case ToolNames.browserScroll: "arrow.up.and.down"
        case ToolNames.browserFind: "text.magnifyingglass"
        case ToolNames.browserScreenshot: "camera.viewfinder"
        case ToolNames.browserShow: "hand.point.up.left"
        case ToolNames.loadSkill: "book.closed"
        case ToolNames.runSkillScript: "play.rectangle"
        case ToolNames.saveSkill: "square.and.arrow.down"
        case ToolNames.showPlaces: "map"
        case ToolNames.currentLocation: "location"
        case ToolNames.showHTML: ArtifactFeedCard.icon
        case ToolNames.healthQuery: HealthFeedCard.icon
        default: "wrench.and.screwdriver"
        }
    }

    /// `summary`: what a finished index tool did, from its result ("Clicked [12] Search"); the line when given.
    static func title(tool: String, argument: String, running: Bool, failed: Bool = false, summary: String? = nil) -> String {
        if ToolNames.isBrowserAction(tool) {
            return BrowserActionLabel.title(tool: tool, argument: argument, running: running, failed: failed, summary: summary)
        }
        return switch tool {
        case ToolNames.browserShow:
            running ? String(localized: "Waiting for you in the browser…")
                : failed ? String(localized: "You closed the browser") : String(localized: "You finished in the browser")
        case ToolNames.loadSkill:
            running ? String(localized: "Loading skill \(argument)…") : String(localized: "Loaded skill \(argument)")
        case ToolNames.runSkillScript:
            running ? String(localized: "Running \(argument)…")
                : failed ? String(localized: "Script failed: \(argument)") : String(localized: "Ran \(argument)")
        case ToolNames.saveSkill:
            running ? String(localized: "Asking to save skill \(argument)…")
                : failed ? String(localized: "Didn't save skill \(argument)") : String(localized: "Saved skill \(argument)")
        case ToolNames.showPlaces:
            running ? String(localized: "Finding places on the map…") : String(localized: "Showed places on a map")
        case ToolNames.currentLocation:
            running ? String(localized: "Getting your location…") : String(localized: "Got your location")
        case ToolNames.healthQuery:
            HealthCallLabel.title(summary: argument, running: running, failed: failed)
        case ToolNames.showHTML:
            running ? String(localized: "Making an artifact…")
                : failed ? String(localized: "Couldn't show the artifact") : String(localized: "Showed \(argument)")
        default:
            running ? String(localized: "Running \(tool)…") : String(localized: "Ran \(tool)")
        }
    }
}

/// The lines of the index tools' cards: "Clicking [12]…", then what the result says it did ("Clicked [12] Search").
enum BrowserActionLabel {
    /// The first line of a finished call's result, when it says what was done (a state starts with its URL instead).
    static func summary(tool: String, result: String) -> String? {
        guard ToolNames.isBrowserAction(tool), tool != ToolNames.browserState else { return nil }
        let line = String(result.prefix { $0 != "\n" }).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("URL:"), !line.hasPrefix("Error") else { return nil }
        return line
    }

    static func title(tool: String, argument: String, running: Bool, failed: Bool, summary: String?) -> String {
        if !running, !failed, let summary { return readable(summary) }
        let shown = withoutIndex(argument)
        let arg = shown.isEmpty ? "" : " " + shown
        switch tool {
        case ToolNames.browserState:
            return running ? String(localized: "Reading the page…") : failed ? String(localized: "Couldn't read the page") : String(localized: "Read the page")
        case ToolNames.browserClick:
            return running ? String(localized: "Clicking\(arg)…") : failed ? String(localized: "Couldn't click\(arg)") : String(localized: "Clicked\(arg)")
        case ToolNames.browserType:
            return running ? String(localized: "Typing\(arg)…") : failed ? String(localized: "Couldn't type into\(arg)") : String(localized: "Typed into\(arg)")
        case ToolNames.browserSelect:
            return running ? String(localized: "Choosing\(arg)…") : failed ? String(localized: "Couldn't choose\(arg)") : String(localized: "Chose\(arg)")
        case ToolNames.browserScroll:
            return running ? String(localized: "Scrolling\(arg)…") : failed ? String(localized: "Couldn't scroll") : String(localized: "Scrolled\(arg)")
        case ToolNames.browserFind:
            return running ? String(localized: "Finding \u{201C}\(argument)\u{201D}…")
                : failed ? String(localized: "Couldn't search the page") : String(localized: "Searched the page for \u{201C}\(argument)\u{201D}")
        case ToolNames.browserScreenshot:
            return running ? String(localized: "Taking a screenshot…") : failed ? String(localized: "Couldn't take a screenshot") : String(localized: "Took a screenshot")
        default:
            return running ? String(localized: "Running \(tool)…") : String(localized: "Ran \(tool)")
        }
    }
}

extension BrowserActionLabel {
    /// The element numbers are for the model ("[12]", from the marked screenshot); the user reads the label:
    /// "Clicked [12] Search" shows as "Clicked “Search”", "Scrolled [4] down 600" as "Scrolled down 600".
    static func readable(_ line: String) -> String {
        guard let index = line.range(of: #"\[\d+\]\s*"#, options: .regularExpression) else { return line }
        let head = line[..<index.lowerBound].trimmingCharacters(in: .whitespaces)
        var rest = String(line[index.upperBound...])
        if line.hasPrefix("Scrolled") { return [head, rest].filter { !$0.isEmpty }.joined(separator: " ") }
        let submitted = " and submitted"
        let tail = rest.hasSuffix(submitted) ? submitted : ""
        rest = String(rest.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else {
            // No label: "Typed "hi" into" reads better without its dangling preposition.
            let words = head.split(separator: " ")
            let trimmed = ["into", "in"].contains(words.last.map(String.init) ?? "") ? words.dropLast().joined(separator: " ") : head
            return trimmed + tail
        }
        return head + " \u{201C}" + rest + "\u{201D}" + tail
    }

    /// A running call's argument without its element number: "[12]" alone is nothing to the user.
    static func withoutIndex(_ argument: String) -> String {
        argument.replacingOccurrences(of: #"^\[\d+\]\s*"#, with: "", options: .regularExpression)
    }
}

/// "Loaded skill naver-places" in the feed, on its own (among browser calls it is a step of the run).
struct ToolNoteFeedCard: View {
    @Environment(\.theme) private var theme
    let card: FeedCard
    var onDetails: () -> Void

    var body: some View {
        if case .note(let tool, let argument) = card.kind {
            FeedLine(title: ToolNote.title(tool: tool, argument: argument, running: card.isRunning, failed: card.isError),
                     meta: card.isError && !card.isRunning && tool != ToolNames.saveSkill ? String(localized: "Failed") : nil) {
                if card.isRunning { FeedSpinner() } else { FeedSymbol(name: ToolNote.icon(tool)) }
            }
            .accessibilityElement(children: .combine)
            .contextMenu {
                Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails)
            }
        }
    }
}
