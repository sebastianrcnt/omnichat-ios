import SwiftUI
import UniformTypeIdentifiers

/// Settings > SSH: the switches, saved servers and credentials, known hosts, and the servers whose commands run
/// without asking.
struct SSHSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.appSettings) private var settings
    @AppStorage(SSHApprovalPolicy.askKey) private var asks = true
    @State private var route: Route?

    private var store: SSHStore { .shared }

    enum Route: Hashable {
        case server(String?)
        case credential(String?)
    }

    var body: some View {
        @Bindable var settings = settings
        let _ = SSHStoreVersion.shared.value // redraw when something is saved or deleted
        let servers = store.servers, credentials = store.credentials, hosts = store.knownHosts, allowed = store.alwaysAllowed
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                GroupedSection(header: "SSH", footer: "The model can run commands and move files on your servers over SSH, and save the passwords and keys you give it in the Keychain on this device. A chat turns SSH on or off from the + menu. Each command connects anew; a connection drops soon after OmniChat leaves the screen.") {
                    SettingsToggleRow(title: "SSH in new chats", isOn: $settings.sshEnabled)
                    SettingsToggleRow(title: "Ask before running commands", subtitle: "Approve each command and upload, or always allow a server.",
                                      isOn: $asks)
                }

                GroupedSection(header: "Servers") {
                    ForEach(servers) { server in
                        SettingsRow(title: "", subtitle: server.credential.map { String(localized: "Credential: \($0)") },
                                    showsChevron: true, verbatimTitle: server.name, detail: server.address) { route = .server(server.name) }
                    }
                    SettingsRow(systemImage: "plus", title: "Add server") { route = .server(nil) }
                }

                GroupedSection(header: "Credentials", footer: "Passwords, private keys and answers, kept in the Keychain. The model can read them.") {
                    ForEach(credentials) { credential in
                        SettingsRow(title: "", subtitle: credential.summary, showsChevron: true, verbatimTitle: credential.name,
                                    detail: credential.username) { route = .credential(credential.name) }
                    }
                    SettingsRow(systemImage: "plus", title: "Add credential") { route = .credential(nil) }
                }

                GroupedSection(header: "Known hosts", footer: "Each server's host key is saved the first time OmniChat connects; a different key later stops the connection. Reset a host after reinstalling it.") {
                    if hosts.isEmpty { SettingsRow(title: "None yet") }
                    ForEach(hosts) { host in
                        HStack(spacing: DS.Spacing.md) {
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text(verbatim: host.hostPort).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                                Text(verbatim: "\(SSHKeyFormat.shortName(host.type)) \(host.fingerprint)")
                                    .font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                                    .lineLimit(1).truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: DS.Spacing.sm)
                            Button("Reset") { try? store.forgetHost(host.hostPort) }.buttonStyle(.quietLink(.accent))
                        }
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.sm)
                    }
                }

                GroupedSection(header: "Always allowed", footer: "Commands on these run without asking (\"Always for this server\").") {
                    if allowed.isEmpty { SettingsRow(title: "None") }
                    ForEach(allowed, id: \.self) { target in
                        HStack {
                            Text(verbatim: target).font(DS.Typography.ui).foregroundStyle(theme.textPrimary).lineLimit(1)
                            Spacer(minLength: DS.Spacing.sm)
                            Button("Revoke") { try? store.setAlwaysAllowed(false, target: target) }.buttonStyle(.quietLink(.accent))
                        }
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.sm)
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("SSH")
        .inlineNavigationTitle()
        .navigationDestination(item: $route) { route in
            switch route {
            case .server(let name): SSHServerEditor(name: name)
            case .credential(let name): SSHCredentialEditor(name: name)
            }
        }
    }
}

// MARK: - Server

private struct SSHServerEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let name: String?

    @State private var draft = SSHServer(name: "", host: "", user: "")
    @State private var port = "22"
    @State private var jump = ""
    @State private var note = ""
    @State private var error: String?
    @State private var test: TestState = .idle
    @State private var confirmDelete = false
    @State private var loaded = false
    @State private var addingCredential = false

    enum TestState: Equatable { case idle, running, ok(String), failed(String) }

    private var store: SSHStore { .shared }
    private static let testCall = "settings-test"

    var body: some View {
        let credentials = store.credentials.map(\.name)
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                GroupedSection(header: "Server") {
                    SettingsFieldRow(title: "Name", prompt: "nas", text: $draft.name)
                    SettingsFieldRow(title: "Host", prompt: "192.168.0.10", text: $draft.host, keyboard: .url)
                    SettingsFieldRow(title: "Port", prompt: "22", text: $port, keyboard: .number)
                    SettingsFieldRow(title: "User", prompt: "admin", text: $draft.user)
                    HStack {
                        Text("Credential").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                        Spacer()
                        // A menu rather than a picker, so a new credential can be made right here and picked.
                        Menu {
                            Picker("Credential", selection: $draft.credential) {
                                Text("None").tag(String?.none)
                                ForEach(credentials, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                            }
                            Divider()
                            Button("Add credential…", systemImage: "plus") { addingCredential = true }
                        } label: {
                            HStack(spacing: DS.Spacing.xxs) {
                                if let credential = draft.credential { Text(verbatim: credential) } else { Text("None") }
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .medium))
                            }
                            .font(DS.Typography.ui)
                            .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                    SettingsFieldRow(title: "Jump hosts", prompt: "bastion, user@host:22", text: $jump)
                    SettingsFieldRow(title: "Note", prompt: "Optional", text: $note, multiline: true)
                }
                if let error {
                    Text(verbatim: error).font(DS.Typography.uiCaption).foregroundStyle(theme.destructive)
                }

                GroupedSection {
                    SettingsRow(systemImage: "checkmark.circle", title: "Save") { save() }
                        .disabled(test == .running)
                    SettingsRow(systemImage: "bolt.horizontal", title: test == .running ? "Testing…" : "Test connection") { Task { await runTest() } }
                        .disabled(test == .running || draft.host.isEmpty || draft.user.isEmpty)
                }
                switch test {
                case .ok(let text):
                    Label { Text(verbatim: text) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent) }
                        .font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                case .failed(let text):
                    Label { Text(verbatim: text) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.destructive) }
                        .font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                case .idle, .running:
                    EmptyView()
                }
                if let request = SSHRequests.shared.pending(conversation: nil).first(where: { $0.callID == Self.testCall }) {
                    SSHRequestCard(request: request)
                        .padding(DS.Spacing.lg)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
                }

                if name != nil {
                    GroupedSection {
                        SettingsRow(systemImage: "trash", title: "Delete server", isDestructive: true) { confirmDelete = true }
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(name ?? String(localized: "New server"))
        .inlineNavigationTitle()
        .onAppear(perform: load)
        .sheet(isPresented: $addingCredential) {
            NavigationStack {
                SSHCredentialEditor(name: nil, suggestedUser: draft.user, onSave: { draft.credential = $0 })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { addingCredential = false } }
                    }
            }
        }
        .confirmationDialog("Delete \(name ?? "")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete server", role: .destructive) {
                if let name { try? store.deleteServer(name) }
                dismiss()
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let name, let server = store.server(named: name) else { return }
        draft = server
        port = String(server.port)
        jump = server.jump.joined(separator: ", ")
        note = server.note ?? ""
    }

    private var edited: SSHServer {
        var s = draft
        s.port = Int(port.trimmingCharacters(in: .whitespaces)) ?? 0
        s.jump = jump.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        s.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        return s
    }

    private func save() {
        do {
            let server = edited
            try store.save(server)
            if let name, name != server.name {
                try? store.deleteServer(name)
            }
            error = nil
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runTest() async {
        test = .running
        let s = edited
        var values = ["host": s.host, "user": s.user, "port": String(s.port), "jump": s.jump.joined(separator: ",")]
        if let credential = s.credential { values["credential"] = credential }
        let store = store
        do {
            let target = try SSHTargetResolver.resolve(SSHArguments(values), store: store)
            let client = SSHClient(checkHostKey: { try store.check($0) }, prompt: { request in
                await SSHRequests.shared.askPrompt(request, conversation: nil, callID: Self.testCall)
            })
            let (key, method) = try await client.test(target.hops)
            test = .ok(String(localized: "Connected. Signed in with \(method). Host key \(SSHKeyFormat.shortName(key.type)) \(key.fingerprint)."))
        } catch {
            test = .failed((error as? SSHError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

// MARK: - Credential

private struct SSHCredentialEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let name: String?
    /// A new credential made from a server's page starts with its user, and is picked for it once saved.
    var suggestedUser = ""
    var onSave: ((String) -> Void)?

    @State private var draft = SSHCredential(name: "", kind: .password)
    @State private var password = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var certificate = ""
    @State private var answers = ""
    @State private var username = ""
    @State private var note = ""
    @State private var revealKey = false
    @State private var revealAnswers = false
    @State private var importing = false
    @State private var generating = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var loaded = false

    private var store: SSHStore { .shared }
    private var keyInfo: SSHKeyInfo? { SSHKeyFormat.inspect(privateKey) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                GroupedSection(header: "Credential") {
                    SettingsFieldRow(title: "Name", prompt: "nas-admin", text: $draft.name)
                    SettingsFieldRow(title: "User", prompt: "Optional", text: $username)
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(SSHCredential.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                }

                switch draft.kind {
                case .password:
                    GroupedSection(header: "Password") {
                        SettingsFieldRow(title: "Password", prompt: "Required", text: $password, isSecure: true)
                    }
                case .privateKey:
                    keySection
                case .keyboardInteractive:
                    GroupedSection(header: "Answers", footer: "One answer per line, in the order the server asks. A prompt with no answer here is asked in the chat.") {
                        if revealAnswers {
                            TextField("", text: $answers, prompt: Text("Answers"), axis: .vertical)
                                .lineLimit(2...8)
                                .font(DS.Typography.mono)
                                .plainTextInput()
                                .unbezeledField()
                                .padding(.horizontal, DS.Spacing.lg)
                                .padding(.vertical, DS.Spacing.md)
                        } else {
                            SettingsRow(title: "", value: answers.isEmpty ? nil : SSHMask.dots, verbatimTitle: String(localized: "\(answers.split(separator: "\n").count) answers"))
                        }
                        SettingsRow(systemImage: revealAnswers ? "eye.slash" : "eye", title: revealAnswers ? "Hide" : "Show and edit") { revealAnswers.toggle() }
                    }
                }

                GroupedSection(header: "Note") {
                    SettingsFieldRow(title: "Note", prompt: "Optional", text: $note, multiline: true)
                }

                if let error {
                    Text(verbatim: error).font(DS.Typography.uiCaption).foregroundStyle(theme.destructive)
                }
                GroupedSection {
                    SettingsRow(systemImage: "checkmark.circle", title: "Save") { save() }
                    if name != nil {
                        SettingsRow(systemImage: "trash", title: "Delete credential", isDestructive: true) { confirmDelete = true }
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(name ?? String(localized: "New credential"))
        .inlineNavigationTitle()
        .onAppear(perform: load)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text, .item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8), SSHKeyFormat.isPrivateKey(text) else {
                error = String(localized: "That file isn't a private key OmniChat can read.")
                return
            }
            privateKey = text
            if draft.name.isEmpty { draft.name = url.lastPathComponent }
            error = nil
        }
        .confirmationDialog("Delete \(name ?? "")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete credential", role: .destructive) {
                if let name { try? store.deleteCredential(name) }
                dismiss()
            }
        } message: {
            Text("Servers that use it can't sign in until they get another.")
        }
    }

    private var keySection: some View {
        GroupedSection(header: "Private key", footer: "Paste the key (from -----BEGIN to -----END), import its file, or generate a new one here and add its public key to ~/.ssh/authorized_keys on the server.") {
            if revealKey || privateKey.isEmpty {
                TextField("", text: $privateKey, prompt: Text(verbatim: "-----BEGIN OPENSSH PRIVATE KEY-----"), axis: .vertical)
                    .lineLimit(3...12)
                    .font(DS.Typography.monoSmall)
                    .plainTextInput()
                    .unbezeledField()
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.md)
            }
            if !privateKey.isEmpty {
                SettingsRow(systemImage: revealKey ? "eye.slash" : "eye",
                            title: revealKey ? "Hide key" : "Show key",
                            subtitle: keyInfo?.summary ?? String(localized: "Not a key OmniChat can read")) { revealKey.toggle() }
            }
            SettingsRow(systemImage: "doc", title: "Import file…") { importing = true }
            SettingsRow(systemImage: "key", title: generating ? "Generating…" : "Generate ED25519 key") { generate(.ed25519) }
                .disabled(generating)
            SettingsRow(systemImage: "key", title: "Generate RSA 4096 key") { generate(.rsa) }
                .disabled(generating)
            if keyInfo?.encrypted == true || !passphrase.isEmpty {
                SettingsFieldRow(title: "Passphrase", prompt: "Required to use it", text: $passphrase, isSecure: true)
            }
            SettingsFieldRow(title: "Certificate", prompt: "Optional …-cert-v01@openssh.com line", text: $certificate, multiline: true)
            if let pub = keyInfo?.publicKey ?? draft.publicKey {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("Public key").font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                    Text(verbatim: pub).font(DS.Typography.monoSmall).foregroundStyle(theme.textPrimary)
                        .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    Button("Copy public key") { Pasteboard.copy(pub) }.buttonStyle(.quietLink(.accent))
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let name, let c = store.credential(named: name) else {
            username = suggestedUser
            return
        }
        draft = c
        password = c.password ?? ""
        privateKey = c.privateKey ?? ""
        passphrase = c.passphrase ?? ""
        certificate = c.certificate ?? ""
        answers = (c.answers ?? []).joined(separator: "\n")
        username = c.username ?? ""
        note = c.note ?? ""
    }

    private func generate(_ type: SSHKeyGenerator.KeyType) {
        generating = true
        let comment = draft.name.isEmpty ? "omnichat" : draft.name
        Task {
            do {
                let key = try await Task.detached(priority: .userInitiated) { try SSHKeyGenerator.generate(type, comment: comment) }.value
                privateKey = key.privateKey
                passphrase = ""
                draft.publicKey = key.publicKey
                draft.kind = .privateKey
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            generating = false
        }
    }

    private func save() {
        var c = draft
        func value(_ s: String) -> String? { s.isEmpty ? nil : s }
        c.username = value(username.trimmingCharacters(in: .whitespaces))
        c.note = value(note.trimmingCharacters(in: .whitespacesAndNewlines))
        c.password = value(password)
        c.privateKey = c.kind == .privateKey ? value(privateKey) : nil
        c.passphrase = c.kind == .privateKey ? value(passphrase) : nil
        c.certificate = c.kind == .privateKey ? value(certificate.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        let lines = answers.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        c.answers = c.kind == .keyboardInteractive && !lines.isEmpty ? lines : nil
        if c.kind == .privateKey, let pub = keyInfo?.publicKey { c.publicKey = pub }
        if c.kind != .privateKey { c.publicKey = nil }
        do {
            try store.save(c)
            if let name, name != c.name { try? store.deleteCredential(name) }
            error = nil
            onSave?(c.name)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
