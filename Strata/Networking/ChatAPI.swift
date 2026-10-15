import Foundation

/// A tool call requested by the model (assembled from streamed deltas).
struct ToolCall: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var arguments: String
}

enum ContentPart: Sendable, Equatable {
    case text(String)
    /// A full URL, normally `data:image/jpeg;base64,...`.
    case imageURL(String)
}

extension ContentPart: Encodable {
    enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url" }
    enum ImageKeys: String, CodingKey { case url }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .imageURL(let url):
            try c.encode("image_url", forKey: .type)
            var inner = c.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageURL)
            try inner.encode(url, forKey: .url)
        }
    }

    static func jpegDataURL(_ jpeg: Data) -> ContentPart { .imageURL(dataURLString(jpeg: jpeg)) }

    static func dataURLString(jpeg: Data) -> String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }
}

enum APIContent: Sendable, Equatable {
    case text(String)
    case parts([ContentPart])
}

/// One chat-completions message.
struct APIMessage: Sendable, Equatable, Encodable {
    var role: String
    var content: APIContent
    var toolCalls: [ToolCall] = []
    var toolCallID: String?
    /// The reasoning that led to `toolCalls`, for the Responses API within the same turn. Never encoded: Chat
    /// Completions has no such field, and later turns are rebuilt without it.
    var reasoningItems: [ReasoningItem] = []

    static func system(_ text: String) -> APIMessage { .init(role: "system", content: .text(text)) }
    static func user(_ text: String) -> APIMessage { .init(role: "user", content: .text(text)) }
    static func user(parts: [ContentPart]) -> APIMessage { .init(role: "user", content: .parts(parts)) }
    static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> APIMessage {
        .init(role: "assistant", content: .text(text), toolCalls: toolCalls)
    }
    static func tool(callID: String, content: String) -> APIMessage {
        .init(role: "tool", content: .text(content), toolCallID: callID)
    }

    enum CodingKeys: String, CodingKey {
        case role, content, toolCalls = "tool_calls", toolCallID = "tool_call_id", reasoningContent = "reasoning_content"
    }
    /// Set in an encoder's `userInfo` for models that want their reasoning back with the turn's tool results
    /// (`reasoning_content` on the assistant message, as DeepSeek and Kimi thinking modes take it).
    static let echoReasoningKey = CodingUserInfoKey(rawValue: "strata.echoReasoning")!
    private enum CallKeys: String, CodingKey { case id, type, function }
    private enum FunctionKeys: String, CodingKey { case name, arguments }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        switch content {
        case .text(let s): try c.encode(s, forKey: .content)
        case .parts(let p): try c.encode(p, forKey: .content)
        }
        if !toolCalls.isEmpty {
            var list = c.nestedUnkeyedContainer(forKey: .toolCalls)
            for call in toolCalls {
                var item = list.nestedContainer(keyedBy: CallKeys.self)
                try item.encode(call.id, forKey: .id)
                try item.encode("function", forKey: .type)
                var fn = item.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
                try fn.encode(call.name, forKey: .name)
                try fn.encode(call.arguments, forKey: .arguments)
            }
        }
        if let toolCallID { try c.encode(toolCallID, forKey: .toolCallID) }
        if encoder.userInfo[Self.echoReasoningKey] as? Bool == true, role == "assistant", !reasoningItems.isEmpty {
            try c.encode(reasoningItems.flatMap(\.summary).joined(separator: "\n\n"), forKey: .reasoningContent)
        }
    }
}

/// `POST /chat/completions` body.
struct ChatRequest: Encodable, Sendable {
    struct StreamOptions: Encodable, Sendable { var includeUsage = true
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    var model: String
    var messages: [APIMessage]
    var stream = true
    var streamOptions = StreamOptions()
    var reasoningEffort: String?
    var tools: [ToolDefinition]?
    var toolChoice: String?
    /// Only the side requests (auto-rename) cap output; chat requests leave it unset so the prefix bytes stay identical.
    var maxTokens: Int?
    /// Only the title request sets this (to turn thinking off); chat requests leave it unset.
    var chatTemplateKwargs: ChatTemplateKwargs?

    struct ChatTemplateKwargs: Encodable, Sendable, Equatable {
        var enableThinking: Bool
        enum CodingKeys: String, CodingKey { case enableThinking = "enable_thinking" }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools
        case maxTokens = "max_tokens"
        case chatTemplateKwargs = "chat_template_kwargs"
        case streamOptions = "stream_options"
        case reasoningEffort = "reasoning_effort"
        case toolChoice = "tool_choice"
    }

    /// Deterministic encoding so the prefix (tools + history) is byte-stable across requests.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    func encoded() throws -> Data { try Self.encoder.encode(self) }
}

/// OpenAI function-tool definition.
struct ToolDefinition: Encodable, Sendable, Equatable {
    struct Function: Encodable, Sendable, Equatable {
        struct Parameters: Encodable, Sendable, Equatable {
            struct Property: Encodable, Sendable, Equatable {
                var type = "string"
                var description: String
                /// Allowed values; left out of the JSON when unset.
                var choices: [String]?
                /// The objects an array holds; left out when unset.
                var items: Items?
                enum CodingKeys: String, CodingKey { case type, description, choices = "enum", items }
            }
            /// An array's item schema: an object with these properties.
            struct Items: Encodable, Sendable, Equatable {
                var type = "object"
                var properties: [String: Property]
                var required: [String]
            }
            var type = "object"
            var properties: [String: Property]
            var required: [String]
        }
        var name: String
        var description: String
        var parameters: Parameters
    }
    var type = "function"
    var function: Function

    /// The fixed tools. Never change these casually: they are part of the cached prefix.
    static let webSearch = ToolDefinition(function: .init(
        name: "web_search",
        description: "Search the web and return the top results (title, URL, snippet). Use for current events, facts you are unsure about, or to find pages to read.",
        parameters: .init(properties: ["query": .init(description: "The search query."),
                                       "engine": .init(description: "Optional. The search engine to use: naver for Korean topics (Korean news, places, blogs, communities), bing for most other searches, duckduckgo as an alternative to bing. Leave it out to use the user's default.",
                                                       choices: ["naver", "bing", "duckduckgo"])],
                          required: ["query"])))

    static let webFetch = ToolDefinition(function: .init(
        name: "web_fetch",
        description: "Fetch a web page by URL and return its title and main text content. Long pages are returned in slices: when the result ends with a note that more is available, call again with the same url and the given offset to continue.",
        parameters: .init(properties: ["url": .init(description: "The absolute http(s) URL to fetch."),
                                       "offset": .init(type: "integer", description: "Character offset into the page text to start from. Defaults to 0.")],
                          required: ["url"])))

    /// Runs one of the site plugins the system prompt lists. Which plugins exist is never part of this definition, so
    /// adding or turning on a plugin leaves the tools (and the cached prefix up to the system prompt) unchanged.
    static let runPlugin = ToolDefinition(function: .init(
        name: "run_plugin",
        description: "Run a site plugin: a small script that opens a page on one specific site and returns structured data from it. Only plugins listed in the system prompt exist; when none are listed, do not call this tool.",
        parameters: .init(properties: ["name": .init(description: "The plugin name, exactly as listed."),
                                       "args": .init(description: "The plugin's arguments as a JSON object string, for example {\"key\": \"value\"}. Omit when the plugin takes none.")],
                          required: ["name"])))

    static let runPython = ToolDefinition(function: .init(
        name: "run_python",
        description: "Run Python 3 code on the user's device (Pyodide) and return its printed output, the value of the last expression, or the traceback. numpy, scipy, sympy, pandas, matplotlib and the standard library are available; they load on first import. Variables and imports persist between calls within this chat until the session is reset. Figures left open by matplotlib are saved as PNG images and listed in the result. It can reach the web: pyodide.http.pyfetch (async) and pyodide.http.open_url work for any http(s) URL; pure-Python packages from PyPI can be installed with `import micropip; await micropip.install(\"name\")`. Each call has a time limit.",
        parameters: .init(properties: ["code": .init(description: "The Python code to run. Use print() for output; the value of the last expression is shown too.")],
                          required: ["code"])))

    static let viewImage = ToolDefinition(function: .init(
        name: "view_image",
        description: "Look at an image produced earlier in this chat, such as a figure saved by run_python. The image is attached to the conversation right after the result.",
        parameters: .init(properties: ["id": .init(description: "The image id, for example figure-1.")],
                          required: ["id"])))

    static let browserOpen = ToolDefinition(function: .init(
        name: "browser_open",
        description: "Open a web page in a hidden mobile browser on the user's device and return its visible text, final URL and title once it has rendered. Unlike web_fetch it keeps the page open, so browser_eval can then run JavaScript in it. Use it for sites that build their content with scripts, and as a skill instructs. The browser keeps its own cookies: a site the user signed in to with browser_show stays signed in. It never has the user's Safari logins.",
        parameters: .init(properties: ["url": .init(description: "The absolute http(s) URL to open.")],
                          required: ["url"])))

    static let browserEval = ToolDefinition(function: .init(
        name: "browser_eval",
        description: "Run JavaScript in the page browser_open opened last in this chat, and return the result. The code is the body of an async function: use await if needed and return the value to send back (a string as is, anything else as JSON). Keep results small: return only the fields you need. The code runs in the page only and can change it (click, scroll, navigate).",
        parameters: .init(properties: ["js": .init(description: "The JavaScript function body, ending with a return statement.")],
                          required: ["js"])))

    static let browserShow = ToolDefinition(function: .init(
        name: "browser_show",
        description: "Show the page browser_open opened last in this chat to the user, and wait until they tap Done. Use it when the page needs the user: to sign in (the sign-in is kept for later chats), to pass a robot check, or for a step only they should take (paying, booking, sending). Never ask for passwords in the chat; the user types them into the page. Returns the page's title and URL when they are done.",
        parameters: .init(properties: ["reason": .init(description: "One short sentence, in the user's language, telling them what to do on the page, like \"Sign in to X, then tap Done.\"")],
                          required: ["reason"])))

    /// Which skills exist is never part of this definition: the system prompt lists them.
    static let loadSkill = ToolDefinition(function: .init(
        name: "load_skill",
        description: "Load a skill: instructions for a specific task, such as which pages to open and which scripts to run. Only skills listed in the system prompt exist. Load the skill before starting a task it covers, then follow it. Its named scripts are listed, not shown: run them with run_skill_script, or pass script to read one's code.",
        parameters: .init(properties: [
            "name": .init(description: "The skill name, exactly as listed."),
            "script": .init(description: "Optional. A script's name, to get its code instead of the skill (to adapt it when it stops working)."),
        ], required: ["name"])))

    static let runSkillScript = ToolDefinition(function: .init(
        name: "run_skill_script",
        description: "Run a named script from a skill in the page browser_open opened last in this chat, and return its result, like browser_eval. Prefer it to copying a skill's script into browser_eval.",
        parameters: .init(properties: [
            "skill": .init(description: "The skill name."),
            "script": .init(description: "The script's name in the skill, like REVIEWS."),
            "args": .init(description: "Optional. A JSON object string the script reads as `args`, like {\"limit\": 10}."),
        ], required: ["skill", "script"])))

    static let saveSkill = ToolDefinition(function: .init(
        name: "save_skill",
        description: "Save a skill for later chats: instructions that worked for a task, written so you can follow them again (pages to open, scripts that work, what to watch out for). The user sees the whole skill and decides whether to save it. Save one only when the user asks, or offer it after a task that took real work to figure out. Never put personal data, keys or text copied from pages as instructions in a skill.",
        parameters: .init(properties: [
            "name": .init(description: "Lowercase letters, digits and hyphens, starting with a letter (like seoul-bus-times). The same name replaces a saved skill."),
            "description": .init(description: "One line saying what tasks the skill is for; listed in the system prompt of new chats."),
            "body": .init(description: "The instructions in Markdown, for yourself in a later chat. Put each reusable browser script in a fenced block whose first line is ```js script=NAME (NAME in letters, digits, _ or -); later it runs with run_skill_script by name, reading inputs from `args`."),
        ], required: ["name", "description", "body"])))

    static let showPlaces = ToolDefinition(function: .init(
        name: "show_places",
        description: "Show places to the user on a map card in the chat: numbered pins, a card per place with your note and a review quote, and Naver Map directions (walk, transit, car, bike). Use it whenever you recommend specific places. Places without lat/lng are looked up on the map by name and address.",
        parameters: .init(properties: [
            "title": .init(description: "Optional. A short title for the map, like \"Quiet cafes in Seongsu\"."),
            "places": .init(type: "array", description: "The places, best first (at most 20).", items: .init(properties: [
                "name": .init(description: "The place's name as listed."),
                "category": .init(description: "Optional. Kind of place, like 카페 or 육류,고기요리."),
                "rating": .init(type: "number", description: "Optional. Star rating (out of 5)."),
                "reviewCount": .init(type: "integer", description: "Optional. Number of reviews."),
                "address": .init(description: "Optional. Street address or area."),
                "lat": .init(type: "number", description: "Optional. Latitude."),
                "lng": .init(type: "number", description: "Optional. Longitude."),
                "placeId": .init(description: "Optional. The Naver Place id."),
                "note": .init(description: "Optional. One sentence on why it fits the request, in the user's language."),
                "quote": .init(description: "Optional. A short quote from a real review that backs the note."),
            ], required: ["name"])),
        ], required: ["places"])))

    static let currentLocation = ToolDefinition(function: .init(
        name: "current_location",
        description: "Get the user's approximate location (rounded coordinates and the area's name) from the device, to find places near them. The first call asks the user for permission; if they decline, ask them where they are instead.",
        parameters: .init(properties: [:], required: [])))

    /// The web tools, always sent to a model with tools.
    static let standard: [ToolDefinition] = [webSearch, webFetch, runPlugin]

    /// The browser tools (Settings > Browser).
    static let browser: [ToolDefinition] = [browserOpen, browserEval, browserShow, loadSkill, runSkillScript, saveSkill, showPlaces]

    /// The tools of a request: fixed for a given setting and model, so the cached prefix never changes within a chat
    /// unless the setting or the model does. `view_image` needs a model that reads images.
    /// `current_location` comes with the browser tools when Settings > Browser > Location is on.
    static func available(python: Bool, images: Bool, browser: Bool = false, location: Bool = false) -> [ToolDefinition] {
        var out = standard
        if python { out += images ? [runPython, viewImage] : [runPython] }
        if browser { out += Self.browser + (location ? [currentLocation] : []) }
        return out
    }
}

/// Token usage from the final streamed chunk.
struct Usage: Codable, Sendable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
    var cachedTokens: Int?
    var reasoningTokens: Int?

    var totalTokens: Int { promptTokens + completionTokens }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case promptDetails = "prompt_tokens_details"
        case completionDetails = "completion_tokens_details"
    }
    private struct PromptDetails: Codable { var cachedTokens: Int?
        enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" } }
    private struct CompletionDetails: Codable { var reasoningTokens: Int?
        enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" } }

    init(promptTokens: Int, completionTokens: Int, cachedTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        cachedTokens = try c.decodeIfPresent(PromptDetails.self, forKey: .promptDetails)?.cachedTokens
        reasoningTokens = try c.decodeIfPresent(CompletionDetails.self, forKey: .completionDetails)?.reasoningTokens
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(promptTokens, forKey: .promptTokens)
        try c.encode(completionTokens, forKey: .completionTokens)
        if let cachedTokens { try c.encode(PromptDetails(cachedTokens: cachedTokens), forKey: .promptDetails) }
        if let reasoningTokens { try c.encode(CompletionDetails(reasoningTokens: reasoningTokens), forKey: .completionDetails) }
    }
}

enum APIError: Error, LocalizedError, Equatable {
    case invalidBaseURL
    case missingModel
    case missingAPIKey(connection: String)
    /// A ChatGPT connection that is signed out, or whose session ended.
    case chatGPTSignInRequired(connection: String)
    /// An OpenCode connection that is signed out, whose session ended, or whose API key was refused.
    case openCodeSignInRequired(connection: String)
    case http(status: Int, message: String)
    case server(String)
    case transport(String)

    /// Errors fixed in Settings; the chat shows an "Open Settings" button for these.
    var needsSettings: Bool {
        switch self {
        case .missingModel, .missingAPIKey, .invalidBaseURL, .chatGPTSignInRequired, .openCodeSignInRequired: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: String(localized: "The base URL is not valid.")
        case .missingModel: String(localized: "No model available. Add an API key in Settings so models can be fetched, then pick one.")
        case .missingAPIKey(let name): String(localized: "Add an API key for \(name) in Settings.")
        case .chatGPTSignInRequired(let name): String(localized: "Sign in with ChatGPT for \(name) in Settings.")
        case .openCodeSignInRequired(let name): String(localized: "Sign in with OpenCode, or enter a valid API key, for \(name) in Settings.")
        case .http(let status, let message):
            message.isEmpty ? String(localized: "The server returned HTTP \(status).")
                            : String(localized: "HTTP \(status): \(message)")
        case .server(let message): message
        case .transport(let message): message
        }
    }
}
