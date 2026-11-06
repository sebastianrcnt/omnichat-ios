import Foundation
import WebKit

// Robot checks (CAPTCHAs, Cloudflare's "Just a moment", Google's "unusual traffic") in the hidden web views. The app
// only notices one and hands that same page to the user: it never solves or works around a check, and no solver
// service is ever involved.

/// Finds a robot check from the page's URL and a few things read from its DOM. Pure, so it is tested on its own.
enum RobotCheck {
    enum Kind: String, Equatable, Sendable {
        case recaptcha, hcaptcha, turnstile, cloudflare, googleSorry, naverCaptcha, other

        /// Cloudflare's checks run by themselves and most visitors never touch them.
        var clearsOnItsOwn: Bool { self == .cloudflare || self == .turnstile }
    }

    /// What the probe reads in the page.
    struct Signals: Decodable, Equatable, Sendable {
        var title = ""
        /// Sources of the iframes that take up room on the page (a check's box), the first few.
        var frames: [String] = []
        /// Cloudflare's challenge page markers: `#challenge-form`, `#challenge-running`, `window._cf_chl_opt.cType`.
        /// (`_cf_chl_opt` alone doesn't count: ordinary pages behind Cloudflare can define it too.)
        var cloudflare = false
        /// The length of the visible text, and its start.
        var textLength = 0
        var text = ""
        /// Visible text inputs and text areas: two or more is a form the page is for, not a check.
        var formFields = 0

        static func decode(_ json: String) -> Signals? { try? JSONDecoder().decode(Signals.self, from: Data(json.utf8)) }
    }

    /// Settings > Tools > "Ask me to solve robot checks" (on by default).
    nonisolated static let askKey = "askRobotChecks"
    nonisolated static var asksUser: Bool {
        UserDefaults.standard.object(forKey: askKey) == nil ? true : UserDefaults.standard.bool(forKey: askKey)
    }

    /// A check's markers and box only count on a page with little else on it: an article with a comment form that
    /// carries a reCAPTCHA is not a check.
    static let shortPage = 2_000
    /// Wording alone is weaker evidence, so it needs a page that says hardly anything else.
    static let wordingPage = 800
    /// A login or contact form with a check's box in it is the form's page, not a wall.
    static let formPage = 2

    static let cloudflareTitles = ["just a moment", "잠시만 기다리십시오", "attention required! | cloudflare", "checking your browser"]

    static let phrases = [
        "verify you are human", "verifying you are human", "verify that you are human", "are you a robot",
        "i'm not a robot", "unusual traffic", "checking your browser", "complete the security check",
        "bots use duckduckgo too", "자동입력 방지", "자동 입력 방지", "로봇이 아닙니다",
    ]

    static func detect(url: URL?, signals: Signals) -> Kind? {
        let host = url?.host()?.lowercased() ?? ""
        let path = url?.path().lowercased() ?? ""
        // Names only: the values are what was searched for, and a search for "captcha" is not a check.
        let queryNames = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?.map { $0.name.lowercased() } ?? []
        let title = signals.title.lowercased()
        let text = signals.text.lowercased()
        let short = signals.textLength < shortPage
        let naver = host == "naver.com" || host.hasSuffix(".naver.com")

        if isGoogle(host) && path.hasPrefix("/sorry") { return .googleSorry }
        if naver && (path.contains("captcha") || queryNames.contains { $0.contains("captcha") }) { return .naverCaptcha }
        if host == "challenges.cloudflare.com" || path.hasPrefix("/cdn-cgi/challenge-platform") { return .cloudflare }
        guard short else { return nil }
        if signals.cloudflare || cloudflareTitles.contains(where: { title.hasPrefix($0) }) { return .cloudflare }
        let frames = signals.formFields < formPage ? signals.frames.map { $0.lowercased() } : []
        for frame in frames where !frame.contains("size=invisible") {
            if frame.contains("/recaptcha/") && (frame.contains("/anchor") || frame.contains("/bframe")) { return .recaptcha }
            if frame.contains("hcaptcha.com") { return .hcaptcha }
            if frame.contains("challenges.cloudflare.com") { return .turnstile }
        }
        guard signals.textLength < wordingPage else { return nil }
        if phrases.contains(where: { text.contains($0) || title.contains($0) }) { return naver ? .naverCaptcha : .other }
        return nil
    }

    /// google.com, www.google.co.kr and the like (not googleusercontent.com or a site named google-something).
    static func isGoogle(_ host: String) -> Bool {
        let labels = host.split(separator: ".")
        guard let i = labels.firstIndex(of: "google"), i <= 1 else { return false }
        if i == 1 && !["www", "ipv4", "ipv6"].contains(labels[0]) { return false }
        let rest = labels[(i + 1)...]
        return !rest.isEmpty && rest.count <= 2 && rest.allSatisfy { $0.count <= 3 }
    }

    /// Reads `Signals` from the page.
    static let probe = """
    (function() {
      var frames = [];
      try {
        document.querySelectorAll("iframe").forEach(function(f) {
          if (frames.length >= 12) return;
          var r = f.getBoundingClientRect();
          if (r.width >= 30 && r.height >= 30 && f.src) frames.push(String(f.src).slice(0, 300));
        });
      } catch (e) {}
      var cf = false;
      try { cf = !!((window._cf_chl_opt && window._cf_chl_opt.cType) || document.getElementById("challenge-form") || document.getElementById("challenge-running") || document.getElementById("cf-challenge-running")); } catch (e) {}
      var fields = 0;
      try {
        document.querySelectorAll("textarea, input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button])").forEach(function(f) {
          var r = f.getBoundingClientRect();
          if (r.width > 0 && r.height > 0) fields++;
        });
      } catch (e) {}
      var t = document.body ? (document.body.innerText || "") : "";
      return JSON.stringify({ title: document.title || "", frames: frames, cloudflare: cf, textLength: t.length, text: t.slice(0, 600), formFields: fields });
    })()
    """

    /// The model's text when a check stopped a tool.
    static func skippedMessage(host: String) -> String {
        "The page at \(host) showed a robot check, and the user skipped this page. Don't open it again in this reply; use other sources."
    }

    static func notAskedMessage(host: String) -> String {
        "The page at \(host) shows a robot check (CAPTCHA). The user has turned off being asked to solve these, so it can't be read; use other sources."
    }
}

enum RobotCheckError: Error, LocalizedError, Equatable {
    /// The user tapped Skip.
    case skipped(host: String)
    /// Settings > Tools > "Ask me to solve robot checks" is off.
    case notAsked(host: String)

    var errorDescription: String? {
        switch self {
        case .skipped(let host): RobotCheck.skippedMessage(host: host)
        case .notAsked(let host): RobotCheck.notAskedMessage(host: host)
        }
    }
}

/// Stops a tool at a robot check until the user is done with the page (or skips it). Every web view a tool loads passes
/// through here after its page loaded: search, fetch and the browser.
@MainActor
enum RobotCheckGate {
    enum Outcome: Equatable, Sendable { case solved, skipped, cancelled }

    typealias Ask = @MainActor (_ host: String, _ kind: RobotCheck.Kind) async -> Outcome

    /// Returns when the page shows no check (now, or after the user solved it in that same view: then true); throws
    /// `RobotCheckError` when the user skipped it or doesn't want to be asked, and `CancellationError` for a stopped turn.
    @discardableResult
    static func pass(_ page: some FetchablePage, timeouts: FetchTimeouts, asks: Bool = RobotCheck.asksUser, ask: Ask) async throws -> Bool {
        var solved = false
        var waited = false
        while true {
            try Task.checkCancellation()
            guard let kind = await kind(of: page, timeouts: timeouts) else { return solved }
            if kind.clearsOnItsOwn && !waited {
                waited = true
                if await clears(page, timeouts: timeouts) {
                    await settle(page, timeouts: timeouts)
                    continue // and look again: the page may only have been navigating
                }
                try Task.checkCancellation()
            }
            let host = page.currentURL?.host() ?? "the site"
            guard asks else { throw RobotCheckError.notAsked(host: host) }
            // The user may take minutes: pause the deadline; a notification brings them back instead.
            let outcome = await Deadline.pausing { await ask(host, kind) }
            switch outcome {
            case .skipped: throw RobotCheckError.skipped(host: host)
            case .cancelled: throw CancellationError()
            case .solved:
                solved = true
                await settle(page, timeouts: timeouts) // and look again: a check can come back
            }
        }
    }

    /// The real gate for a hidden view: the chat shows the approval card, and the sheet shows this view.
    @discardableResult
    static func pass(_ view: HiddenWebView, timeouts: FetchTimeouts) async throws -> Bool {
        let conversation = ToolContext.conversationID
        let callID = ToolContext.callID
        return try await pass(view, timeouts: timeouts) { host, kind in
            await RobotCheckRequests.shared.ask(.init(host: host, kind: kind, page: view, conversationID: conversation, callID: callID))
        }
    }

    /// The check the page shows now, if any.
    private static func kind(of page: some FetchablePage, timeouts: FetchTimeouts) async -> RobotCheck.Kind? {
        guard let json = try? await page.evaluate(RobotCheck.probe, timeout: timeouts.probe),
              let signals = RobotCheck.Signals.decode(json) else { return nil }
        return RobotCheck.detect(url: page.currentURL, signals: signals)
    }

    /// Whether a check goes away by itself. This only waits for the page: nothing touches the check.
    private static func clears(_ page: some FetchablePage, timeouts: FetchTimeouts) async -> Bool {
        await Deadline.pausing {
            let started = ContinuousClock.now
            while ContinuousClock.now - started < timeouts.checkClears, !Task.isCancelled {
                try? await Task.sleep(for: timeouts.checkClears / 12)
                if await kind(of: page, timeouts: timeouts) == nil { return true }
            }
            return false
        }
    }

    /// After Done, or a check that cleared: the page it let through may still be loading.
    private static func settle(_ page: some FetchablePage, timeouts: FetchTimeouts) async {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < timeouts.load {
            let state = (try? await page.evaluate("document.readyState", timeout: timeouts.probe)) ?? ""
            if state == "complete" || state == "interactive" { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: timeouts.settle)
    }
}

/// Robot checks waiting for the user: the running reply's feed shows each as a card ("<host> wants a robot check",
/// Open page / Skip). Open lends the same web view to the browser sheet (`BrowserShowRequests`).
@MainActor
@Observable
final class RobotCheckRequests {
    static let shared = RobotCheckRequests()

    enum Choice: Sendable { case open, skip, cancel }

    struct Request: Identifiable {
        let id = UUID()
        let host: String
        let kind: RobotCheck.Kind
        let page: HiddenWebView
        let conversationID: UUID?
        let callID: String?
    }

    private var queue: [(request: Request, answer: CheckedContinuation<Choice, Never>)] = []
    /// Shows the sheet for a request. Test seam; by default the chat's browser sheet.
    @ObservationIgnored var present: @MainActor (Request) async -> Bool = { request in
        await BrowserShowRequests.shared.ask(.init(reason: String(localized: "Solve the robot check on this page, then tap Done."),
                                                   page: request.page, conversationID: request.conversationID))
    }
    /// Told when a card is posted while the app is not in front. Test seam; by default a local notification.
    @ObservationIgnored var notify: @MainActor (Request) -> Void = { request in
        ReplyBackgroundExecution.notifyRobotCheck(host: request.host, conversationID: request.conversationID, requestID: request.id)
    }

    /// The cards to show, oldest first, from every chat.
    var pending: [Request] { queue.map(\.request) }

    /// The chat's own cards (and any that belong to no chat): another chat's check waits in that chat's feed.
    func pending(for conversationID: UUID?) -> [Request] {
        queue.map(\.request).filter { $0.conversationID == nil || $0.conversationID == conversationID }
    }

    /// Waits until the user is done with the page (Done in the sheet) or skips it. Closing the sheet without Done shows
    /// the card again.
    func ask(_ request: Request) async -> RobotCheckGate.Outcome {
        while true {
            switch await choice(request) {
            case .skip: return .skipped
            case .cancel: return .cancelled
            case .open:
                if Task.isCancelled { return .cancelled }
                if await present(request) { return .solved }
                if Task.isCancelled { return .cancelled }
            }
        }
    }

    private func choice(_ request: Request) async -> Choice {
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled { cont.resume(returning: .cancel); return }
                queue.append((request, cont))
                if !AppLifecycle.isActive { notify(request) }
            }
        } onCancel: {
            Task { @MainActor in self.answer(request.id, .cancel) }
        }
    }

    /// Ignored for a request already answered.
    func answer(_ id: UUID, _ choice: Choice) {
        guard let i = queue.firstIndex(where: { $0.request.id == id }) else { return }
        queue.remove(at: i).answer.resume(returning: choice)
    }
}
