#if os(iOS)
import SwiftUI
import WidgetKit

// The Live Activity's views, shared by the widget extension (which puts them in the Lock Screen and Dynamic Island
// slots) and the app's DEBUG gallery (which shows them as plain views for screenshots). They take plain values, no
// `ActivityViewContext`, and use only the system font and the accent: the extension has none of the app's tokens or
// bundled fonts. The sizes follow the app's (`DS.Spacing`, `DS.Radius.md`) and Apple's margins for the Lock Screen
// (14 pt).

enum ReplyActivityStyle {
    /// The Lock Screen margin Apple's guidelines give for Live Activities.
    static let margin: CGFloat = 14
    static let rowSpacing: CGFloat = 10
    static let glyph: CGFloat = 36
    static let smallGlyph: CGFloat = 28

    /// `#RRGGBB` as a color; the app's default purple for anything else.
    static func accent(_ hex: String) -> Color {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return Color(red: 0.545, green: 0.361, blue: 0.965) }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    static let failure = Color.orange
}

/// The phase's symbol in a circle: tinted while it works, filled when it needs the person or is ready.
struct ReplyActivityGlyph: View {
    let chat: ReplyActivityChat
    let accent: Color
    var size: CGFloat = ReplyActivityStyle.glyph

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Image(systemName: chat.symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(foreground)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var fill: Color {
        switch chat.status {
        case .needsYou, .ready: accent
        case .working: accent.opacity(0.18)
        case .queued, .stopped: Color.secondary.opacity(0.15)
        case .failed: ReplyActivityStyle.failure.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch chat.status {
        case .needsYou, .ready: .white
        case .working: accent
        case .queued, .stopped: Color.secondary
        case .failed: ReplyActivityStyle.failure
        }
    }
}

/// How long the reply has been working: counting while it runs (no updates needed), fixed once it ended.
struct ReplyActivityElapsed: View {
    let chat: ReplyActivityChat
    var font: Font = .system(size: 15, weight: .semibold)
    /// The app was suspended mid-reply: a clock that keeps counting would pretend it still works.
    var isStale = false

    var body: some View {
        Group {
            if let started = chat.started, !(isStale && chat.status.isActive) {
                if let ended = chat.ended {
                    Text(Self.duration(ended.timeIntervalSince(started)))
                } else {
                    Text(timerInterval: started...Date.distantFuture, countsDown: false)
                }
            }
        }
        .font(font)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }

    /// "0:42", "12:05", "1:02:05".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// "Searching the web · 3 steps", the label in the accent when the chat needs the person.
struct ReplyActivityStatusLine: View {
    let chat: ReplyActivityChat
    let accent: Color
    var isStale = false
    /// Off where the steps show elsewhere (the expanded island's trailing corner).
    var showsSteps = true

    var body: some View {
        Text("\(Text(label).foregroundStyle(labelColor))\(Text(steps).foregroundStyle(Color.secondary))")
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
    }

    private var label: String {
        isStale && chat.status.isActive ? String(localized: "Open OpenChat to continue") : chat.label
    }

    private var labelColor: Color {
        switch chat.status {
        case .needsYou: accent
        case .failed: ReplyActivityStyle.failure
        default: isStale ? .secondary : .primary.opacity(0.8)
        }
    }

    private var steps: String {
        guard showsSteps, chat.steps > 0, !isStale else { return "" }
        return " · " + (chat.steps == 1 ? String(localized: "1 step") : String(localized: "\(chat.steps) steps"))
    }
}

// MARK: - Lock Screen

/// The Lock Screen (and StandBy) layout: one chat large, with the start of its answer; several as rows, each opening
/// its own chat.
struct ReplyActivityLockScreen: View {
    let state: ReplyActivityAttributes.ContentState
    let accent: Color
    var isStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: ReplyActivityStyle.rowSpacing) {
            if state.chats.count == 1 && state.hiddenCount == 0, let chat = state.chats.first {
                single(chat)
            } else {
                ForEach(state.chats) { chat in
                    Link(destination: ReplyActivityLink.url(for: chat.id)) { row(chat) }
                }
                if state.hiddenCount > 0 {
                    Text(state.hiddenCount == 1 ? String(localized: "1 more chat replying")
                                                : String(localized: "\(state.hiddenCount) more chats replying"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .padding(.leading, ReplyActivityStyle.smallGlyph + ReplyActivityStyle.rowSpacing)
                }
            }
        }
        .padding(ReplyActivityStyle.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func single(_ chat: ReplyActivityChat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ReplyActivityGlyph(chat: chat, accent: accent)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(chat.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    ReplyActivityElapsed(chat: chat, isStale: isStale)
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: 64, alignment: .trailing)
                }
                ReplyActivityStatusLine(chat: chat, accent: accent, isStale: isStale)
                if let detail = chat.detail {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func row(_ chat: ReplyActivityChat) -> some View {
        HStack(spacing: ReplyActivityStyle.rowSpacing) {
            ReplyActivityGlyph(chat: chat, accent: accent, size: ReplyActivityStyle.smallGlyph)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                ReplyActivityStatusLine(chat: chat, accent: accent, isStale: isStale)
            }
            Spacer(minLength: 0)
            ReplyActivityElapsed(chat: chat, font: .system(size: 14, weight: .semibold), isStale: isStale)
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: 60, alignment: .trailing)
        }
    }
}

// MARK: - Dynamic Island

/// The Dynamic Island's pieces. The widget puts them in `DynamicIsland` regions; the gallery lays them out on a black
/// capsule. The island is always dark.
enum ReplyActivityIsland {
    /// Compact, leading: the lead chat's phase.
    struct CompactLeading: View {
        let state: ReplyActivityAttributes.ContentState
        let accent: Color

        var body: some View {
            if let lead = state.lead {
                Image(systemName: lead.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(lead.status == .failed ? ReplyActivityStyle.failure : accent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 22)
                    .accessibilityLabel(Text(lead.label))
            }
        }
    }

    /// Compact, trailing: how long it has worked, "Ready", or how many chats reply. Hidden where the island is narrow.
    struct CompactTrailing: View {
        let state: ReplyActivityAttributes.ContentState
        let accent: Color

        var body: some View {
            Group {
                if let lead = state.lead {
                    if lead.status == .needsYou {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(accent))
                            .accessibilityLabel(Text("Needs you"))
                    } else if state.activeCount > 1 {
                        Text("\(state.activeCount)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accent)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Circle().fill(accent.opacity(0.25)))
                            .accessibilityLabel(Text("\(state.activeCount) chats replying"))
                    } else if !lead.status.isActive {
                        Text(lead.status == .ready ? String(localized: "Ready") : lead.status == .failed ? String(localized: "Failed") : String(localized: "Stopped"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(lead.status == .failed ? ReplyActivityStyle.failure : accent)
                    } else {
                        ReplyActivityElapsed(chat: lead, font: .system(size: 14, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(maxWidth: 46)
                    }
                }
            }
            .hiddenWhereIslandIsNarrow()
        }
    }

    /// Minimal: the phase, filled when the person is needed.
    struct Minimal: View {
        let state: ReplyActivityAttributes.ContentState
        let accent: Color

        var body: some View {
            if let lead = state.lead {
                Image(systemName: lead.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(lead.status == .failed ? ReplyActivityStyle.failure : accent)
                    .accessibilityLabel(Text(lead.label))
            }
        }
    }

    /// Expanded, leading.
    struct ExpandedLeading: View {
        let state: ReplyActivityAttributes.ContentState
        let accent: Color

        var body: some View {
            if let lead = state.lead {
                ReplyActivityGlyph(chat: lead, accent: accent, size: 40)
                    .padding(.leading, 4)
                    .padding(.top, 4)
            }
        }
    }

    /// Expanded, trailing: the elapsed time and steps.
    struct ExpandedTrailing: View {
        let state: ReplyActivityAttributes.ContentState
        let accent: Color

        var body: some View {
            if let lead = state.lead {
                VStack(alignment: .trailing, spacing: 1) {
                    ReplyActivityElapsed(chat: lead, font: .system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: 72, alignment: .trailing)
                    if lead.steps > 0 {
                        Text(lead.steps == 1 ? String(localized: "1 step") : String(localized: "\(lead.steps) steps"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.trailing, 4)
                .padding(.top, 4)
            }
        }
    }

    /// Expanded, center: the lead chat's title and phase.
    struct ExpandedCenter: View {
        let state: ReplyActivityAttributes.ContentState
        let accent: Color
        var isStale = false

        var body: some View {
            if let lead = state.lead {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lead.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    ReplyActivityStatusLine(chat: lead, accent: accent, isStale: isStale, showsSteps: false)
                        .environment(\.colorScheme, .dark)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
    }

    /// Expanded, bottom: the start of the answer (or what is asked), then the other chats.
    struct ExpandedBottom: View {
        let state: ReplyActivityAttributes.ContentState
        let accent: Color

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let detail = state.lead?.detail {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }
                ForEach(others) { chat in
                    Link(destination: ReplyActivityLink.url(for: chat.id)) {
                        HStack(spacing: 8) {
                            Image(systemName: chat.symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(chat.status == .failed ? ReplyActivityStyle.failure : accent)
                                .frame(width: 18)
                            Text(chat.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Text(chat.label)
                                .font(.system(size: 13))
                                .foregroundStyle(chat.status == .needsYou ? accent : .white.opacity(0.6))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
                if moreCount > 0 {
                    Text(moreCount == 1 ? String(localized: "1 more chat replying")
                                        : String(localized: "\(moreCount) more chats replying"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.leading, 26)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }

        /// The expanded island is at most 160 pt tall: one other chat under an answer line, two without one.
        private var others: [ReplyActivityChat] {
            Array(state.chats.dropFirst().prefix(state.lead?.detail == nil ? 2 : 1))
        }

        private var moreCount: Int {
            state.chats.dropFirst(1 + others.count).filter(\.status.isActive).count + state.hiddenCount
        }
    }
}

private struct NarrowIslandHidden: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            NarrowIslandReader(content: content)
        } else {
            content
        }
    }
}

/// iOS 27 shows the island in landscape, where compact views get a 28 pt circle: the leading symbol alone says enough.
@available(iOS 27.0, *)
private struct NarrowIslandReader<Content: View>: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var limited
    let content: Content

    var body: some View {
        if !limited { content }
    }
}

extension View {
    func hiddenWhereIslandIsNarrow() -> some View { modifier(NarrowIslandHidden()) }
}
#endif
