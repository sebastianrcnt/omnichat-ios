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
            /// A package tool's schema as the package wrote it (`ToolDefinition.package`): encoded in place of the typed
            /// fields. Built-in tools never set it, so their bytes are what they always were.
            var raw: PackageJSON?

            init(type: String = "object", properties: [String: Property], required: [String], raw: PackageJSON? = nil) {
                self.type = type
                self.properties = properties
                self.required = required
                self.raw = raw
            }

            enum CodingKeys: String, CodingKey { case type, properties, required }

            func encode(to encoder: Encoder) throws {
                if let raw { try raw.encode(to: encoder); return }
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(type, forKey: .type)
                try c.encode(properties, forKey: .properties)
                try c.encode(required, forKey: .required)
            }
        }
        var name: String
        var description: String
        var parameters: Parameters
    }
    var type = "function"
    var function: Function

    /// A package tool from its frozen definition (`PackageRender.toolDefinition`, kept in the chat's snapshot): the same
    /// snapshot gives the same bytes on every request.
    static func package(_ definition: PackageJSON) -> ToolDefinition? {
        guard let function = definition["function"], let name = function["name"]?.stringValue,
              let description = function["description"]?.stringValue, let parameters = function["parameters"] else { return nil }
        return ToolDefinition(function: .init(name: name, description: description,
                                              parameters: .init(properties: [:], required: [], raw: parameters)))
    }

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
        description: "Fetch a web page by URL and return its title and main text content. PDFs work too (their text, page by page; for arXiv use the /pdf/ link). Long pages are returned in slices: when the result ends with a note that more is available, call again with the same url and the given offset to continue.",
        parameters: .init(properties: ["url": .init(description: "The absolute http(s) URL to fetch."),
                                       "offset": .init(type: "integer", description: "Character offset into the page text to start from. Defaults to 0.")],
                          required: ["url"])))

    static let videoTranscript = ToolDefinition(function: .init(
        name: "video_transcript",
        description: "Get a video's transcript from its captions (uploaded by the channel, or auto-generated), with [mm:ss] timestamps, and its title, channel and length. Use it to summarize a video, answer questions about it or quote it; web_fetch can't read what is said in a video. Only YouTube works for now: youtube.com and youtu.be links, Shorts and live streams. Long transcripts are returned in slices: when the result ends with a note that more is available, call again with the same url and the given offset to continue.",
        parameters: .init(properties: ["url": .init(description: "The video's link, like https://www.youtube.com/watch?v=... or https://youtu.be/..."),
                                       "lang": .init(description: "Optional. A language code like ko or en, for captions in that language. Leave it out for the video's original language."),
                                       "offset": .init(type: "integer", description: "Character offset into the transcript to start from. Defaults to 0.")],
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
        description: "Run Python 3 code on the user's device (Pyodide) and return its printed output, the value of the last expression, or the traceback. numpy, scipy, sympy, pandas, matplotlib and the standard library are available; they load on first import. Variables, imports and files persist between calls within this chat until the session is reset; files exist only inside this interpreter. Figures left open by matplotlib are saved as PNG images and listed in the result. It can reach the web: pyodide.http.pyfetch (async; use top-level await, not asyncio.run) and pyodide.http.open_url work for any http(s) URL; pure-Python packages from PyPI can be installed with `import micropip; await micropip.install(\"name\")`. Real TCP and UDP sockets work too, through the socket module and libraries built on it (database drivers, smtplib, imaplib, asyncio streams, aiohttp), including TLS as a client. Connecting to a private, LAN or loopback address asks the user first; a refusal raises PermissionError. Not possible: raw sockets or ICMP (ping), multicast or broadcast (needs an Apple entitlement), connections from the internet to the device, subprocess or other programs; connections can drop while the app is in the background. Each call has a time limit.",
        parameters: .init(properties: ["code": .init(description: "The Python code to run. Use print() for output; the value of the last expression is shown too.")],
                          required: ["code"])))

    static let viewImage = ToolDefinition(function: .init(
        name: "view_image",
        description: "Look at an image produced earlier in this chat, such as a figure saved by run_python. The image is attached to the conversation right after the result.",
        parameters: .init(properties: ["id": .init(description: "The image id, for example figure-1.")],
                          required: ["id"])))

    static let browserOpen = ToolDefinition(function: .init(
        name: "browser_open",
        description: "Open a web page in a hidden mobile browser on the user's device and return its visible text, final URL and title once it has rendered, followed by the page state: the elements in view with an [index] for browser_click, browser_type and the other index tools. Unlike web_fetch it keeps the page open. Use it for sites that build their content with scripts, to click through or fill in a site, and as a skill instructs. The browser shares its cookies with web_search and web_fetch: a site the user signed in to with browser_show, or a robot check they solved, stays that way. It never has the user's Safari logins.",
        parameters: .init(properties: ["url": .init(description: "The absolute http(s) URL to open.")],
                          required: ["url"])))

    static let browserEval = ToolDefinition(function: .init(
        name: "browser_eval",
        description: "Run JavaScript in the page browser_open opened last in this chat, and return the result. For clicking, typing and scrolling, prefer the index tools (browser_click, browser_type, ...); use this to extract data in bulk or for what they can't do. The code is the body of an async function: use await if needed and return the value to send back (a string as is, anything else as JSON). Keep results small: return only the fields you need. The code runs in the page only and can change it.",
        parameters: .init(properties: ["js": .init(description: "The JavaScript function body, ending with a return statement.")],
                          required: ["js"])))

    static let browserShow = ToolDefinition(function: .init(
        name: "browser_show",
        description: "Show a page to the user, and wait until they tap Done: by default the page browser_open opened last in this chat, or, with page, a page a failed web_search, web_fetch or browser call kept open (its result names the page id). Use it when the page needs the user: to sign in (the sign-in is kept for later chats and every web tool), to pass a robot check, to close a pop-up, or for a step only they should take (paying, booking, sending). Never ask for passwords in the chat; the user types them into the page. Returns the page's title and URL when they are done, and for a kept page its text.",
        parameters: .init(properties: ["reason": .init(description: "One short sentence, in the user's language, telling them what to do on the page, like \"Sign in to X, then tap Done.\""),
                                       "page": .init(description: "Optional. The id of a page a failed tool kept open, like page7, from its result. Leave it out for the page browser_open opened last.")],
                          required: ["reason"])))

    static let browserState = ToolDefinition(function: .init(
        name: "browser_state",
        description: "Return the current page's state: URL, title, scroll position, and the elements in view as a tree. `[12]<button aria-label=Close />` is an element you can act on by its index; lines without an index are text; tabs show nesting; `*[n]` marks elements new since the last state (after typing, often suggestions); `|SCROLL|[n]` is a container that scrolls on its own. Indices are valid only for the latest state. Each index tool already returns the new state, so call this only to look again (after a wait, or after browser_eval).",
        parameters: .init(properties: [:], required: [])))

    static let browserClick = ToolDefinition(function: .init(
        name: "browser_click",
        description: "Click (tap) an element of the current page by its index from the latest state. Waits for what it causes (a new page, a menu, more content) and returns the new state.",
        parameters: .init(properties: ["index": .init(type: "integer", description: "The element's index, like 12 for [12].")],
                          required: ["index"])))

    static let browserType = ToolDefinition(function: .init(
        name: "browser_type",
        description: "Type text into a text field (input, textarea or editable element) by its index, replacing what it holds, and return the new state. Suggestions that appear are marked *[n]: click the right one instead of submitting.",
        parameters: .init(properties: ["index": .init(type: "integer", description: "The field's index."),
                                       "text": .init(description: "The text to enter. An empty string clears the field."),
                                       "submit": .init(type: "boolean", description: "Optional. Press Enter after typing (submits a search box or form). Defaults to false.")],
                          required: ["index", "text"])))

    static let browserSelect = ToolDefinition(function: .init(
        name: "browser_select",
        description: "Choose an option of a <select> element by its index and return the new state. For other dropdowns, click them and then click the option.",
        parameters: .init(properties: ["index": .init(type: "integer", description: "The <select> element's index."),
                                       "option": .init(description: "The option's visible text (or its value).")],
                          required: ["index", "option"])))

    static let browserScroll = ToolDefinition(function: .init(
        name: "browser_scroll",
        description: "Scroll the page, or a scrolling container by its index, and return the new state (it lists only what is in view).",
        parameters: .init(properties: ["direction": .init(description: "Defaults to down.", choices: ["down", "up"]),
                                       "pages": .init(type: "number", description: "Optional. How far, in screen heights (0.5 to 10). Defaults to 1."),
                                       "index": .init(type: "integer", description: "Optional. A |SCROLL| container's index (or an element inside one) to scroll it instead of the page.")],
                          required: [])))

    static let browserFind = ToolDefinition(function: .init(
        name: "browser_find",
        description: "Find text anywhere on the current page, including parts out of view, and list the matches with where they are and the index of the element holding them. Cheap: prefer it to scrolling when looking for something specific.",
        parameters: .init(properties: ["text": .init(description: "The text to look for (not case-sensitive)."),
                                       "scroll_to": .init(type: "integer", description: "Optional. A match's number from an earlier result, to scroll it into view and return the new state.")],
                          required: ["text"])))

    static let browserScreenshot = ToolDefinition(function: .init(
        name: "browser_screenshot",
        description: "Look at the current page: a screenshot of what is in view, with a numbered box on each element of the state, is attached after the result. Use it when the state doesn't make the layout clear (icons without labels, images, maps, a page that looks wrong).",
        parameters: .init(properties: [:], required: [])))

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

    static let showHTML = ToolDefinition(function: .init(
        name: "show_html",
        description: "Show the user an HTML artifact: a page that opens full screen from a card in the chat and stays in their list of artifacts. Use it for interactive demos, visualizations and charts, small apps or games, and formatted documents worth keeping, not for short answers. Send a complete, self-contained HTML document every time (inline CSS and JS; scripts and styles from CDNs work), also when changing one. The page runs in a sandbox without access to the user's local network or this app.",
        parameters: .init(properties: [
            "title": .init(description: "A short title for the card, like \"Mortgage calculator\"."),
            "html": .init(description: "The complete HTML document."),
            "id": .init(description: "Optional. The id of an artifact shown earlier in this chat (like a1), to replace it with this new version. Leave it out to make a new artifact."),
        ], required: ["title", "html"])))

    /// The web tools, always sent to a model with tools.
    static let standard: [ToolDefinition] = [webSearch, webFetch, runPlugin]

    /// Tools that show the user something, always sent with the web tools (no setting: they only display).
    static let display: [ToolDefinition] = [showHTML]

    /// The browser tools (Settings > Browser). `browser_screenshot` needs a model that reads images.
    static func browser(images: Bool) -> [ToolDefinition] {
        [browserOpen, browserState, browserClick, browserType, browserSelect, browserScroll, browserFind]
            + (images ? [browserScreenshot] : [])
            + [browserEval, browserShow, loadSkill, runSkillScript, saveSkill, showPlaces]
    }

    /// The tools for the given switches, web search on (`available(groups:images:)`). `view_image` needs a model that
    /// reads images; `current_location` comes only with the browser tools here, as in Settings.
    static func available(python: Bool, images: Bool, browser: Bool = false, location: Bool = false) -> [ToolDefinition] {
        var groups: Set<ToolGroup> = [.web]
        if python { groups.insert(.python) }
        if browser { groups.insert(.browser) }
        if browser && location { groups.insert(.location) }
        return available(groups: groups, images: images)
    }

    /// The tools of a chat's offered groups (`ToolGroup`), always in the same order: the same groups give the same
    /// bytes, so a chat's cached prefix holds.
    static func available(groups: Set<ToolGroup>, images: Bool) -> [ToolDefinition] {
        var out = (groups.contains(.web) ? standard : []) + display
        if groups.contains(.python) { out += images ? [runPython, viewImage] : [runPython] }
        if groups.contains(.browser) { out += Self.browser(images: images) }
        if groups.contains(.location) { out += [currentLocation] }
        if groups.contains(.ssh) { out += ssh }
        if groups.contains(.video) { out += [videoTranscript] }
        if groups.contains(.health), ToolGroup.health.isSupported { out += [healthQuery] }
        return out
    }
}

/// Token usage from the final streamed chunk.
struct Usage: Codable, Sendable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
    var cachedTokens: Int?
    var reasoningTokens: Int?
    /// Prompt tokens written to the cache by this request (Anthropic's `cache_creation_input_tokens`, OpenRouter's
    /// `cache_write_tokens`): billed above plain input, read cheaply by the next request. Part of `promptTokens`.
    var cacheWriteTokens: Int?

    var totalTokens: Int { ContextLimits.add(promptTokens, completionTokens) }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case promptDetails = "prompt_tokens_details"
        case completionDetails = "completion_tokens_details"
    }
    private struct PromptDetails: Codable { var cachedTokens: Int?; var cacheWriteTokens: Int?
        enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens", cacheWriteTokens = "cache_write_tokens" } }
    private struct CompletionDetails: Codable { var reasoningTokens: Int?
        enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" } }

    init(promptTokens: Int, completionTokens: Int, cachedTokens: Int? = nil, reasoningTokens: Int? = nil,
         cacheWriteTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        let details = try c.decodeIfPresent(PromptDetails.self, forKey: .promptDetails)
        cachedTokens = details?.cachedTokens
        cacheWriteTokens = details?.cacheWriteTokens
        reasoningTokens = try c.decodeIfPresent(CompletionDetails.self, forKey: .completionDetails)?.reasoningTokens
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(promptTokens, forKey: .promptTokens)
        try c.encode(completionTokens, forKey: .completionTokens)
        if cachedTokens != nil || cacheWriteTokens != nil {
            try c.encode(PromptDetails(cachedTokens: cachedTokens, cacheWriteTokens: cacheWriteTokens), forKey: .promptDetails)
        }
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
    /// The server refused the connection's API key (an Anthropic connection: 401).
    case rejectedAPIKey(connection: String)
    /// A ChatGPT usage limit (`subscription_sharing_usage_limit_exceeded`, or 429 before the stream): the plan's or this
    /// app's limit in ChatGPT. Never retried; the chat offers "Manage usage" first.
    case chatGPTUsageLimit
    /// The chat holds Apple Health data and the connection's model is remote, while Settings > Health allows health data
    /// only on on-device or local models (`HealthPrivacy.blockedRequest`). Nothing was sent.
    case healthLocalOnly(connection: String)
    case http(status: Int, message: String)
    case server(String)
    case transport(String)

    /// Errors fixed in Settings; the chat shows an "Open Settings" button for these.
    var needsSettings: Bool {
        switch self {
        case .missingModel, .missingAPIKey, .invalidBaseURL, .chatGPTSignInRequired, .openCodeSignInRequired, .rejectedAPIKey: true
        default: false
        }
    }

    /// Errors whose first action is "Manage usage" (ChatGPT's usage settings), as OpenAI's guidelines ask.
    var managesUsage: Bool { self == .chatGPTUsageLimit }

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: String(localized: "The base URL is not valid.")
        case .missingModel: String(localized: "No model available. Add a connection in Settings, or fetch its models, then pick one.")
        case .missingAPIKey(let name): String(localized: "Add an API key for \(name) in Settings.")
        case .chatGPTSignInRequired(let name): String(localized: "Sign in to ChatGPT for \(name) in Settings.")
        case .openCodeSignInRequired(let name): String(localized: "Sign in with OpenCode, or enter a valid API key, for \(name) in Settings.")
        case .rejectedAPIKey(let name): String(localized: "The API key for \(name) was not accepted. Check it in Settings.")
        // No reset time: the limit may be the app's rather than the whole plan's (the errors-and-recovery docs).
        case .chatGPTUsageLimit: String(localized: "ChatGPT usage limit reached. The limit may be on your ChatGPT plan or on OpenChat's use of it.")
        case .healthLocalOnly(let name):
            String(localized: "This chat holds Apple Health data, which you allow only for on-device or local models, and \(name) runs on a remote server. Switch the chat to a local model, or turn off \"Only send health data to on-device or local models\" in Settings > Health.")
        case .http(let status, let message):
            message.isEmpty ? String(localized: "The server returned HTTP \(status).")
                            : String(localized: "HTTP \(status): \(message)")
        case .server(let message): message
        case .transport(let message): message
        }
    }
}
