import Foundation

/// A web result a tool found. The turn runner turns these into numbered `<source>` blocks.
struct SourceCandidate: Sendable, Equatable, Codable {
    var title: String
    var url: String
    var content: String
}

/// Result of running a tool on device.
struct ToolOutput: Sendable, Equatable {
    var text: String
    var isError: Bool = false
    /// Web results behind `text`. When present and a `SourceStore` is available, `text` is replaced by
    /// `<source id="N" ...>` blocks with conversation-wide stable ids.
    var sources: [SourceCandidate] = []
    /// The search engine that answered a `web_search` (named in the text the model sees).
    var engine: String?
    /// Figures a `run_python` call saved (listed in `text`).
    var figures: [ToolImage] = []
    /// The image a `view_image` call attaches: it goes to the model in a user message right after the tool results.
    var viewedImage: ToolImage?
    /// What the chat shows for `viewedImage` when the model's copy is marked up: a browser screenshot without the
    /// numbered boxes. Display only; never sent.
    var shownImage: ToolImage?
    /// The places a `show_places` call put on the map (for the chat's map card; the model reads `text`).
    var places: PlaceCollection?
    /// The artifact a `show_html` call saved (for the chat's card; the model reads `text`).
    var artifact: ArtifactRef?
    /// Text that follows the `<source>` blocks when `sources` replace `text` (`browser_open`'s page state). `text`
    /// already ends with it.
    var trailer: String?
}

/// A tool result that finished before the results ahead of it in the round, held (and checkpointed) until it can be
/// numbered in call order.
struct RawToolResult: Codable, Sendable, Equatable {
    var callID: String
    var text: String
    var isError: Bool
    var sources: [SourceCandidate]
    var engine: String?
    var figures: [ToolImage]?
    var viewedImage: ToolImage?
    var shownImage: ToolImage?
    var places: PlaceCollection?
    var artifact: ArtifactRef?
    var trailer: String?

    init(callID: String, output: ToolOutput) {
        self.callID = callID
        text = output.text
        isError = output.isError
        sources = output.sources
        engine = output.engine
        figures = output.figures.isEmpty ? nil : output.figures
        viewedImage = output.viewedImage
        shownImage = output.shownImage
        places = output.places
        artifact = output.artifact
        trailer = output.trailer
    }

    var output: ToolOutput {
        ToolOutput(text: text, isError: isError, sources: sources, engine: engine, figures: figures ?? [], viewedImage: viewedImage,
                   shownImage: shownImage, places: places, artifact: artifact, trailer: trailer)
    }
}

protocol ToolExecuting: Sendable {
    /// WebKit tools may need to wait for an active scene if no continued-processing lease is available.
    var usesWebKit: Bool { get }
    func execute(name: String, arguments: String) async -> ToolOutput
}

extension ToolExecuting { var usesWebKit: Bool { false } }

/// A persisted tool call plus its result, shown in the tool row and replayed in later requests.
struct ToolCallRecord: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var arguments: String
    var result: String
    var isError: Bool
    /// Ids of the sources this call produced (see `SourceStore`).
    var sourceIDs: [Int] = []
    /// Display-only facts kept when `displayOnly` drops the result text (never sent to the API): the engine that
    /// answered a search, and a page read's length and whether it held little real content.
    var engine: String?
    var pageCharacters: Int?
    var thinPage: Bool?
    /// Figures a `run_python` call saved, and the image a `view_image` call attached (sent again with every request).
    var figures: [ToolImage]?
    var viewedImage: ToolImage?
    /// The unmarked copy of a browser screenshot, which the chat shows (display only).
    var shownImage: ToolImage?
    /// The places a `show_places` call put on the map (display only).
    var places: PlaceCollection?
    /// The artifact a `show_html` call saved (display only).
    var artifact: ArtifactRef?

    init(id: String, name: String, arguments: String, result: String, isError: Bool, sourceIDs: [Int] = []) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.sourceIDs = sourceIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        arguments = try c.decode(String.self, forKey: .arguments)
        result = try c.decode(String.self, forKey: .result)
        isError = try c.decode(Bool.self, forKey: .isError)
        sourceIDs = try c.decodeIfPresent([Int].self, forKey: .sourceIDs) ?? []
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        pageCharacters = try c.decodeIfPresent(Int.self, forKey: .pageCharacters)
        thinPage = try c.decodeIfPresent(Bool.self, forKey: .thinPage)
        figures = try c.decodeIfPresent([ToolImage].self, forKey: .figures)
        viewedImage = try c.decodeIfPresent(ToolImage.self, forKey: .viewedImage)
        places = try c.decodeIfPresent(PlaceCollection.self, forKey: .places)
        artifact = try c.decodeIfPresent(ArtifactRef.self, forKey: .artifact)
    }

    /// Human-readable argument (the query or URL; for a plugin, the page it opens).
    var primaryArgument: String {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return arguments }
        switch name {
        case "web_search": return (obj["query"] as? String) ?? arguments
        case "web_fetch", "video_transcript": return (obj["url"] as? String) ?? arguments
        case "run_plugin": return PluginCall.pageURL(in: arguments) ?? (obj["name"] as? String) ?? arguments
        case "run_python": return (obj["code"] as? String) ?? arguments
        case "view_image": return (obj["id"] as? String) ?? arguments
        case "browser_open": return (obj["url"] as? String) ?? arguments
        case "browser_eval": return (obj["js"] as? String) ?? arguments
        case "browser_show": return (obj["reason"] as? String) ?? ""
        case "browser_state", "browser_screenshot": return ""
        case "browser_click": return BrowserAction.index(obj["index"]).map { "[\($0)]" } ?? ""
        case "browser_type":
            let text = (obj["text"] as? String).map { " \u{201C}\(BrowserAgentTool.short($0, 40))\u{201D}" } ?? ""
            return (BrowserAction.index(obj["index"]).map { "[\($0)]" } ?? "") + text
        case "browser_select":
            let option = (obj["option"] as? String).map { " \u{201C}\(BrowserAgentTool.short($0, 40))\u{201D}" } ?? ""
            return (BrowserAction.index(obj["index"]).map { "[\($0)]" } ?? "") + option
        case "browser_scroll":
            let target = BrowserAction.index(obj["index"]).map { "[\($0)] " } ?? ""
            return target + ((obj["direction"] as? String)?.lowercased() == "up" ? "up" : "down")
        case "browser_find": return (obj["text"] as? String) ?? ""
        case "load_skill", "save_skill": return (obj["name"] as? String) ?? arguments
        case "run_skill_script":
            return [obj["skill"] as? String, obj["script"] as? String].compactMap { $0 }.joined(separator: " · ")
        case "show_places": return (obj["title"] as? String) ?? ""
        case "show_html": return (obj["title"] as? String) ?? ""
        case "current_location": return ""
        case ToolNames.healthQuery: return HealthArguments.summary(of: arguments)
        case _ where SSHToolNames.covers(name): return SSHMask.sanitized(arguments)
        case _ where PackageToolNames.covers(name): return PackageToolNames.displayArgument(name: name, arguments: arguments)
        default: return arguments
        }
    }

    /// `offset` argument of a `web_fetch` call (0 for a first read).
    var fetchOffset: Int { Self.fetchOffset(in: arguments) }

    static func fetchOffset(in arguments: String) -> Int {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        if let n = obj["offset"] as? Int { return n }
        if let d = obj["offset"] as? Double { return Int(exactly: d.rounded(.down)) ?? 0 }
        if let s = obj["offset"] as? String, let n = Int(s) { return n }
        return 0
    }

    var toolCall: ToolCall { ToolCall(id: id, name: name, arguments: arguments) }

    /// The result as the next requests send it again (with the image a `view_image` call attached).
    var output: ToolOutput {
        ToolOutput(text: result, isError: isError, figures: figures ?? [], viewedImage: viewedImage, places: places, artifact: artifact)
    }

    /// The record without its result text: all a process row needs, so segments never hold fetched page bodies.
    /// A Python run and a browser script keep their output (the card shows it; it is capped like a page slice).
    private static func actionDisplay(_ result: String) -> String {
        let first = String(result.prefix { $0 != "\n" }.prefix(200))
        let url = result.split(separator: "\n").first { $0.hasPrefix("URL: ") }.map { String($0.prefix(300)) }
        return url.map { first + "\n" + $0 } ?? first
    }

    var displayOnly: ToolCallRecord {
        let keepsResult = name == ToolNames.runPython || name == ToolNames.browserEval || SSHToolNames.covers(name)
            || name == ToolNames.healthQuery // its line opens to the table it read (capped)
            || PackageToolNames.keepsResult(name) // a package tool that asks for it (`display.keepResult`)
        // An index tool keeps its first line ("Clicked [12] Search"), its card's title, and the page's "URL:" line,
        // which names the site of its run (`BrowserRun.host`). The rest of the page state is dropped.
        let kept = keepsResult ? result : ToolNames.isBrowserAction(name) ? Self.actionDisplay(result) : ""
        var out = ToolCallRecord(id: id, name: name, arguments: arguments, result: kept,
                                 isError: isError, sourceIDs: sourceIDs)
        out.figures = figures
        out.viewedImage = viewedImage
        out.shownImage = shownImage
        out.places = places
        out.artifact = artifact
        if name == ToolNames.webSearch {
            out.engine = searchEngine
        } else if name == ToolNames.webFetch, !isError {
            out.pageCharacters = fetchedCharacters
            out.thinPage = isThinPage
        }
        return out
    }

    /// The engine that answered a search (`Results from Bing:` heads the result the model sees).
    var searchEngine: String? {
        if let engine { return engine }
        guard name == ToolNames.webSearch, result.hasPrefix(Self.enginePrefix),
              let end = result.firstIndex(of: "\n") else { return nil }
        let raw = result[result.index(result.startIndex, offsetBy: Self.enginePrefix.count)..<end]
        guard raw.hasSuffix(":") else { return nil }
        let name = raw.dropLast().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
    private static let enginePrefix = "Results from "

    /// The whole page's length in characters, from the footer `web_fetch` adds to each slice.
    var fetchedCharacters: Int? {
        if let pageCharacters { return pageCharacters }
        guard name == ToolNames.webFetch, !isError else { return nil }
        return FetchOutcome.totalCharacters(in: result)
    }

    /// The page loaded but held almost no text, or looks like a bot check or consent wall.
    var isThinPage: Bool {
        if let thinPage { return thinPage }
        guard name == ToolNames.webFetch, !isError else { return false }
        return FetchOutcome.isThin(result: result, characters: fetchedCharacters)
    }
}

/// One tool round: the assistant message that requested tools, and the results.
struct ToolStep: Codable, Hashable, Sendable {
    var assistantContent: String
    var calls: [ToolCallRecord]
    /// How many reasoning paragraphs preceded this step (places the step in the timeline).
    var reasoningParagraphs: Int = 0
    /// The signed thinking blocks that led to the calls, on an Anthropic connection only (`StepThinking`).
    var thinking: StepThinking?

    init(assistantContent: String, calls: [ToolCallRecord], reasoningParagraphs: Int = 0, thinking: StepThinking? = nil) {
        self.assistantContent = assistantContent
        self.calls = calls
        self.reasoningParagraphs = reasoningParagraphs
        self.thinking = thinking
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assistantContent = try c.decode(String.self, forKey: .assistantContent)
        calls = try c.decode([ToolCallRecord].self, forKey: .calls)
        reasoningParagraphs = try c.decodeIfPresent(Int.self, forKey: .reasoningParagraphs) ?? 0
        thinking = try? c.decodeIfPresent(StepThinking.self, forKey: .thinking)
    }
}

/// The thinking blocks (text and signature, as `ReasoningItem`s) of an Anthropic answer that called tools, kept with
/// the step so later turns send them back unchanged. Anthropic recommends passing every thinking block back: newer
/// models keep earlier turns' thinking in context, and a later turn's request then repeats the earlier one byte for byte
/// up to its last tool results, so the prompt cache reads all of it instead of writing the turn's tool loop again.
/// Tagged with the model that wrote them: another model can't read them, and they are left out for it.
struct StepThinking: Codable, Hashable, Sendable {
    var model: String
    var items: [ReasoningItem]
}

enum ToolNames {
    static let webSearch = "web_search"
    static let webFetch = "web_fetch"
    static let runPlugin = "run_plugin"
    static let runPython = "run_python"
    static let viewImage = "view_image"
    static let browserOpen = "browser_open"
    static let browserEval = "browser_eval"
    static let browserShow = "browser_show"
    static let browserState = "browser_state"
    static let browserClick = "browser_click"
    static let browserType = "browser_type"
    static let browserSelect = "browser_select"
    static let browserScroll = "browser_scroll"
    static let browserFind = "browser_find"
    static let browserScreenshot = "browser_screenshot"
    static let loadSkill = "load_skill"
    static let runSkillScript = "run_skill_script"
    static let saveSkill = "save_skill"
    static let showPlaces = "show_places"
    static let currentLocation = "current_location"
    static let showHTML = "show_html"
    static let videoTranscript = "video_transcript"

    /// Tools safe to run a second time when the first run failed because the app went to the background: they only
    /// read. Python, page scripts, plugins and skill scripts may have done something already (a click, a POST).
    static func isSafeToRetry(_ name: String) -> Bool {
        [webSearch, webFetch, browserOpen, browserState, browserFind, browserScreenshot, loadSkill, currentLocation,
         videoTranscript, healthQuery].contains(name) || PackageToolNames.isReadOnly(name)
    }

    /// The index tools (`BrowserAction`): one card each, with the page live while the reply works.
    static func isBrowserAction(_ name: String) -> Bool { BrowserAction.tools.contains(name) }

    /// Tools that load or script pages in hidden web views, which iOS stops while the app is in the background unless
    /// they play sound (`BackgroundLoadingSound`). `browser_show` puts its page on screen, so it is not one.
    static func usesWebPage(_ name: String) -> Bool {
        [webSearch, webFetch, runPlugin, browserOpen, browserEval, runSkillScript].contains(name) || isBrowserAction(name)
    }

    /// Tools shown in the feed as a card of their own (not a search card or a row of "Read pages").
    static func hasOwnCard(_ name: String) -> Bool {
        [runPython, viewImage, browserOpen, browserEval, browserShow, loadSkill, runSkillScript, saveSkill, showPlaces, currentLocation,
         showHTML, healthQuery].contains(name) || isBrowserAction(name) || SSHToolNames.covers(name) || PackageToolNames.covers(name)
    }

    /// Tools that read a page (and count as one in the summaries).
    static func readsPage(_ name: String) -> Bool { name == webFetch || name == runPlugin || name == browserOpen }

    /// `video_transcript`: a read like a page's, shown and counted as a transcript.
    static func readsTranscript(_ name: String) -> Bool { name == videoTranscript }
}

/// Plain-value message used to build API history without touching SwiftData.
struct HistoryMessage: Sendable, Equatable {
    var role: String          // "user" | "assistant"
    var text: String
    var images: [Data] = []   // JPEG
    /// Ready-made data URLs for persisted attachments (from `ImageDataURLCache`); used instead of `images` when set.
    var imageDataURLs: [String] = []
    var steps: [ToolStep] = []
}

enum MessageAssembler {
    /// Convert stored conversation messages to API messages, expanding tool steps.
    /// - Parameter replacing: messages that stand for the history before `history` (a compaction's replacement).
    /// - Parameter readsImages: false for a model without image input (the chat switched to one after images were
    ///   attached): each image becomes a fixed note, so the request isn't rejected and the model knows one was there.
    /// - Parameter thinkingModel: an Anthropic model: steps whose thinking it wrote send that thinking back
    ///   (`StepThinking`). Nil everywhere else, so other APIs' requests are what they always were.
    static func apiMessages(from history: [HistoryMessage], systemPrompt: String = "", replacing: [APIMessage] = [],
                            readsImages: Bool = true, thinkingModel: String? = nil) -> [APIMessage] {
        var out: [APIMessage] = []
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty { out.append(.system(trimmedPrompt)) }
        out.append(contentsOf: replacing)
        for m in history {
            switch m.role {
            case "user":
                let urls = m.imageDataURLs.isEmpty ? m.images.map { ContentPart.dataURLString(jpeg: $0) } : m.imageDataURLs
                if urls.isEmpty {
                    out.append(.user(m.text))
                } else if !readsImages {
                    let notes = Array(repeating: omittedImageNote, count: urls.count).joined(separator: "\n")
                    out.append(.user(m.text.isEmpty ? notes : notes + "\n\n" + m.text))
                } else {
                    var parts: [ContentPart] = urls.map { ContentPart.imageURL($0) }
                    if !m.text.isEmpty { parts.append(.text(m.text)) }
                    out.append(.user(parts: parts))
                }
            case "assistant":
                for step in m.steps {
                    let thinking = step.thinking.flatMap { $0.model == thinkingModel ? $0.items : nil } ?? []
                    appendToolRound(to: &out, assistantContent: step.assistantContent,
                                    calls: step.calls.map(\.toolCall),
                                    results: step.calls.map(\.output), readsImages: readsImages, reasoningItems: thinking)
                }
                if !m.text.isEmpty || m.steps.isEmpty { out.append(.assistant(m.text)) }
            default:
                break
            }
        }
        return out
    }

    /// Stands for an image when the model can't read images. Fixed text, so the prefix stays the same between requests.
    static let omittedImageNote = "[Image omitted: the current model can't read images.]"

    /// Append the assistant message carrying `tool_calls`, then one `tool` message per call. Images `view_image`
    /// attached follow in one `user` message after the last tool message (a tool message carries text only), so the
    /// order stays assistant → tool… → user, valid for OpenAI-style APIs and Qwen chat templates. It is rebuilt the
    /// same way from the saved records for every later request, so its bytes never change.
    /// `reasoningItems` (Responses API) ride on the assistant message, for the next request of the same turn.
    static func appendToolRound(to messages: inout [APIMessage], assistantContent: String,
                                calls: [ToolCall], results: [ToolOutput], readsImages: Bool = true,
                                reasoningItems: [ReasoningItem] = [], images: ToolImageStore = .shared) {
        var assistant = APIMessage.assistant(assistantContent, toolCalls: calls)
        assistant.reasoningItems = reasoningItems
        messages.append(assistant)
        for (call, result) in zip(calls, results) {
            messages.append(.tool(callID: call.id, content: result.text))
        }
        let viewed = zip(calls, results).compactMap { _, result in result.isError ? nil : result.viewedImage }
        guard !viewed.isEmpty else { return }
        if readsImages {
            var parts: [ContentPart] = []
            for image in viewed {
                parts.append(.text(viewedImageLabel(image)))
                if let url = images.dataURL(file: image.file) { parts.append(.imageURL(url)) } else { parts.append(.text(missingImageNote)) }
            }
            messages.append(.user(parts: parts))
        } else {
            let text = viewed.map { viewedImageLabel($0) + "\n" + omittedImageNote }.joined(separator: "\n\n")
            messages.append(.user(text))
        }
    }

    /// Heads an image `view_image` attached.
    static func viewedImageLabel(_ image: ToolImage) -> String { "[view_image: \(image.id), \(image.width)x\(image.height)]" }
    static let missingImageNote = "[Image unavailable: it is no longer stored on this device.]"
}
