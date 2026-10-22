import SwiftUI

// Apple Health in the feed: one quiet line per `health_query` call ("Read sleep, last 14 days") that opens to the table
// the model read, and the card asking to read Apple Health right under the call that needs it.

/// One `health_query` call in the feed.
struct HealthFeedCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.citations) private var citations
    let card: FeedCard
    let collapsed: Bool
    let onToggle: () -> Void
    var onDetails: () -> Void

    static let icon = "heart"

    private var summary: String { if case .health(let summary) = card.kind { summary } else { "" } }

    var body: some View {
        let request = HealthRequests.shared.request(forCall: card.id, conversation: citations.conversationID)
        let declined = !card.isRunning && HealthCallLabel.declined(card.output)
        let opens = !card.isRunning && !card.output.isEmpty && request == nil
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                FeedLine(title: HealthCallLabel.title(summary: summary, running: card.isRunning, failed: card.isError, declined: declined,
                                                     empty: HealthCallLabel.empty(card.output)),
                         meta: card.isError && !declined ? String(localized: "Failed") : nil,
                         expanded: opens ? !collapsed : nil) {
                    if card.isRunning && request == nil { FeedSpinner() }
                    else { FeedSymbol(name: Self.icon, color: card.isError && !declined ? theme.warning : nil) }
                }
            }
            .buttonStyle(.plain)
            .disabled(!opens)
            .accessibilityValue(Text(opens ? (collapsed ? "Collapsed" : "Expanded") : ""))
            if let request {
                HealthAccessCard(request: request) { HealthRequests.shared.answer(request.id, allowed: $0) }
                    .padding(.leading, DS.Feed.textInset)
                    .padding(.vertical, DS.Spacing.xs)
                    .transition(.opacity)
            } else if opens && !collapsed {
                HealthResultView(text: card.output, isError: card.isError)
                    .padding(.leading, DS.Feed.textInset)
                    .padding(.vertical, DS.Spacing.xs)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : ActivityFeedView.fold, value: collapsed)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: request?.id)
        .contextMenu {
            Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails)
        }
    }
}

/// What the model read: the table, in a box that scrolls sideways when the rows are wide.
struct HealthResultView: View {
    @Environment(\.theme) private var theme
    let text: String
    var isError = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: text)
                .font(DS.Typography.monoSmall)
                .foregroundStyle(isError ? theme.warning : theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(DS.Spacing.sm + 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
    }
}

/// "Let the assistant read Sleep from Apple Health?", with where it goes, then Continue (iOS's sheet) or Not now.
struct HealthAccessCard: View {
    @Environment(\.theme) private var theme
    let request: HealthRequests.Request
    let onAnswer: (Bool) -> Void

    private var names: String {
        ListFormatter.localizedString(byJoining: request.metrics.map { $0.displayName })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Let the assistant read \(names) from Apple Health?").font(DS.Typography.feedEmphasis).foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if let destination = request.destination {
                    Text("Read-only. What it reads is sent to \(destination) to answer you, and kept in this chat. iOS asks next; you choose what to share.")
                } else {
                    Text("Read-only. What it reads is sent to this chat's model to answer you, and kept in this chat. iOS asks next; you choose what to share.")
                }
            }
            .font(DS.Typography.feed).foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Spacing.lg) {
                Button("Continue") { onAnswer(true) }.buttonStyle(.quietLink(.accent))
                Button("Not now") { onAnswer(false) }.buttonStyle(.quietLink(.secondary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
