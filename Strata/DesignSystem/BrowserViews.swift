import SwiftUI

// The feed cards of the browser tools: one per call. `browser_open` is a single line with the page's site and a progress
// ring; `browser_eval` opens to the script and what it returned.

/// "Opened m.place.naver.com" or "Ran a script on m.place.naver.com" in the feed.
struct BrowserFeedCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: FeedCard
    let collapsed: Bool
    let onToggle: () -> Void
    var onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if case .script(let code) = card.kind, !collapsed {
                BrowserScriptDetail(code: code, output: card.output, isRunning: card.isRunning, isError: card.isError)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(theme.separator, lineWidth: 1)
        }
        .animation(reduceMotion ? nil : ActivityFeedView.fold, value: collapsed)
        .contextMenu {
            Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails)
        }
    }

    private var pageURL: String? {
        switch card.kind {
        case .browser(let url): url
        case .script: BrowserScript.url(inResult: card.output)
        default: nil
        }
    }

    private var host: String? { pageURL.map { DomainFormatter.short(ActivityEntry.host(of: $0)) } }

    private var isScript: Bool { if case .script = card.kind { true } else { false } }

    private var header: some View {
        let row = HStack(spacing: DS.Spacing.sm) {
            Group {
                if !isScript, let url = pageURL {
                    FaviconView(host: ActivityEntry.host(of: url), size: DS.IconSize.feedFavicon, square: true)
                } else {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .frame(width: 18)
            Text(title)
                .font(DS.Typography.feedEmphasis)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Spacing.sm)
            trailing.fixedSize()
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        return Group {
            if isScript {
                Button(action: onToggle) { row }
                    .buttonStyle(.plain)
                    .accessibilityValue(Text(collapsed ? "Collapsed" : "Expanded"))
                    .accessibilityHint(Text(collapsed ? "Shows the script and its result" : "Hides the script and its result"))
            } else {
                Button { if let url = pageURL.flatMap(URL.init(string:)) { openURL(url) } } label: { row }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the page"))
            }
        }
    }

    private var title: String {
        switch card.kind {
        case .script:
            if card.isRunning { return String(localized: "Running a script…") }
            if let host { return String(localized: "Ran a script on \(host)") }
            return String(localized: "Ran a script")
        default:
            let site = host ?? ""
            return card.isRunning ? String(localized: "Opening \(site)…") : String(localized: "Opened \(site)")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if card.isRunning {
            if isScript { ProgressView().controlSize(.mini) } else { ReadProgressRing(callID: card.id) }
        } else if card.isError {
            Text(isScript ? String(localized: "Error") : (card.pageFailure ?? .failed).label)
                .font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
        } else if isScript {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
        }
    }
}

/// A browser script and what it returned (inside the feed card and the Timeline card).
struct BrowserScriptDetail: View {
    let code: String
    let output: String
    var isRunning = false
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            CodeBlockView(content: CodeBlockContent(language: "javascript", code: code))
            if !isRunning && !displayedOutput.isEmpty {
                PythonOutputView(text: displayedOutput, isError: isError)
            }
        }
    }

    /// The result without the "URL: …" line it starts with (the header names the site).
    private var displayedOutput: String {
        guard BrowserScript.url(inResult: output) != nil, let end = output.firstIndex(of: "\n") else { return output }
        return output[end...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Previews

#Preview("Dark · Purple") { browserPreview.previewStyle(.dark) }
#Preview("Light · Purple") { browserPreview.previewStyle(.light) }
#Preview("Dark · Orange") { browserPreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }

@MainActor private var browserPreview: some View {
    var open = FeedCard(id: "o", kind: .browser(url: "https://m.search.naver.com/search.naver?query=%EC%84%B1%EC%88%98"))
    open.isRunning = false
    var script = FeedCard(id: "s", kind: .script(code: "const items = [...document.querySelectorAll('li')];\nreturn items.length;"))
    script.output = "URL: https://m.search.naver.com/search.naver\n\n12"
    return ScrollView {
        VStack(spacing: 10) {
            BrowserFeedCard(card: open, collapsed: true, onToggle: {}, onDetails: {})
            BrowserFeedCard(card: script, collapsed: false, onToggle: {}, onDetails: {})
        }
        .padding()
    }
}

// MARK: - One-line cards

/// The icon and line of a call shown as a single line (`load_skill` and the like), in the feed and the Timeline.
enum ToolNote {
    static func covers(_ tool: String) -> Bool { tool == ToolNames.loadSkill }

    static func icon(_ tool: String) -> String {
        switch tool {
        case ToolNames.loadSkill: "book.closed"
        default: "wrench.and.screwdriver"
        }
    }

    static func title(tool: String, argument: String, running: Bool) -> String {
        switch tool {
        case ToolNames.loadSkill:
            running ? String(localized: "Loading skill \(argument)…") : String(localized: "Loaded skill \(argument)")
        default:
            running ? String(localized: "Running \(tool)…") : String(localized: "Ran \(tool)")
        }
    }
}

/// "Loaded skill naver-places" in the feed.
struct ToolNoteFeedCard: View {
    @Environment(\.theme) private var theme
    let card: FeedCard
    var onDetails: () -> Void

    var body: some View {
        if case .note(let tool, let argument) = card.kind {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: ToolNote.icon(tool))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 18)
                Text(ToolNote.title(tool: tool, argument: argument, running: card.isRunning))
                    .font(DS.Typography.feedEmphasis)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.sm)
                if card.isRunning {
                    ProgressView().controlSize(.mini)
                } else if card.isError {
                    Text("Failed").font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(theme.separator, lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .contextMenu {
                Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails)
            }
        }
    }
}
