import Foundation
import SwiftData
import SwiftUI
import Translation
import Observation

/// Hands a TranslationSession to the code that translates. The session is not Sendable; it is only used while the
/// closure that received it is waiting.
final class SessionTranslator: TextTranslating, @unchecked Sendable {
    private let session: TranslationSession

    init(_ session: TranslationSession) { self.session = session }

    func translate(_ texts: [String]) async throws -> [String] {
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        let responses = try await withTaskCancellationHandler {
            try await session.translations(from: requests)
        } onCancel: {
            session.cancel()
        }
        var out = [String?](repeating: nil, count: texts.count)
        for (position, response) in responses.enumerated() {
            let index = response.clientIdentifier.flatMap(Int.init) ?? position
            if out.indices.contains(index) { out[index] = response.targetText }
        }
        guard out.allSatisfy({ $0 != nil }) else { throw TranslationFailure.countMismatch }
        return out.map { $0! }
    }
}

/// What the answer row needs to draw the translate action and the original/translated toggle.
struct TranslationUI: Equatable {
    var offered = false
    var isTranslating = false
    /// A translation for the reader's language exists.
    var hasTranslation = false
    var showing = false
    var translatedText: String?
    var error: String?

    static let none = TranslationUI()
}

/// Translates finished answers on the device. Installed languages translate with no UI; others go through
/// `.translationTask`, which asks the person to download the language.
@MainActor
@Observable
final class TranslationService {
    enum Availability: Equatable { case installed, needsDownload, unsupported }

    /// Bound to `.translationTask` by the chat. Set when a language has to be downloaded first.
    var configuration: TranslationSession.Configuration?
    private(set) var translating: Set<UUID> = []
    private(set) var errors: [UUID: String] = [:]

    @ObservationIgnored var preferredLanguage: () -> String? = { TranslationLanguage.preferred }
    /// How a language pair is available. Replaced in tests and in debug runs.
    @ObservationIgnored var availability: (_ source: String, _ target: String) async -> Availability = { source, target in
        await TranslationService.systemAvailability(source: source, target: target)
    }
    /// Translators that need no download (installed languages). Replaced in tests and in debug runs.
    @ObservationIgnored var installedTranslator: (_ source: String, _ target: String) -> any TextTranslating = { source, target in
        TranslationService.systemTranslator(source: source, target: target)
    }

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var waiting: Waiting?
    @ObservationIgnored private var offers: [UUID: (key: Int, offered: Bool)] = [:]

    private struct Waiting {
        var text: String
        var continuation: CheckedContinuation<String, Error>
    }

    // MARK: What the row shows

    func ui(for message: Message, isStreaming: Bool) -> TranslationUI {
        guard TranslationEligibility.isEligible(role: message.role, text: message.text, isStreaming: isStreaming,
                                                hasError: message.errorText != nil, hasUnfinishedTurn: message.hasResume) else { return .none }
        let target = preferredLanguage()
        let state = TranslationState.resolve(translatedText: message.translatedText, storedTarget: message.translationTarget,
                                             showing: message.showingTranslation, currentTarget: target)
        var ui = TranslationUI(isTranslating: translating.contains(message.id), error: errors[message.id])
        if case .translated(let showing) = state {
            ui.offered = true
            ui.hasTranslation = true
            ui.showing = showing
            ui.translatedText = message.translatedText
        } else {
            ui.offered = offer(message, target: target)
        }
        return ui
    }

    /// The language check reads the whole answer, so it runs once per text and reader language.
    private func offer(_ message: Message, target: String?) -> Bool {
        var hasher = Hasher()
        hasher.combine(message.text)
        hasher.combine(target)
        let key = hasher.finalize()
        if let cached = offers[message.id], cached.key == key { return cached.offered }
        let offered = TranslationLanguage.shouldOffer(text: message.text, preferred: target)
        offers[message.id] = (key, offered)
        return offered
    }

    // MARK: Actions

    /// Translates the answer, or shows the translation it already has.
    func translate(_ message: Message, context: ModelContext, isStreaming: Bool = false) {
        let ui = ui(for: message, isStreaming: isStreaming)
        guard ui.offered, !ui.isTranslating, let target = preferredLanguage() else { return }
        errors[message.id] = nil
        if ui.hasTranslation { setShowing(true, message, context: context); return }
        let id = message.id, text = message.text
        translating.insert(id)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.translating.remove(id); self.tasks[id] = nil }
            do {
                let result = try await self.produce(text: text, target: target)
                guard !Task.isCancelled, message.text == text else { return }
                message.translatedText = result
                message.translationTarget = target
                message.showingTranslation = true
                try? context.save()
            } catch is CancellationError {
            } catch {
                self.errors[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func setShowing(_ showing: Bool, _ message: Message, context: ModelContext) {
        guard message.translatedText != nil else { return }
        message.showingTranslation = showing
        try? context.save()
    }

    func toggle(_ message: Message, context: ModelContext) {
        setShowing(!message.showingTranslation, message, context: context)
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }

    // MARK: Producing the translation

    /// The translated Markdown for `text`. Installed language pairs translate right here; others wait for the view.
    func produce(text: String, target: String) async throws -> String {
        guard let source = TranslationLanguage.dominant(of: text) else { throw TranslationFailure.unsupportedPair }
        switch await availability(source, target) {
        case .unsupported:
            throw TranslationFailure.unsupportedPair
        case .installed:
            return try await TranslationRunner.translate(text, with: installedTranslator(source, target))
        case .needsDownload:
            return try await withCheckedThrowingContinuation { continuation in
                waiting?.continuation.resume(throwing: CancellationError())
                waiting = Waiting(text: text, continuation: continuation)
                var next = Self.configuration(source: source, target: target)
                if configuration == next { next.invalidate() }
                configuration = next
            }
        }
    }

    /// Runs inside `.translationTask`, where the session may show the download prompt.
    func fulfill(_ translator: SessionTranslator) async {
        guard let waiting else { return }
        self.waiting = nil
        do {
            waiting.continuation.resume(returning: try await TranslationRunner.translate(waiting.text, with: translator))
        } catch {
            waiting.continuation.resume(throwing: error)
        }
    }

    // MARK: System framework

    static func configuration(source: String, target: String) -> TranslationSession.Configuration {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        if #available(iOS 26.4, *) {
            return TranslationSession.Configuration(source: from, target: to, preferredStrategy: .highFidelity)
        }
        return TranslationSession.Configuration(source: from, target: to)
    }

    static func systemAvailability(source: String, target: String) async -> Availability {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        let status: LanguageAvailability.Status
        if #available(iOS 26.4, *) {
            status = await LanguageAvailability(preferredStrategy: .highFidelity).status(from: from, to: to)
        } else {
            status = await LanguageAvailability().status(from: from, to: to)
        }
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        default: return .unsupported
        }
    }

    static func systemTranslator(source: String, target: String) -> any TextTranslating {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        if #available(iOS 26.4, *) {
            return SessionTranslator(TranslationSession(installedSource: from, target: to, preferredStrategy: .highFidelity))
        }
        return SessionTranslator(TranslationSession(installedSource: from, target: to))
    }
}
