import Foundation
import Observation
import Translation

/// Translates English thinking into Korean on the device, for the thought lines (Settings > Thinking > Translate).
///
/// Uses the low-latency on-device model and only an installed language pair: nothing is downloaded mid-answer (Settings
/// offers the download). Text that isn't English maps to itself. The newest request goes first, so a live line never
/// waits behind a scroll through old ones.
@MainActor
@Observable
final class ThoughtTranslator {
    static let shared = ThoughtTranslator()
    static let source = "en"
    static let target = "ko"

    /// Source text to what to show for it: the translation, or the text itself when it isn't English.
    private(set) var results: [String: String] = [:]

    @ObservationIgnored var translator: (any TextTranslating)?
    /// Whether the pair is installed. Replaced in tests.
    @ObservationIgnored var isInstalled: () async -> Bool = { await ThoughtTranslator.systemStatus() == .installed }
    /// The language of a short text, or nil when unsure. Replaced in tests.
    @ObservationIgnored var language: (String) -> String? = { ThoughtTranslator.detect($0) }

    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var installed: Bool?

    static let maxQueue = 40
    static let maxResults = 600

    /// What to show for `text`, once known.
    func result(for text: String) -> String? { results[text] }

    /// Asks for `text`; the newest request is translated next.
    func request(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, results[text] == nil else { return }
        if queued.contains(text) { queue.removeAll { $0 == text } } else { queued.insert(text) }
        queue.append(text)
        if queue.count > Self.maxQueue {
            let dropped = queue.removeFirst()
            queued.remove(dropped)
        }
        if worker == nil { worker = Task { [weak self] in await self?.drain() } }
    }

    private func drain() async {
        defer { worker = nil }
        while let text = queue.popLast() {
            queued.remove(text)
            guard results[text] == nil else { continue }
            guard let language = language(text), TranslationLanguage.differs(language, Self.target) else {
                store(text, text) // already Korean, or too short to tell
                continue
            }
            guard !TranslationLanguage.differs(language, Self.source) else { store(text, text); continue }
            if installed == nil { installed = await isInstalled() }
            guard installed == true else { queue.removeAll(); queued.removeAll(); return }
            if translator == nil { translator = Self.systemTranslator() }
            guard let translator, let out = try? await translator.translate([text]).first, !out.isEmpty else { continue }
            store(text, out)
        }
    }

    private func store(_ text: String, _ shown: String) {
        if results.count >= Self.maxResults { results.removeAll(keepingCapacity: true) }
        results[text] = shown
    }

    /// After a download in Settings, check again.
    func recheck() { installed = nil }

    // MARK: System framework

    static func detect(_ text: String) -> String? {
        let letters = text.unicodeScalars.lazy.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 4 else { return nil }
        if text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) { return "ko" }
        return TranslationLanguage.dominant(of: text) ?? (text.unicodeScalars.allSatisfy(\.isASCII) ? "en" : nil)
    }

    static func systemStatus() async -> LanguageAvailability.Status {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        if #available(iOS 26.4, macOS 26.4, *) {
            return await LanguageAvailability(preferredStrategy: .lowLatency).status(from: from, to: to)
        }
        return await LanguageAvailability().status(from: from, to: to)
    }

    static func systemTranslator() -> any TextTranslating {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        if #available(iOS 26.4, macOS 26.4, *) {
            return SessionTranslator(TranslationSession(installedSource: from, target: to, preferredStrategy: .lowLatency))
        }
        return SessionTranslator(TranslationSession(installedSource: from, target: to))
    }

    /// For `.translationTask` in Settings, which shows the download prompt.
    static var downloadConfiguration: TranslationSession.Configuration {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        if #available(iOS 26.4, macOS 26.4, *) {
            return TranslationSession.Configuration(source: from, target: to, preferredStrategy: .lowLatency)
        }
        return TranslationSession.Configuration(source: from, target: to)
    }
}

/// When a live thought is ready to translate: a finished sentence, not one still being written.
enum ThoughtCompletion {
    static func isFinished(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return ".?!。:)\"'”".contains(last)
    }
}
