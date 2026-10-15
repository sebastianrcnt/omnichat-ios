import SwiftUI
import WebKit

/// The model's browser page, lent to the user (`browser_show`): what the model asks them to do, the page, and Done.
/// Closing the sheet any other way tells the model they didn't finish.
struct BrowserShowSheet: View {
    @Environment(\.theme) private var theme
    let request: BrowserShowRequests.Request
    let onAnswer: (Bool) -> Void
    @State private var host = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.md) {
                GlassIconButton(systemName: "xmark", label: "Close") { onAnswer(false) }
                Spacer(minLength: 0)
                Label(host.isEmpty ? String(localized: "Browser") : host, systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Done") { onAnswer(true) }
                    .buttonStyle(.glassProminent)
                    .tint(theme.accent)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.md)
            if !request.reason.isEmpty {
                Text(verbatim: request.reason)
                    .font(DS.Typography.ui)
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.bottom, DS.Spacing.md)
            }
            LentWebView(page: request.page)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(theme.background.ignoresSafeArea())
        .task {
            // The address bar's host, kept current as the user moves between pages (a sign-in redirects).
            while !Task.isCancelled {
                host = request.page.webView.url?.host(percentEncoded: false) ?? ""
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onDisappear { request.page.park() }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 640, idealHeight: 760)
        #endif
    }
}

/// Holds the hidden web view while the sheet is up; `HiddenWebView.park` takes it back.
#if canImport(UIKit)
private struct LentWebView: UIViewRepresentable {
    let page: HiddenWebView
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        return container
    }
    func updateUIView(_ container: UIView, context: Context) {
        if page.webView.superview !== container { page.show(in: container) }
    }
}
#else
private struct LentWebView: NSViewRepresentable {
    let page: HiddenWebView
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ container: NSView, context: Context) {
        if page.webView.superview !== container { page.show(in: container) }
    }
}
#endif

/// Settings > Developer > Browser cookies: what the model's browser keeps (`BrowserData`), by site, and a way to delete it.
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
                    GroupedSection(footer: "Sites the model's browser signs in to keep their cookies here.") {
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
                        Text("Delete all browser data").font(DS.Typography.ui).foregroundStyle(theme.destructive)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, DS.Spacing.md)
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Browser cookies")
        .inlineNavigationTitle()
        .task { await reload() }
        .confirmationDialog("Delete all browser data?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteAll() } }
        } message: {
            Text("Cookies, storage and caches of the model's browser. Sites it was signed in to will ask again.")
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
        BrowserSessions.shared.closeAll()
        await BrowserData.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await reload()
    }
}
