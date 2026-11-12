import SwiftUI
import UniformTypeIdentifiers
import WebKit

// HTML artifacts (`show_html`): the one-line card in the feed and the full-screen page it opens. The page runs in a web
// view of its own: a throwaway data store, the local-network content blocker, no bridge into the app, no file access,
// and links that leave the page open outside it.

/// "Mortgage calculator  HTML  v2 ›" in the feed; a tap opens the page.
struct ArtifactFeedCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.artifactPanel) private var panel
    let card: FeedCard
    var onDetails: () -> Void
    @State private var showing = false

    static let icon = "chevron.left.forwardslash.chevron.right"

    var body: some View {
        Button {
            guard let ref = card.artifact else { return }
            if let panel { panel.open(ref) } else { showing = true }
        } label: {
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

/// An artifact in the answer: a card with the page's title that opens it full screen. The feed keeps its one line too.
struct ArtifactAnswerCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.artifactPanel) private var panel
    let ref: ArtifactRef
    @State private var showing = false

    /// Each artifact of these calls once, at its newest version, in the order they were first made.
    nonisolated static func latest(_ calls: [ToolCallRecord]) -> [ArtifactRef] {
        var order: [String] = []
        var newest: [String: ArtifactRef] = [:]
        for ref in calls.compactMap(\.artifact) {
            if newest[ref.id] == nil { order.append(ref.id) }
            if ref.version >= newest[ref.id]?.version ?? 0 { newest[ref.id] = ref }
        }
        return order.compactMap { newest[$0] }
    }

    var body: some View {
        Button { if let panel { panel.open(ref) } else { showing = true } } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: ArtifactFeedCard.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 44, height: 44)
                    .background(theme.accentMuted, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ref.title.isEmpty ? String(localized: "Artifact") : ref.title)
                        .font(DS.Typography.uiEmphasis)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(ref.version > 1 ? "Interactive page · v\(ref.version)" : "Interactive page")
                        .font(DS.Typography.uiSmall)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: DS.Spacing.sm)
                Text("Open")
                    .font(DS.Typography.uiSmall.weight(.semibold))
                    .foregroundStyle(theme.accent)
            }
            .padding(DS.Spacing.md)
            .frame(maxWidth: 480, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(theme.separator))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens the artifact"))
        .fullScreenCoverOrSheet(isPresented: $showing) { ArtifactViewer(ref: ref) }
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
    /// Set when the viewer is the panel beside the chat (`ArtifactPanel`): Done closes the panel, and the panel's column
    /// sets the size.
    var onClose: (() -> Void)?

    private func close() { if let onClose { onClose() } else { dismiss() } }

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
        .frame(minWidth: onClose == nil ? 640 : nil, idealWidth: onClose == nil ? 900 : nil,
               minHeight: onClose == nil ? 520 : nil, idealHeight: onClose == nil ? 720 : nil)
        .background { Button("Close", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
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
                    close()
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
            Button("Done", action: close)
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

// MARK: - Live preview

/// Opens the page of an artifact the model is still writing.
struct ArtifactDraftRequest: Identifiable {
    let id = UUID()
    let feed: ArtifactDraftFeed
    /// How many `show_html` calls the run had finished when the preview opened (`ArtifactDraftFeed.state`).
    let seen: Int

    @MainActor init(feed: ArtifactDraftFeed) {
        self.feed = feed
        seen = feed.results.count
    }
}

/// An artifact while the model writes it: the page as far as it has come, refreshed a few times a second where it is
/// scrolled. The page's scripts don't run here (the page is cut off mid-way most of the time, and they would start
/// again at every refresh). Once the artifact is stored, the real one takes the preview's place.
struct ArtifactDraftViewer: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let request: ArtifactDraftRequest
    /// The panel beside the chat (`ArtifactPanel`): the stored artifact opens in it, and Done closes it.
    var onStored: ((ArtifactRef) -> Void)?
    var onClose: (() -> Void)?

    /// How often the page is brought up to date.
    static let refresh: Duration = .milliseconds(400)

    @State private var title = ""
    @State private var html = ""
    @State private var bytes = 0
    @State private var stored: ArtifactRef?
    @State private var ended = false
    private enum Rules { case loading, ready(WKContentRuleList), unsafe }
    @State private var rules = Rules.loading

    private func close() { if let onClose { onClose() } else { dismiss() } }

    var body: some View {
        if let stored {
            ArtifactViewer(ref: stored, onClose: onClose)
        } else {
            draft
        }
    }

    private var draft: some View {
        VStack(spacing: 0) {
            bar
            Group {
                switch rules {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unsafe:
                    notice("The artifact can't be opened safely right now.")
                case .ready(let rules):
                    if html.isEmpty {
                        notice(ended ? "This artifact wasn't finished." : "The page appears here as it's written.")
                    } else {
                        ArtifactDraftWebView(html: ArtifactHTML.prepared(html), rules: rules)
                    }
                }
            }
            Text(ended ? "This artifact wasn't finished." : "A preview of the page so far. Its scripts start once it's finished.")
                .font(DS.Typography.uiCaption)
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.sm)
                .frame(maxWidth: .infinity)
        }
        .background(theme.background.ignoresSafeArea())
        .task {
            // Nothing loads before the local-network rules are in place.
            if let list = await LocalNetworkRules.artifactRules() { rules = .ready(list) } else { rules = .unsafe }
            await follow()
        }
        #if os(macOS)
        .frame(minWidth: onClose == nil ? 640 : nil, idealWidth: onClose == nil ? 900 : nil,
               minHeight: onClose == nil ? 520 : nil, idealHeight: onClose == nil ? 720 : nil)
        .background { Button("Close", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        #endif
    }

    /// Reads the feed until the artifact is stored or the run is over.
    private func follow() async {
        while !Task.isCancelled {
            switch request.feed.state(after: request.seen) {
            case .stored(let ref):
                if let onStored { onStored(ref) } else { stored = ref }
                return
            case .ended:
                await read()
                ended = true
                return
            case .writing:
                await read()
            }
            try? await Task.sleep(for: Self.refresh)
        }
    }

    private func read() async {
        let arguments = request.feed.arguments
        let size = arguments.utf8.count
        guard size != bytes else { return }
        bytes = size
        let (newTitle, page) = await Task.detached(priority: .userInitiated) {
            (ToolDraft.title(in: arguments), ToolDraft.html(in: arguments))
        }.value
        if !newTitle.isEmpty { title = newTitle }
        html = page
    }

    private var bar: some View {
        HStack(spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title.isEmpty ? String(localized: "Artifact") : title)
                    .font(DS.Typography.title).foregroundStyle(theme.textPrimary).lineLimit(1)
                HStack(spacing: DS.Spacing.xs) {
                    ArtifactBadge()
                    Text(verbatim: Self.status(bytes: bytes, ended: ended))
                        .font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            if !ended { ProgressView().controlSize(.small) }
            Button("Done", action: close)
                .buttonStyle(.glassProminent)
                .tint(theme.accent)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
    }

    /// "Writing · 12 KB" under the title; the size once there is a KB.
    nonisolated static func status(bytes: Int, ended: Bool) -> String {
        let what = ended ? String(localized: "Not finished") : String(localized: "Writing")
        guard bytes >= 1024 else { return what }
        return what + " · " + bytes.formatted(.byteCount(style: .file))
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

/// Decides where the artifact's page may go: it stays put, subframes load from public hosts, and a link the user taps
/// that would replace it opens outside (the in-app browser on a phone, the default browser on a Mac).
@MainActor
class ArtifactNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var lastOpened = Date.distantPast

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        // The page itself (loaded from a string: about:blank) and its in-page anchors.
        if scheme == "about" || scheme == "blob" || scheme == "data" { return .allow }
        if let frame = action.targetFrame, !frame.isMainFrame { return await ArtifactNavigation.subframePolicy(url) }
        await openOutside(url, type: action.navigationType)
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
        if let url = action.request.url {
            let type = action.navigationType
            Task { await openOutside(url, type: type) }
        }
        return nil
    }

    /// Hands a tapped link to another browser, at most one a second so a page can't stack browsers on the user.
    private func openOutside(_ url: URL, type: WKNavigationType) async {
        guard Date.now.timeIntervalSince(lastOpened) > 1 else { return }
        lastOpened = .now
        guard await ArtifactNavigation.mayOpenOutside(url, type: type) else { return }
        if InAppBrowser.isWeb(url) { InAppBrowser.present(url) } else { InAppBrowser.openExternally(url) }
    }

    /// Only a link the user activated leaves the artifact; a script setting `location` or calling `window.open` stays
    /// put. A web destination must also be public, since the other browser has no local-network rules.
    static func mayOpenOutside(_ url: URL, type: WKNavigationType,
                               resolver: any HostResolving = SystemHostResolver()) async -> Bool {
        guard type == .linkActivated else { return false }
        if InAppBrowser.isWeb(url) { return (try? await URLGuard.validate(url, resolver: resolver)) != nil }
        return ["mailto", "tel", "sms"].contains(url.scheme?.lowercased() ?? "")
    }

    /// A web view with nothing of the app in it: its own throwaway data store, no message handlers, no file access
    /// (loaded from a string with no base URL), and the local-network rules.
    /// - Parameter scripts: false for the live preview of a page still being written (`ArtifactDraftNavigation`).
    static func makeWebView(html: String, rules: WKContentRuleList, delegate: ArtifactNavigation, scripts: Bool = true) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = scripts
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

/// The live preview's page: an empty document that the page so far is written into again as it grows, in place, so the
/// scroll position stays and nothing navigates. The page's own scripts are off; only this rewrite runs.
@MainActor
final class ArtifactDraftNavigation: ArtifactNavigation {
    static let shell = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>"
    private static let rewrite = "var x=window.scrollX,y=window.scrollY;document.open();document.write(h);document.close();window.scrollTo(x,y);"

    private var loaded = false
    private var writing = false
    private var shown = ""
    private var wanted = ""

    func show(_ html: String, in view: WKWebView) {
        wanted = html
        flush(view)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        flush(webView)
    }

    /// One rewrite at a time; a page that came while one ran is written after it.
    private func flush(_ view: WKWebView) {
        guard loaded, !writing, wanted != shown else { return }
        let html = wanted
        writing = true
        Task { [weak self, weak view] in
            _ = try? await view?.callAsyncJavaScript(Self.rewrite, arguments: ["h": html], in: nil, contentWorld: .defaultClient)
            guard let self else { return }
            self.shown = html
            self.writing = false
            if let view { self.flush(view) }
        }
    }
}

#if canImport(UIKit)
private struct ArtifactDraftWebView: UIViewRepresentable {
    let html: String
    let rules: WKContentRuleList
    func makeCoordinator() -> ArtifactDraftNavigation { ArtifactDraftNavigation() }
    func makeUIView(context: Context) -> WKWebView {
        ArtifactNavigation.makeWebView(html: ArtifactDraftNavigation.shell, rules: rules, delegate: context.coordinator, scripts: false)
    }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.show(html, in: view) }
}
#else
private struct ArtifactDraftWebView: NSViewRepresentable {
    let html: String
    let rules: WKContentRuleList
    func makeCoordinator() -> ArtifactDraftNavigation { ArtifactDraftNavigation() }
    func makeNSView(context: Context) -> WKWebView {
        ArtifactNavigation.makeWebView(html: ArtifactDraftNavigation.shell, rules: rules, delegate: context.coordinator, scripts: false)
    }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.show(html, in: view) }
}
#endif

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
