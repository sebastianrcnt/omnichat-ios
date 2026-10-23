#if os(iOS)
import Foundation

/// What the Live Activity needs to know about one running chat, gathered from its `ChatRun` and the request queues
/// (`ReplyLiveActivities.inputs`). Plain values, so the wording is tested without a controller.
struct ReplyActivityInput: Equatable {
    /// Something waits for the person in this chat.
    enum Approval: Equatable {
        case sshCommand(server: String)
        case sshPrompt(hop: String)
        case skill(name: String)
        case robotCheck(host: String)
        /// `browser_show`: the model handed the page over.
        case browser
        /// A package tool waits for approval.
        case packageTool(package: String, tool: String)
        /// Python asks to connect to a local or private host.
        case network(host: String)
    }

    var id: UUID
    var title: String
    var phase: ChatController.Phase
    /// The running call waits for the browser or Python another chat is using.
    var toolWait: ToolWaits.Reason?
    var approval: Approval?
    /// The site the chat's browser is on, for browser actions whose argument names no page ("Browsing naver.com").
    var browserHost: String?
    var steps: Int = 0
    var started: Date?
}

/// How a reply ended, for its last row.
enum ReplyActivityOutcome: Equatable {
    case ready(answer: String)
    case stopped
    case failed(message: String)
}

/// Puts a reply's phase into the activity's words. One place, so the lock screen, the Dynamic Island and the system's
/// task list (`continuedTaskText`) say the same thing.
enum ReplyActivityPhase {
    static func chat(_ input: ReplyActivityInput) -> ReplyActivityChat {
        var chat = ReplyActivityChat(id: input.id, title: ReplyActivityText.clip(input.title, ReplyActivityText.titleLimit),
                                     status: .working, label: "", symbol: "sparkle", steps: input.steps,
                                     started: input.started)
        if let approval = input.approval ?? implicitApproval(input.phase) {
            chat.status = .needsYou
            chat.label = String(localized: "Needs you")
            chat.detail = ReplyActivityText.clip(ask(approval), ReplyActivityText.detailLimit)
            chat.symbol = "hand.raised.fill"
            return chat
        }
        if input.phase == .queued {
            chat.status = .queued
            chat.label = String(localized: "Waiting for another chat")
            chat.symbol = "hourglass"
            chat.started = nil
            return chat
        }
        if let wait = input.toolWait {
            chat.label = wait.label
            chat.symbol = "hourglass"
            return chat
        }
        (chat.label, chat.symbol) = words(input.phase, browserHost: input.browserHost)
        return chat
    }

    /// The row of a reply that ended: "Reply ready" and the start of the answer.
    static func ended(id: UUID, title: String, outcome: ReplyActivityOutcome, steps: Int, started: Date?,
                      at date: Date = .now) -> ReplyActivityChat {
        var chat = ReplyActivityChat(id: id, title: ReplyActivityText.clip(title, ReplyActivityText.titleLimit),
                                     status: .ready, label: "", symbol: "checkmark", steps: steps, started: started,
                                     ended: date)
        switch outcome {
        case .ready(let answer):
            chat.label = String(localized: "Reply ready")
            let line = ChatController.notificationBody(firstParagraphs(answer), limit: ReplyActivityText.detailLimit)
            chat.detail = line.isEmpty ? nil : line
        case .stopped:
            chat.status = .stopped
            chat.label = String(localized: "Reply stopped")
            chat.symbol = "stop.fill"
        case .failed(let message):
            chat.status = .failed
            chat.label = String(localized: "Reply failed")
            chat.detail = message.isEmpty ? nil : ReplyActivityText.clip(message, ReplyActivityText.detailLimit)
            chat.symbol = "exclamationmark.triangle.fill"
        }
        return chat
    }

    /// The answer from its first line of prose: a heading that opens it ("## Summary") says less than what follows.
    static func firstParagraphs(_ answer: String) -> String {
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false)
        let body = lines.drop { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.isEmpty || text.hasPrefix("#")
        }
        return body.isEmpty ? answer : body.joined(separator: "\n")
    }

    /// The rows: running chats and the ones that ended while the activity was up, most urgent first, then oldest first.
    /// A chat that runs again replaces its ended row.
    static func state(running: [ReplyActivityChat], ended: [ReplyActivityChat]) -> ReplyActivityAttributes.ContentState {
        let runningIDs = Set(running.map(\.id))
        let all = running + ended.filter { !runningIDs.contains($0.id) }
        let sorted = all.sorted { a, b in
            if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
            // Ended rows: the newest first. Running ones: the one that started first.
            if !a.status.isActive { return (a.ended ?? .distantPast) > (b.ended ?? .distantPast) }
            return (a.started ?? .distantFuture) < (b.started ?? .distantFuture)
        }
        let rows = Array(sorted.prefix(ReplyActivityText.maxRows))
        let hidden = sorted.dropFirst(ReplyActivityText.maxRows).filter(\.status.isActive).count
        return .init(chats: rows, hiddenCount: hidden)
    }

    /// What the system's task list says while the continued task holds the app (`BGContinuedProcessingTask` titles):
    /// the lead chat's phase, then its title, and how many others reply.
    static func continuedTaskText(_ state: ReplyActivityAttributes.ContentState) -> (title: String, subtitle: String)? {
        guard let lead = state.chats.first(where: \.status.isActive) else { return nil }
        let others = state.activeCount - 1
        var subtitle = lead.status == .needsYou ? (lead.detail ?? lead.title) : lead.title
        if others > 0 {
            subtitle += " · " + (others == 1 ? String(localized: "1 more chat") : String(localized: "\(others) more chats"))
        }
        return (lead.label, subtitle)
    }

    /// Tool calls that are themselves a question to the person, before (or without) a card in the queues.
    private static func implicitApproval(_ phase: ChatController.Phase) -> ReplyActivityInput.Approval? {
        guard case .tool(let name, let argument) = phase else { return nil }
        switch name {
        case ToolNames.saveSkill: return .skill(name: argument)
        case ToolNames.browserShow: return .browser
        default: return nil
        }
    }

    private static func ask(_ approval: ReplyActivityInput.Approval) -> String {
        switch approval {
        case .sshCommand(let server): String(localized: "Approve a command on \(server)")
        case .sshPrompt(let hop): String(localized: "\(hop) asks for an answer")
        case .skill(let name): name.isEmpty ? String(localized: "Save a skill?") : String(localized: "Save the skill \u{201C}\(name)\u{201D}?")
        case .robotCheck(let host): String(localized: "\(host) wants a robot check")
        case .browser: String(localized: "Finish a step in the browser")
        case .packageTool(let package, let tool): String(localized: "Approve \(package) › \(tool)")
        case .network(let host): String(localized: "Allow a connection to \(host)")
        }
    }

    private static func words(_ phase: ChatController.Phase, browserHost: String?) -> (String, String) {
        switch phase {
        case .idle, .waiting, .thinking: return (String(localized: "Thinking"), "sparkle")
        case .queued: return (String(localized: "Waiting for another chat"), "hourglass")
        case .writing: return (String(localized: "Writing"), "text.alignleft")
        case .compacting: return (String(localized: "Summarizing the chat"), "arrow.down.right.and.arrow.up.left")
        case .tool(let name, let argument): return toolWords(name, argument: argument, browserHost: browserHost)
        case .drafting(let name, _, _): return toolWords(name, argument: "", browserHost: browserHost)
        }
    }

    private static func toolWords(_ name: String, argument: String, browserHost: String?) -> (String, String) {
        switch name {
        case ToolNames.webSearch:
            return (String(localized: "Searching the web"), "magnifyingglass")
        case ToolNames.webFetch, ToolNames.runPlugin:
            guard let host = host(of: argument) else { return (String(localized: "Reading a page"), "doc.text") }
            return (String(localized: "Reading \(host)"), "doc.text")
        case ToolNames.browserOpen:
            guard let host = host(of: argument) ?? browserHost else { return (String(localized: "Browsing"), "safari") }
            return (String(localized: "Browsing \(host)"), "safari")
        case _ where ToolNames.isBrowserAction(name):
            guard let browserHost else { return (String(localized: "Browsing"), "safari") }
            return (String(localized: "Browsing \(browserHost)"), "safari")
        case ToolNames.runPython: return (String(localized: "Running Python"), "chevron.left.forwardslash.chevron.right")
        case ToolNames.viewImage: return (String(localized: "Looking at an image"), "photo")
        case ToolNames.browserEval, ToolNames.runSkillScript: return (String(localized: "Running a script"), "curlybraces")
        case ToolNames.loadSkill: return (String(localized: "Reading a skill"), "book")
        case ToolNames.showPlaces: return (String(localized: "Mapping places"), "map")
        case ToolNames.showHTML: return (String(localized: "Making an artifact"), "rectangle.on.rectangle")
        case ToolNames.currentLocation: return (String(localized: "Finding your location"), "location")
        case ToolNames.videoTranscript: return (String(localized: "Reading the transcript"), "captions.bubble")
        case _ where SSHToolNames.covers(name): return (String(localized: "Working on a server"), "server.rack")
        case _ where PackageToolNames.covers(name): return (String(localized: "Using \(PackageToolNames.packageName(of: name))"), "shippingbox")
        default: return (String(localized: "Working"), "gearshape")
        }
    }

    /// "naver.com" for "https://www.naver.com/…"; nil for text that is not a web address.
    static func host(of argument: String) -> String? {
        let text = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

/// When the activity shows, and how it goes. Pure, so the rules are tested without ActivityKit.
enum ReplyActivityPolicy {
    /// Whether an activity should be up now.
    ///
    /// - Parameter systemProgressShown: the continued task (`BGContinuedProcessingTask`) holds the app. iOS then shows its
    ///   own progress for the reply on the Lock Screen and in the Dynamic Island, and an app can't hide it. A Live
    ///   Activity next to it would say the same thing twice, so the reply's words go into that task's title instead
    ///   (`continuedTaskText`), and the activity covers the times it isn't there.
    static func wantsActivity(enabled: Bool, authorized: Bool, activeRuns: Int, systemProgressShown: Bool) -> Bool {
        enabled && authorized && activeRuns > 0 && !systemProgressShown
    }

    /// ActivityKit starts an activity only while the app is in front (`ActivityAuthorizationError.visibility`): when
    /// the app is about to leave the screen, not once it has.
    static func canStart(inBackground: Bool) -> Bool { !inBackground }

    enum Dismissal: Equatable {
        case immediate
        case after(Duration)
    }

    struct Ending: Equatable {
        /// How long the result stays in the Dynamic Island before the activity ends.
        var dwell: Duration
        var dismissal: Dismissal
    }

    static let dwell: Duration = .seconds(8)
    /// How long the summary stays on the Lock Screen when no notification carries it.
    static let summaryLifetime: Duration = .seconds(15 * 60)

    /// How the activity goes once every reply has ended.
    /// - The person is in the app: at once, they are looking at the answer.
    /// - In the background: the result shows for a moment. Then, when a notification brings the answer (Settings and
    ///   permission), the activity goes, so the Lock Screen doesn't show the same answer twice; without one, its
    ///   summary stays on the Lock Screen for a while.
    static func ending(appActive: Bool, notifies: Bool) -> Ending {
        if appActive { return Ending(dwell: .zero, dismissal: .immediate) }
        return Ending(dwell: dwell, dismissal: notifies ? .immediate : .after(summaryLifetime))
    }
}

/// At most one update a second, and none that would show what is already there. Pure: the caller supplies the time.
struct ReplyActivityThrottle {
    let interval: Duration
    private(set) var lastSent: ContinuousClock.Instant?
    private(set) var lastState: ReplyActivityAttributes.ContentState?

    init(interval: Duration = .seconds(1)) { self.interval = interval }

    /// How long to wait before `state` may go out; nil when it is what was sent last.
    func delay(for state: ReplyActivityAttributes.ContentState, now: ContinuousClock.Instant = .now) -> Duration? {
        guard state != lastState else { return nil }
        guard let lastSent else { return .zero }
        let since = now - lastSent
        return since >= interval ? .zero : interval - since
    }

    mutating func sent(_ state: ReplyActivityAttributes.ContentState, at now: ContinuousClock.Instant = .now) {
        lastState = state
        lastSent = now
    }

    mutating func reset() {
        lastState = nil
        lastSent = nil
    }
}
#endif
