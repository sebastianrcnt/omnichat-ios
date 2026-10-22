import SwiftUI

/// The editor for a connection: ChatGPT and OpenCode accounts have their own, every other connection the server editor.
struct ConnectionDestination: View {
    @Environment(\.connectionStore) private var connections
    let connectionID: UUID
    @Binding var path: [UUID]

    var body: some View {
        if connections.connection(connectionID)?.isChatGPT == true {
            ChatGPTConnectionEditor(connectionID: connectionID, path: $path)
        } else if connections.connection(connectionID)?.isOpenCode == true {
            OpenCodeConnectionEditor(connectionID: connectionID, path: $path)
        } else if connections.connection(connectionID)?.isAppleOnDevice == true {
            OnDeviceConnectionEditor(connectionID: connectionID, path: $path)
        } else {
            ConnectionEditor(connectionID: connectionID, path: $path)
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

    /// Takes an `openchat://add-connection` link; false for any other URL.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard AddConnectionLink.isAddLink(url) else { return false }
        pending = Pending(result: AddConnectionLink.parse(url))
        return true
    }
}

/// Opens `openchat://add-connection` links in their confirmation sheet, at the root of the window. A sheet that is open
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
/// link. Either way the new connection then opens in its editor, which asks for the key or the sign-in.
struct ConnectionSetupSheet: View {
    enum Start {
        case presets
        case link(Result<AddConnectionLink, AddConnectionLink.Failure>)
    }

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.connectionStore) private var connections
    let start: Start

    @State private var path: [UUID] = []
    /// The connection the link added, so going back from its editor doesn't offer to add it again.
    @State private var addedFromLink: UUID?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    switch start {
                    case .presets: presets
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
            .navigationDestination(for: UUID.self) { id in ConnectionDestination(connectionID: id, path: $path) }
        }
        .presentationBackground(theme.background)
        #if os(macOS)
        .frame(width: 520, height: 620)
        #endif
        .onDisappear { connections.removeUnconfigured() }
        .onChange(of: path) { _, now in if now.isEmpty { connections.removeUnconfigured() } }
    }

    private var title: LocalizedStringKey {
        switch start {
        case .presets: "Add a connection"
        case .link: "Add this connection?"
        }
    }

    // MARK: Presets

    private var presets: some View {
        Group {
            Text("Pick the service OpenChat talks to. You'll enter its API key or sign in next. Keys stay in the Keychain on this device.")
                .font(DS.Typography.ui)
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, DS.Spacing.lg)
            OnDeviceOfferSection { id in path = [id] }
            GroupedSection(header: "With an API key") {
                ForEach([ConnectionPreset.openAI, .openRouter, .groq]) { row($0) }
            }
            GroupedSection(header: "On your computer", footer: localFooter) {
                ForEach([ConnectionPreset.ollama, .lmStudio]) { row($0) }
            }
            GroupedSection(header: "With an account") {
                ForEach([ConnectionPreset.chatGPT, .openCode]) { row($0) }
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

    private func row(_ preset: ConnectionPreset) -> some View {
        SettingsRow(systemImage: preset.systemImage, title: "", subtitle: preset.subtitle, showsChevron: true,
                    verbatimTitle: preset.title) {
            let new = preset.makeConnection()
            connections.upsert(new)
            path = [new.id]
        }
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
                SettingsRow(title: "API", value: link.api?.title ?? String(localized: "Automatic"))
                SettingsRow(title: "Images", value: link.images ? String(localized: "On") : String(localized: "Off"))
                SettingsRow(title: "Reasoning effort", value: link.effort ? String(localized: "On") : String(localized: "Off"))
                SettingsRow(title: "Resumable replies", value: link.resumable ? String(localized: "On") : String(localized: "Off"))
            }
            ForEach(warnings(link), id: \.self) { warning in
                Label { Text(verbatim: warning) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.warning)
                    .padding(.horizontal, DS.Spacing.lg)
            }
            GroupedSection(footer: "You'll enter the API key next. Links never carry keys.") {
                if let addedFromLink {
                    SettingsRow(systemImage: "checkmark.circle", title: "Added · Open", showsChevron: true) { path = [addedFromLink] }
                } else {
                    SettingsRow(systemImage: "plus", title: "Add connection") {
                        let new = link.makeConnection()
                        connections.upsert(new)
                        addedFromLink = new.id
                        path = [new.id]
                    }
                }
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

/// Shown in an empty chat while there is no connection: what to do first.
struct NoConnectionState: View {
    @Environment(\.theme) private var theme
    /// Adds the on-device connection; nil hides the offer (the device can't run it).
    var onUseOnDevice: (() -> Void)?
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: DS.IconSize.lg))
                .foregroundStyle(theme.textSecondary)
            Text("Add a connection to start")
                .font(DS.Typography.title)
                .foregroundStyle(theme.textPrimary)
            Text("OpenChat talks to the AI service you choose: OpenAI, OpenRouter, Groq, a server on your computer such as Ollama or LM Studio, or your ChatGPT or OpenCode account.")
                .font(DS.Typography.ui)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            if let onUseOnDevice {
                Button(action: onUseOnDevice) {
                    Label("Use Apple Intelligence (free, on device)", systemImage: "apple.intelligence")
                }
                .buttonStyle(.glassProminent)
                .tint(theme.accent)
                .padding(.top, DS.Spacing.sm)
                Button("Add another service", action: onAdd)
                    .buttonStyle(.glass)
            } else {
                Button("Add a connection", action: onAdd)
                    .buttonStyle(.glassProminent)
                    .tint(theme.accent)
                    .padding(.top, DS.Spacing.sm)
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
