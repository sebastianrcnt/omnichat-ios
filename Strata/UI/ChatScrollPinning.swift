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

    /// Room under the transcript so the pinned question can sit at the top of the screen.
    var reserve: CGFloat { Self.reserve(viewport: viewport, pinnedTop: pinnedTop, contentEnd: contentEnd) }

    nonisolated static func reserve(viewport: CGFloat, pinnedTop: CGFloat, contentEnd: CGFloat) -> CGFloat {
        max(0, viewport - (contentEnd - pinnedTop))
    }

    /// Nothing of the reserved room is on screen, so dropping it moves nothing.
    var reserveOutOfView: Bool { reserve <= 0 || visibleBottom <= contentEnd + 1 }
}

/// Where the chat is scrolled, what it follows and what floats over it. Observed property by property, so a change
/// re-evaluates only the small views that read that value (the jump button reads `atBottom`, the floating controls
/// `composerHeight`, the scroll container `followsBottom`): the chat view and its rows read none of them.
@MainActor
@Observable
final class ChatScroll {
    var position = ScrollPosition(edge: .bottom)
    /// The end of the chat is on screen (the end marker's visibility: the true scroll position).
    var atBottom = true
    /// The question being answered, held at the top of the screen from its send until the next send or until the user
    /// scrolls the room reserved under it out of view. Nil when nothing is pinned (a chat just opened).
    var pinnedID: UUID?
    /// Growth keeps the end of the chat on screen (`defaultScrollAnchor(.bottom, for: .sizeChanges)`). On while the
    /// user is at the end with nothing pinned (a chat opens there) and after the jump button; a drag or a send turns it
    /// off, so a pinned answer grows under its question and a reader who scrolled up is never moved.
    var followsBottom = true
    /// The question just sent: its bubble flies up from the composer once (`SendFlyIn`).
    var flyingID: UUID?
    /// The composer's height, so the floating controls sit just above it.
    var composerHeight: CGFloat = 0
    /// The jump button's scroll hasn't reached the end yet. Rows above the end are laid out lazily from estimated
    /// heights, so a long jump can stop short; every move of the end marker until it is on screen asks again.
    @ObservationIgnored var jumping = false
    /// Alternates the end scroll's anchor by a hair: the same `ScrollPosition` value asked twice (a jump correcting
    /// itself) is otherwise a no-op. (Scrolling to the bottom edge instead jumps past rows the lazy stack hasn't laid out
    /// yet, and the screen stays blank until the next scroll.)
    @ObservationIgnored private var endAnchorFlip = false
    @ObservationIgnored private var endScrollQueued = false
    /// End scrolls actually made (tests and the jump smoke run).
    @ObservationIgnored private(set) var endScrolls = 0

    /// Scrolls to the end marker now.
    func scrollToEnd() {
        endScrolls += 1
        endAnchorFlip.toggle()
        position.scrollTo(id: ChatScroll.endID, anchor: endAnchorFlip ? .bottom : UnitPoint(x: 0.5, y: 0.999))
    }

    /// Scrolls to the end once the current layout pass is over: however many geometry changes ask in one pass, one
    /// scroll is made.
    func requestScrollToEnd() {
        guard !endScrollQueued else { return }
        endScrollQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            endScrollQueued = false
            guard jumping, !atBottom else { return }
            scrollToEnd()
        }
    }

    /// The end marker moved: a jump still on its way asks again.
    func endMoved() {
        if jumping && !atBottom { requestScrollToEnd() }
    }

    func setAtBottom(_ visible: Bool) {
        atBottom = visible
        if visible { jumping = false }
    }

    /// A drag hands the position back to the user.
    func userBeganScrolling() {
        if followsBottom { followsBottom = false }
        jumping = false
    }

    /// The user's scroll came to rest: at the end, with nothing pinned, the chat follows again.
    func userEndedScrolling(reserveOutOfView: Bool) {
        // Once the room under the answer is out of view it can go without moving anything.
        if pinnedID != nil, reserveOutOfView { pinnedID = nil }
        let follows = pinnedID == nil && atBottom
        if followsBottom != follows { followsBottom = follows }
    }

    /// Keep the latest message visible when the keyboard opens. A pinned question stays where it is.
    func composerFocused() {
        guard atBottom, pinnedID == nil else { return }
        withAnimation(DS.Motion.spring) { scrollToEnd() }
    }

    static let endID = "bottom"
}

/// Measures the pinned question's top.
struct PinTopReader: ViewModifier {
    let id: UUID
    let scroll: ChatScroll
    let pin: PinLayout

    func body(content: Content) -> some View {
        if scroll.pinnedID == id {
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

/// `SendFlyIn` for the question being sent, or `AfterSendFlyIn` for the reply under it. Reads `ChatScroll.flyingID` here,
/// so a send never re-evaluates the rows themselves.
struct FlyInReader: ViewModifier {
    let id: UUID
    let parentID: UUID?
    let isReply: Bool
    let scroll: ChatScroll

    func body(content: Content) -> some View {
        if isReply {
            content.modifier(AfterSendFlyIn(active: parentID != nil && parentID == scroll.flyingID))
        } else {
            content.modifier(SendFlyIn(active: id == scroll.flyingID))
        }
    }
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
