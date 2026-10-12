import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Read-only WebKit tools can fail while their WebContent process is suspended,
/// even when the app holds a continued-processing lease. Don't persist that
/// background-only failure as a tool result: retry on the next active scene.
enum ToolExecutionRecovery {
    private final class Transitions: @unchecked Sendable {
        let lock = NSLock()
        private var backgrounded = false
        func mark() { lock.withLock { backgrounded = true } }
        var wasBackgrounded: Bool { lock.withLock { backgrounded } }
    }

    @MainActor
    private static func waitForForeground() async throws {
        // Woken by the foreground signal; the long timeout is only a safety net, not a poll.
        while !AppLifecycle.isActive {
            try await RecoverySignals.shared.wait(seconds: 30)
        }
        try Task.checkCancellation()
    }

    /// Runs one call with its id known to the tool (for progress), and finishes its progress fill.
    @MainActor
    static func execute(_ call: ToolCall, using tools: any ToolExecuting) async throws -> ToolOutput {
        do {
            let output = try await ToolContext.$callID.withValue(call.id) { try await run(call, using: tools) }
            ToolProgress.shared.finish(call.id, success: !output.isError)
            return output
        } catch {
            ToolProgress.shared.clear(call.id)
            throw error
        }
    }

    @MainActor
    private static func run(_ call: ToolCall, using tools: any ToolExecuting) async throws -> ToolOutput {
        #if os(macOS)
        // A Mac app is never suspended, so WebKit keeps working while another app is in front.
        return await tools.execute(name: call.name, arguments: call.arguments)
        #else
        guard tools.usesWebKit else { return await tools.execute(name: call.name, arguments: call.arguments) }
        if !ReplyBackgroundExecution.hasContinuedLease { try await waitForForeground() }
        let transitions = Transitions()
        if !AppLifecycle.isActive { transitions.mark() }
        let observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                              object: nil, queue: nil) { _ in transitions.mark() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let output = await tools.execute(name: call.name, arguments: call.arguments)
        try Task.checkCancellation()
        if output.isError && transitions.wasBackgrounded {
            try await waitForForeground()
            return await tools.execute(name: call.name, arguments: call.arguments)
        }
        return output
        #endif
    }
}
