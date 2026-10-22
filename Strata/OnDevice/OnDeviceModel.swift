import Foundation

/// Apple's on-device model (the Foundation Models framework) as a connection: no key, no network, nothing leaves the
/// device. `OnDeviceClient` turns the app's requests into what the model takes; the model itself sits behind
/// `OnDeviceLanguageModel` so the mapping is tested without it (`AppleFoundationModel` is the real one).
enum OnDevice {
    /// The one model the connection offers. Requests carry this id; the model behind it is the system's.
    static let modelID = "apple-on-device"
    static let modelName = "Apple Foundation Model"
    static let connectionName = "Apple Intelligence"
    /// Never contacted: an `Endpoint` needs a URL, and the request ring shows it.
    static let baseURL = URL(string: "ondevice://apple-intelligence")!
    /// The window when the system doesn't say (the first release's).
    static let fallbackContextSize = 4096
    /// The connection used for titles when "Name chats on device" is on and no on-device connection exists.
    static let titleConnectionID = UUID(uuidString: "A99E0D3C-0000-4000-8000-0000000000A1")!

    /// The system's model. Code that needs it takes it as a parameter defaulting to this, so tests pass a stand-in.
    static let system: any OnDeviceLanguageModel = AppleFoundationModel()
}

/// Whether the on-device model can answer now: `SystemLanguageModel.Availability`, plus an OS without the framework.
enum OnDeviceAvailability: Equatable, Sendable {
    case available
    /// Not an Apple Intelligence device (or a Mac or simulator host without it).
    case deviceNotEligible
    /// Supported, but Apple Intelligence is turned off in Settings.
    case appleIntelligenceNotEnabled
    /// Supported and on, but the model is still downloading (or otherwise not ready yet).
    case modelNotReady

    var isAvailable: Bool { self == .available }

    /// Worth offering on this device: it runs now, or will once the user turns it on or the download finishes.
    var isSupported: Bool { self != .deviceNotEligible }

    /// What the chat says when a request can't run, and the connection's status line.
    var message: String {
        switch self {
        case .available: String(localized: "Ready · runs on this device")
        case .deviceNotEligible:
            #if os(macOS)
            String(localized: "This Mac can't run Apple Intelligence, so the on-device model isn't available. Choose another connection.")
            #else
            String(localized: "This device can't run Apple Intelligence, so the on-device model isn't available. Choose another connection.")
            #endif
        case .appleIntelligenceNotEnabled:
            #if os(macOS)
            String(localized: "Apple Intelligence is off. Turn it on in System Settings > Apple Intelligence & Siri to use the on-device model.")
            #else
            String(localized: "Apple Intelligence is off. Turn it on in Settings > Apple Intelligence & Siri to use the on-device model.")
            #endif
        case .modelNotReady:
            String(localized: "The on-device model is still downloading. Keep the device on Wi-Fi and power, and try again in a few minutes.")
        }
    }

    /// Shorter, for a settings row.
    var shortStatus: String {
        switch self {
        case .available: String(localized: "Ready")
        case .deviceNotEligible: String(localized: "Not supported on this device")
        case .appleIntelligenceNotEnabled: String(localized: "Apple Intelligence is off")
        case .modelNotReady: String(localized: "Downloading the model…")
        }
    }
}

/// Why a request to the on-device model failed, as the app tells it (`message`). The real model maps the framework's
/// errors onto these, so the client and the tests never see the framework's types.
enum OnDeviceFailure: Error, Equatable, Sendable {
    case unavailable(OnDeviceAvailability)
    /// The prompt (instructions, history and answer) didn't fit the window.
    case contextExceeded
    /// Apple's safety guardrails flagged the prompt or the answer.
    case guardrailViolation
    case unsupportedLanguage
    /// Too many requests (the system limits apps in the background).
    case rateLimited
    case assetsUnavailable
    case refusal(String?)
    case other(String)

    var message: String {
        switch self {
        case .unavailable(let availability): availability.message
        case .contextExceeded:
            // Says "context window" so compaction's `isContextOverflow` recognizes it.
            String(localized: "This conversation is too long for the on-device model's context window. Start a new chat, or shorten the message.")
        case .guardrailViolation:
            String(localized: "Apple's on-device safety guardrails stopped this answer. Try rephrasing, or use another connection.")
        case .unsupportedLanguage:
            String(localized: "The on-device model doesn't support this language yet. Try English or another supported language, or use another connection.")
        case .rateLimited:
            String(localized: "The on-device model is busy. Try again in a moment, with OmniChat open.")
        case .assetsUnavailable:
            String(localized: "The on-device model isn't available right now (it may be updating). Try again later.")
        case .refusal(let explanation):
            explanation.map { String(localized: "The on-device model declined: \($0)") }
                ?? String(localized: "The on-device model declined to answer this request.")
        case .other(let text): String(localized: "The on-device model failed: \(text)")
        }
    }

    /// The error the chat shows.
    var apiError: APIError { .server(message) }
}

/// One function tool offered to the on-device model: a name, a short description and flat parameters.
struct OnDeviceToolSpec: Equatable, Sendable {
    struct Parameter: Equatable, Sendable {
        enum Kind: String, Sendable { case string, integer, number, boolean }
        var name: String
        var description: String
        var kind: Kind = .string
        var optional = false
    }

    var name: String
    var description: String
    var parameters: [Parameter]
}

/// What the model is asked: its instructions, the turns before, and the message to answer now (with that message's
/// images, for a model that reads them).
struct OnDevicePrompt: Equatable, Sendable {
    struct Turn: Equatable, Sendable {
        enum Role: Sendable { case user, assistant }
        var role: Role
        var text: String
    }

    var instructions: String
    var history: [Turn]
    var prompt: String
    var images: [Data] = []
    /// The largest answer to allow, when the request caps it (titles do).
    var maxTokens: Int?
}

/// What the model streams back.
enum OnDeviceEvent: Equatable, Sendable {
    /// New answer text since the last event.
    case text(String)
    /// The model asked for a tool; the arguments are a JSON object. The answer stops here (`OnDeviceClient`).
    case toolCall(name: String, arguments: String)
    /// Tokens of the prompt and the answer, when the system reports them.
    case usage(prompt: Int, completion: Int)
}

/// The on-device model. Errors thrown from `respond` are `OnDeviceFailure`s (anything else counts as `.other`).
protocol OnDeviceLanguageModel: Sendable {
    var availability: OnDeviceAvailability { get }
    /// The context window in tokens: instructions, history, prompt and answer together.
    var contextSize: Int { get }
    /// Whether the prompt may carry images (the model has vision).
    var readsImages: Bool { get }
    func respond(to prompt: OnDevicePrompt, tools: [OnDeviceToolSpec]) -> AsyncThrowingStream<OnDeviceEvent, Error>
}
