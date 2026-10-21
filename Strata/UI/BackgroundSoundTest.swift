#if os(iOS)
import SwiftUI
import UIKit

/// Settings > Developer > Background sound test: does the loading sound keep a hidden page running while Strata is in
/// the background? Two hidden views load a page that notes the time every second; only one of them plays the sound
/// (`BackgroundLoadingSound`, the same path a web tool takes). While the test runs it counts as web work, and the app is
/// kept alive the way a reply is (`ReplyBackgroundExecution`). Pages are read only once the app is back: asking a page
/// anything wakes its process, which would hide the suspension being measured.
@MainActor
@Observable
final class BackgroundSoundProbe {
    struct Result {
        let title: String
        let report: String
    }

    private(set) var running = false
    private(set) var results: [Result] = []
    private(set) var awaySeconds: Double = 0
    private var awaySince: Date?
    private var pages: [(title: String, view: HiddenWebView)] = []
    private var lease: ReplyBackgroundExecution?
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    static let duration: Duration = .seconds(150)

    func start() {
        guard !running else { return }
        running = true
        results = []
        awaySeconds = 0
        let lease = ReplyBackgroundExecution()
        lease.begin()
        self.lease = lease
        BackgroundLoadingSound.shared.beginWebWork()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.awaySince = Date() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cameBack() }
            },
        ]
        for (title, sound) in [("With the loading sound", true), ("Without sound", false)] {
            let page = HiddenWebView(guardNavigations: false)
            page.playsLoadingSound = sound
            pages.append((title, page))
            Task { try? await page.load(html: Self.page, baseURL: URL(string: "https://strata.invalid/")) }
        }
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if awaySince != nil { cameBack() }
        BackgroundLoadingSound.shared.endWebWork()
        let pages = self.pages
        self.pages = []
        Task {
            await read(pages)
            for page in pages { page.view.dispose() }
        }
        lease?.end(success: true, title: String(localized: "Background sound test finished"))
        lease = nil
    }

    private func cameBack() {
        if let awaySince { awaySeconds += Date().timeIntervalSince(awaySince) }
        awaySince = nil
        Task { await read(pages) }
    }

    private func read(_ pages: [(title: String, view: HiddenWebView)]) async {
        var results: [Result] = []
        for page in pages {
            let report = (try? await page.view.evaluate("report()", timeout: .seconds(3))) ?? "no answer"
            results.append(Result(title: page.title, report: report))
        }
        if !results.isEmpty { self.results = results }
    }

    /// Notes the time every second; `report()` gives the tick count and the longest gap between ticks, which is about
    /// how long the page's process was suspended.
    private static let page = """
        <!doctype html><meta name="viewport" content="width=device-width">
        <script>
        let ticks = 0, last = Date.now(), longest = 0;
        setInterval(() => { const now = Date.now(); longest = Math.max(longest, now - last); last = now; ticks++; }, 1000);
        function report() { return `${ticks} ticks · longest gap ${(longest / 1000).toFixed(1)} s`; }
        </script>
        """
}

struct BackgroundSoundTestView: View {
    @Environment(\.theme) private var theme
    @State private var probe = BackgroundSoundProbe()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                GroupedSection(footer: "Tap Start, go to the Home screen or another app for about a minute, then come back. A page that kept running has a longest gap near 1 s; one that was suspended shows a gap about as long as you were away. The sound plays only while you are away, and only when Settings > Tools > Play a sound while browsing in the background is on.") {
                    if probe.running {
                        SettingsRow(systemImage: "stop.circle", title: "Stop") { probe.stop() }
                    } else {
                        SettingsRow(systemImage: "play.circle", title: "Start") { probe.start() }
                    }
                }
                GroupedSection(header: "Results", footer: "Away for \(Int(probe.awaySeconds)) s.") {
                    if probe.results.isEmpty { SettingsRow(title: "No results yet") }
                    ForEach(probe.results, id: \.title) { result in
                        SettingsRow(title: "", subtitle: result.report, verbatimTitle: result.title)
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Background sound test")
        .inlineNavigationTitle()
        .onDisappear { probe.stop() }
        #if DEBUG
        .task { if DebugHooks.value("StrataBgSoundAutoStart") != nil { probe.start() } }
        #endif
    }
}
#endif
