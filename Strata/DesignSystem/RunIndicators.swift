import SwiftUI

// Marks for chats that reply while another one is on screen: a sidebar row's dot (working, or a reply not seen yet),
// and the quiet "Reply ready" banner over the chat.

/// The trailing mark of a sidebar row: the breathing accent dot while the chat's reply runs, a still one while a reply
/// that ended elsewhere hasn't been seen. Nothing otherwise.
struct ChatRowMark: View {
    @Environment(\.theme) private var theme
    let status: ChatIndicators.Status

    var body: some View {
        switch status {
        case .running:
            ZStack { PulsingDot() }
                .accessibilityElement()
                .accessibilityLabel(Text("Replying"))
        case .unread:
            Circle()
                .fill(theme.accent)
                .frame(width: 8, height: 8)
                .accessibilityLabel(Text("New reply"))
        case .none:
            EmptyView()
        }
    }
}

/// "Reply ready · <chat>": a reply finished in another chat. A glass capsule at the top of the chat; a tap opens that
/// chat, and it goes by itself after a few seconds.
struct ReplyReadyBanner: View {
    @Environment(\.theme) private var theme
    let title: String
    let onOpen: () -> Void

    /// How long it stays.
    static let lifetime: Duration = .seconds(4)

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: DS.Spacing.sm) {
                Circle().fill(theme.accent).frame(width: 6, height: 6)
                Text(label)
                    .font(DS.Typography.uiSmall)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.Feed.mark, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .frame(height: DS.IconSize.compactControlDiameter)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityHint(Text("Opens the chat"))
    }

    /// One line, so the chat's title is what gets cut.
    private var label: AttributedString {
        var head = AttributedString(String(localized: "Reply ready"))
        head.foregroundColor = theme.textSecondary
        var separator = AttributedString(" · ")
        separator.foregroundColor = theme.textTertiary
        var name = AttributedString(title)
        name.foregroundColor = theme.textPrimary
        return head + separator + name
    }
}
