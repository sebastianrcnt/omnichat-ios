import Foundation

/// Runs the calls of one tool round side by side, a few at a time.
enum ToolRound {
    /// How many calls of a round run at once.
    static let maxConcurrent = 5

    /// Runs `indices` of `calls`, at most `limit` at a time. `onFinished` is called on the main actor with each result
    /// as it arrives (in finishing order, not call order). Cancelling the caller cancels every running call, and the
    /// error is thrown once they have all returned.
    @MainActor
    static func execute(_ calls: [ToolCall], indices: [Int], tools: any ToolExecuting, limit: Int = maxConcurrent,
                        onFinished: @MainActor (Int, ToolOutput) throws -> Void) async throws {
        guard !indices.isEmpty else { return }
        try await withThrowingTaskGroup(of: (Int, ToolOutput).self) { group in
            var next = 0
            let first = min(max(limit, 1), indices.count)
            while next < first {
                let index = indices[next]
                let call = calls[index]
                next += 1
                group.addTask { try await runOne(index, call, tools) }
            }
            while let (index, output) = try await group.next() {
                try Task.checkCancellation()
                try onFinished(index, output)
                if next < indices.count {
                    let nextIndex = indices[next]
                    let call = calls[nextIndex]
                    next += 1
                    group.addTask { try await runOne(nextIndex, call, tools) }
                }
            }
        }
    }

    @MainActor
    private static func runOne(_ index: Int, _ call: ToolCall, _ tools: any ToolExecuting) async throws -> (Int, ToolOutput) {
        let output = try await ToolExecutionRecovery.execute(call, using: tools)
        return (index, output)
    }
}
