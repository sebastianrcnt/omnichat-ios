import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// The index tools of the model's browser: `browser_state` lists what the page shows with an index on each element the
// model can act on, and `browser_click`, `browser_type`, `browser_select`, `browser_scroll`, `browser_find` and
// `browser_screenshot` act on those indices, each returning the page's new state. The work happens in
// `BrowserAgent.js`, run in an isolated content world so the page can't see or change it. The format and the rules
// follow browser-use (MIT, https://github.com/browser-use/browser-use), rebuilt on WKWebView without CDP.

/// The agent script and the calls into it.
enum BrowserAgentScript {
    static let source: String? = Bundle.main.url(forResource: "BrowserAgent", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    enum Op: String, Sendable { case observe, click, type, select, scroll, find, mark, unmark }

    /// A function body for `callAsyncJavaScript` in the agent's world: installs the agent once per document, runs
    /// `op` with the JSON in the `input` argument and returns its result as JSON.
    static func body(_ op: Op) -> String {
        let wait = op == .mark
            ? "await new Promise((r) => { let done = false; const f = () => { if (!done) { done = true; r(); } }; requestAnimationFrame(() => requestAnimationFrame(f)); setTimeout(f, 300); });\n"
            : ""
        return """
        \(source ?? "")
        if (!window.__strataAgent) return JSON.stringify({ error: "script", message: "The page state could not be read." });
        const __out = window.__strataAgent.\(op.rawValue)(JSON.parse(input));
        \(wait)return JSON.stringify(__out);
        """
    }

    static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// One observation of the page (`observe`).
struct BrowserAgentState: Decodable, Sendable, Equatable {
    var url: String
    var title: String
    var docId: String
    /// The last index handed out.
    var counter: Int
    /// Elements listed.
    var count: Int
    /// "0 px above, 1200 px below (viewport 390x844)".
    var scroll: String
    var below: Int
    var tree: String

    /// What the model reads: the page, its scroll position, and the tree.
    var text: String { "URL: \(url)\nTitle: \(PageMetadata.capped(title))\nScroll: \(scroll)\n\n\(tree)" }

    static func decode(_ json: String) -> BrowserAgentState? { try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) }
}

/// What an action reports.
struct BrowserAgentReply: Decodable, Sendable {
    var ok: Bool?
    var error: String?
    var message: String?
    var label: String?
    var tag: String?
    var value: String?
    var submitted: Bool?
    var docId: String?
    var what: String?
    var moved: Int?
    var down: Bool?
    var atEnd: Bool?
    var total: Int?
    var matches: [Match]?
    var scrolled: Bool?

    struct Match: Decodable, Sendable {
        var snippet: String
        var `where`: String
        var index: Int?
    }

    var isStale: Bool { error == "stale" }

    static func decode(_ json: String) -> BrowserAgentReply? { try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) }
}

/// A call of an index tool, from its arguments.
enum BrowserAction: Equatable, Sendable {
    case state
    case click(index: Int)
    case type(index: Int, text: String, submit: Bool)
    case select(index: Int, option: String)
    case scroll(down: Bool, pages: Double, index: Int?)
    case find(text: String, scrollTo: Int?)
    case screenshot

    static let tools: Set<String> = [ToolNames.browserState, ToolNames.browserClick, ToolNames.browserType, ToolNames.browserSelect,
                                     ToolNames.browserScroll, ToolNames.browserFind, ToolNames.browserScreenshot]

    /// The action a tool call asks for, or the error the model reads.
    static func parse(tool: String, arguments args: [String: Any]) -> Result<BrowserAction, BrowserActionError> {
        switch tool {
        case ToolNames.browserState: return .success(.state)
        case ToolNames.browserScreenshot: return .success(.screenshot)
        case ToolNames.browserClick:
            guard let index = index(args["index"]) else { return .failure(.missing(tool, "index")) }
            return .success(.click(index: index))
        case ToolNames.browserType:
            guard let index = index(args["index"]) else { return .failure(.missing(tool, "index")) }
            guard let text = args["text"].flatMap(string) else { return .failure(.missing(tool, "text")) }
            return .success(.type(index: index, text: text, submit: bool(args["submit"]) ?? false))
        case ToolNames.browserSelect:
            guard let index = index(args["index"]) else { return .failure(.missing(tool, "index")) }
            guard let option = args["option"].flatMap(string), !option.isEmpty else { return .failure(.missing(tool, "option")) }
            return .success(.select(index: index, option: option))
        case ToolNames.browserScroll:
            let direction = (args["direction"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces) ?? "down"
            guard direction == "down" || direction == "up" else { return .failure(.invalid("direction must be \"down\" or \"up\".")) }
            let pages = number(args["pages"]) ?? 1
            guard pages > 0 else { return .failure(.invalid("pages must be more than 0.")) }
            return .success(.scroll(down: direction == "down", pages: min(pages, 10), index: args["index"].flatMap(index)))
        case ToolNames.browserFind:
            guard let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return .failure(.missing(tool, "text"))
            }
            return .success(.find(text: text, scrollTo: args["scroll_to"].flatMap(index)))
        default:
            return .failure(.invalid("unknown browser tool \"\(tool)\"."))
        }
    }

    /// 12, 12.0, "12" and "[12]" are all index 12.
    static func index(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n >= 0 ? n : nil
        case let d as Double: return d >= 0 ? Int(exactly: d) : nil
        case let s as String:
            let digits = s.trimmingCharacters(in: CharacterSet(charactersIn: " *[]"))
            return Int(digits).flatMap { $0 >= 0 ? $0 : nil }
        default: return nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as Int: return Double(n)
        case let d as Double: return d
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func string(_ value: Any) -> String? {
        switch value {
        case let s as String: return s
        case let n as Int: return String(n)
        case let d as Double: return Int(exactly: d).map(String.init) ?? String(d)
        default: return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let s as String: return ["true", "yes", "1"].contains(s.lowercased())
        case let n as Int: return n != 0
        default: return nil
        }
    }
}

struct BrowserActionError: Error, Equatable {
    var message: String
    static func missing(_ tool: String, _ argument: String) -> Self { .init(message: "\(tool) needs \"\(argument)\".") }
    static func invalid(_ message: String) -> Self { .init(message: message) }
    var output: ToolOutput { ToolOutput(text: "Error: " + message, isError: true) }
}

/// After an action: wait for a navigation it started, or for the page to stop changing.
enum BrowserAgentSettle {
    static let quiet = 450.0
    static let limit: Duration = .seconds(4)
    static let navigationLimit: Duration = .seconds(12)

    @MainActor
    static func wait(_ page: any BrowserPage, quiet: Double = quiet, limit: Duration = limit,
                     navigationLimit: Duration = navigationLimit) async throws {
        try await Task.sleep(for: .milliseconds(150))
        let started = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            let elapsed = ContinuousClock.now - started
            if page.isLoading {
                if elapsed >= navigationLimit { return }
            } else {
                let probe = (try? await page.evaluate(BrowserSettle.probe, timeout: .seconds(2))).flatMap(BrowserSettle.Probe.decode)
                if let probe, probe.ready != "loading", probe.domQuiet >= quiet {
                    // A network that never rests (ads, analytics, polling): a DOM quiet twice as long will do.
                    if probe.netQuiet >= BrowserSettle.networkQuiet || probe.domQuiet >= quiet * 2 { return }
                }
                let loading = probe?.ready == "loading"
                if elapsed >= (loading ? navigationLimit : limit) { return }
            }
            try await Task.sleep(for: BrowserSettle.pollInterval)
        }
    }
}

/// The index tools on the conversation's page (the one `browser_open` opened).
struct BrowserAgentTool {
    var sessions: BrowserSessions?
    /// Looks for a robot check after an action that may have navigated. Test seam, as for `BrowserOpenTool`.
    var robotCheck: (@MainActor (any BrowserPage, FetchTimeouts) async throws -> Bool)?
    var images: ToolImageStore = .shared
    /// The model reads images (only then is `browser_screenshot` offered).
    var readsImages: Bool = ToolContext.readsImages
    /// The state's size limit.
    var maxCharacters = 14_000
    var timeout: Duration = .seconds(40)
    /// Waits after an action. Test seam: tests on static pages wait less.
    var settle: @MainActor (any BrowserPage) async throws -> Void = { try await BrowserAgentSettle.wait($0) }

    /// The state's size limit after `browser_open`, which returns the page's text too.
    static let openStateCharacters = 6_000

    /// Pixel width of a screenshot: half again the phone's width, sharp enough to read, small enough to send.
    static let screenshotWidth = 585

    @MainActor
    func run(_ action: BrowserAction, conversation: UUID?) async -> ToolOutput {
        let check = robotCheck ?? BrowserRobotCheck.gate
        let sessions = sessions ?? .shared
        let me = self
        if case .screenshot = action, !readsImages {
            return ToolOutput(text: "Error: the current model can't read images, so browser_screenshot is not available. Use browser_state.", isError: true)
        }
        do {
            return try await sessions.run(conversation: conversation) { session in
                guard session.hasPage, let current = session.page.currentURL, current.scheme?.hasPrefix("http") == true else {
                    return ToolOutput(text: "Error: no page is open. Call browser_open first.", isError: true)
                }
                return try await Deadline.run(me.timeout, onAbort: { session.page.stop() }) {
                    try await me.perform(action, session: session, conversation: conversation, check: check)
                }
            }
        } catch is BrowserStoppedError {
            return BrowserStoppedError.output
        } catch is CancellationError {
            return ToolOutput(text: "Error: cancelled.", isError: true)
        } catch WebToolError.timeout {
            return sessions.failure("the page did not answer within \(FetchTimeouts.seconds(timeout)).", conversation: conversation,
                                    error: WebToolError.timeout)
        } catch {
            return sessions.failure(error.localizedDescription, conversation: conversation, error: error)
        }
    }

    /// Reads the page's state and remembers its indices as the latest.
    @MainActor
    static func observe(_ session: BrowserSessions.Session, maxCharacters: Int, markNew: Bool) async throws -> BrowserAgentState {
        let input = BrowserAgentScript.json(["startAt": session.agentIndex + 1, "maxChars": maxCharacters, "markNew": markNew])
        let json = try await session.page.callAgent(BrowserAgentScript.body(.observe), input: input, timeout: .seconds(10))
        guard let state = BrowserAgentState.decode(json) else {
            let reply = BrowserAgentReply.decode(json)
            throw WebToolError.script(reply?.message ?? "could not read the page state.")
        }
        session.agentIndex = max(session.agentIndex, state.counter)
        return state
    }

    @MainActor
    private func call(_ op: BrowserAgentScript.Op, _ input: [String: Any], session: BrowserSessions.Session) async throws -> BrowserAgentReply {
        let json = try await session.page.callAgent(BrowserAgentScript.body(op), input: BrowserAgentScript.json(input), timeout: .seconds(10))
        guard let reply = BrowserAgentReply.decode(json) else { throw WebToolError.script("the page did not answer.") }
        return reply
    }

    @MainActor
    private func perform(_ action: BrowserAction, session: BrowserSessions.Session, conversation: UUID?,
                         check: @MainActor (any BrowserPage, FetchTimeouts) async throws -> Bool) async throws -> ToolOutput {
        let page = session.page
        let before = page.currentURL
        let reply: BrowserAgentReply
        var line: String
        var changesPage = true
        var markNew = true
        switch action {
        case .state:
            let state = try await Self.observe(session, maxCharacters: maxCharacters, markNew: true)
            return ToolOutput(text: state.text)
        case .screenshot:
            return try await screenshot(session: session, conversation: conversation)
        case .click(let index):
            page.acceptPopups(for: .seconds(2))
            reply = try await call(.click, ["index": index], session: session)
            line = "Clicked [\(index)] \(reply.label ?? "")"
        case .type(let index, let text, let submit):
            if submit { page.acceptPopups(for: .seconds(2)) }
            reply = try await call(.type, ["index": index, "text": text, "submit": submit], session: session)
            line = "Typed \"\(Self.short(text))\" into [\(index)] \(reply.label ?? "")" + (submit ? " and submitted" : "")
            changesPage = submit
            if let value = reply.value, reply.ok == true, value != text, !value.isEmpty || !text.isEmpty {
                line += "\nThe field now shows \"\(Self.short(value, 120))\"."
            }
        case .select(let index, let option):
            reply = try await call(.select, ["index": index, "option": option], session: session)
            line = "Selected \"\(reply.value ?? option)\" in [\(index)] \(reply.label ?? "")"
        case .scroll(let down, let pages, let index):
            var input: [String: Any] = ["direction": down ? "down" : "up", "pages": pages]
            if let index { input["index"] = index }
            reply = try await call(.scroll, input, session: session)
            let amount = pages == 1 ? "1 page" : "\(pages.formatted(.number.precision(.fractionLength(0...1)))) pages"
            let target = (reply.what ?? "the page") == "the page" ? "" : " " + (reply.what ?? "")
            line = reply.atEnd == true
                ? "Already at the \(down ? "bottom" : "top")\(target.isEmpty ? " of the page" : " of" + target); nothing moved"
                : "Scrolled\(target) \(down ? "down" : "up") \(amount)"
            changesPage = false
            markNew = false
        case .find(let text, let scrollTo):
            reply = try await call(.find, ["text": text, "scrollTo": scrollTo ?? 0], session: session)
            if reply.ok == true, reply.scrolled != true {
                return ToolOutput(text: Self.findText(reply, query: text))
            }
            line = Self.findText(reply, query: text)
            changesPage = false
            markNew = false
        }
        if reply.isStale {
            let state = try await Self.observe(session, maxCharacters: maxCharacters, markNew: false)
            return ToolOutput(text: "Error: \(reply.message ?? "That index is not in the latest page state.") Indices are only valid for the latest state; use one from this state:\n\n" + state.text, isError: true)
        }
        guard reply.ok == true else {
            return ToolOutput(text: "Error: " + (reply.message ?? "the action failed."), isError: true)
        }
        try await settle(page)
        page.releaseFocus()
        var notes: [String] = []
        if changesPage, try await check(page, .current) {
            notes.append("A robot check appeared after this, and the user solved it.")
        }
        let state = try await Self.observe(session, maxCharacters: maxCharacters, markNew: markNew)
        if state.docId != reply.docId || before?.absoluteString != state.url {
            notes.append(state.url == before?.absoluteString ? "The page reloaded." : "The page is now \(state.url).")
        }
        return ToolOutput(text: ([line.trimmingCharacters(in: .whitespaces)] + notes).joined(separator: "\n") + "\n\n" + state.text)
    }

    static func short(_ s: String, _ limit: Int = 60) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// "Found 3 matches for "price"" and the matches.
    static func findText(_ reply: BrowserAgentReply, query: String) -> String {
        let total = reply.total ?? 0
        guard total > 0, let matches = reply.matches, !matches.isEmpty else {
            return "No visible text on the page matches \"\(short(query))\"."
        }
        var lines = [total == 1 ? "Found 1 match for \"\(short(query))\"" : "Found \(total) matches for \"\(short(query))\""]
        for (i, m) in matches.enumerated() {
            let index = m.index.map { " in [\($0)]" } ?? ""
            lines.append("\(i + 1). (\(m.where)\(index)) \(m.snippet)")
        }
        if total > matches.count { lines.append("[\(total - matches.count) more not listed; search for something more specific.]") }
        if reply.scrolled == true { lines.append("Scrolled the match into view.") }
        else if matches.contains(where: { $0.where != "in view" }) { lines.append("Pass scroll_to with a match's number to scroll it into view.") }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private func screenshot(session: BrowserSessions.Session, conversation: UUID?) async throws -> ToolOutput {
        guard let conversation else { return ToolOutput(text: "Error: screenshots are not available here.", isError: true) }
        let state = try await Self.observe(session, maxCharacters: maxCharacters, markNew: false)
        // The chat shows the page as it looks; the model gets the copy with the numbered boxes.
        let clean = try? await session.page.snapshotPNG(width: Self.screenshotWidth)
        _ = try? await call(.mark, [:], session: session)
        let png: Data
        do {
            png = try await session.page.snapshotPNG(width: Self.screenshotWidth)
        } catch {
            _ = try? await call(.unmark, [:], session: session)
            throw error
        }
        _ = try? await call(.unmark, [:], session: session)
        guard let image = images.addImage(png: png, conversationID: conversation, prefix: ToolImageStore.screenshotPrefix) else {
            return ToolOutput(text: "Error: the screenshot could not be saved.", isError: true)
        }
        let shown = clean.flatMap { images.addImage(png: $0, conversationID: conversation, prefix: ToolImageStore.screenshotPrefix) }
        return ToolOutput(text: "Took a screenshot\nIt is attached in the next message as \(image.listing): a numbered box marks each element of this state.\n\n" + state.text,
                          viewedImage: image, shownImage: shown)
    }
}

/// A snapshot made smaller and written as PNG, the same on iOS and the Mac.
enum SnapshotPNG {
    static func encode(_ image: CGImage, width: Int) -> Data? {
        let w = min(width, image.width)
        let h = max(1, Int((Double(image.height) * Double(w) / Double(max(image.width, 1))).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)) // a page without a background is white, as in a browser
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
