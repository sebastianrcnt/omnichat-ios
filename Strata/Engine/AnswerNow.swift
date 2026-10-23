import Foundation

/// "Answer now": ends a long think-and-search run and asks for an answer from what has been gathered.
enum AnswerNow {
    /// The message appended after the last completed result. Sent to the model as it is; never shown in the transcript.
    static let instruction = "Answer now using only the information gathered so far. Do not call tools."
    /// The capsule appears after this long in a turn...
    static let minimumSeconds: TimeInterval = 10
    /// ...or after this many searches, whichever comes first.
    static let minimumSearches = 2

    /// Only while the turn is running tool rounds (a tool is running or one has finished) and the model is still
    /// researching: not before it uses a tool, not once it is writing, not while summarizing.
    static func isOffered(elapsed: TimeInterval, completedToolRounds: Int, searches: Int, phase: ChatController.Phase) -> Bool {
        let researching: Bool
        switch phase {
        case .tool: researching = true
        case .waiting, .thinking: researching = completedToolRounds > 0
        case .idle, .queued, .writing, .drafting, .compacting: researching = false
        }
        return researching && (elapsed > minimumSeconds || searches >= minimumSearches)
    }
}
