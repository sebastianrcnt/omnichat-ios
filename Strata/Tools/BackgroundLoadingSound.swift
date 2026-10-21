import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// A soft looping "loading" sound, played while web tools run with the app in the background, so the searches keep going.
///
/// Why it plays inside the pages: iOS WebKit lets the WebContent process of a page that is not visible drop to
/// suspended, whatever the app itself is doing. `WebPageProxy::updateThrottleState` keeps a process running for a hidden
/// page only while that page is audible (an "audible" activity, released about 10 s after the audio stops). Audio the app
/// plays natively (AVAudioPlayer, AVAudioEngine) keeps the app awake but no page audible, so it would not help; the
/// sound has to come out of every page doing the work. Each hidden view usually has a process of its own, so it plays
/// in all of them.
///
/// How: an `<audio>` element in an isolated content world (page scripts can't see or stop it), playing a generated WAV.
/// Web Audio would be quieter to set up but iOS WebKit interrupts it when the app goes to the background
/// (`BackgroundProcessPlaybackRestricted`); an audio-only media element is allowed to keep playing. Script can't set an
/// element's volume on iOS, so the tone itself is quiet (`LoadingTone`). The hidden views keep WebKit's default that
/// audio needs a user gesture (sites must not autoplay sound in them); script the app runs counts as one.
///
/// The audio session is WebKit's, not the app's: WebKit's GPU process sets the playback category for an audible media
/// element, so the sound plays with the silent switch on and may pause music from another app while it lasts. That is
/// on purpose in the sense that it is a status sound the person turned on (Settings > Tools, on by default), and it lasts
/// only while web tools run in the background. The `audio` background mode lets it keep playing there.
@MainActor
final class BackgroundLoadingSound {
    static let shared = BackgroundLoadingSound()

    /// Settings > Tools > "Play a sound while browsing in the background" (on by default).
    nonisolated static let enabledKey = "backgroundLoadingSound"
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil ? true : UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Plays while the setting is on, at least one web tool is running, and the app is in the background.
    nonisolated static func shouldPlay(enabled: Bool, webWork: Int, inBackground: Bool) -> Bool {
        enabled && webWork > 0 && inBackground
    }

    private final class Entry {
        weak var view: HiddenWebView?
        init(_ view: HiddenWebView) { self.view = view }
    }

    private(set) var isPlaying = false
    private(set) var webWork = 0
    private var inBackground = false
    /// Views that may be doing web work: every live hidden view except idle ones kept by `WebViewPool`.
    private var views: [ObjectIdentifier: Entry] = [:]
    /// The setting, read when the state changes. Test seam.
    var enabled: () -> Bool = { BackgroundLoadingSound.isEnabled }
    private var observers: [NSObjectProtocol] = []
    /// The last answer from a page asked to play, for the diagnostics panel.
    private(set) var lastPageState: String?

    init() {
        #if os(iOS)
        inBackground = AppLifecycle.isBackground
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setBackground(true) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setBackground(false) }
            },
        ]
        #endif
    }

    // MARK: State

    /// A web tool started. Every call is matched by one `endWebWork`.
    func beginWebWork() {
        webWork += 1
        update()
    }

    func endWebWork() {
        webWork = max(0, webWork - 1)
        update()
    }

    /// Runs `body` as web work.
    func duringWebWork<T>(_ body: () async throws -> T) async rethrows -> T {
        beginWebWork()
        defer { endWebWork() }
        return try await body()
    }

    func setBackground(_ background: Bool) {
        inBackground = background
        update()
    }

    private func update() {
        let play = Self.shouldPlay(enabled: enabled(), webWork: webWork, inBackground: inBackground)
        guard play != isPlaying else { return }
        isPlaying = play
        views = views.filter { $0.value.view != nil }
        for entry in views.values {
            guard let view = entry.view else { continue }
            if play { start(in: view) } else { stop(in: view) }
        }
    }

    // MARK: Views

    /// A hidden view that may load pages for a tool. It starts playing at once if the sound is on.
    func register(_ view: HiddenWebView) {
        guard views[ObjectIdentifier(view)] == nil else { return }
        views[ObjectIdentifier(view)] = Entry(view)
        if isPlaying { start(in: view) }
    }

    /// A view going idle or away. Its sound stops.
    func unregister(_ view: HiddenWebView) {
        guard views.removeValue(forKey: ObjectIdentifier(view)) != nil else { return }
        if isPlaying { stop(in: view) }
    }

    var registeredCount: Int { views.values.filter { $0.view != nil }.count }

    func isRegistered(_ view: HiddenWebView) -> Bool { views[ObjectIdentifier(view)]?.view === view }

    /// A registered view committed a new page, which has no sound yet.
    func pageDidCommit(_ view: HiddenWebView) {
        guard isPlaying, views[ObjectIdentifier(view)] != nil else { return }
        start(in: view)
    }

    private static let world = WKContentWorld.world(name: "strata-loading-sound")

    private func start(in view: HiddenWebView) {
        guard view.playsLoadingSound else { return }
        view.webView.callAsyncJavaScript(Self.startScript, arguments: ["wav": LoadingTone.base64WAV], in: nil,
                                         in: Self.world) { [weak self] result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let value): self?.lastPageState = value as? String
                case .failure(let error): self?.lastPageState = error.localizedDescription
                }
            }
        }
    }

    private func stop(in view: HiddenWebView) {
        view.webView.callAsyncJavaScript(Self.stopScript, arguments: [:], in: nil, in: Self.world) { _ in }
    }

    /// Idempotent within a page: the element lives on the isolated world's `window` until the next page. A page whose
    /// Content Security Policy blocks `blob:` media gets a `data:` URL instead; one that blocks both (`default-src 'none'`)
    /// stays silent, since an isolated world doesn't bypass the page's policy for media loads, and may still be suspended.
    static let startScript = """
        let a = window.strataLoadingSound;
        if (!a) {
          const bytes = Uint8Array.from(atob(wav), c => c.charCodeAt(0));
          a = new Audio(URL.createObjectURL(new Blob([bytes], { type: 'audio/wav' })));
          a.loop = true;
          a.addEventListener('error', () => {
            if (a.src.startsWith('data:')) return;
            a.src = 'data:audio/wav;base64,' + wav;
            a.play().catch(() => {});
          });
          window.strataLoadingSound = a;
        }
        a.play().catch(() => {});
        return 'started';
        """

    static let stopScript = """
        const a = window.strataLoadingSound;
        if (a) { a.pause(); a.removeAttribute('src'); a.load(); window.strataLoadingSound = null; }
        return 'stopped';
        """
}

/// The loading sound: two soft, quickly fading notes every two seconds, generated rather than bundled. 16 kHz mono
/// 16-bit PCM, about 64 KB. Quiet at the source (peaks below 20% of full scale), since a page can't turn it down.
enum LoadingTone {
    static let sampleRate = 16_000
    static let seconds = 2.0
    /// Peak amplitude, 0...1.
    static let level = 0.15

    static let base64WAV: String = wav().base64EncodedString()

    /// A WAV file holding one loop.
    static func wav() -> Data {
        let samples = pcm()
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)) // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for s in samples { append(s) }
        return data
    }

    /// One loop of samples: a D5 then an A5, each with a short rise and a soft exponential fade, then quiet until
    /// the loop starts again (so the seam can't click).
    static func pcm() -> [Int16] {
        let count = Int(Double(sampleRate) * seconds)
        let notes: [(start: Double, frequency: Double)] = [(0.0, 587.33), (0.18, 880.0)]
        return (0..<count).map { i in
            let t = Double(i) / Double(sampleRate)
            var value = 0.0
            for note in notes where t >= note.start {
                let u = t - note.start
                guard u < 0.6 else { continue }
                let rise = min(1, u / 0.012)
                let fade = exp(-u * 9)
                let tail = u > 0.5 ? (0.6 - u) / 0.1 : 1 // reaches exactly zero
                // A touch of the octave above makes it rounder than a bare sine.
                let wave = sin(2 * .pi * note.frequency * u) + 0.2 * sin(4 * .pi * note.frequency * u)
                value += wave / 1.2 * rise * fade * tail
            }
            return Int16((max(-1, min(1, value * level)) * Double(Int16.max)).rounded())
        }
    }
}
