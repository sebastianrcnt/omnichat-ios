#if os(macOS) && DEBUG
import AppKit
import os

/// Debug builds: logs where clicks and keys go, to catch the state where the window takes no typing (no first
/// responder, and a click on the composer or the search field doesn't give it one). Each click logs the view it lands
/// on and the first responder before and just after; each key logs its first responder (never the key itself).
/// Read with: `log show --last 30m --predicate 'subsystem == "cc.coolservices.strata" && category == "input"'`.
@MainActor
enum MacInputDiagnostics {
    private static let log = Logger(subsystem: "cc.coolservices.strata", category: "input")
    private static var monitor: Any?
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            if event.type == .leftMouseDown { click(event) } else { key(event) }
            return event
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                let became = name == NSWindow.didBecomeKeyNotification
                MainActor.assumeIsolated {
                    log.notice("\(became ? "became key" : "resigned key", privacy: .public): \(describe(window), privacy: .public)")
                }
            })
        }
        log.notice("input diagnostics on")
    }

    private static func click(_ event: NSEvent) {
        guard let window = event.window else {
            log.notice("click with no window; key=\(describe(NSApp.keyWindow), privacy: .public)")
            return
        }
        let hit = window.contentView?.superview?.hitTest(event.locationInWindow) ?? window.contentView?.hitTest(event.locationInWindow)
        let before = responder(window)
        log.notice("click in \(describe(window), privacy: .public) on \(chain(hit), privacy: .public); responder before: \(before, privacy: .public)\(state(window), privacy: .public)")
        DispatchQueue.main.async {
            log.notice("responder after click: \(responder(window), privacy: .public)")
        }
    }

    private static func key(_ event: NSEvent) {
        let window = event.window ?? NSApp.keyWindow
        log.notice("key in \(describe(window), privacy: .public); responder: \(window.map(responder) ?? "no window", privacy: .public)\(window.map(state) ?? "", privacy: .public)")
    }

    private static func describe(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        return "\(type(of: window)) #\(window.windowNumber) \"\(window.title)\""
    }

    private static func responder(_ window: NSWindow) -> String {
        guard let first = window.firstResponder else { return "nil" }
        if first === window { return "the window" }
        if let view = first as? NSView { return chain(view) }
        return String(describing: type(of: first))
    }

    /// Window flags worth seeing when input goes nowhere.
    private static func state(_ window: NSWindow) -> String {
        var flags: [String] = []
        if !window.isKeyWindow { flags.append("not key") }
        if !NSApp.isActive { flags.append("app inactive") }
        if window.ignoresMouseEvents { flags.append("ignores mouse") }
        if let sheet = window.attachedSheet { flags.append("sheet \(describe(sheet))") }
        if let modal = NSApp.modalWindow { flags.append("modal \(describe(modal))") }
        if NSApp.keyWindow !== window { flags.append("key window \(describe(NSApp.keyWindow))") }
        return flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
    }

    /// The view and a few of its ancestors, innermost first.
    private static func chain(_ view: NSView?) -> String {
        var names: [String] = []
        var current = view
        while let v = current, names.count < 6 {
            names.append(String(describing: type(of: v)))
            current = v.superview
        }
        return names.isEmpty ? "nil" : names.joined(separator: " < ")
    }
}
#endif
