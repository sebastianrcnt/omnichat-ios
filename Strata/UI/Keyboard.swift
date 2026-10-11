import SwiftUI
import UIKit

/// Resigns whatever currently has keyboard focus (composer, rename field, ...).
@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

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
