import Foundation

/// Whether anyone can see the screen. Smoothed reveal only matters while the screen can be seen: in the background
/// (a reply continuing under a background lease) text is revealed at once and no display timer runs. `.inactive`
/// (an overlay, the app switcher opening) still shows the app, so it keeps animating.
@MainActor
enum DisplayActivity {
    static var isActive: () -> Bool = { !AppLifecycle.isBackground }
}

/// Runs one action when the app next becomes active (the reveal of text that arrived in the background).
@MainActor
final class ActivationFlush {
    private nonisolated(unsafe) var token: NSObjectProtocol?

    var isArmed: Bool { token != nil }

    func arm(center: NotificationCenter = .default, _ action: @escaping @MainActor () -> Void) {
        guard token == nil else { return }
        token = center.addObserver(forName: AppLifecycle.didBecomeActive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.disarm()
                action()
            }
        }
    }

    func disarm(center: NotificationCenter = .default) {
        if let token { center.removeObserver(token) }
        token = nil
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
