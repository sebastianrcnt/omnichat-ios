import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Resigns whatever currently has keyboard focus (composer, rename field, ...). A Mac has no software keyboard to put away.
@MainActor
func dismissKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

#if canImport(UIKit)

/// A horizontal pan recognizer attached to the app's root view (so sheets are unaffected).
/// It begins only for mostly-horizontal drags in the allowed direction and steps aside for
/// horizontally scrolling content (code blocks, chip rows) that can still scroll that way.
struct EdgeFreePanRecognizer: UIViewRepresentable {
    var isOpen: Bool
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let v = Attacher()
        v.isUserInteractionEnabled = false
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let c = context.coordinator
        c.isOpen = isOpen
        c.onBegan = onBegan
        c.onChanged = onChanged
        c.onEnded = onEnded
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let pan = coordinator.pan { pan.view?.removeGestureRecognizer(pan) }
    }

    final class Attacher: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let coordinator, let root = window?.rootViewController?.view, coordinator.pan == nil else { return }
            let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handle(_:)))
            pan.delegate = coordinator
            pan.cancelsTouchesInView = false
            root.addGestureRecognizer(pan)
            coordinator.pan = pan
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var pan: UIPanGestureRecognizer?
        var isOpen = false
        var onBegan: () -> Void = {}
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: (CGFloat, CGFloat) -> Void = { _, _ in }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view).x
            switch g.state {
            case .began: onBegan()
            case .changed: onChanged(t)
            case .ended: onEnded(t, g.velocity(in: g.view).x)
            case .cancelled, .failed: onEnded(t, 0)
            default: break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let v = pan.velocity(in: view)
            guard abs(v.x) > abs(v.y) * 1.5, abs(v.x) > 40 else { return false }
            if isOpen { return v.x < 0 }
            guard v.x > 0 else { return false }
            // Opening: let a horizontally scrolled region scroll back first.
            var hit = view.hitTest(pan.location(in: view), with: nil)
            while let h = hit {
                if let scroll = h as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1,
                   scroll.contentOffset.x > 1 {
                    return false
                }
                hit = h.superview
            }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

#endif

// MARK: - Running on a Mac

enum Platform {
    /// "My Mac (Designed for iPhone)": an iPhone app on Apple Silicon, with a hardware keyboard and no software one.
    static let isiOSAppOnMac = ProcessInfo.processInfo.isiOSAppOnMac
    /// A hardware keyboard and no software one: the native Mac app, or the iPhone app running on a Mac.
    static let hasOnlyHardwareKeyboard: Bool = {
        #if os(macOS)
        true
        #else
        ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }()
}

/// What the composer needs from the text input that SwiftUI's `TextField` wraps.
@MainActor
final class TextInputHandle {
    #if canImport(UIKit)
    weak var input: UIView?

    /// True while an input method (Korean, Japanese, ...) holds uncommitted text.
    var hasMarkedText: Bool {
        if let tv = input as? UITextView { return tv.markedTextRange != nil }
        if let tf = input as? UITextField { return tf.markedTextRange != nil }
        return false
    }
    #else
    /// True while an input method (Korean, Japanese, ...) holds uncommitted text in the field being edited.
    var hasMarkedText: Bool {
        (NSApplication.shared.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }
    #endif
}

extension View {
    /// Removes the empty shortcuts bar (the input assistant view) that UIKit shows with a hardware keyboard, and on a
    /// Mac reports as a keyboard frame, from the text input behind this view. Fills `handle` with that input.
    func withoutInputAssistantBar(handle: TextInputHandle? = nil) -> some View {
        #if canImport(UIKit)
        background(InputAssistantBarRemover(handle: handle).allowsHitTesting(false))
        #else
        self
        #endif
    }

    /// On a Mac (native, or the iPhone app running on one): Return calls `send`, Shift+Return (and any other modifier) still inserts a newline. While an
    /// input method has uncommitted text, Return is left to it so it commits instead of sending. iPhone and iPad
    /// behavior is untouched.
    func returnSends(handle: TextInputHandle, send: @escaping () -> Void) -> some View {
        modifier(ReturnSendsModifier(handle: handle, send: send))
    }

    /// No keyboard safe area on a Mac: there is no software keyboard, so any frame UIKit reports is a bar, not content.
    @ViewBuilder func ignoresKeyboardOnMac() -> some View {
        if Platform.hasOnlyHardwareKeyboard { ignoresSafeArea(.keyboard) } else { self }
    }
}

private struct ReturnSendsModifier: ViewModifier {
    let handle: TextInputHandle
    let send: () -> Void

    func body(content: Content) -> some View {
        if Platform.hasOnlyHardwareKeyboard {
            content.onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.isEmpty, !handle.hasMarkedText else { return .ignored }
                send()
                return .handled
            }
        } else {
            content
        }
    }
}

#if canImport(UIKit)
/// Finds the UITextView/UITextField SwiftUI created for the view this sits behind (the one whose frame holds this
/// view's center) and empties its input assistant item.
private struct InputAssistantBarRemover: UIViewRepresentable {
    let handle: TextInputHandle?

    func makeUIView(context: Context) -> Finder {
        let v = Finder()
        v.isUserInteractionEnabled = false
        v.handle = handle
        return v
    }

    func updateUIView(_ uiView: Finder, context: Context) {
        uiView.handle = handle
        uiView.setNeedsLayout()
    }

    final class Finder: UIView {
        var handle: TextInputHandle?
        private weak var configured: UIView?
        private var attempts = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil else { return }
            if configured?.window == nil {
                guard attempts < 30 else { return }
                attempts += 1
                guard let input = findInput() else {
                    DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() } // SwiftUI may add the text view a beat later
                    return
                }
                configured = input
                handle?.input = input
                let item = (input as? UITextView)?.inputAssistantItem ?? (input as? UITextField)?.inputAssistantItem
                item?.leadingBarButtonGroups = []
                item?.trailingBarButtonGroups = []
                if input.isFirstResponder { input.reloadInputViews() }
            }
        }

        private func findInput() -> UIView? {
            guard let window else { return nil }
            let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: window)
            var best: UIView?
            var stack: [UIView] = [window]
            while let v = stack.popLast() {
                if v is UITextView || v is UITextField, !v.isHidden,
                   v.convert(v.bounds, to: window).contains(center) {
                    best = v
                    break
                }
                stack.append(contentsOf: v.subviews)
            }
            return best
        }
    }
}
#endif
