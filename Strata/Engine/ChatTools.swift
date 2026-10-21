import Foundation

/// The tools a chat turns on and off from the composer's "+" menu, in groups. Settings holds the switches a new chat
/// starts with (`AppSettings.defaultToolGroups`).
///
/// The request's prefix (tools, then the system message, then the messages) is what the provider caches, so a chat
/// keeps the groups it offered at its first request (`Conversation.offeredTools`): a group turned off later stays in
/// the request and its calls are refused (`OfferedTools`), and the model hears about the change in a short note at the
/// end of the next user message (`Message.apiNote`). A group that was off at the start is simply not offered.
enum ToolGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case web, browser, python, location, video

    var id: String { rawValue }

    /// The tools of the group. `show_html` is in none: it only displays, so every chat with tools has it.
    var toolNames: Set<String> {
        switch self {
        case .web: [ToolNames.webSearch, ToolNames.webFetch, ToolNames.runPlugin]
        case .browser: Set(ToolDefinition.browser(images: true).map(\.function.name))
        case .python: [ToolNames.runPython, ToolNames.viewImage]
        case .location: [ToolNames.currentLocation]
        case .video: [ToolNames.videoTranscript]
        }
    }

    static func group(of tool: String) -> ToolGroup? {
        allCases.first { $0.toolNames.contains(tool) }
    }

    /// The menu's title.
    var title: String {
        switch self {
        case .web: String(localized: "Web search")
        case .browser: String(localized: "Browser")
        case .python: String(localized: "Python")
        case .location: String(localized: "Location")
        case .video: String(localized: "Video transcripts")
        }
    }

    var systemImage: String {
        switch self {
        case .web: "magnifyingglass"
        case .browser: "safari"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .location: "location"
        case .video: "captions.bubble"
        }
    }

    /// The group's name in what the model reads (English, like the rest of the prompt).
    private var noteName: String {
        switch self {
        case .web: "Web search"
        case .browser: "Browser"
        case .python: "Python"
        case .location: "Location"
        case .video: "Video transcripts"
        }
    }

    private var modelName: String {
        switch self {
        case .web: "web search"
        case .browser: "the browser"
        case .python: "Python"
        case .location: "location"
        case .video: "video transcripts"
        }
    }

    /// The result of a call to a tool of the group after the user turned it off in the chat.
    var refusal: String {
        "The user turned off \(modelName) for this chat. Answer without it, or ask them to turn it on."
    }

    /// The state note appended to a user message in the request: "[Web search: off] [Python: on]", in a fixed order.
    static func note(_ groups: Set<ToolGroup>, enabled: Set<ToolGroup>) -> String {
        allCases.filter(groups.contains).map { "[\($0.noteName): \(enabled.contains($0) ? "on" : "off")]" }.joined(separator: " ")
    }

    /// The groups a note names.
    static func groups(inNote note: String?) -> Set<ToolGroup> {
        guard let note else { return [] }
        return Set(allCases.filter { note.contains("[\($0.noteName): ") })
    }

    /// Stored as their raw values, comma-separated, in a fixed order.
    static func encode(_ groups: Set<ToolGroup>) -> String {
        allCases.filter(groups.contains).map(\.rawValue).joined(separator: ",")
    }

    static func decode(_ raw: String) -> Set<ToolGroup> {
        Set(raw.split(separator: ",").compactMap { ToolGroup(rawValue: String($0)) })
    }
}

/// The switches of the chat a turn runs in, read by its tool calls when they run (a switch flipped while the reply
/// works holds from the next call). Main-actor bound, so the runner can hold it.
@MainActor
final class ChatToolSwitches {
    private weak var conversation: Conversation?

    init(_ conversation: Conversation) { self.conversation = conversation }

    /// The groups turned off now.
    var off: Set<ToolGroup> {
        guard let conversation, conversation.modelContext != nil, !conversation.isDeleted,
              let on = conversation.toolSwitches else { return [] }
        return Set(ToolGroup.allCases).subtracting(on)
    }
}
