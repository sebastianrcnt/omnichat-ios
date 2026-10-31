import SwiftUI

/// Settings > Connections > a ChatGPT account: the signed-in account, sign-in and sign-out, and the account's models.
/// No base URL, headers, API key or resumable replies: the connection always talks to the Responses API with the
/// account's OAuth token. Being added (`draft`), the sign-in is kept under the draft's id and the rest stays in the
/// draft; on Add, an account that is already connected goes to that connection (`ConnectionStore.add`).
struct ChatGPTConnectionEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.connectionStore) private var connections
    @Environment(\.openURL) private var openURL
    let connectionID: UUID
    @Binding var path: [UUID]
    var draft: ConnectionDraft?

    @State private var signedIn = false
    @State private var registration: ChatGPTRegistration?
    @State private var planAllowed: Bool?
    @State private var flow: ChatGPTSignIn?
    @State private var working = false
    @State private var status: String?
    @State private var statusIsError = false
    @State private var fetching = false
    /// The one-time "You're using your ChatGPT plan" welcome (`ChatGPTPlanUsage.claimWelcome`).
    @State private var showsWelcome = false

    /// This editor's fetch, or one from launch still running.
    private var fetchingModels: Bool { fetching || connections.modelFetches[connectionID]?.running == true }
    @State private var editingModel: String?

    private var connection: Connection? { connections.connection(connectionID, draft: draft) }

    var body: some View {
        if let connection {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    // Signed out, the section offers the plan: the guidelines' heading and sign-in label.
                    GroupedSection(header: signedIn ? "ChatGPT account" : "Use your ChatGPT plan", footer: accountFooter) {
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
                            SettingsRow(systemImage: "person.badge.key", title: flow == nil ? "Continue with ChatGPT" : "Signing in…") {
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
                        // Near the account and its plan, as the guidelines ask of a usage page.
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
                                flow?.cancel()
                                Task {
                                    await connections.chatGPT.signOut(connectionID: connectionID)
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
            .onAppear(perform: reload)
            .onDisappear { flow?.cancel() }
            .sheet(item: Binding(get: { editingModel.map { ModelRef(id: $0) } }, set: { editingModel = $0?.id })) { ref in
                ModelEditor(connectionID: connectionID, modelID: ref.id, draft: draft)
            }
            .alert("You're using your ChatGPT plan", isPresented: $showsWelcome) {
                Button("Manage usage") { openURL(ChatGPTOAuth.usageURL) }
                Button("Got it", role: .cancel) {}
            } message: {
                Text("Eligible requests in OmniChat use your ChatGPT plan and count toward its usage limits. You can manage usage in ChatGPT settings.")
            }
        }
    }

    private struct ModelRef: Identifiable { let id: String }

    private var accountFooter: LocalizedStringKey {
        if signedIn && planAllowed == false {
            return "This sign-in didn't allow OmniChat to use your ChatGPT plan, so requests will be refused. Sign out and sign in again, and allow plan usage."
        }
        return "Eligible requests use your ChatGPT plan and count toward its usage limits, which you manage in ChatGPT settings. The sign-in is stored in the Keychain."
    }

    private func reload() {
        signedIn = connections.isChatGPTSignedIn(connectionID)
        registration = connections.chatGPTRegistration(connectionID)
        planAllowed = connections.chatGPTAllowsPlanUsage(connectionID)
        if let draft { connections.checkSignIn(draft) }
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
            // An account another connection already has keeps that one: the sign-in moves there and this one goes, and
            // the editor shows that one instead. A draft waits for Add to do that.
            let id = draft == nil ? connections.finishChatGPTSignIn(connectionID) : connectionID
            if id != connectionID {
                if let i = path.lastIndex(of: connectionID) { path[i] = id } else { path.append(id) }
                if connections.chatGPTAllowsPlanUsage(id) != false { try? await connections.refreshModels(for: id) }
                return
            }
            reload()
            if let name = account.name ?? account.email, connection?.name == String(localized: "ChatGPT") {
                connections.edit(connectionID, draft: draft) { $0.name = "ChatGPT (\(name))" }
            }
            if planAllowed == false {
                show(String(localized: "Signed in, but plan usage wasn't allowed."), error: true)
            } else {
                if ChatGPTPlanUsage.claimWelcome(planAllowed: planAllowed == true) {
                    // Once the sign-in sheet has gone: an alert asked for while it closes is never shown.
                    Task { try? await Task.sleep(for: .milliseconds(600)); showsWelcome = true }
                }
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
                       : String(localized: "Signed out on this device, but ChatGPT didn't confirm it. You can disconnect OmniChat in ChatGPT Settings."),
             error: !confirmed)
    }

    private func fetch() async {
        fetching = true
        defer { fetching = false }
        // How it went shows in the Models footer (`ConnectionStore.modelFetches`).
        do { try await connections.refreshModels(for: connectionID, draft: draft) } catch { reload() }
    }
}
