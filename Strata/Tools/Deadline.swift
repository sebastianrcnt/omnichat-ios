import Foundation

/// Time limits of one web fetch. The overall deadline is the backstop for the phases added together.
struct FetchTimeouts: Sendable, Equatable {
    /// Navigation until the page finishes loading.
    var load: Duration = .seconds(15)
    /// One JavaScript evaluation.
    var script: Duration = .seconds(10)
    /// The `document.readyState` check after a load timeout.
    var probe: Duration = .seconds(2)
    /// Wait for client-side rendering to settle after the load.
    var settle: Duration = .milliseconds(600)
    /// The whole fetch, from URL check to extracted text.
    var overall: Duration = .seconds(25)

    static let standard = FetchTimeouts()

    /// The limits for the user's "Page timeout" setting. Read by the tools off the main actor, per call.
    static var current: FetchTimeouts { FetchPatience.current.timeouts }

    /// "12.3 s", for messages the model reads.
    static func seconds(_ d: Duration) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return s == s.rounded() ? "\(Int(s)) s" : String(format: "%.1f s", s)
    }
}

/// How long the hidden browser waits for a page: the "Page timeout" setting.
enum FetchPatience: String, CaseIterable, Identifiable, Sendable {
    case fast, standard, patient

    var id: String { rawValue }

    var timeouts: FetchTimeouts {
        switch self {
        case .fast: FetchTimeouts(load: .seconds(8), overall: .seconds(15))
        case .standard: .standard
        case .patient: FetchTimeouts(load: .seconds(30), overall: .seconds(45))
        }
    }

    var label: String {
        switch self {
        case .fast: String(localized: "Fast (15 s)")
        case .standard: String(localized: "Standard (25 s)")
        case .patient: String(localized: "Patient (45 s)")
        }
    }

    static let defaultsKey = "fetchPatience"
    static var current: FetchPatience {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(FetchPatience.init(rawValue:)) ?? .standard
    }
}

/// Races an operation against a time limit and against cancellation. Built on a continuation rather than a task
/// group, so a caller is released at once even when the operation never returns and ignores cancellation (a
/// WebKit call on a stuck page): the operation is cancelled and `onAbort` runs, but nothing waits for it.
enum Deadline {
    /// A running race's clock, which `pausing` stops while the user is asked something.
    @MainActor
    protocol Clock: AnyObject, Sendable {
        func pause()
        func resume()
    }

    /// The deadlines the current task runs under, innermost last (nested tools: a fetch inside a shared load).
    @TaskLocal static var clocks: [any Clock] = []

    @MainActor
    private final class Race<T: Sendable>: Clock {
        var continuation: CheckedContinuation<T, Error>?
        var operation: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var onAbort: (@MainActor () -> Void)?
        var finished = false
        var cancelledEarly = false
        var limit: Duration = .zero
        var timeoutError: Error = WebToolError.timeout
        private var pauses = 0

        func startTimer() {
            timer?.cancel()
            let limit = limit
            timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled, let self else { return }
                self.finish(.failure(self.timeoutError), abort: true)
            }
        }

        /// Waiting for the user doesn't count against the limit: the clock stops, and starts over in full after, for
        /// the work that follows (reading a page the user just got past a check on).
        func pause() {
            pauses += 1
            timer?.cancel()
            timer = nil
        }

        func resume() {
            pauses = max(0, pauses - 1)
            if pauses == 0, !finished { startTimer() }
        }

        func finish(_ result: Result<T, Error>, abort: Bool) {
            guard !finished else { return }
            finished = true
            timer?.cancel()
            if abort {
                operation?.cancel()
                onAbort?()
            }
            onAbort = nil
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    /// Runs `body` with every deadline of the current task stopped (the user is solving a robot check).
    @MainActor
    static func pausing<T>(_ body: () async throws -> T) async rethrows -> T {
        let held = clocks
        for clock in held { clock.pause() }
        defer { for clock in held { clock.resume() } }
        return try await body()
    }

    /// Runs `operation`. If `limit` passes first, `onAbort` runs and `timeoutError` is thrown; if the calling task is
    /// cancelled first, `onAbort` runs and `CancellationError` is thrown. Otherwise the operation's result is returned.
    @MainActor
    static func run<T: Sendable>(_ limit: Duration, timeoutError: Error = WebToolError.timeout,
                                 onAbort: @escaping @MainActor () -> Void = {},
                                 operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let race = Race<T>()
        race.onAbort = onAbort
        race.limit = limit
        race.timeoutError = timeoutError
        let chain = clocks + [race]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                if Task.isCancelled || race.cancelledEarly {
                    cont.resume(throwing: CancellationError())
                    return
                }
                race.continuation = cont
                race.operation = Task { @MainActor in
                    do { race.finish(.success(try await Deadline.$clocks.withValue(chain) { try await operation() }), abort: false) }
                    catch { race.finish(.failure(error), abort: false) }
                }
                race.startTimer()
            }
        } onCancel: {
            Task { @MainActor in
                race.cancelledEarly = true
                race.finish(.failure(CancellationError()), abort: true)
            }
        }
    }
}
