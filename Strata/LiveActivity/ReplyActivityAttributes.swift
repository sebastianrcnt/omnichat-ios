#if os(iOS)
import Foundation
import ActivityKit

/// The Live Activity of running replies, shared by the app (which starts and updates it) and the widget extension
/// (which draws it). One activity for every chat that replies at once, not one per chat: see `ReplyLiveActivities`.
///
/// Everything here is plain values the app has already put into words, so the extension needs nothing of the app
/// (no SwiftData, no settings, no App Group). ActivityKit caps the payload at 4 KB: titles and lines are cut short
/// before they get here (`ReplyActivityText`).
struct ReplyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The rows, most urgent first (`ReplyActivityChat.Status.rank`), at most `ReplyActivityText.maxRows`.
        var chats: [ReplyActivityChat]
        /// Chats replying beyond the rows ("+2 more").
        var hiddenCount: Int = 0

        /// The chat the compact presentations and a tap on the activity are about.
        var lead: ReplyActivityChat? { chats.first }
        var needsYou: Bool { chats.contains { $0.status == .needsYou } }
        /// Chats still replying (or waiting their turn), rows and hidden ones.
        var activeCount: Int { chats.filter(\.status.isActive).count + hiddenCount }
        /// Every reply has ended.
        var isFinished: Bool { activeCount == 0 }
    }

    /// The accent the person picked in Settings, as `#RRGGBB`. Fixed for the activity's life.
    var accentHex: String
}

/// One chat's row: what its reply is doing, in words.
struct ReplyActivityChat: Codable, Hashable, Identifiable {
    enum Status: String, Codable, Hashable {
        /// Waiting for another chat to finish (`ChatController.Phase.queued`).
        case queued
        case working
        /// An approval or a robot check waits for the person.
        case needsYou
        case ready
        case stopped
        case failed

        var isActive: Bool { self == .queued || self == .working || self == .needsYou }

        /// Row order: what needs the person, then what runs, then what waits, then what ended.
        var rank: Int {
            switch self {
            case .needsYou: 0
            case .working: 1
            case .queued: 2
            case .ready: 3
            case .failed: 4
            case .stopped: 5
            }
        }
    }

    var id: UUID
    /// The chat's title, or its question before it has one.
    var title: String
    var status: Status
    /// The phase in plain words: "Searching the web", "Browsing naver.com", "Needs you", "Reply ready".
    var label: String
    /// A second line: the start of the answer, or what the person is asked.
    var detail: String?
    /// SF Symbol for the phase.
    var symbol: String
    /// Tool rounds finished so far.
    var steps: Int = 0
    /// When the reply started working (nil while queued): the elapsed time counts from here.
    var started: Date?
    /// When it ended: the elapsed time stops here.
    var ended: Date?
}

/// `openchat://chat/<id>`: a tap on the activity (or on one of its rows) opens that chat.
enum ReplyActivityLink {
    static let scheme = "openchat"
    static let host = "chat"

    static func url(for conversation: UUID) -> URL {
        URL(string: "\(scheme)://\(host)/\(conversation.uuidString)")!
    }

    /// The chat a link opens; nil for any other URL.
    static func conversationID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == host else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

/// Keeps the payload small and the lines short enough for a lock screen.
enum ReplyActivityText {
    static let maxRows = 3
    static let titleLimit = 60
    static let detailLimit = 120

    /// One line, at most `limit` characters, with an ellipsis when cut.
    static func clip(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
#endif
