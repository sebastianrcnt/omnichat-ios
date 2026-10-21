import Testing
import Foundation
@testable import Strata

struct LoadingSoundPolicyTests {
    @Test func playsOnlyForWebWorkInTheBackgroundWithTheSettingOn() {
        #expect(BackgroundLoadingSound.shouldPlay(enabled: true, webWork: 1, inBackground: true))
        #expect(BackgroundLoadingSound.shouldPlay(enabled: true, webWork: 3, inBackground: true))
        #expect(!BackgroundLoadingSound.shouldPlay(enabled: false, webWork: 1, inBackground: true))
        #expect(!BackgroundLoadingSound.shouldPlay(enabled: true, webWork: 0, inBackground: true))
        #expect(!BackgroundLoadingSound.shouldPlay(enabled: true, webWork: 1, inBackground: false))
    }

    @MainActor @Test func theSettingIsOnByDefault() {
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        #expect(AppSettings(defaults: defaults).backgroundLoadingSound)
        defaults.set(false, forKey: BackgroundLoadingSound.enabledKey)
        #expect(!AppSettings(defaults: defaults).backgroundLoadingSound)
    }
}

@MainActor
struct LoadingSoundStateTests {
    @Test func startsWhenBackgroundedDuringWebWorkAndStopsWhenEitherEnds() async {
        let sound = BackgroundLoadingSound()
        sound.enabled = { true }
        sound.setBackground(false)
        sound.beginWebWork()
        #expect(!sound.isPlaying)
        sound.setBackground(true)
        #expect(sound.isPlaying)
        sound.setBackground(false) // back in front
        #expect(!sound.isPlaying)
        sound.setBackground(true)
        sound.beginWebWork() // two tools at once
        sound.endWebWork()
        #expect(sound.isPlaying)
        sound.endWebWork()
        #expect(!sound.isPlaying)
        sound.endWebWork() // unbalanced end never goes negative
        #expect(sound.webWork == 0)
    }

    @Test func offInSettingsNeverPlays() async {
        let sound = BackgroundLoadingSound()
        sound.enabled = { false }
        sound.setBackground(true)
        await sound.duringWebWork { #expect(!sound.isPlaying) }
    }

    @Test func duringWebWorkCountsForTheBody() async {
        let sound = BackgroundLoadingSound()
        sound.enabled = { true }
        sound.setBackground(true)
        await sound.duringWebWork { #expect(sound.isPlaying && sound.webWork == 1) }
        #expect(!sound.isPlaying && sound.webWork == 0)
    }

    @Test func viewsComeAndGo() {
        let sound = BackgroundLoadingSound()
        let view = HiddenWebView()
        defer { view.dispose() }
        sound.register(view)
        sound.register(view)
        #expect(sound.registeredCount == 1)
        sound.unregister(view)
        #expect(sound.registeredCount == 0)
    }

    @Test func poolIdleViewsAreNotPlayed() {
        let pool = WebViewPool()
        let view = pool.acquire(reader: false)
        #expect(BackgroundLoadingSound.shared.isRegistered(view))
        pool.release(view, reusable: true)
        #expect(!BackgroundLoadingSound.shared.isRegistered(view))
        let again = pool.acquire(reader: false)
        #expect(again === view && BackgroundLoadingSound.shared.isRegistered(view))
        view.dispose()
        #expect(!BackgroundLoadingSound.shared.isRegistered(view))
    }
}

struct LoadingToneTests {
    @Test func isAValidMonoPCMWave() {
        let wav = LoadingTone.wav()
        let samples = LoadingTone.pcm()
        #expect(samples.count == Int(Double(LoadingTone.sampleRate) * LoadingTone.seconds))
        #expect(wav.count == 44 + samples.count * 2)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        func u32(_ at: Int) -> UInt32 { wav[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        #expect(u32(24) == UInt32(LoadingTone.sampleRate))
        #expect(u32(40) == UInt32(samples.count * 2))
        #expect(Data(base64Encoded: LoadingTone.base64WAV) == wav)
    }

    @Test func isGentleAudibleAndLoopsWithoutAClick() {
        let samples = LoadingTone.pcm()
        let peak = samples.map { abs(Double($0)) / Double(Int16.max) }.max() ?? 0
        #expect(peak > 0.05) // WebKit counts the page as audible only if it really plays sound
        #expect(peak < 0.2)
        #expect(samples.first == 0)
        #expect(samples.suffix(1000).allSatisfy { $0 == 0 }) // quiet at the seam
    }
}
