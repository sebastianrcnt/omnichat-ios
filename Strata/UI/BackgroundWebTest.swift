#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// Settings > Developer > Background web test: does a hidden web view still answer while the app is in the background?
/// WebKit drops a page's process to suspended once its view is off screen, unless the page plays audio. Four pages run
/// side by side (nothing, a Web Audio tone, an <audio> loop started on hide, one started at once) and each is pinged
/// every 2 s; the result counts the pings answered quickly while the app was away. The app itself is kept alive the way
/// a reply is (`ReplyBackgroundExecution`), so only the web side is measured.
@MainActor
@Observable
final class BackgroundWebProbe {
    struct Variant: Identifiable {
        let id: String
        let title: String
        let script: String
    }

    struct Ping {
        let sent: Date
        var answered: Date?
        var state: String?
        let away: Bool
    }

    static let variants: [Variant] = [
        Variant(id: "plain", title: "No audio", script: ""),
        Variant(id: "webaudio", title: "Web Audio tone", script: "startTone();"),
        Variant(id: "audioOnHide", title: "<audio> started on hide",
                script: "document.addEventListener('visibilitychange', () => { if (document.hidden) startLoop(); });"),
        Variant(id: "audioNow", title: "<audio> started at once", script: "startLoop();"),
    ]

    private(set) var running = false
    private(set) var pings: [String: [Ping]] = [:]
    private(set) var awaySeconds: Double = 0
    private(set) var startedAt: Date?
    private var awaySince: Date?
    private var views: [String: WKWebView] = [:]
    private var lease: ReplyBackgroundExecution?
    private var loop: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    static let duration: Duration = .seconds(150)

    func start() {
        guard !running else { return }
        running = true
        pings = [:]
        awaySeconds = 0
        startedAt = Date()
        let lease = ReplyBackgroundExecution()
        lease.begin()
        self.lease = lease
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.awaySince = Date() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cameBack() }
            },
        ]
        for variant in Self.variants {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.mediaTypesRequiringUserActionForPlayback = []
            config.allowsInlineMediaPlayback = true
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 32, height: 32), configuration: config)
            view.alpha = 0.01
            view.isUserInteractionEnabled = false
            HiddenWebView.keyWindow?.insertSubview(view, at: 0)
            view.loadHTMLString(Self.page(variant.script), baseURL: nil)
            views[variant.id] = view
        }
        loop = Task { [weak self] in
            let end = ContinuousClock.now + Self.duration
            while ContinuousClock.now < end, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.pingAll()
            }
            self?.stop()
        }
    }

    func stop() {
        guard running else { return }
        if awaySince != nil { cameBack() }
        running = false
        loop?.cancel()
        loop = nil
        for view in views.values {
            view.stopLoading()
            view.loadHTMLString("", baseURL: nil)
            view.removeFromSuperview()
        }
        views = [:]
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        lease?.end(success: true, title: String(localized: "Background web test finished"))
        lease = nil
    }

    private func cameBack() {
        if let awaySince { awaySeconds += Date().timeIntervalSince(awaySince) }
        awaySince = nil
    }

    private func pingAll() {
        let away = awaySince != nil
        for (id, view) in views {
            let index = pings[id, default: []].count
            pings[id, default: []].append(Ping(sent: Date(), away: away))
            view.evaluateJavaScript("state()") { [weak self] result, _ in
                MainActor.assumeIsolated {
                    guard let self, var list = self.pings[id], index < list.count else { return }
                    list[index].answered = Date()
                    list[index].state = result as? String
                    self.pings[id] = list
                }
            }
        }
    }

    /// Pings sent while away, and how many were answered within 1.5 s.
    func summary(_ id: String) -> (answered: Int, sent: Int, state: String?) {
        let away = (pings[id] ?? []).filter(\.away)
        let quick = away.filter { p in p.answered.map { $0.timeIntervalSince(p.sent) <= 1.5 } ?? false }
        return (quick.count, away.count, (pings[id] ?? []).last(where: { $0.state != nil })?.state)
    }

    /// The test page: ticks a counter, and can play a near-silent tone (Web Audio) or loop (an <audio> element playing a
    /// generated WAV of faint noise, so WebKit counts it as audible without anyone hearing it).
    private static func page(_ script: String) -> String {
        """
        <!doctype html><meta name="viewport" content="width=device-width">
        <script>
        let ticks = 0, ctx = null, audio = null, err = '';
        setInterval(() => ticks++, 1000);
        function startTone() {
          try {
            ctx = new AudioContext();
            const osc = ctx.createOscillator(), gain = ctx.createGain();
            osc.frequency.value = 40; gain.gain.value = 0.0005;
            osc.connect(gain).connect(ctx.destination); osc.start(); ctx.resume();
          } catch (e) { err = String(e); }
        }
        function startLoop() {
          if (audio) { audio.play().catch(e => err = String(e)); return; }
          const rate = 8000, n = rate, buf = new ArrayBuffer(44 + n * 2), v = new DataView(buf);
          const w = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
          w(0, 'RIFF'); v.setUint32(4, 36 + n * 2, true); w(8, 'WAVEfmt '); v.setUint32(16, 16, true);
          v.setUint16(20, 1, true); v.setUint16(22, 1, true); v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true);
          v.setUint16(32, 2, true); v.setUint16(34, 16, true); w(36, 'data'); v.setUint32(40, n * 2, true);
          for (let i = 0; i < n; i++) v.setInt16(44 + i * 2, (i % 2 ? 3 : -3), true);
          audio = new Audio(URL.createObjectURL(new Blob([buf], { type: 'audio/wav' })));
          audio.loop = true;
          audio.play().catch(e => err = String(e));
        }
        function state() {
          const a = audio ? (audio.paused ? 'paused' : 'playing') : '-';
          return `ticks ${ticks} · audio ${a} · ctx ${ctx ? ctx.state : '-'} · ${document.visibilityState}${err ? ' · ' + err : ''}`;
        }
        \(script)
        </script>
        """
    }
}

struct BackgroundWebTestView: View {
    @Environment(\.theme) private var theme
    @State private var probe = BackgroundWebProbe()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                GroupedSection(footer: "Tap Start, go to the Home screen or another app for about a minute, then come back. Each row counts how often its hidden page answered within 1.5 s while Strata was away. Note whether music you were playing stopped.") {
                    if probe.running {
                        SettingsRow(systemImage: "stop.circle", title: "Stop") { probe.stop() }
                    } else {
                        SettingsRow(systemImage: "play.circle", title: "Start") { probe.start() }
                    }
                }
                GroupedSection(header: "Results", footer: "Away for \(Int(probe.awaySeconds)) s.") {
                    ForEach(BackgroundWebProbe.variants) { variant in
                        let s = probe.summary(variant.id)
                        SettingsRow(title: "", subtitle: s.state, value: s.sent == 0 ? "–" : "\(s.answered)/\(s.sent)",
                                    verbatimTitle: variant.title)
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Background web test")
        .inlineNavigationTitle()
        .onDisappear { probe.stop() }
        #if DEBUG
        .task { if DebugHooks.value("StrataBgWebAutoStart") != nil { probe.start() } }
        #endif
    }
}
#endif
