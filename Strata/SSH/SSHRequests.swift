import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// What a command waits for the user to approve.
struct SSHApproval: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case exec(command: String)
        case upload(path: String, bytes: Int)
    }
    /// The approval key "Always for this server" saves: a server's name, or `user@host:port`.
    var target: String
    /// How the card names the server: its name, or `user@host`.
    var server: String
    var action: Action
}

/// The user's answer to an approval card.
enum SSHApprovalAnswer: Sendable, Equatable { case run, always, deny }

/// Whether a command needs the user's approval: with "Ask before running commands" on, unless the user chose
/// "Always for this server" for its target.
enum SSHApprovalPolicy {
    static let askKey = "sshAskBeforeRunning"

    static var asks: Bool { UserDefaults.standard.object(forKey: askKey) as? Bool ?? true }

    static func needsApproval(asks: Bool, alwaysAllowed: Bool) -> Bool { asks && !alwaysAllowed }

    /// Asks when needed; "Always" is saved for the target. True when the command may run.
    static func approve(_ approval: SSHApproval, asks: Bool, store: SSHStore,
                        ask: @Sendable (SSHApproval) async -> SSHApprovalAnswer) async -> Bool {
        guard needsApproval(asks: asks, alwaysAllowed: store.isAlwaysAllowed(approval.target)) else { return true }
        switch await ask(approval) {
        case .run: return true
        case .always:
            try? store.setAlwaysAllowed(true, target: approval.target)
            return true
        case .deny: return false
        }
    }
}

/// The SSH cards waiting for the user: approvals, and keyboard-interactive prompts no saved answer covered. Each is
/// tied to its chat and its tool call, so the feed shows it under that call's line, in that chat only.
@MainActor
@Observable
final class SSHRequests {
    static let shared = SSHRequests()

    enum Kind: Equatable {
        case approval(SSHApproval)
        case prompt(SSHPromptRequest)
    }

    enum Answer: Equatable {
        case approval(SSHApprovalAnswer)
        /// Answers to the prompts, in order; nil gives up.
        case prompt([String]?)
    }

    struct Request: Identifiable, Equatable {
        let id = UUID()
        var conversationID: UUID?
        var callID: String?
        var kind: Kind
    }

    private var queue: [(request: Request, answer: CheckedContinuation<Answer, Never>)] = []

    var all: [Request] { queue.map(\.request) }

    func pending(conversation: UUID?) -> [Request] { queue.map(\.request).filter { $0.conversationID == conversation } }

    /// The request of a tool call, shown under its line in the feed.
    func request(forCall callID: String) -> Request? { queue.first { $0.request.callID == callID }?.request }

    /// Waits for the answer. A cancelled turn denies (or gives up the prompt).
    func ask(_ request: Request) async -> Answer {
        let fallback: Answer = if case .approval = request.kind { .approval(.deny) } else { .prompt(nil) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled { cont.resume(returning: fallback); return }
                queue.append((request, cont))
                SSHRequestNotifier.notify(request)
            }
        } onCancel: {
            Task { @MainActor in self.answer(request.id, fallback) }
        }
    }

    /// Ignored for a request already answered.
    func answer(_ id: UUID, _ answer: Answer) {
        guard let i = queue.firstIndex(where: { $0.request.id == id }) else { return }
        queue.remove(at: i).answer.resume(returning: answer)
    }

    func askApproval(_ approval: SSHApproval, conversation: UUID?, callID: String?) async -> SSHApprovalAnswer {
        if case .approval(let a) = await ask(Request(conversationID: conversation, callID: callID, kind: .approval(approval))) { return a }
        return .deny
    }

    func askPrompt(_ prompt: SSHPromptRequest, conversation: UUID?, callID: String?) async -> [String]? {
        if case .prompt(let answers) = await ask(Request(conversationID: conversation, callID: callID, kind: .prompt(prompt))) { return answers }
        return nil
    }
}

/// A card that waits while OpenChat is in the background: a notification says so (tapping it opens the chat).
enum SSHRequestNotifier {
    @MainActor
    static func notify(_ request: SSHRequests.Request) {
        guard !AppLifecycle.isActive, let conversation = request.conversationID else { return }
        let body = switch request.kind {
        case .approval(let a): String(localized: "Approve a command on \(a.server)?")
        case .prompt(let p): String(localized: "\(p.hop) asks for an answer.")
        }
        ReplyBackgroundExecution.notifyCompletion(title: "OpenChat", body: body, conversationID: conversation)
    }
}

/// Keeps an SSH operation going for a short while after the app leaves the screen (iOS gives a background task about
/// half a minute), and tells whether it went to the background meanwhile, so a dropped connection can say why.
@MainActor
final class SSHBackgroundGuard {
    private(set) var wentToBackground = false
    #if canImport(UIKit)
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var observer: NSObjectProtocol?
    #endif

    func begin() {
        #if canImport(UIKit)
        if !AppLifecycle.isActive { wentToBackground = true }
        task = UIApplication.shared.beginBackgroundTask(withName: "OpenChat SSH") { [weak self] in
            Task { @MainActor in self?.end() }
        }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentToBackground = true }
        }
        #endif
    }

    func end() {
        #if canImport(UIKit)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
        #endif
    }
}
