import AppIntents
import Foundation
import SwiftData

/// Ask OmniChat: sends a message and returns the answer, so a shortcut can pass it on and Siri can read it out.
///
/// Runs in the background where it can: the reply is an ordinary run in its chat, the chat's tool switches apply,
/// and the answer comes back without the app opening. A reply that takes longer than `IntentChat.backgroundWait`
/// (long tool runs; the browser and Python tools also need the app's window) asks to continue in the app, where it
/// is waited for longer; declining leaves it running, and its notification says when it's ready.
struct AskOmniChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask OmniChat"
    static let description = IntentDescription("Sends a message to a model and returns its answer. Leave Chat empty to start a new chat.",
                                               categoryName: "Chats")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Prompt", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What do you want to ask?")
    var prompt: String

    @Parameter(title: "Model", description: "The model to answer. Leave empty for the one a new chat uses (or the chat's own).")
    var model: ChatModelEntity?

    @Parameter(title: "Chat", description: "The chat to continue. Leave empty to start a new chat.")
    var chat: ConversationEntity?

    @Parameter(title: "Show in OmniChat", description: "Open the chat in the app while it answers.", default: false)
    var showInApp: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$prompt)") {
            \.$model
            \.$chat
            \.$showInApp
        }
    }

    @Dependency private var container: ModelContainer
    @Dependency private var controller: ChatController
    @Dependency private var connections: ConnectionStore
    @Dependency private var settings: AppSettings

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let chat = IntentChat(controller: controller, connections: connections, settings: settings, context: container.mainContext)
        let answer = try await IntentReply.run(prompt: prompt, existing: self.chat?.id, model: model?.choice, requiredTools: [],
                                               showInApp: showInApp, chat: chat, intent: self)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: IntentChat.spoken(answer)))
    }
}

/// Summarize: a link (read with web search, a YouTube link from its transcript) or text, summarized in a new chat.
struct SummarizeIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize"
    static let description = IntentDescription("Summarizes a web page, a YouTube video or text, and returns the summary.",
                                               categoryName: "Chats")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Text or Link", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What do you want summarized?")
    var input: String

    @Parameter(title: "Model", description: "The model to answer. Leave empty for the one a new chat uses.")
    var model: ChatModelEntity?

    @Parameter(title: "Show in OmniChat", description: "Open the chat in the app while it answers.", default: false)
    var showInApp: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Summarize \(\.$input)") {
            \.$model
            \.$showInApp
        }
    }

    @Dependency private var container: ModelContainer
    @Dependency private var controller: ChatController
    @Dependency private var connections: ConnectionStore
    @Dependency private var settings: AppSettings

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let request = IntentPrompts.summary(of: input)
        let chat = IntentChat(controller: controller, connections: connections, settings: settings, context: container.mainContext)
        let answer = try await IntentReply.run(prompt: request.prompt, existing: nil, model: model?.choice, requiredTools: request.tools,
                                               showInApp: showInApp, chat: chat, intent: self)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: IntentChat.spoken(answer)))
    }
}

/// The flow Ask OmniChat and Summarize share.
@MainActor
enum IntentReply {
    static func run(prompt: String, existing: UUID?, model: ModelSelection.Choice?, requiredTools: Set<ToolGroup>,
                    showInApp: Bool, chat: IntentChat, intent: some AppIntent) async throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw IntentChat.Failure.emptyPrompt }
        let mode = intent.systemContext.currentMode
        var inApp = mode == .foreground
        if showInApp, !inApp, mode.canContinueInForeground {
            try await intent.continueInForeground(nil, alwaysConfirm: false)
            inApp = true
        }
        let conversation = try await chat.conversation(existing: existing, model: model, requiredTools: requiredTools)
        try chat.send(prompt, in: conversation)
        if inApp { IntentRouter.shared.open(conversation.id) }
        return try await chat.answer(conversation, inApp: inApp, canContinueInForeground: mode.canContinueInForeground,
                                     continueInForeground: {
                                         try await intent.continueInForeground(
                                             IntentDialog("Still working on it. Continue in OmniChat?"), alwaysConfirm: true)
                                     },
                                     show: { IntentRouter.shared.open($0) })
    }
}

/// New Chat: opens the app to an empty chat, with text in the composer when given.
struct NewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description = IntentDescription("Opens OmniChat to a new chat, optionally with text ready to send.",
                                               categoryName: "Chats")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Text", description: "Text to put in the message box.", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("New chat with \(\.$text)")
    }

    init() {}

    init(text: String?) {
        self.text = text
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.startNewChat(text: text)
        return .result()
    }
}

/// Open Chat: opens the app to a chat. Also what Spotlight runs when a chat found there is opened.
struct OpenChatIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Opens a chat in OmniChat.", categoryName: "Chats")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Chat", requestValueDialog: "Which chat?")
    var target: ConversationEntity

    init() {}

    init(target: ConversationEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.open(target.id)
        return .result()
    }
}

/// Transcribe Video: a video's captions, with timestamps, read on the device the way the `video_transcript` tool reads
/// them. No model is involved, so it's quick and costs nothing; Summarize does the summarizing.
struct TranscribeVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe Video"
    static let description = IntentDescription("Returns a YouTube video's transcript from its captions.", categoryName: "Chats")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Video Link", requestValueDialog: "Which video?")
    var link: URL

    @Parameter(title: "Language", description: "A language code such as en or ko. Leave empty for the video's own captions.")
    var language: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$link)") {
            \.$language
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = try await IntentTranscripts.text(link: link.absoluteString, language: language)
        return .result(value: text)
    }
}
