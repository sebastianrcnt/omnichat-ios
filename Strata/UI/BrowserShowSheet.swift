import SwiftUI
import WebKit

/// A hidden web view lent to the user, the same instance the tools use (its page, scroll and input as they are):
/// - handed over (`browser_show`, a robot check, a failed row's page): what to do, the page, and Done. Closing the
///   sheet any other way tells the waiting tool they didn't finish.
/// - watched (the model's browser while it works): read-only, with Stop browsing (ends the reply's browser calls; the
///   reply goes on) and Take over (the model's calls wait while the user uses the page, until Done).
struct BrowserShowSheet: View {
    @Environment(\.theme) private var theme
    let request: BrowserShowRequests.Request
    let onAnswer: (Bool) -> Void
    @State private var host = ""
    @State private var secure = false
    @State private var canGoBack = false
    @State private var tookOver = false

    private var page: HiddenWebView { request.page }

    /// The model's session this sheet shows, when it is one.
    private var session: UUID? {
        switch request.mode {
        case .handover: nil
        case .watch(let conversation), .takenOver(let conversation), .browse(let conversation): conversation
        }
    }

    private var watching: Bool {
        if case .watch = request.mode { return !tookOver }
        return false
    }

    /// The user has the model's page: its calls wait until the sheet closes.
    private var holdsSession: Bool {
        switch request.mode {
        case .handover: false
        case .watch: tookOver
        case .takenOver, .browse: true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.md) {
                GlassIconButton(systemName: "xmark", label: "Close") { close(done: false) }
                if !watching {
                    GlassIconButton(systemName: "chevron.left", label: "Back") { page.webView.goBack() }
                        .disabled(!canGoBack)
                        .opacity(canGoBack ? 1 : 0.4)
                    GlassIconButton(systemName: "arrow.clockwise", label: "Reload") { page.webView.reload() }
                }
                Spacer(minLength: 0)
                // The lock only for a page that is all https; a plain http page says so before the user signs in.
                Label(host.isEmpty ? String(localized: "Browser") : host, systemImage: secure ? "lock.fill" : "exclamationmark.triangle")
                    .labelStyle(.titleAndIcon)
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !watching {
                    Button("Done") { close(done: true) }
                        .buttonStyle(.glassProminent)
                        .tint(theme.accent)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.md)
            if let note, !watching {
                Text(verbatim: note)
                    .font(DS.Typography.ui)
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.bottom, DS.Spacing.md)
            }
            WebStage(page: page, kind: .sheet, interactive: !watching)
                .overlay(alignment: .top) { if watching { watchBanner } }
                .ignoresSafeArea(edges: watching ? [] : .bottom)
            if watching { watchBar }
        }
        .background(theme.background.ignoresSafeArea())
        .task {
            // The address bar's host, kept current as the user moves between pages (a sign-in redirects).
            while !Task.isCancelled {
                let view = page.webView
                host = view.url?.host(percentEncoded: false) ?? ""
                secure = view.url?.scheme?.lowercased() == "https" && view.hasOnlySecureContent
                canGoBack = view.canGoBack
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // However the sheet goes, the model gets its page back.
        .onDisappear {
            if holdsSession, let session { BrowserSessions.shared.handBack(session) }
            if case .browse(let conversation) = request.mode { BrowserSessions.shared.pageReturned(conversation) }
        }
        // A swipe down would tell the model "not done" in the middle of a sign-in: closing is the X, finishing is Done.
        .interactiveDismissDisabled(!watching)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 640, idealHeight: 760)
        #endif
    }

    /// What the user is asked to do, above the page.
    private var note: String? {
        if case .browse = request.mode { return nil }
        if holdsSession { return String(localized: "OpenChat waits while you use the page. Tap Done to hand it back.") }
        return request.reason.isEmpty ? nil : request.reason
    }

    private func close(done: Bool) {
        if holdsSession, let session { BrowserSessions.shared.handBack(session) }
        onAnswer(done)
    }

    private var watchBanner: some View {
        HStack(spacing: DS.Spacing.sm) {
            ProgressView().controlSize(.small).tint(.white)
            Text("OpenChat is using this page · view only")
                .font(DS.Typography.uiSmall)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .padding(DS.Spacing.md)
        .accessibilityElement(children: .combine)
    }

    private var watchBar: some View {
        HStack(spacing: DS.Spacing.md) {
            Button(role: .destructive) {
                if let session { BrowserSessions.shared.stopBrowsing(session) }
                onAnswer(false)
            } label: {
                Text("Stop browsing").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(theme.destructive)
            Button {
                if let session { BrowserSessions.shared.takeOver(session) }
                tookOver = true
            } label: {
                Text("Take over").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(theme.accent)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
    }
}

/// Opening a page from the chat: watching the model's browser, or a page a failed tool kept.
@MainActor
enum PageHandover {
    /// The Watch sheet for the model's page of `conversation`.
    static func watch(_ page: HiddenWebView, conversation: UUID) {
        BrowserShowRequests.shared.present(.init(reason: "", page: page, mode: .watch(conversation: conversation)))
    }

    /// The feed's "Open page" after a reply: the conversation's (frozen) page, to browse; Done freezes it again.
    static func browse(_ page: HiddenWebView, conversation: UUID) {
        BrowserSessions.shared.takeOver(conversation)
        BrowserShowRequests.shared.present(.init(reason: "", page: page, mode: .browse(conversation: conversation)))
    }

    /// "Page closed · Reopen": the conversation's last URL, loaded fresh in a new session, to browse.
    static func reopen(_ conversation: UUID) {
        guard let page = BrowserSessions.shared.reopen(conversation) as? HiddenWebView else { return }
        browse(page, conversation: conversation)
    }

    /// A failed row's "Open this page". Nothing waits for it; a model's page is taken over while it is open, so the
    /// reply's browser calls wait until the user is done.
    static func open(_ page: HiddenWebView) {
        if let conversation = BrowserSessions.shared.conversation(showing: page) {
            BrowserSessions.shared.takeOver(conversation)
            BrowserShowRequests.shared.present(.init(reason: "", page: page, mode: .takenOver(conversation: conversation)))
        } else {
            BrowserShowRequests.shared.present(.init(reason: "", page: page))
        }
    }
}

/// Settings > Tools > Site cookies: what the hidden browser keeps (`BrowserData`, shared by search, fetch and the
/// model's browser), by site, and a way to delete it.
struct BrowserCookiesView: View {
    @Environment(\.theme) private var theme
    @State private var cookies: [HTTPCookie] = []
    @State private var loaded = false
    @State private var confirmAll = false

    private var sites: [(domain: String, cookies: [HTTPCookie])] {
        Dictionary(grouping: cookies) { Self.site($0.domain) }
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.domain < $1.domain }
    }

    static func site(_ domain: String) -> String { domain.hasPrefix(".") ? String(domain.dropFirst()) : domain }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                if loaded && cookies.isEmpty {
                    GroupedSection(footer: "Sites you sign in to or pass a robot check on in OpenChat's browser keep their cookies here.") {
                        SettingsRow(title: "No cookies")
                    }
                }
                ForEach(sites, id: \.domain) { site in
                    GroupedSection(header: "\(site.domain)") {
                        ForEach(site.cookies, id: \.self) { cookie in
                            SettingsRow(title: "\(cookie.name)", value: Self.expiry(cookie))
                        }
                        Button(role: .destructive) { delete(site.cookies) } label: {
                            Text("Delete cookies for this site").font(DS.Typography.ui).foregroundStyle(theme.destructive)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.sm)
                    }
                }
                if !cookies.isEmpty {
                    Button(role: .destructive) { confirmAll = true } label: {
                        Text("Clear browsing data").font(DS.Typography.ui).foregroundStyle(theme.destructive)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, DS.Spacing.md)
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Site cookies")
        .inlineNavigationTitle()
        .task { await reload() }
        .confirmationDialog("Clear browsing data?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { Task { await deleteAll() } }
        } message: {
            Text(BrowsingDataSection.clearMessage)
        }
    }

    static func expiry(_ cookie: HTTPCookie) -> String {
        guard let date = cookie.expiresDate else { return String(localized: "Session") }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func reload() async {
        cookies = await BrowserData.store.httpCookieStore.allCookies()
        loaded = true
    }

    private func delete(_ list: [HTTPCookie]) {
        Task {
            for cookie in list { await BrowserData.store.httpCookieStore.deleteCookie(cookie) }
            await reload()
        }
    }

    private func deleteAll() async {
        await BrowsingData.clearAll()
        await reload()
    }
}
