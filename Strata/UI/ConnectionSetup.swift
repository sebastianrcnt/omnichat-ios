import SwiftUI

/// The editor for a connection: ChatGPT and OpenCode accounts have their own, every other connection (Anthropic too)
/// the server editor. A connection being added (`draft`) opens in the same editor, with Cancel and Add in place of the
/// back button, like a new contact: its changes stay in the draft, and only Add saves it.
struct ConnectionDestination: View {
    @Environment(\.connectionStore) private var connections
    let connectionID: UUID
    @Binding var path: [UUID]
    var draft: ConnectionDraft?
    /// After Add saved the draft (true) or Cancel was pressed (false). Whoever holds the draft discards it.
    var onFinish: (Bool) -> Void = { _ in }

    @State private var addError: String?

    var body: some View {
        editor
            .navigationBarBackButtonHidden(draft != nil)
            .toolbar {
                if let draft {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onFinish(false) } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { add(draft) }.disabled(!draft.canAdd)
                    }
                }
            }
            .alert("Couldn't add the connection", isPresented: Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: addError ?? "")
            }
    }

    @ViewBuilder
    private var editor: some View {
        let connection = connections.connection(connectionID, draft: draft)
        if connection?.isChatGPT == true {
            ChatGPTConnectionEditor(connectionID: connectionID, path: $path, draft: draft)
        } else if connection?.isOpenCode == true {
            OpenCodeConnectionEditor(connectionID: connectionID, path: $path, draft: draft)
        } else if connection?.isAppleOnDevice == true {
            OnDeviceConnectionEditor(connectionID: connectionID, path: $path, draft: draft)
        } else {
            ConnectionEditor(connectionID: connectionID, path: $path, draft: draft)
        }
    }

    private func add(_ draft: ConnectionDraft) {
        do {
            guard let id = try connections.add(draft) else { return }
            // Added before its models were fetched (or while a fetch still runs): they come in the background.
            if let c = connections.connection(id), c.models.isEmpty, connections.modelFetches[draft.id]?.running != true,
               connections.canRefreshModels(c) {
                Task { try? await connections.refreshModels(for: id) }
            }
            onFinish(true)
        } catch {
            addError = error.localizedDescription
        }
    }
}

/// A link the app was opened with, waiting for its confirmation sheet.
@MainActor
@Observable
final class ConnectionLinks {
    static let shared = ConnectionLinks()

    struct Pending: Identifiable {
        let id = UUID()
        let result: Result<AddConnectionLink, AddConnectionLink.Failure>
    }

    var pending: Pending?

    /// Takes an `omnichat://add-connection` link; false for any other URL.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard AddConnectionLink.isAddLink(url) else { return false }
        pending = Pending(result: AddConnectionLink.parse(url))
        return true
    }
}

/// Opens `omnichat://add-connection` links in their confirmation sheet, at the root of the window. A sheet that is open
/// (`closing`, Settings on the phone) is closed first: one sheet can't open on top of another from the root.
private struct ConnectionLinkHandler: ViewModifier {
    @Environment(\.theme) private var theme
    @Binding var closing: Bool
    @State private var links = ConnectionLinks.shared
    @State private var shown: ConnectionLinks.Pending?

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in links.receive(url) }
            .onChange(of: links.pending?.id, initial: true) { _, id in
                guard id != nil, let pending = links.pending else { return }
                links.pending = nil
                Task { @MainActor in
                    if closing || shown != nil {
                        closing = false
                        shown = nil
                        try? await Task.sleep(for: .milliseconds(600)) // let the open sheet go away first
                    }
                    shown = pending
                }
            }
            .sheet(item: $shown) { pending in
                ConnectionSetupSheet(start: .link(pending.result))
                    .inAppLinks()
                    .environment(\.theme, theme)
            }
    }
}

extension View {
    /// Handles add-connection links opened with the app (see `ConnectionLinkHandler`).
    func connectionLinks(closing: Binding<Bool>) -> some View { modifier(ConnectionLinkHandler(closing: closing)) }
}

/// Adds a connection: a list of services to start from (first run, Settings), or the confirmation of an add-connection
/// link. Either way the new connection then opens in its editor, which asks for the key or the sign-in, as a draft
/// (`ConnectionDraft`): Add saves it and closes the sheet; Cancel goes back to where it was picked (or closes the
/// sheet when it opened on the editor), and nothing of it is left.
struct ConnectionSetupSheet: View {
    enum Start {
        case presets
        /// Straight into the editor of this new connection, not saved until Add (a first-run shortcut).
        case editor(Connection)
        case link(Result<AddConnectionLink, AddConnectionLink.Failure>)
    }

    /// The sheet asked for, with where it starts: shown with `.sheet(item:)`, so it opens on the start it was asked
    /// with (a start kept apart from an `isPresented` flag can be read before it is set).
    struct Request: Identifiable {
        let id = UUID()
        let start: Start
    }

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.connectionStore) private var connections
    let start: Start

    @State private var path: [UUID]
    /// The connection being added, open in its editor. Kept after it is discarded so the editor still has it while it
    /// slides away.
    @State private var draft: ConnectionDraft?

    init(start: Start) {
        self.start = start
        if case .editor(let connection) = start {
            let draft = ConnectionDraft(connection)
            _draft = State(initialValue: draft)
            _path = State(initialValue: [draft.id])
        } else {
            _path = State(initialValue: [])
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    switch start {
                    case .presets, .editor: presets
                    case .link(.success(let link)): confirmation(link)
                    case .link(.failure(let failure)): rejected(failure)
                    }
                }
                .padding(DS.Spacing.lg)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .navigationDestination(for: UUID.self) { id in
                ConnectionDestination(connectionID: id, path: $path, draft: draft?.id == id ? draft : nil) { added in
                    if added { dismiss() } else if case .editor = start { dismiss() } else { path = [] }
                }
            }
        }
        .presentationBackground(theme.background)
        #if os(macOS)
        .frame(width: 520, height: 620)
        #endif
        // Closing the sheet, or leaving the editor any way but Add, drops the draft.
        .onDisappear { discardDraft() }
        .onChange(of: path) { _, now in if let draft, !now.contains(draft.id) { discardDraft() } }
    }

    /// Opens a new connection in its editor, as a draft.
    private func open(_ connection: Connection) {
        discardDraft()
        let new = ConnectionDraft(connection)
        draft = new
        path = [new.id]
    }

    private func discardDraft() {
        guard let draft, draft.isOpen else { return }
        Task { await connections.discard(draft) }
    }

    private var title: LocalizedStringKey {
        switch start {
        case .presets, .editor: "Add a connection"
        case .link: "Add this connection?"
        }
    }

    // MARK: Presets

    private var presets: some View {
        Group {
            Text("Pick the service OmniChat talks to. You'll enter its API key or sign in next. Keys stay in the Keychain on this device.")
                .font(DS.Typography.ui)
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, DS.Spacing.lg)
            Link("Privacy Policy", destination: URL(string: "https://sebastianrcnt.github.io/omnichat-ios/privacy/")!)
                .padding(.horizontal, DS.Spacing.lg)
            OnDeviceOfferSection { open(.appleOnDevice(name: String(localized: "Apple Intelligence"))) }
            let builtIn = PackageStore.shared.package(id: BuiltInPackages.connections)?.manifest.connections ?? []
            GroupedSection(header: "With an API key") {
                row(.anthropic)
                ForEach(builtIn.filter { !$0.isLocal }) { row($0) }
            }
            GroupedSection(header: "On your computer", footer: localFooter) {
                ForEach(builtIn.filter(\.isLocal)) { row($0) }
            }
            // Installed packages' presets, under each package's name. Picking one goes through the same editor.
            ForEach(PackageStore.shared.all.filter { !$0.isBuiltIn && !$0.manifest.connections.isEmpty }) { package in
                GroupedSection(header: LocalizedStringKey(package.name)) {
                    ForEach(package.manifest.connections) { row($0) }
                }
            }
            GroupedSection(header: "With an account") {
                ForEach(ConnectionPreset.accounts) { row($0) }
            }
            GroupedSection(footer: "Anything that speaks the OpenAI API: vLLM, llama.cpp, LiteLLM, a company gateway.") {
                row(.custom)
            }
        }
    }

    private var localFooter: LocalizedStringKey {
        #if os(macOS)
        "The server has to be running. To use it from an iPhone too, start it so it listens on the network."
        #else
        "localhost is this iPhone. For a server on your Mac, put the Mac's address on your Wi-Fi in the URL (like http://192.168.1.20:11434/v1) and start the server so it listens on the network."
        #endif
    }

    private func row(_ preset: PackageConnectionPreset) -> some View {
        SettingsRow(systemImage: preset.systemImage, title: "", subtitle: preset.subtitleText, showsChevron: true,
                    verbatimTitle: preset.name) { open(preset.makeConnection()) }
    }

    private func row(_ preset: ConnectionPreset) -> some View {
        SettingsRow(systemImage: preset.systemImage, title: "", subtitle: preset.subtitle, showsChevron: true,
                    verbatimTitle: preset.title) { open(preset.makeConnection()) }
    }

    // MARK: Link

    private func confirmation(_ link: AddConnectionLink) -> some View {
        Group {
            Text("A link asks to add this server. Add it only if you trust where the link came from: what you send in chats goes to this server.")
                .font(DS.Typography.ui)
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, DS.Spacing.lg)
            GroupedSection {
                SettingsRow(title: "Name", value: link.name)
                SettingsRow(title: "", verbatimTitle: String(localized: "Server"), detail: link.baseURL.absoluteString)
                if link.anthropic {
                    SettingsRow(title: "API", value: String(localized: "Anthropic Messages"))
                } else {
                    SettingsRow(title: "API", value: link.api?.title ?? String(localized: "Automatic"))
                    SettingsRow(title: "Images", value: link.images ? String(localized: "On") : String(localized: "Off"))
                    SettingsRow(title: "Reasoning effort", value: link.effort ? String(localized: "On") : String(localized: "Off"))
                    SettingsRow(title: "Resumable replies", value: link.resumable ? String(localized: "On") : String(localized: "Off"))
                }
            }
            ForEach(warnings(link), id: \.self) { warning in
                Label { Text(verbatim: warning) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.warning)
                    .padding(.horizontal, DS.Spacing.lg)
            }
            GroupedSection(footer: "You'll enter the API key next. Links never carry keys.") {
                // Nothing is saved before the editor's Add: backing out of it leaves the link to add again.
                SettingsRow(systemImage: "plus", title: "Add connection") { open(link.makeConnection()) }
            }
        }
    }

    private func warnings(_ link: AddConnectionLink) -> [String] {
        var list: [String] = []
        if link.isPlainHTTP {
            list.append(String(localized: "This server uses http: the API key and your messages travel unencrypted."))
        }
        if link.isPrivateAddress {
            list.append(String(localized: "This is a local or private network address. It only works where that network is reachable."))
        }
        if link.droppedKey {
            list.append(String(localized: "The link included an API key. It was ignored: enter the key yourself."))
        }
        return list
    }

    private func rejected(_ failure: AddConnectionLink.Failure) -> some View {
        Label { Text(verbatim: failure.localizedDescription) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .font(DS.Typography.ui)
            .foregroundStyle(theme.destructive)
            .padding(.horizontal, DS.Spacing.lg)
    }
}

/// Shown in an empty chat while there is no connection: the three ways to start, as buttons.
struct NoConnectionState: View {
    @Environment(\.theme) private var theme
    /// Opens Sign in with ChatGPT.
    let onChatGPT: () -> Void
    /// Opens "Add a connection" (API keys, servers, everything else).
    let onAdd: () -> Void
    /// Adds the on-device connection; nil hides the offer (the device can't run it).
    var onUseOnDevice: (() -> Void)?

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            Text("Connect a model to start")
                .font(DS.Typography.title)
                .foregroundStyle(theme.textPrimary)
            Text("Use the models you already have: your ChatGPT plan, an API key, or a server on your network. Web search, Python and your own servers are built in.")
                .font(DS.Typography.ui)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            VStack(spacing: DS.Spacing.sm) {
                Button(action: onChatGPT) {
                    Text("Continue with ChatGPT").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(theme.accent)
                Button(action: onAdd) {
                    Text("Use an API key or server").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                if let onUseOnDevice {
                    Button(action: onUseOnDevice) {
                        Label("Try Apple Intelligence (free)", systemImage: "apple.intelligence")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
            .controlSize(.large)
            .padding(.top, DS.Spacing.sm)
            .frame(maxWidth: 320)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
