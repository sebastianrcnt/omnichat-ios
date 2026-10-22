import Foundation
import SwiftData

/// What Shortcuts and Siri do with a chat: pick or make the conversation, send through `ChatController` like the
/// composer does, and wait for the answer. The App Intents themselves (`ChatIntents.swift`) only gather parameters and
/// hand over; this part is tested with a stub streamer.
///
/// Intents run in the app's own process (they live in the app target, not an extension), so they use the same
/// controller and SwiftData container as the window (`IntentDependencies`). A reply started here is an ordinary run in
/// its chat: it shows in the sidebar, keeps going if the intent stops waiting, and can be opened like any other.
@MainActor
struct IntentChat {
    let controller: ChatController
    let connections: ConnectionStore
    let settings: AppSettings
    let context: ModelContext

    enum Failure: LocalizedError, Equatable {
        case emptyPrompt
        case noModel
        case chatNotFound
        case chatBusy
        case reply(String)
        case stopped
        /// The intent stopped waiting; the reply goes on in the chat.
        case stillAnswering

        var errorDescription: String? {
            switch self {
            case .emptyPrompt: String(localized: "There is nothing to send.")
            case .noModel: String(localized: "Add a connection with a model in OpenChat first.")
            case .chatNotFound: String(localized: "That chat no longer exists.")
            case .chatBusy: String(localized: "That chat is still answering. Try again when it's done.")
            case .reply(let message): message
            case .stopped: String(localized: "The reply was stopped.")
            case .stillAnswering: String(localized: "OpenChat is still answering. The reply will be in the chat when it's done.")
            }
        }
    }

    /// How a reply that is still being written when the intent stops waiting ends up.
    enum Outcome: Equatable {
        case answered(String)
        case failed(String)
        case stopped
        case stillRunning
    }

    // MARK: Waiting

    /// How long an intent waits for its answer.
    ///
    /// In the background an iPhone app gets about half a minute before it is suspended (the reply's own background
    /// lease is the finite `beginBackgroundTask` one there: a continued-processing task can't be started from the
    /// background), and Siri wants an answer about as soon. Past that the intent asks to continue in the app, where
    /// the window is up (the browser and Python tools need it) and the reply can take as long as it takes. A Mac app
    /// is never suspended, so it waits the long time from the start.
    static var backgroundWait: Duration {
        #if os(iOS)
        .seconds(25)
        #else
        .seconds(300)
        #endif
    }
    static let foregroundWait: Duration = .seconds(600)

    // MARK: The conversation

    /// The chat to send in: `existing`, or a new one on `model` (else the model a new chat in the app would get).
    ///
    /// A new chat starts with the tool switches a new chat in the app has (Settings), minus interactive views (an
    /// answer read out by Siri or passed on by a shortcut can't show them), plus `requiredTools` (the intent's purpose
    /// needs them, as Summarize needs web search for a link). An existing chat keeps its own switches.
    func conversation(existing: UUID?, model: ModelSelection.Choice?, requiredTools: Set<ToolGroup> = []) async throws -> Conversation {
        if let existing {
            guard let conversation = Self.fetch(existing, in: context) else { throw Failure.chatNotFound }
            guard !controller.isRunning(conversation.id) else { throw Failure.chatBusy }
            if let model {
                conversation.connectionID = model.connectionID
                conversation.modelID = model.modelID
            } else if conversation.modelID == nil {
                // A chat made while there was no model takes the one there is now, as in the app.
                guard let choice = await defaultModel() else { throw Failure.noModel }
                conversation.connectionID = choice.connectionID
                conversation.modelID = choice.modelID
            }
            return conversation
        }
        let resolved: ModelSelection.Choice?
        if let model { resolved = model } else { resolved = await defaultModel() }
        guard let choice = resolved else { throw Failure.noModel }
        let conversation = Conversation(connectionID: choice.connectionID, modelID: choice.modelID, effort: settings.lastEffort)
        conversation.toolSwitches = settings.defaultToolGroups.subtracting([.views]).union(requiredTools)
        context.insert(conversation)
        return conversation
    }

    /// The model a new chat in the app would use. With none listed yet, the connections that can fetch their lists do
    /// first (the composer does the same before its first send).
    private func defaultModel() async -> ModelSelection.Choice? {
        if let choice = resolve() { return choice }
        for c in connections.connections where c.models.isEmpty {
            _ = try? await connections.refreshModels(for: c.id)
        }
        return resolve()
    }

    private func resolve() -> ModelSelection.Choice? {
        ModelSelection.resolve(connections: connections.connections, preferredConnectionID: settings.lastConnectionID,
                               preferredModelID: settings.lastModelID)
    }

    static func fetch(_ id: UUID, in context: ModelContext) -> Conversation? {
        try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: Sending

    /// Sends `prompt` in the chat. The reply's "Reply ready" notification is held back while the intent waits for it:
    /// the intent delivers the answer itself (`answer`).
    func send(_ prompt: String, in conversation: Conversation) throws {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyPrompt }
        guard !controller.isRunning(conversation.id) else { throw Failure.chatBusy }
        ReplyBackgroundExecution.quietConversations.insert(conversation.id)
        controller.send(text: text, images: [], conversation: conversation, context: context)
        try? context.save()
    }

    /// Waits for the chat's reply, at most `timeout`.
    func wait(for conversation: Conversation, timeout: Duration) async -> Outcome {
        let deadline = ContinuousClock.now + timeout
        while controller.isRunning(conversation.id) {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return .stillRunning }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Self.outcome(of: conversation)
    }

    /// What the chat's last turn came to.
    static func outcome(of conversation: Conversation) -> Outcome {
        guard let answer = conversation.leafMessage, answer.role == .assistant else {
            return .failed(String(localized: "There is no answer."))
        }
        if let error = answer.errorText { return .failed(error) }
        if answer.stoppedByUser && !answer.answeredEarly { return .stopped }
        return .answered(answer.text)
    }

    /// The whole reply as an intent sees it: wait in the background; when that runs out, continue in the app (when the
    /// system lets it) and wait there. `continueInForeground` brings the app up (it throws when the person declines);
    /// `show` opens the chat in it.
    ///
    /// - Parameter inApp: the app is already in front (or was asked to be): wait the long time from the start.
    func answer(_ conversation: Conversation, inApp: Bool, canContinueInForeground: Bool,
                backgroundWait: Duration = IntentChat.backgroundWait, foregroundWait: Duration = IntentChat.foregroundWait,
                continueInForeground: () async throws -> Void, show: (UUID) -> Void) async throws -> String {
        let id = conversation.id
        // Given up on (or done): a reply that ends later is announced as usual.
        defer { ReplyBackgroundExecution.quietConversations.remove(id) }
        var outcome = await wait(for: conversation, timeout: inApp ? foregroundWait : backgroundWait)
        if outcome == .stillRunning, !inApp, canContinueInForeground {
            ReplyBackgroundExecution.quietConversations.remove(id) // declining leaves the reply to its notification
            try await continueInForeground()
            ReplyBackgroundExecution.quietConversations.insert(id)
            show(id)
            outcome = await wait(for: conversation, timeout: foregroundWait)
        }
        switch outcome {
        case .answered(let text): return text
        case .failed(let message): throw Failure.reply(message)
        case .stopped: throw Failure.stopped
        case .stillRunning: throw Failure.stillAnswering
        }
    }

    /// What Siri says: the answer as plain text, cut to a length worth listening to. The intent's value keeps the
    /// Markdown for the next action.
    static func spoken(_ answer: String) -> String {
        ChatController.notificationBody(answer, limit: 1000)
    }
}

/// The prompts behind Summarize, and the tools each needs.
enum IntentPrompts {
    /// A single web link (with or without its scheme), else nil.
    static func link(in input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), host.contains(".") else { return nil }
        return url
    }

    struct Request: Equatable {
        var prompt: String
        var tools: Set<ToolGroup>
    }

    /// A link is read with web search (and a YouTube link from its transcript); text is summarized as it is.
    static func summary(of input: String) -> Request {
        if let url = link(in: input) {
            if YouTubeURL.isYouTube(url) {
                return Request(prompt: "Summarize this video: \(url.absoluteString)", tools: [.video, .web])
            }
            return Request(prompt: "Summarize this page: \(url.absoluteString)", tools: [.web])
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return Request(prompt: "Summarize the following text.\n\n\(text)", tools: [])
    }
}

/// Transcribe Video: the captions as `video_transcript` reads them, but whole and without a model in between.
enum IntentTranscripts {
    enum Failure: LocalizedError, Equatable {
        case notAVideoLink
        case unsupportedSite
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAVideoLink: String(localized: "That isn't a video link.")
            case .unsupportedSite: String(localized: "Only YouTube videos can be transcribed for now.")
            case .failed(let message): message
            }
        }
    }

    /// The video's title and link, the caption details and the timestamped transcript.
    static func text(link: String, language: String?, sources: [any TranscriptSource] = [YouTubeTranscriptSource()]) async throws -> String {
        guard let url = VideoTranscriptTool.url(from: link), url.host() != nil else { throw Failure.notAVideoLink }
        guard let (source, id) = sources.lazy.compactMap({ source in source.videoID(in: url).map { (source, $0) } }).first else {
            throw YouTubeURL.isYouTube(url) ? Failure.notAVideoLink : Failure.unsupportedSite
        }
        let lang = language.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
        let transcript: VideoTranscript
        do {
            transcript = try await source.transcript(videoID: id, language: lang)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        // The tool's first page, without the paging.
        let body = TranscriptFormatter.body(transcript.cues, duration: transcript.duration)
        return "Title: \(transcript.title)\nURL: \(transcript.url)\n\n" + TranscriptFormatter.header(transcript) + "\n\n" + body
    }
}
