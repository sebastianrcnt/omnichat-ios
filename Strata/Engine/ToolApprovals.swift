import Foundation
import Observation

/// What a package tool call waits for the user to approve: shown under the call's line in its chat's feed.
struct PackageApproval: Sendable, Equatable {
    enum Level: Sendable, Equatable {
        /// The first call of the tool in this chat: "Allow in this chat", "Always", "Deny".
        case first
        /// Every call: "Run", "Always for this tool" (when allowed), "Deny".
        case always
    }

    var packageID: String
    var packageName: String
    var trust: PackageTrust
    /// The tool's title ("Create issue") and full name (`jira__create`).
    var toolTitle: String
    var toolName: String
    var host: String
    /// The resolved request without credentials: method, URL and body, exactly what will be sent.
    var request: String
    /// The arguments, pretty-printed.
    var arguments: String
    var level: Level
    /// Whether "Always" is offered.
    var offersAlways = true
}

/// The user's answer to a package approval card.
enum PackageApprovalAnswer: Sendable, Equatable {
    /// Run this call ("Run").
    case run
    /// This call and the tool's later calls in this chat ("Allow in this chat").
    case allowInChat
    /// Every call of the tool from now on, in every chat ("Always").
    case always
    case deny

    var allows: Bool { self != .deny }
}

/// A connection Python wants to make to a private or local address (`PySocketBridge`): asked once per chat and host.
struct NetworkApproval: Sendable, Equatable {
    /// The host as the code named it, and the address it resolved to when that's different.
    var host: String
    var address: String?
    var port: Int
    /// "TCP" or "UDP".
    var proto: String
}

/// The cards tool calls wait on: SSH approvals and prompts (`SSHRequests` is a view of these), package tool
/// approvals, and Python's connections to local addresses. Each is tied to its chat and its call, so the feed shows it under that call's line, in that chat only;
/// call ids repeat across chats (`call_0`). A cancelled turn denies. While OmniChat is in the background a notification
/// says a card waits, and the Live Activity reads "Needs you".
@MainActor
@Observable
final class ToolApprovals {
    static let shared = ToolApprovals()

    enum Kind: Equatable {
        case ssh(SSHRequests.Kind)
        case package(PackageApproval)
        case network(NetworkApproval)
    }

    enum Answer: Equatable {
        case ssh(SSHRequests.Answer)
        case package(PackageApprovalAnswer)
        case network(Bool)
    }

    struct Request: Identifiable, Equatable {
        var id = UUID()
        var conversationID: UUID? = ToolContext.conversationID
        var callID: String? = ToolContext.callID
        var kind: Kind

        /// What a cancelled turn (or a card nobody answers) gives.
        var fallback: Answer {
            switch kind {
            case .ssh(.approval): .ssh(.approval(.deny))
            case .ssh(.prompt): .ssh(.prompt(nil))
            case .package: .package(.deny)
            case .network: .network(false)
            }
        }
    }

    private var queue: [(request: Request, answer: CheckedContinuation<Answer, Never>)] = []

    var all: [Request] { queue.map(\.request) }

    func pending(conversation: UUID?) -> [Request] { all.filter { $0.conversationID == conversation } }

    /// The card of a tool call in a chat, shown under its line in that chat's feed.
    func request(forCall callID: String, conversation: UUID?) -> Request? {
        queue.first { $0.request.callID == callID && $0.request.conversationID == conversation }?.request
    }

    /// Waits for the answer. A cancelled turn gets the request's fallback (deny).
    func ask(_ request: Request) async -> Answer {
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled { cont.resume(returning: request.fallback); return }
                queue.append((request, cont))
                ToolApprovalNotifier.notify(request)
            }
        } onCancel: {
            Task { @MainActor in self.answer(request.id, request.fallback) }
        }
    }

    /// Ignored for a request already answered.
    func answer(_ id: UUID, _ answer: Answer) {
        guard let i = queue.firstIndex(where: { $0.request.id == id }) else { return }
        queue.remove(at: i).answer.resume(returning: answer)
    }

    // MARK: Package tools

    /// "Allow in this chat" answers, by chat and `<package id>/<tool>`. For this session: a relaunch asks again.
    private var allowedInChat: [UUID: Set<String>] = [:]

    func isAllowedInChat(_ key: String, conversation: UUID?) -> Bool {
        conversation.map { allowedInChat[$0]?.contains(key) == true } ?? false
    }

    func allowInChat(_ key: String, conversation: UUID?) {
        guard let conversation else { return }
        allowedInChat[conversation, default: []].insert(key)
    }

    func askPackage(_ approval: PackageApproval, conversation: UUID?, callID: String?) async -> PackageApprovalAnswer {
        if case .package(let a) = await ask(Request(conversationID: conversation, callID: callID, kind: .package(approval))) { return a }
        return .deny
    }

    // MARK: Python's connections

    /// Whether Python may connect to a private or local host: asked once per chat and host, and remembered for this
    /// session. Without a chat there is no one to ask.
    func approveNetwork(_ approval: NetworkApproval, conversation: UUID?, callID: String?) async -> Bool {
        let key = "network/" + approval.host.lowercased()
        if isAllowedInChat(key, conversation: conversation) { return true }
        guard conversation != nil else { return false }
        guard case .network(let allowed) = await ask(Request(conversationID: conversation, callID: callID, kind: .network(approval))) else {
            return false
        }
        if allowed { allowInChat(key, conversation: conversation) }
        return allowed
    }
}

/// A card that waits while OmniChat is in the background: a notification says so (tapping it opens the chat).
enum ToolApprovalNotifier {
    @MainActor
    static func notify(_ request: ToolApprovals.Request) {
        guard !AppLifecycle.isActive, let conversation = request.conversationID else { return }
        let body = switch request.kind {
        case .ssh(.approval(let a)): String(localized: "Approve a command on \(a.server)?")
        case .ssh(.prompt(let p)): String(localized: "\(p.hop) asks for an answer.")
        case .package(let p): String(localized: "Approve \(p.packageName) › \(p.toolTitle)?")
        case .network(let n): String(localized: "Allow Python to connect to \(n.host)?")
        }
        ReplyBackgroundExecution.notifyCompletion(title: "OmniChat", body: body, conversationID: conversation)
    }
}
