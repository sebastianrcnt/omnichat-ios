import SwiftUI
import Translation

/// A connection Settings should open on, set by whoever opens Settings for it (the model picker's "Set up").
@MainActor
@Observable
final class SettingsRoute {
    static let shared = SettingsRoute()
    var connection: UUID?
}

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appSettings) private var settings
    @Environment(\.connectionStore) private var connections

    @State private var path: [UUID] = []
    @State private var showDiagnostics = false
    @State private var showCookies = false
    @State private var showLicenses = false
    @State private var showAppearance = false
    @State private var showTools = false
    @State private var showChats = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    GroupedSection(header: "Connections", footer: "A server with an OpenAI-compatible API, your ChatGPT plan, or your OpenCode account. API keys and sign-ins are stored in the Keychain.") {
                        ForEach(connections.connections) { c in
                            SettingsRow(title: LocalizedStringKey(c.name), subtitle: subtitle(for: c),
                                        value: c.models.isEmpty ? nil : String(localized: "\(c.models.count) models"),
                                        showsChevron: true) { path.append(c.id) }
                        }
                        SettingsRow(systemImage: "plus", title: "Add OpenAI-compatible server") {
                            let new = Connection(name: String(localized: "New connection"), baseURL: "https://")
                            connections.upsert(new)
                            path.append(new.id)
                        }
                        SettingsRow(systemImage: "person.badge.plus", title: "Add ChatGPT account") {
                            let new = Connection.chatGPT(name: String(localized: "ChatGPT"))
                            connections.upsert(new)
                            path.append(new.id)
                        }
                        SettingsRow(systemImage: "person.badge.plus", title: "Add OpenCode account") {
                            let new = Connection.openCode(name: String(localized: "OpenCode"))
                            connections.upsert(new)
                            path.append(new.id)
                        }
                    }
                    .onAppear { connections.removeUnconfigured() }
                    .onChange(of: path) { _, now in if now.isEmpty { connections.removeUnconfigured() } }

                    GroupedSection(header: "Personalization", footer: "How the assistant should behave and respond: personality, tone, a name, how long answers should be. Sent with every message. A chat keeps the preferences it started with; changes apply to new chats.") {
                        TextField("", text: $settings.userPreferences,
                                  prompt: Text("For example: Be concise and casual. Skip the pleasantries."), axis: .vertical)
                            .lineLimit(3...12)
                            .font(DS.Typography.ui)
                            .foregroundStyle(theme.textPrimary)
                            .unbezeledField()
                            .padding(.horizontal, DS.Spacing.lg)
                            .padding(.vertical, DS.Spacing.md)
                    }

                    GroupedSection {
                        SettingsRow(systemImage: "textformat.size", title: "Appearance", subtitle: "Text size, color, streaming and thinking",
                                    showsChevron: true) { showAppearance = true }
                        SettingsRow(systemImage: "wrench.and.screwdriver", title: "Tools", subtitle: "Web, plugins, Python and the browser",
                                    showsChevron: true) { showTools = true }
                        SettingsRow(systemImage: "bubble.left.and.text.bubble.right", title: "Chats",
                                    subtitle: "Answers, notifications, dictation and context", showsChevron: true) { showChats = true }
                    }

                    GroupedSection(header: "About") {
                        SettingsRow(systemImage: "doc.text", title: "Licenses", showsChevron: true) { showLicenses = true }
                    }

                    GroupedSection(header: "Developer", footer: "Memory, storage, caches and recent requests, with a bundle you can save and share.") {
                        SettingsToggleRow(title: "Developer mode", isOn: $settings.developerMode)
                        if settings.developerMode {
                            SettingsRow(systemImage: "gauge.with.dots.needle.50percent", title: "Diagnostics", showsChevron: true) { showDiagnostics = true }
                            SettingsRow(systemImage: "list.bullet.rectangle", title: "Browser cookies", showsChevron: true) { showCookies = true }
                        }
                    }
                }
                .padding(DS.Spacing.lg)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .inlineNavigationTitle()
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .trailingBar) { Button("Done") { dismiss() } }
            }
            #endif
            .navigationDestination(for: UUID.self) { id in
                if connections.connection(id)?.isChatGPT == true {
                    ChatGPTConnectionEditor(connectionID: id, path: $path)
                } else if connections.connection(id)?.isOpenCode == true {
                    OpenCodeConnectionEditor(connectionID: id, path: $path)
                } else {
                    ConnectionEditor(connectionID: id, path: $path)
                }
            }
            .navigationDestination(isPresented: $showDiagnostics) { AppDiagnosticsView() }
            .navigationDestination(isPresented: $showCookies) { BrowserCookiesView() }
            .navigationDestination(isPresented: $showLicenses) { LicensesView() }
            .onChange(of: SettingsRoute.shared.connection, initial: true) { _, id in
                guard let id else { return }
                SettingsRoute.shared.connection = nil
                if connections.connection(id) != nil { path = [id] }
            }
            .navigationDestination(isPresented: $showAppearance) { AppearanceSettingsView() }
            .navigationDestination(isPresented: $showTools) { ToolSettingsView() }
            .navigationDestination(isPresented: $showChats) { ChatSettingsView() }
        }
        .presentationBackground(theme.background)
        #if DEBUG
        .task {
            if DebugHooks.openSheet == "diagnostics" { settings.developerMode = true; showDiagnostics = true }
            if DebugHooks.openSheet == "licenses" { showLicenses = true }
            if DebugHooks.openSheet == "connection" { // what "Add connection" does
                let new = Connection(name: String(localized: "New connection"), baseURL: "https://")
                connections.upsert(new)
                path.append(new.id)
            }
        }
        #endif
    }

    /// The base URL, or for a ChatGPT account the signed-in email, or for an OpenCode account its plan.
    private func subtitle(for c: Connection) -> String {
        if c.isOpenCode {
            guard connections.isOpenCodeSignedIn(c.id) else { return String(localized: "OpenCode · Signed out") }
            return "OpenCode · \((c.openCodeGateway ?? .go).title)"
        }
        guard c.isChatGPT else { return String(localized: "OpenAI-compatible · \(c.baseURL)") }
        guard connections.isChatGPTSignedIn(c.id) else { return String(localized: "ChatGPT · Signed out") }
        return connections.chatGPTRegistration(c.id)?.email.map { "ChatGPT · \($0)" } ?? String(localized: "ChatGPT")
    }
}

// MARK: - Connection editor

struct ConnectionEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.connectionStore) private var connections
    let connectionID: UUID
    @Binding var path: [UUID]

    @State private var apiKeyText = ""
    @State private var hasKey = false
    @State private var fetchStatus: String?
    @State private var fetching = false

    /// This editor's fetch, or one from launch still running.
    private var fetchingModels: Bool { fetching || connections.modelFetches[connectionID]?.running == true }
    @State private var manualModel = ""
    @State private var keyError: String?
    @State private var editingModel: String?
    @State private var confirmDelete = false
    @State private var confirmRemoveKey = false
    /// The last fetch failed (its message is `fetchStatus`).
    @State private var fetchFailed = false

    private var connection: Connection? { connections.connection(connectionID) }

    /// Where the connection stands, at the top of the editor: no key yet, the last fetch's error, or how many models.
    private var status: (text: String, symbol: String, ok: Bool) {
        if fetching { return (String(localized: "Checking…"), "arrow.triangle.2.circlepath", true) }
        if fetchFailed, let fetchStatus { return (fetchStatus, "exclamationmark.triangle.fill", false) }
        guard hasKey else { return (String(localized: "Add an API key to use this server"), "key", false) }
        let n = connection?.models.count ?? 0
        return n == 0 ? (String(localized: "Key saved · no models yet"), "checkmark.circle", true)
                      : (String(localized: "Connected · \(n) models"), "checkmark.circle.fill", true)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Connection, T>, fallback: T) -> Binding<T> {
        Binding(get: { connection?[keyPath: keyPath] ?? fallback },
                set: { value in
                    guard var c = connection else { return }
                    c[keyPath: keyPath] = value
                    connections.upsert(c)
                })
    }

    var body: some View {
        if let connection {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    GroupedSection {
                        HStack(spacing: DS.Spacing.md) {
                            Image(systemName: status.symbol).foregroundStyle(status.ok ? theme.accent : theme.destructive)
                            Text(verbatim: status.text).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Test") { Task { await fetch() } }
                                .disabled(fetching || !hasKey)
                        }
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.md)
                    }

                    GroupedSection(header: "Connection", footer: plainHTTPWarning) {
                        SettingsFieldRow(title: "Name", prompt: "Name", text: binding(\.name, fallback: ""))
                        SettingsFieldRow(title: "Base URL", prompt: "https://host/v1", text: binding(\.baseURL, fallback: ""),
                                         keyboard: .url)
                        SettingsFieldRow(title: "Headers", prompt: "Name: value", text: binding(\.customHeaders, fallback: ""),
                                         multiline: true)
                    }

                    GroupedSection(header: "Stream recovery") {
                        SettingsToggleRow(title: "Resumable replies", subtitle: "Enable only for gateways supporting Strata stream replay.", isOn: binding(\.supportsResumable, fallback: false))
                    }

                    GroupedSection(header: "API key", footer: hasKey ? "A key is saved in the Keychain. Enter a new one to replace it." : "Pasted keys are stored in the Keychain, never in the app's files.") {
                        SettingsFieldRow(title: "Key", prompt: hasKey ? "Saved" : "sk-…", text: $apiKeyText, isSecure: true)
                        SettingsRow(systemImage: "key", title: "Save key") { saveKey() }
                            .disabled(apiKeyText.trimmingCharacters(in: .whitespaces).isEmpty)
                        if hasKey {
                            SettingsRow(systemImage: "xmark.circle", title: "Remove key", isDestructive: true) { confirmRemoveKey = true }
                        }
                    }
                    if let keyError {
                        Text(keyError).font(DS.Typography.uiCaption).foregroundStyle(theme.destructive)
                    }

                    GroupedSection(header: "Models", footer: connections.modelFetches[connectionID]?.footer.map { LocalizedStringKey($0) }) {
                        ForEach(connection.models) { model in
                            SettingsRow(modelID: model.id, alias: connection.alias(forModel: model.id),
                                        subtitle: connection.modelRowSubtitle(model),
                                        value: model.effectiveContextLength(default: AppSettings.defaultContextLength).formatted(),
                                        showsChevron: true) { editingModel = model.id }
                        }
                        SettingsRow(systemImage: "arrow.down.circle", title: fetchingModels ? "Fetching…" : "Fetch models") {
                            Task { await fetch() }
                        }
                        .disabled(fetching)
                        HStack {
                            SettingsFieldRow(title: "Add model", prompt: "model-id", text: $manualModel)
                            Button("Add") { addManual() }
                                .disabled(manualModel.trimmingCharacters(in: .whitespaces).isEmpty)
                                .padding(.trailing, DS.Spacing.lg)
                        }
                    }

                    if !connection.isStrata {
                        GroupedSection {
                            SettingsRow(systemImage: "trash", title: "Delete connection", isDestructive: true) { confirmDelete = true }
                        }
                    }
                }
                .padding(DS.Spacing.lg)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(connection.name)
            .inlineNavigationTitle()
            .onAppear { hasKey = connections.apiKey(for: connectionID) != nil }
            .confirmationDialog("Delete \(connection.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete connection", role: .destructive) {
                    connections.delete(connectionID)
                    path.removeAll()
                }
            } message: {
                Text("Its saved key is removed too. Chats that used it stay.")
            }
            .confirmationDialog("Remove the API key?", isPresented: $confirmRemoveKey, titleVisibility: .visible) {
                Button("Remove key", role: .destructive) { removeKey() }
            }
            .sheet(item: Binding(get: { editingModel.map { ModelRef(id: $0) } }, set: { editingModel = $0?.id })) { ref in
                ModelEditor(connectionID: connectionID, modelID: ref.id)
            }
        }
    }

    private struct ModelRef: Identifiable { let id: String }

    /// Plain http to a host outside the local network sends the API key unencrypted. Local servers (a Mac on the same
    /// Wi-Fi, Tailscale) are the usual reason for http, so those aren't flagged.
    private var plainHTTPWarning: LocalizedStringKey? {
        guard let url = connection?.normalizedBaseURL, url.scheme?.lowercased() == "http",
              let host = url.host(percentEncoded: false) else { return nil }
        if URLGuard.isBlockedHostname(host) || URLGuard.isIPLiteralPrivate(host) { return nil }
        return "This server uses http, so the API key and your messages travel unencrypted. Use https if the server supports it."
    }

    private func saveKey() {
        do {
            try connections.setAPIKey(apiKeyText, for: connectionID)
            apiKeyText = ""
            hasKey = connections.apiKey(for: connectionID) != nil
            keyError = nil
            Task { await fetch() } // a new key usually means models can now be listed
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeKey() {
        try? connections.setAPIKey(nil, for: connectionID)
        hasKey = false
    }

    private func fetch() async {
        fetching = true
        defer { fetching = false }
        do {
            let n = try await connections.refreshModels(for: connectionID)
            fetchStatus = String(localized: "Fetched \(n) models.")
            fetchFailed = false
        } catch {
            fetchStatus = error.localizedDescription
            fetchFailed = true
        }
    }

    private func addManual() {
        let id = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = connection, !id.isEmpty, !c.models.contains(where: { $0.id == id }) else { return }
        var m = c.defaultModel(id: id, fetchedContextLength: nil)
        m.isManual = true
        c.models.append(m)
        connections.upsert(c)
        manualModel = ""
    }
}

struct ModelEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.connectionStore) private var connections
    let connectionID: UUID
    let modelID: String

    private var model: ModelInfo? { connections.connection(connectionID)?.models.first { $0.id == modelID } }
    /// Edited here and saved trimmed, so typing a space between words is not undone mid-edit.
    @State private var aliasText = ""

    private func update(_ change: (inout ModelInfo) -> Void) {
        guard var c = connections.connection(connectionID), let i = c.models.firstIndex(where: { $0.id == modelID }) else { return }
        change(&c.models[i])
        connections.upsert(c)
    }

    var body: some View {
        SheetScaffold(title: LocalizedStringKey(modelID)) {
            if let model {
                GroupedSection(header: "Display name", footer: "Shown instead of the model id in the app. Requests still use the id. Leave blank to show the id.") {
                    SettingsFieldRow(title: "Display name", prompt: LocalizedStringKey(modelID), text: $aliasText)
                }
                GroupedSection(footer: "Off keeps this model out of the composer's model menu. A chat already using it keeps it.") {
                    SettingsToggleRow(title: "Show in picker",
                                      isOn: Binding(get: { connections.connection(connectionID)?.showsInPicker(modelID) ?? true },
                                                    set: { connections.setModelShownInPicker($0, connectionID: connectionID, modelID: modelID) }))
                }
                GroupedSection(header: "Context", footer: model.fetchedContextLength.map { LocalizedStringKey("The server reports \($0.formatted()) tokens. Leave blank to use it.") }) {
                    SettingsFieldRow(title: "Context length",
                                     prompt: LocalizedStringKey(model.fetchedContextLength.map(String.init) ?? String(AppSettings.defaultContextLength)),
                                     text: Binding(get: { model.contextLength.map(String.init) ?? "" },
                                                   set: { text in update { $0.contextLength = Int(text.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil } } }),
                                     keyboard: .number)
                }
                GroupedSection(header: "Capabilities") {
                    SettingsToggleRow(title: "Supports images", isOn: Binding(get: { model.supportsImages }, set: { v in update { $0.supportsImages = v; $0.supportsImagesUserSet = true } }))
                    SettingsToggleRow(title: "Supports reasoning effort", subtitle: "Sends reasoning_effort with each request.",
                                      isOn: Binding(get: { model.supportsEffort }, set: { v in update { $0.supportsEffort = v } }))
                    SettingsToggleRow(title: "Supports tools", subtitle: "Lets the model use web search, Python, the browser and plugins.",
                                      isOn: Binding(get: { model.supportsTools }, set: { v in update { $0.supportsTools = v } }))
                }
                if connections.connection(connectionID)?.kind == .openAICompatible {
                    ModelAPISection(connectionID: connectionID, modelID: modelID)
                }
                if model.isManual {
                    GroupedSection {
                        SettingsRow(systemImage: "trash", title: "Remove model", isDestructive: true) {
                            if var c = connections.connection(connectionID) {
                                c.models.removeAll { $0.id == modelID }
                                connections.upsert(c)
                            }
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { aliasText = connections.connection(connectionID)?.alias(forModel: modelID) ?? "" }
        .onChange(of: aliasText) { _, text in
            let capped = String(text.prefix(ModelAlias.maxLength))
            if capped != text { aliasText = capped; return }
            connections.setModelAlias(text, connectionID: connectionID, modelID: modelID)
        }
    }
}

/// The API an OpenAI-compatible model is talked to with: Automatic (Chat Completions, switching to the Responses API when
/// the server says the model needs it) or one picked by hand.
private struct ModelAPISection: View {
    @Environment(\.theme) private var theme
    @Environment(\.connectionStore) private var connections
    let connectionID: UUID
    let modelID: String

    private var connection: Connection? { connections.connection(connectionID) }

    private var footer: LocalizedStringKey {
        guard let connection else { return "" }
        if let picked = connection.modelAPIOverrides[modelID] {
            return picked == .responses
                ? "Requests always use the Responses API. Replies through it can't be resumed."
                : "Requests always use Chat Completions."
        }
        if connection.detectedModelAPIs[modelID] == .responses {
            return "Using the Responses API: this model refused Chat Completions and answered there."
        }
        return "Using Chat Completions. Switches to the Responses API if the server says this model needs it."
    }

    var body: some View {
        GroupedSection(header: "API", footer: footer) {
            HStack {
                Text("API").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                Spacer()
                Picker("API", selection: Binding(get: { connection?.modelAPIOverrides[modelID] },
                                                 set: { connections.setModelAPIOverride($0, connectionID: connectionID, modelID: modelID) })) {
                    Text("Automatic").tag(ChatAPI?.none)
                    ForEach(ChatAPI.allCases, id: \.self) { Text($0.title).tag(ChatAPI?.some($0)) }
                }
                .labelsHidden()
                .tint(theme.textSecondary)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
        }
    }
}

/// Settings > Browser: the browser tools on or off, and whether they include `current_location`.
struct BrowserSettingsSection: View {
    @Environment(\.appSettings) private var settings

    var body: some View {
        @Bindable var settings = settings
        GroupedSection(header: "Browser", footer: "The model can open pages in a hidden browser on this device with browser_open and run JavaScript in them with browser_eval. It can't reach your local network. When the model needs you to sign in, it shows you the page; the sign-in is kept for later. Skills teach the model tasks like finding places on Naver; it saves new ones only when you approve.") {
            SettingsToggleRow(title: "Browser", subtitle: "Let the model browse sites and read data from them.", isOn: $settings.browserEnabled)
            if settings.browserEnabled {
                SettingsToggleRow(title: "Location", subtitle: "Let the model ask for your approximate location to find places near you.",
                                  isOn: $settings.locationEnabled)
            }
            NavigationLink { SkillsSettingsView() } label: {
                SettingsRow(systemImage: "book.closed", title: "Skills", showsChevron: true)
            }
            .buttonStyle(.plain)
        }
        .onChange(of: settings.browserEnabled) { _, on in if !on { BrowserSessions.shared.closeAll() } }
    }
}

/// Settings > Python: on/off, the time limit of one run, and the packages downloaded so far.
struct PythonSettingsSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.appSettings) private var settings
    @State private var packageBytes: Int64?

    var body: some View {
        @Bindable var settings = settings
        GroupedSection(header: "Python", footer: "The model can run Python code on this device with run_python (Pyodide \(Pyodide.version)). Packages such as numpy, sympy and pandas are downloaded the first time they are used and kept for later.") {
            SettingsToggleRow(title: "Python", subtitle: "Let the model run code and make charts.", isOn: $settings.pythonEnabled)
            if settings.pythonEnabled {
                HStack {
                    Text("Python time limit").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Picker("Python time limit", selection: $settings.pythonTimeLimit) {
                        ForEach(PythonSettings.timeLimitOptions, id: \.self) { Text(PythonSettings.label(seconds: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .tint(theme.textSecondary)
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.sm)
            }
            HStack {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text("Downloaded packages").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                    Text(verbatim: packageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                        .font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Button("Clear") { clear() }
                    .disabled((packageBytes ?? 0) == 0)
                    .tint(theme.accent)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
        }
        .onChange(of: settings.pythonEnabled) { _, on in if !on { PythonRuntime.shared.dispose() } }
        .task { await measure() }
    }

    private func measure() async {
        packageBytes = await Task.detached(priority: .utility) {
            PyodidePackageCache(directory: Pyodide.packagesRoot).size
        }.value
    }

    private func clear() {
        PythonRuntime.shared.dispose() // a running interpreter may hold loaded packages; the next one fetches again
        PyodidePackageCache(directory: Pyodide.packagesRoot).clear()
        Task { await measure() }
    }
}

/// How thought lines look: how many lines they take, and whether English thinking shows in Korean.
private struct ThinkingSettingsSection: View {
    @Environment(\.appSettings) private var settings
    @Environment(\.theme) private var theme
    @State private var status: LanguageAvailability.Status?
    @State private var download: TranslationSession.Configuration?

    var body: some View {
        @Bindable var settings = settings
        GroupedSection(header: "Thinking", footer: footer) {
            HStack {
                Text("Lines").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                Spacer()
                Picker("Lines", selection: $settings.thinkingLines) {
                    ForEach(AppSettings.thinkingLineOptions, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .tint(theme.textSecondary)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
            SettingsToggleRow(title: "Translate English thinking",
                              subtitle: "Show the model's English thinking in Korean, translated on this device.",
                              isOn: $settings.translateThinking)
            if settings.translateThinking, status == .supported {
                Button {
                    var next = ThoughtTranslator.downloadConfiguration
                    if download == next { next.invalidate() }
                    download = next
                } label: {
                    Text("Download English–Korean").font(DS.Typography.ui).foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.sm)
            }
        }
        .task(id: settings.translateThinking) { status = await ThoughtTranslator.systemStatus() }
        .translationTask(download) { session in
            await SessionTranslator(session).prepare()
            ThoughtTranslator.shared.recheck()
            status = await ThoughtTranslator.systemStatus()
        }
    }

    private var footer: LocalizedStringKey {
        guard settings.translateThinking else { return "How many lines a thought may take while the model works and after." }
        switch status {
        case .installed: return "Finished sentences are translated as the model thinks. Thinking in other languages shows as written."
        case .supported: return "Download the English–Korean language to translate thinking. Until then it shows as written."
        case .unsupported: return "This device can't translate English to Korean."
        default: return "Checking the translation languages…"
        }
    }
}

/// Settings > Appearance.
private struct AppearanceSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.appSettings) private var settings

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                #if os(iOS)
                TextSizeSection() // a Mac has no Dynamic Type: text there keeps the size it is designed at
                #endif

                GroupedSection(header: "Accent color") {
                    accentRow
                    ColorPicker(selection: $settings.accent, supportsOpacity: false) {
                        Text("Custom color").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                }

                GroupedSection(header: "Streaming") {
                    SettingsToggleRow(title: "Smooth streaming",
                                      subtitle: "Reveal text at a steady pace instead of in bursts.",
                                      isOn: $settings.smoothStreaming)
                }

                ThinkingSettingsSection()
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Appearance")
        .inlineNavigationTitle()
    }

    private var accentRow: some View {
        HStack(spacing: DS.Spacing.md) {
            ForEach(AccentPreset.all) { preset in
                let selected = settings.accentHex.caseInsensitiveCompare(preset.hex) == .orderedSame
                Button { settings.accentHex = preset.hex } label: {
                    Circle().fill(Color(hex: preset.hex))
                        .frame(width: DS.IconSize.lg + DS.Spacing.sm, height: DS.IconSize.lg + DS.Spacing.sm)
                        .overlay {
                            if selected { Image(systemName: "checkmark").font(.system(size: DS.IconSize.sm, weight: .bold)).foregroundStyle(theme.onAccent) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(preset.name))
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Settings > Tools.
private struct ToolSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.appSettings) private var settings

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                GroupedSection(header: "Web tools", footer: "Auto searches Naver for Korean queries and Bing otherwise. If the engine fails or finds nothing, the next one is tried. web_fetch returns up to the fetch length per call; longer pages continue in further calls.") {
                    HStack {
                        Text("Search engine").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Picker("Search engine", selection: $settings.searchEngine) {
                            ForEach(SearchEnginePreference.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .tint(theme.textSecondary)
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                    HStack {
                        Text("Fetch length").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Picker("Fetch length", selection: $settings.fetchLength) {
                            ForEach(AppSettings.fetchLengthOptions, id: \.self) { Text("\($0 / 1000)k characters").tag($0) }
                        }
                        .labelsHidden()
                        .tint(theme.textSecondary)
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                    HStack {
                        Text("Page timeout").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Picker("Page timeout", selection: $settings.fetchPatience) {
                            ForEach(FetchPatience.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .tint(theme.textSecondary)
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                }

                GroupedSection(header: "Plugins", footer: "Site plugins the model can run with run_plugin. A plugin that is on is listed in the system prompt.") {
                    if PluginRegistry.bundled.plugins.isEmpty {
                        SettingsRow(title: "No plugins")
                    }
                    ForEach(PluginRegistry.bundled.plugins) { plugin in
                        // Interpolated, so names and descriptions show as written (no Markdown).
                        SettingsToggleRow(title: "\(plugin.name)", subtitle: "\(plugin.manifest.description)",
                                          isOn: Binding(
                                            get: { settings.enabledPlugins.contains(plugin.name) },
                                            set: { on in
                                                if on { settings.enabledPlugins.insert(plugin.name) } else { settings.enabledPlugins.remove(plugin.name) }
                                            }))
                    }
                }

                PythonSettingsSection()

                BrowserSettingsSection()
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Tools")
        .inlineNavigationTitle()
    }
}

/// Settings > Chats.
private struct ChatSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.appSettings) private var settings
    @State private var lengthText = ""

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                GroupedSection(header: "Answers", footer: "If the model searches and then stops without writing anything, it is asked once more for the answer. Tapping a notification opens its chat.") {
                    SettingsToggleRow(title: "Continue when the answer is empty", isOn: $settings.continueOnEmptyAnswer)
                    SettingsToggleRow(title: "Notify when a reply finishes",
                                      subtitle: "When Strata is in the background: the chat's title and the start of the answer.",
                                      isOn: $settings.notifyReplies)
                    SettingsToggleRow(title: "Generate chat titles",
                                      subtitle: "After the first answer, ask the model for a short title.",
                                      isOn: $settings.generateTitles)
                }

                GroupedSection(header: "Dictation", footer: "The language the microphone in the composer listens for. Speech in another language comes out garbled.") {
                    HStack {
                        Text("Language").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Picker("Language", selection: $settings.dictationLanguage) {
                            ForEach(DictationLanguage.options(), id: \.self) { Text(verbatim: DictationLanguage.name($0)).tag($0) }
                        }
                        .labelsHidden()
                        .tint(theme.textSecondary)
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                }

                GroupedSection(header: "Context", footer: "Used for the context ring when a model does not report its context length. Leave blank for 262144.") {
                    // A draft, so clearing the field to type a new number doesn't snap back to the default.
                    SettingsFieldRow(title: "Default length", prompt: "262144", text: $lengthText, keyboard: .number)
                        .onChange(of: lengthText) { _, text in
                            settings.defaultContextLength = Int(text.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil } ?? AppSettings.defaultContextLength
                        }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Chats")
        .inlineNavigationTitle()
        .onAppear { lengthText = lengthDefault }
    }

    private var lengthDefault: String {
        settings.defaultContextLength == AppSettings.defaultContextLength ? "" : String(settings.defaultContextLength)
    }
}
