import SwiftUI
import UniformTypeIdentifiers
import WebKit

// HTML artifacts (`show_html`): the one-line card in the feed and the full-screen page it opens. The page runs in a web
// view of its own: a throwaway data store, the local-network content blocker, no bridge into the app, no file access,
// and links that leave the page open outside it.

/// "Mortgage calculator  HTML  v2 ›" in the feed; a tap opens the page.
struct ArtifactFeedCard: View {
    @Environment(\.theme) private var theme
    let card: FeedCard
    var onDetails: () -> Void
    @State private var showing = false

    static let icon = "chevron.left.forwardslash.chevron.right"

    var body: some View {
        Button { if card.artifact != nil { showing = true } } label: {
            FeedLine(title: title, meta: meta, expanded: card.artifact == nil || card.isRunning ? nil : false) {
                if card.isRunning { FeedSpinner() } else { FeedSymbol(name: Self.icon) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(card.artifact == nil ? "" : "Opens the artifact"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails)
        }
        .fullScreenCoverOrSheet(isPresented: $showing) {
            if let ref = card.artifact { ArtifactViewer(ref: ref) }
        }
    }

    private var title: String {
        if card.isRunning { return String(localized: "Making an artifact…") }
        if card.isError { return String(localized: "Couldn't show the artifact") }
        if let ref = card.artifact { return ref.title }
        if case .artifact(let title) = card.kind, !title.isEmpty { return title }
        return String(localized: "Artifact")
    }

    private var meta: String? {
        if card.isRunning { return nil }
        if card.isError { return String(localized: "Failed") }
        if let version = card.artifact?.version, version > 1 { return "HTML · v\(version)" }
        return card.artifact == nil ? nil : "HTML"
    }
}

/// The small outlined "HTML" label (the look of the search card's engine badge).
struct ArtifactBadge: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text(verbatim: "HTML")
            .font(DS.Typography.feedBadge)
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(theme.separator, lineWidth: 1) }
    }
}

// MARK: - Viewer

/// An artifact full screen (a sheet on a Mac): its title, Share, Done, and the page. It always shows the newest version.
/// Opened from the gallery of all artifacts, it also offers to go to the chat that made it, and a swipe across its bar
/// (or ⌘[ and ⌘]) moves to the artifact before or after it in the gallery.
struct ArtifactViewer: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let ref: ArtifactRef
    var store: ArtifactStore = .shared
    var onGoToChat: (() -> Void)?
    var paging: Paging?

    /// Where the artifact is in the gallery's order, and how to move from it.
    struct Paging {
        /// 1-based.
        var position: Int
        var count: Int
        var previous: (() -> Void)?
        var next: (() -> Void)?
    }

    private enum Content { case loading, page(Artifact, String, WKContentRuleList), missing, unsafe }
    @State private var content = Content.loading

    var body: some View {
        VStack(spacing: 0) {
            bar
            Group {
                switch content {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .page(_, let html, let rules):
                    ArtifactWebView(html: ArtifactHTML.prepared(html), rules: rules)
                        .ignoresSafeArea(edges: .bottom)
                case .missing:
                    notice("This artifact is no longer stored on this device.")
                case .unsafe:
                    notice("The artifact can't be opened safely right now.")
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .task {
            guard let html = store.html(id: ref.id, conversationID: ref.conversationID) else { content = .missing; return }
            let artifact = store.artifact(id: ref.id, conversationID: ref.conversationID)
                ?? Artifact(id: ref.id, title: ref.title, version: ref.version, created: .now, updated: .now)
            // Nothing loads before the local-network rules are in place.
            guard let rules = await LocalNetworkRules.artifactRules() else { content = .unsafe; return }
            content = .page(artifact, html, rules)
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 900, minHeight: 520, idealHeight: 720)
        .background { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        #endif
        .background {
            if let paging {
                Group {
                    Button("Previous Artifact") { paging.previous?() }.keyboardShortcut("[", modifiers: .command)
                        .disabled(paging.previous == nil)
                    Button("Next Artifact") { paging.next?() }.keyboardShortcut("]", modifiers: .command)
                        .disabled(paging.next == nil)
                }
                .opacity(0).accessibilityHidden(true)
            }
        }
        .inAppLinks()
    }

    private var artifact: Artifact? { if case .page(let a, _, _) = content { a } else { nil } }

    private var bar: some View {
        HStack(spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: artifact?.title ?? ref.title)
                    .font(DS.Typography.title).foregroundStyle(theme.textPrimary).lineLimit(1)
                HStack(spacing: DS.Spacing.xs) {
                    ArtifactBadge()
                    let version = artifact?.version ?? ref.version
                    if version > 1 {
                        Text("Version \(version)").font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                    }
                    if let paging {
                        Text("\(paging.position) of \(paging.count)").font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
                            .monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 0)
            if let onGoToChat {
                GlassIconButton(systemName: "bubble.left", label: "Go to chat") {
                    dismiss()
                    onGoToChat()
                }
                .help("Go to chat")
            }
            if let artifact, case .page(_, let html, _) = content {
                ShareLink(item: ArtifactFile(title: artifact.title, html: html),
                          preview: SharePreview(artifact.title)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: DS.IconSize.headerIcon, weight: .medium))
                        .frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Share"))
            }
            Button("Done") { dismiss() }
                .buttonStyle(.glassProminent)
                .tint(theme.accent)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .contentShape(Rectangle())
        // Only the bar pages: the page below keeps every gesture of its own (sliders, canvases, horizontal scrolling).
        .gesture(DragGesture(minimumDistance: 20).onEnded { drag in
            guard let paging, abs(drag.translation.width) > 50, abs(drag.translation.width) > abs(drag.translation.height) * 1.5
            else { return }
            if drag.translation.width < 0 { paging.next?() } else { paging.previous?() }
        }, isEnabled: paging != nil)
        .accessibilityActions {
            if let next = paging?.next { Button("Next Artifact", action: next) }
            if let previous = paging?.previous { Button("Previous Artifact", action: previous) }
        }
    }

    private func notice(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(DS.Typography.ui)
            .foregroundStyle(theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(DS.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The artifact as an `.html` file named after its title, for Share.
struct ArtifactFile: Transferable {
    let title: String
    /// The page, read when it is shared (so a menu can offer Share without reading every artifact up front).
    private let load: @Sendable () -> String?

    init(title: String, html: String) {
        self.title = title
        load = { html }
    }

    /// The stored artifact, read from `store` when shared.
    init(entry: ArtifactStore.Entry, store: ArtifactStore = .shared) {
        title = entry.artifact.title
        load = { store.html(id: entry.artifact.id, conversationID: entry.conversationID) }
    }

    var html: String? { load() }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .html) { file in
            guard let html = file.html else { throw CocoaError(.fileNoSuchFile) }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artifacts", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(file.fileName)
            try html.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }

    /// "Mortgage calculator.html": the title without characters a file name can't hold.
    var fileName: String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Artifact" : cleaned).prefix(80)) + ".html"
    }
}

// MARK: - Web view

/// Decides where the artifact's page may go: it stays put, subframes load from public hosts, and a link that would
/// replace it opens outside (the in-app browser on a phone, the default browser on a Mac).
@MainActor
final class ArtifactNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var lastOpened = Date.distantPast

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        // The page itself (loaded from a string: about:blank) and its in-page anchors.
        if scheme == "about" || scheme == "blob" || scheme == "data" { return .allow }
        if let frame = action.targetFrame, !frame.isMainFrame { return await ArtifactNavigation.subframePolicy(url) }
        openOutside(url)
        return .cancel
    }

    /// A subframe loads when it is on the web and its host resolves only to public addresses (the content rules see
    /// URLs only, so a name that resolves to a LAN device would get past them).
    static func subframePolicy(_ url: URL, resolver: any HostResolving = SystemHostResolver()) async -> WKNavigationActionPolicy {
        guard InAppBrowser.isWeb(url), (try? await URLGuard.validate(url, resolver: resolver)) != nil else { return .cancel }
        return .allow
    }

    /// `target="_blank"` and `window.open`: never a second web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { openOutside(url) }
        return nil
    }

    /// At most one page a second, so a script can't stack browsers on the user.
    private func openOutside(_ url: URL) {
        guard Date.now.timeIntervalSince(lastOpened) > 1 else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        if InAppBrowser.isWeb(url) {
            lastOpened = .now
            InAppBrowser.present(url)
        } else if ["mailto", "tel", "sms"].contains(scheme) {
            lastOpened = .now
            InAppBrowser.openExternally(url)
        }
    }

    /// A web view with nothing of the app in it: its own throwaway data store, no message handlers, no file access
    /// (loaded from a string with no base URL), and the local-network rules.
    static func makeWebView(html: String, rules: WKContentRuleList, delegate: ArtifactNavigation) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(rules)
        #if canImport(UIKit)
        config.allowsInlineMediaPlayback = true
        #endif
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        #if canImport(UIKit)
        view.isOpaque = false
        view.backgroundColor = .clear
        #else
        view.underPageBackgroundColor = .clear
        #endif
        view.loadHTMLString(html, baseURL: nil)
        return view
    }
}

#if canImport(UIKit)
private struct ArtifactWebView: UIViewRepresentable {
    let html: String
    let rules: WKContentRuleList
    func makeCoordinator() -> ArtifactNavigation { ArtifactNavigation() }
    func makeUIView(context: Context) -> WKWebView { ArtifactNavigation.makeWebView(html: html, rules: rules, delegate: context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
private struct ArtifactWebView: NSViewRepresentable {
    let html: String
    let rules: WKContentRuleList
    func makeCoordinator() -> ArtifactNavigation { ArtifactNavigation() }
    func makeNSView(context: Context) -> WKWebView { ArtifactNavigation.makeWebView(html: html, rules: rules, delegate: context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif

// MARK: - Previews

#Preview("Dark · Purple") { artifactPreview.previewStyle(.dark) }
#Preview("Light · Purple") { artifactPreview.previewStyle(.light) }

@MainActor private var artifactPreview: some View {
    var done = FeedCard(id: "a", kind: .artifact(title: "Mortgage calculator"))
    done.artifact = ArtifactRef(conversationID: UUID(), id: "a1", title: "Mortgage calculator", version: 3)
    var running = FeedCard(id: "b", kind: .artifact(title: ""))
    running.isRunning = true
    return VStack(spacing: 10) {
        ArtifactFeedCard(card: done, onDetails: {})
        ArtifactFeedCard(card: running, onDetails: {})
    }
    .padding()
}
