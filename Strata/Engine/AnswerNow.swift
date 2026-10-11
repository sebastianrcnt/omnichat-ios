import Foundation

/// "Answer now": ends a long think-and-search run and asks for an answer from what has been gathered.
enum AnswerNow {
    /// The message appended after the last completed result. Sent to the model as it is; never shown in the transcript.
    static let instruction = "Answer now using only the information gathered so far. Do not call tools."
    /// The pill appears after this long in a turn...
    static let minimumSeconds: TimeInterval = 10
    /// ...or after this many finished tool rounds, whichever comes first.
    static let minimumToolRounds = 2

    /// Only while the model is still working on its research (not once it is writing, or while summarizing).
    static func isOffered(elapsed: TimeInterval, completedToolRounds: Int, phase: ChatController.Phase) -> Bool {
        switch phase {
        case .waiting, .thinking, .tool: elapsed > minimumSeconds || completedToolRounds >= minimumToolRounds
        case .idle, .writing, .compacting: false
        }
    }
}
