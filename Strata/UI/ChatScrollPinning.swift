import SwiftUI

/// Geometry for pinning a question to the top while its answer streams. A reference type written from geometry
/// callbacks and read only by `PinReserve`, so neither scrolling nor a growing answer re-evaluates the chat.
@MainActor
@Observable
final class PinLayout {
    static let space = "chatContent"

    struct Viewport: Equatable { var height: CGFloat; var visibleBottom: CGFloat }

    /// Top of the pinned question and end of the transcript, in content coordinates.
    var pinnedTop: CGFloat = 0
    var contentEnd: CGFloat = 0
    /// The visible height (between the header and the composer).
    var viewport: CGFloat = 0
    @ObservationIgnored var visibleBottom: CGFloat = 0
    /// Alternates the end scroll's anchor, so asking again is a new value and never a no-op (`ChatView.scrollToEnd`).
    @ObservationIgnored var endAnchorFlip = false

    /// Room under the transcript so the pinned question can sit at the top of the screen.
    var reserve: CGFloat { Self.reserve(viewport: viewport, pinnedTop: pinnedTop, contentEnd: contentEnd) }

    nonisolated static func reserve(viewport: CGFloat, pinnedTop: CGFloat, contentEnd: CGFloat) -> CGFloat {
        max(0, viewport - (contentEnd - pinnedTop))
    }

    /// Nothing of the reserved room is on screen, so dropping it moves nothing.
    var reserveOutOfView: Bool { reserve <= 0 || visibleBottom <= contentEnd + 1 }
}

/// Measures the pinned question's top.
struct PinTopReader: ViewModifier {
    let isPinned: Bool
    let pin: PinLayout

    func body(content: Content) -> some View {
        if isPinned {
            content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(PinLayout.space)).minY } action: { pin.pinnedTop = $0 }
        } else {
            content
        }
    }
}

/// The room under a pinned question's answer. It shrinks as the answer grows into it, never by a jump.
struct PinReserve: View {
    let pin: PinLayout
    var body: some View { Color.clear.frame(height: pin.reserve).accessibilityHidden(true) }
}

/// A sent question's bubble rises from the composer into its place, like a sent iMessage: it starts lower, a little
/// smaller and faint, and springs up as the chat scrolls the question to the top.
struct SendFlyIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    @State private var settled: Bool

    init(active: Bool) {
        self.active = active
        _settled = State(initialValue: !active)
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(settled ? 1 : 0.9, anchor: .bottomTrailing)
            .offset(y: settled ? 0 : 140)
            .opacity(settled ? 1 : 0.3)
            .onAppear {
                guard !settled else { return }
                if reduceMotion { settled = true; return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { settled = true }
            }
    }
}

/// The reply under a question that is flying in waits for it to land, so "Thinking" doesn't show up while the bubble
/// is still on its way.
struct AfterSendFlyIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    @State private var shown: Bool

    init(active: Bool) {
        self.active = active
        _shown = State(initialValue: !active)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true; return }
                withAnimation(.easeOut(duration: 0.2).delay(0.4)) { shown = true }
            }
    }
}
