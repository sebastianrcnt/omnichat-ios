import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformView = UIView
#else
import AppKit
typealias PlatformView = NSView
#endif

/// One place that wants a hidden web view on screen: a sheet the user works or watches in, or a card's live preview.
@MainActor
final class ScreenClaim {
    enum Kind: Int, Comparable, Sendable {
        /// A card's live preview: scaled down, never touched.
        case preview = 1
        /// The browser sheet: full size.
        case sheet = 2

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    let kind: Kind
    /// The sheet lets the user touch the page (after Done, or Take over); watching doesn't.
    var interactive: Bool
    weak var container: PlatformView?
    /// When it was made: of two equal claims the newer wins.
    let order: Int

    init(kind: Kind, container: PlatformView, interactive: Bool, order: Int) {
        self.kind = kind
        self.container = container
        self.interactive = interactive
        self.order = order
    }
}

/// Which claim holds a web view. Pure, so the hand-offs are tested on their own.
enum ScreenOwnership {
    struct Candidate: Equatable, Sendable {
        var kind: ScreenClaim.Kind
        var order: Int
        /// Its container is in a window (a card scrolled out of a lazy stack, or a sheet not up yet, is not).
        var inWindow: Bool
    }

    /// The index of the holder: the strongest kind among those in a window, the newest of equals; nil parks the view.
    static func owner(_ candidates: [Candidate]) -> Int? {
        candidates.indices.filter { candidates[$0].inWindow }
            .max { a, b in (candidates[a].kind, candidates[a].order) < (candidates[b].kind, candidates[b].order) }
    }
}

/// The container a `WebStage` lends: it holds its claim while it is in a window and lays the page out again when it
/// changes size.
final class WebStageView: PlatformView {
    private(set) weak var page: HiddenWebView?
    private var claim: ScreenClaim?
    #if canImport(AppKit)
    /// The page gets clicks and keys (an interactive sheet); otherwise they go to what is around it.
    var passesEvents = false
    override var isFlipped: Bool { true }
    #endif

    func hold(_ page: HiddenWebView, kind: ScreenClaim.Kind, interactive: Bool) {
        if page !== self.page { letGo() }
        self.page = page
        #if canImport(UIKit)
        isUserInteractionEnabled = kind == .sheet
        clipsToBounds = true
        #else
        wantsLayer = true
        layer?.masksToBounds = true
        #endif
        if let claim, claim.kind == kind {
            claim.interactive = interactive
            page.updatePlacement()
        } else {
            if let claim { page.release(claim) }
            claim = page.claim(kind, in: self, interactive: interactive)
        }
    }

    func letGo() {
        if let claim, let page { page.release(claim) }
        claim = nil
        page = nil
    }

    #if canImport(UIKit)
    override func didMoveToWindow() {
        super.didMoveToWindow()
        page?.updatePlacement()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        page?.layoutOnStage(self)
    }
    #else
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        page?.updatePlacement()
    }

    override func layout() {
        super.layout()
        page?.layoutOnStage(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesEvents ? super.hitTest(point) : nil
    }
    #endif
}

/// Shows a hidden web view here, the same instance the tools use (its page, scroll and input stay as they are): as a
/// sheet's page or as a card's live preview. Leaving the screen (dismantled, or out of a window) gives it back.
#if canImport(UIKit)
struct WebStage: UIViewRepresentable {
    let page: HiddenWebView
    var kind: ScreenClaim.Kind = .sheet
    var interactive = true

    func makeUIView(context: Context) -> WebStageView { WebStageView() }
    func updateUIView(_ view: WebStageView, context: Context) { view.hold(page, kind: kind, interactive: interactive) }
    static func dismantleUIView(_ view: WebStageView, coordinator: ()) { view.letGo() }
}
#else
struct WebStage: NSViewRepresentable {
    let page: HiddenWebView
    var kind: ScreenClaim.Kind = .sheet
    var interactive = true

    func makeNSView(context: Context) -> WebStageView { WebStageView() }
    func updateNSView(_ view: WebStageView, context: Context) { view.hold(page, kind: kind, interactive: interactive) }
    static func dismantleNSView(_ view: WebStageView, coordinator: ()) { view.letGo() }
}
#endif
