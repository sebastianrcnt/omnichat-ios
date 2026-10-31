import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings > Connections > an OpenCode account: the device-code sign-in (or a service-account API key instead), the
/// plan the requests go to (Go or pay as you go), and the account's models. No base URL, headers or resumable replies.
/// Being added (`draft`), a sign-in is kept under the draft's id, while a service-account key waits in the draft for Add.
struct OpenCodeConnectionEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.connectionStore) private var connections
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    let connectionID: UUID
    @Binding var path: [UUID]
    var draft: ConnectionDraft?

    @State private var session: OpenCodeSession?
    @State private var hasAPIKey = false
    /// The code on screen while a sign-in waits for approval.
    @State private var device: OpenCodeDeviceCode?
    @State private var signIn: Task<Void, Never>?
    @State private var showsKeyField = false
    @State private var apiKeyText = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var fetching = false

    /// This editor's fetch, or one from launch still running.
    private var fetchingModels: Bool { fetching || connections.modelFetches[connectionID]?.running == true }
    @State private var editingModel: String?
    @State private var copied = false
    @State private var browser = DeviceSignInBrowser()

    private var connection: Connection? { connections.connection(connectionID, draft: draft) }
    private var signedIn: Bool { session != nil || hasAPIKey }

    var body: some View {
        if let connection {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    GroupedSection(header: "OpenCode account", footer: accountFooter) {
                        if let session {
                            SettingsRow(systemImage: "person.crop.circle", title: "",
                                        subtitle: String(localized: "Signed in with the OpenCode Console"),
                                        verbatimTitle: session.email ?? String(localized: "Signed in"))
                            signOutRow
                        } else if hasAPIKey {
                            SettingsRow(systemImage: "key", title: "API key",
                                        subtitle: draft == nil ? String(localized: "Saved in the Keychain")
                                                               : String(localized: "Saved in the Keychain when you add the connection"))
                            signOutRow
                        } else if let device {
                            deviceCodeRows(device)
                        } else {
                            SettingsRow(systemImage: "person.badge.key", title: signIn == nil ? "Sign in with OpenCode" : "Signing in…") {
                                startSignIn()
                            }
                            .disabled(signIn != nil)
                            if showsKeyField {
                                SettingsFieldRow(title: "API key", prompt: "oc_sk_…", text: $apiKeyText, isSecure: true)
                                SettingsRow(systemImage: "key", title: "Save key") { saveKey() }
                                    .disabled(apiKeyText.trimmingCharacters(in: .whitespaces).isEmpty)
                            } else {
                                SettingsRow(systemImage: "key", title: "Use an API key instead") { showsKeyField = true }
                            }
                        }
                        SettingsRow(systemImage: "chart.bar", title: "Open the OpenCode Console", showsChevron: true) {
                            openURL(OpenCodeAPI.consoleURL)
                        }
                    }
                    if let status {
                        Text(status).font(DS.Typography.uiCaption)
                            .foregroundStyle(statusIsError ? theme.destructive : theme.textSecondary)
                    }

                    GroupedSection(header: "Plan", footer: "Go is the monthly subscription with usage limits. Pay as you go bills the workspace balance. Each plan has its own models.") {
                        ForEach(OpenCodeGateway.allCases) { gateway in
                            SettingsRow(title: LocalizedStringKey(gateway.title),
                                        isChecked: (connection.openCodeGateway ?? .go) == gateway) { select(gateway) }
                        }
                    }

                    GroupedSection(header: "Connection") {
                        SettingsFieldRow(title: "Name", prompt: "Name", text: Binding(
                            get: { connection.name },
                            set: { value in connections.edit(connectionID, draft: draft) { $0.name = value } }))
                    }

                    GroupedSection(header: "Models", footer: connections.modelFetches[connectionID]?.footer.map { LocalizedStringKey($0) }) {
                        ForEach(connection.models) { model in
                            SettingsRow(modelID: model.id, alias: connection.alias(forModel: model.id) ?? model.fetchedDisplayName,
                                        subtitle: connection.showsInPicker(model.id)
                                            ? model.capabilitiesSummary
                                            : [String(localized: "Hidden"), model.capabilitiesSummary].compactMap { $0 }.joined(separator: " · "),
                                        value: model.effectiveContextLength(default: AppSettings.defaultContextLength).formatted(),
                                        showsChevron: true) { editingModel = model.id }
                        }
                        SettingsRow(systemImage: "arrow.down.circle", title: fetchingModels ? "Fetching…" : "Fetch models") {
                            Task { await fetch() }
                        }
                        .disabled(fetching || !signedIn)
                    }

                    if draft == nil {
                        GroupedSection {
                            SettingsRow(systemImage: "trash", title: "Delete connection", isDestructive: true) {
                                signIn?.cancel()
                                Task {
                                    await connections.openCode.signOut(connectionID: connectionID)
                                    connections.delete(connectionID)
                                }
                                path.removeAll()
                            }
                        }
                    }
                }
                .padding(DS.Spacing.lg)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(connection.name)
            .inlineNavigationTitle()
            .onAppear {
                reload()
                fetchIfEmpty()
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { fetchIfEmpty() } }
            .onDisappear { signIn?.cancel() }
            .sheet(item: Binding(get: { editingModel.map { ModelRef(id: $0) } }, set: { editingModel = $0?.id })) { ref in
                ModelEditor(connectionID: connectionID, modelID: ref.id, draft: draft)
            }
        }
    }

    private struct ModelRef: Identifiable { let id: String }

    private var accountFooter: LocalizedStringKey {
        if device != nil {
            return "Open the sign-in page and approve. The code is copied when the page opens, so paste it if the page asks. OmniChat keeps checking and comes back here once you approve."
        }
        return "Sign in with your OpenCode Console account, or paste a service-account API key from the Console. Sign-ins and keys are stored in the Keychain."
    }

    private var signOutRow: some View {
        SettingsRow(systemImage: "rectangle.portrait.and.arrow.right", title: hasAPIKey ? "Remove key" : "Sign out",
                    isDestructive: true) {
            Task { await signOut() }
        }
    }

    /// The code, large and selectable, with copy, open and cancel.
    @ViewBuilder
    private func deviceCodeRows(_ device: OpenCodeDeviceCode) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Your code").font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
            Text(verbatim: device.userCode)
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
                .accessibilityLabel(Text(verbatim: device.userCode.map(String.init).joined(separator: " ")))
            HStack(spacing: DS.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Waiting for approval…").font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        SettingsRow(systemImage: copied ? "checkmark" : "doc.on.doc", title: copied ? "Copied" : "Copy code") {
            Pasteboard.copy(device.userCode)
            copied = true
        }
        SettingsRow(systemImage: "safari", title: "Open sign-in page", showsChevron: true,
                    detail: device.verificationURL.host().map { "\($0)\(device.verificationURL.path())" }) { openSignInPage(device) }
        SettingsRow(systemImage: "xmark.circle", title: "Cancel sign-in") { signIn?.cancel() }
    }

    /// The page may lose the code on its way through a login, and once it covers the app the code is out of sight: copy
    /// it first, so it can be pasted.
    private func openSignInPage(_ device: OpenCodeDeviceCode) {
        Pasteboard.copy(device.userCode)
        copied = true
        let url = device.verificationURL
        #if os(macOS)
        NSWorkspace.shared.open(url) // the default browser, where the person is likely signed in already
        #else
        if !browser.open(url) { openURL(url) } // a sheet over the app; closed for them once approved
        #endif
    }

    private func reload() {
        session = connections.openCode.store.session(connectionID)
        hasAPIKey = draft.map { $0.apiKey != nil } ?? (connections.openCode.store.apiKey(connectionID) != nil)
        if let draft { connections.checkSignIn(draft) }
    }

    private func show(_ text: String?, error: Bool = false) {
        status = text
        statusIsError = error
    }

    private func startSignIn() {
        signIn?.cancel()
        show(nil)
        copied = false
        signIn = Task { await runSignIn() }
    }

    private func runSignIn() async {
        let auth = connections.openCode
        defer {
            browser.close()
            device = nil
            signIn = nil
        }
        do {
            let code = try await auth.requestDeviceCode()
            device = code // the page opens from its row, after the person has seen the code it should show
            let session = try await auth.completeSignIn(connectionID: connectionID, device: code)
            reload()
            device = nil
            if let email = session.email, connection?.name == String(localized: "OpenCode") {
                connections.edit(connectionID, draft: draft) { $0.name = "OpenCode (\(email))" }
            }
            await detectPlanAndFetch()
        } catch OpenCodeAuthError.cancelled {
            show(nil)
        } catch let error as URLError where error.code == .cancelled {
            show(nil)
        } catch is CancellationError {
            show(nil)
        } catch {
            reload()
            show(error.localizedDescription, error: true)
        }
    }

    private func saveKey() {
        do {
            if let draft { draft.setAPIKey(apiKeyText) } else { try connections.openCode.saveAPIKey(apiKeyText, connectionID: connectionID) }
            apiKeyText = ""
            showsKeyField = false
            reload()
            show(nil)
            Task { await detectPlanAndFetch() }
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func signOut() async {
        await connections.openCode.signOut(connectionID: connectionID)
        draft?.setAPIKey(nil)
        reload()
        show(String(localized: "Signed out on this device."))
    }

    /// After a sign-in: the workspace config says whether it has Go. With Go the connection uses it; without, pay as you
    /// go. When the config can't be read, the plan stays as it is.
    private func detectPlanAndFetch() async {
        let auth = connections.openCode
        let gateways = if let key = draft?.apiKey { await auth.availableGateways(token: key) }
                       else { await auth.availableGateways(connectionID: connectionID) }
        if let gateways, let current = connection.map({ $0.openCodeGateway ?? .go }) {
            var picked = current
            if gateways.contains(.go) {
                picked = .go
            } else if !gateways.isEmpty {
                picked = .console
                if current == .go { show(String(localized: "No Go subscription found for this workspace, so Pay as you go is selected.")) }
            }
            connections.edit(connectionID, draft: draft) { c in
                c.openCodeGateway = picked
                if picked != current {
                    c.baseURL = picked.baseURL.absoluteString
                    c.models = []
                }
            }
        }
        await fetch()
    }

    private func select(_ gateway: OpenCodeGateway) {
        guard let c = connection, (c.openCodeGateway ?? .go) != gateway else { return }
        connections.edit(connectionID, draft: draft) { c in
            c.openCodeGateway = gateway
            c.baseURL = gateway.baseURL.absoluteString
            c.models = [] // each plan has its own models
        }
        if signedIn { Task { await fetch() } }
    }

    /// A signed-in account with no models fetches them: the fetch right after sign-in can fail while the browser has
    /// the app in the background.
    private func fetchIfEmpty() {
        guard signedIn, signIn == nil, !fetching, connection?.models.isEmpty == true else { return }
        Task { await fetch() }
    }

    private func fetch() async {
        fetching = true
        defer { fetching = false }
        // How it went shows in the Models footer (`ConnectionStore.modelFetches`).
        do { try await connections.refreshModels(for: connectionID, draft: draft) } catch { reload() }
    }

}
