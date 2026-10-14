import SwiftUI

/// Settings > Connections > a ChatGPT account: the signed-in account, sign-in and sign-out, and the account's models.
/// No base URL, headers, API key or resumable replies: the connection always talks to the Responses API with the
/// account's OAuth token.
struct ChatGPTConnectionEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.connectionStore) private var connections
    @Environment(\.openURL) private var openURL
    let connectionID: UUID
    @Binding var path: [UUID]

    @State private var signedIn = false
    @State private var registration: ChatGPTRegistration?
    @State private var planAllowed: Bool?
    @State private var flow: ChatGPTSignIn?
    @State private var working = false
    @State private var status: String?
    @State private var statusIsError = false
    @State private var fetchStatus: String?
    @State private var fetching = false
    @State private var editingModel: String?

    private var connection: Connection? { connections.connection(connectionID) }

    var body: some View {
        if let connection {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    GroupedSection(header: "ChatGPT account", footer: accountFooter) {
                        if signedIn {
                            SettingsRow(systemImage: "person.crop.circle", title: "", subtitle: registration?.email,
                                        verbatimTitle: registration?.name ?? registration?.email ?? String(localized: "Signed in"))
                            SettingsRow(systemImage: "rectangle.portrait.and.arrow.right", title: "Sign out", isDestructive: true) {
                                Task { await signOut() }
                            }
                            .disabled(working)
                        } else {
                            if let email = registration?.email {
                                SettingsRow(systemImage: "person.crop.circle", title: "", subtitle: String(localized: "Signed out"),
                                            verbatimTitle: email)
                            }
                            SettingsRow(systemImage: "person.badge.key", title: flow == nil ? "Sign in with ChatGPT" : "Signing in…") {
                                Task { await signIn() }
                            }
                            .disabled(flow != nil)
                            #if os(macOS)
                            if flow != nil {
                                // The page is in the browser, which has no sheet to close: this is the way out.
                                SettingsRow(systemImage: "xmark.circle", title: "Cancel sign-in") { flow?.cancel() }
                            }
                            #endif
                        }
                        SettingsRow(systemImage: "chart.bar", title: "Manage usage", showsChevron: true) {
                            openURL(ChatGPTOAuth.usageURL)
                        }
                    }
                    if let status {
                        Text(status).font(DS.Typography.uiCaption)
                            .foregroundStyle(statusIsError ? theme.destructive : theme.textSecondary)
                    }

                    GroupedSection(header: "Connection") {
                        SettingsFieldRow(title: "Name", prompt: "Name", text: Binding(
                            get: { connection.name },
                            set: { value in
                                guard var c = connections.connection(connectionID) else { return }
                                c.name = value
                                connections.upsert(c)
                            }))
                    }

                    GroupedSection(header: "Models", footer: fetchStatus.map { LocalizedStringKey($0) }) {
                        ForEach(connection.models) { model in
                            SettingsRow(modelID: model.id, alias: connection.alias(forModel: model.id) ?? model.fetchedDisplayName,
                                        subtitle: connection.showsInPicker(model.id)
                                            ? model.capabilitiesSummary
                                            : [String(localized: "Hidden"), model.capabilitiesSummary].compactMap { $0 }.joined(separator: " · "),
                                        value: model.effectiveContextLength(default: AppSettings.defaultContextLength).formatted(),
                                        showsChevron: true) { editingModel = model.id }
                        }
                        SettingsRow(systemImage: "arrow.down.circle", title: fetching ? "Fetching…" : "Fetch models") {
                            Task { await fetch() }
                        }
                        .disabled(fetching || !signedIn)
                    }

                    GroupedSection {
                        SettingsRow(systemImage: "trash", title: "Delete connection", isDestructive: true) {
                            flow?.cancel()
                            Task {
                                await connections.chatGPT.signOut(connectionID: connectionID)
                                connections.delete(connectionID)
                            }
                            path.removeAll()
                        }
                    }
                }
                .padding(DS.Spacing.lg)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(connection.name)
            .inlineNavigationTitle()
            .onAppear(perform: reload)
            .onDisappear { flow?.cancel() }
            .sheet(item: Binding(get: { editingModel.map { ModelRef(id: $0) } }, set: { editingModel = $0?.id })) { ref in
                ModelEditor(connectionID: connectionID, modelID: ref.id)
            }
        }
    }

    private struct ModelRef: Identifiable { let id: String }

    private var accountFooter: LocalizedStringKey {
        if signedIn && planAllowed == false {
            return "This sign-in didn't allow Strata to use your ChatGPT plan, so requests will be refused. Sign out and sign in again, and allow plan usage."
        }
        return "Uses your ChatGPT plan. Requests count toward its usage limits. The sign-in is stored in the Keychain."
    }

    private func reload() {
        signedIn = connections.isChatGPTSignedIn(connectionID)
        registration = connections.chatGPTRegistration(connectionID)
        planAllowed = connections.chatGPTAllowsPlanUsage(connectionID)
    }

    private func show(_ text: String?, error: Bool = false) {
        status = text
        statusIsError = error
    }

    private func signIn() async {
        let flow = ChatGPTSignIn(connectionID: connectionID, auth: connections.chatGPT)
        self.flow = flow
        show(nil)
        defer { self.flow = nil }
        do {
            let account = try await flow.run()
            reload()
            if let name = account.name ?? account.email, var c = connections.connection(connectionID),
               c.name == String(localized: "ChatGPT") {
                c.name = "ChatGPT (\(name))"
                connections.upsert(c)
            }
            if planAllowed == false {
                show(String(localized: "Signed in, but plan usage wasn't allowed."), error: true)
            } else {
                await fetch()
            }
        } catch ChatGPTAuthError.cancelled {
            show(nil)
        } catch {
            reload()
            show(error.localizedDescription, error: true)
        }
    }

    private func signOut() async {
        working = true
        defer { working = false }
        let confirmed = await connections.chatGPT.signOut(connectionID: connectionID)
        reload()
        show(confirmed ? String(localized: "Signed out.")
                       : String(localized: "Signed out on this device, but ChatGPT didn't confirm it. You can disconnect Strata in ChatGPT Settings."),
             error: !confirmed)
    }

    private func fetch() async {
        fetching = true
        defer { fetching = false }
        do {
            let n = try await connections.refreshModels(for: connectionID)
            fetchStatus = String(localized: "Fetched \(n) models.")
        } catch {
            reload()
            fetchStatus = error.localizedDescription
        }
    }
}
