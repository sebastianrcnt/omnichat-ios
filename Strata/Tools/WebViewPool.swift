import Foundation
import Foundation

/// Hidden web views kept for the next fetch instead of being torn down: creating a WKWebView and its web content
/// process is the slow part of a short fetch. A few idle views are kept for a minute; a memory warning drops them.
@MainActor
final class WebViewPool {
    static let shared: WebViewPool = {
        let pool = WebViewPool()
        MemoryPurge.register { pool.drain() }
        return pool
    }()

    var maxIdle = 3
    var idleLifetime: Duration = .seconds(60)

    private var idle: [(view: HiddenWebView, since: ContinuousClock.Instant)] = []
    private var sweeper: Task<Void, Never>?

    var idleCount: Int { idle.count }

    /// A view ready for a page: an idle one of the right kind, or a new one.
    func acquire(reader: Bool, resolver: any HostResolving = SystemHostResolver(), guardNavigations: Bool = true) -> HiddenWebView {
        if let i = idle.lastIndex(where: { $0.view.injectsReader == reader }) {
            let view = idle.remove(at: i).view
            view.reset(resolver: resolver, guardNavigations: guardNavigations)
            return view
        }
        return HiddenWebView(guardNavigations: guardNavigations, resolver: resolver, injectsReader: reader)
    }

    /// Returns a view after use. A view that failed or timed out is torn down: its state cannot be trusted.
    func release(_ view: HiddenWebView, reusable: Bool) {
        view.stop()
        view.onProgress = nil
        guard reusable, idle.count < maxIdle else {
            view.dispose()
            return
        }
        idle.append((view, .now))
        scheduleSweep()
    }

    /// Tears down every idle view.
    func drain() {
        for entry in idle { entry.view.dispose() }
        idle.removeAll()
        sweeper?.cancel()
        sweeper = nil
    }

    private func scheduleSweep() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while let self, !Task.isCancelled, !self.idle.isEmpty {
                try? await Task.sleep(for: self.idleLifetime)
                guard !Task.isCancelled else { return }
                self.dropExpired()
            }
            self?.sweeper = nil
        }
    }

    private func dropExpired() {
        let now = ContinuousClock.now
        let expired = idle.filter { now - $0.since >= idleLifetime }
        for entry in expired { entry.view.dispose() }
        idle.removeAll { entry in expired.contains { $0.view === entry.view } }
    }
}
