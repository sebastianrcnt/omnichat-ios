import SwiftUI

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(ConnectionStore.self) private var connections

    @State private var path: [UUID] = []
    @State private var showDiagnostics = false
    @State private var showLicenses = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    GroupedSection(header: "Connections", footer: "Any OpenAI-compatible endpoint. API keys are stored in the Keychain.") {
                        ForEach(connections.connections) { c in
                            SettingsRow(title: LocalizedStringKey(c.name), subtitle: c.baseURL,
                                        value: c.models.isEmpty ? nil : String(localized: "\(c.models.count) models"),
                                        showsChevron: true) { path.append(c.id) }
                        }
                        SettingsRow(systemImage: "plus", title: "Add connection") {
                            let new = Connection(name: String(localized: "New connection"), baseURL: "https://")
                            connections.upsert(new)
                            path.append(new.id)
                        }
                    }

                    TextSizeSection()

                    GroupedSection(header: "Accent color") {
                        accentRow
                        ColorPicker(selection: $settings.accent, supportsOpacity: false) {
                            Text("Custom color").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                        }
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.sm)
                    }

                    GroupedSection(header: "Streaming") {
                        SettingsToggleRow(title: "Smooth streaming",
                                          subtitle: "Reveal text at a steady pace instead of in bursts.",
                                          isOn: $settings.smoothStreaming)
                    }

                    GroupedSection(header: "Web tools", footer: "How much of a page web_fetch returns per call. Longer pages continue in further calls.") {
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
                    }

                    GroupedSection(header: "Context", footer: "Used for the context ring when a model does not report its context length.") {
                        SettingsFieldRow(title: "Default length", prompt: "262144",
                                         text: Binding(
                                            get: { String(settings.defaultContextLength) },
                                            set: { settings.defaultContextLength = Int($0.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil } ?? AppSettings.defaultContextLength }),
                                         keyboard: .numberPad)
                    }

                    GroupedSection(header: "About") {
                        SettingsRow(systemImage: "doc.text", title: "Licenses", showsChevron: true) { showLicenses = true }
                    }

                    GroupedSection(header: "Developer", footer: "Memory, storage, caches and recent requests, with a bundle you can save and share.") {
                        SettingsToggleRow(title: "Developer mode", isOn: $settings.developerMode)
                        if settings.developerMode {
                            SettingsRow(systemImage: "gauge.with.dots.needle.50percent", title: "Diagnostics", showsChevron: true) { showDiagnostics = true }
                        }
                    }
                }
                .padding(DS.Spacing.lg)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: UUID.self) { id in
                ConnectionEditor(connectionID: id, path: $path)
            }
            .navigationDestination(isPresented: $showDiagnostics) { AppDiagnosticsView() }
            .navigationDestination(isPresented: $showLicenses) { LicensesView() }
        }
        .presentationBackground(theme.background)
        #if DEBUG
        .task {
            if DebugHooks.openSheet == "diagnostics" { settings.developerMode = true; showDiagnostics = true }
            if DebugHooks.openSheet == "licenses" { showLicenses = true }
        }
        #endif
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

// MARK: - Connection editor

struct ConnectionEditor: View {
    @Environment(\.theme) private var theme
    @Environment(ConnectionStore.self) private var connections
    let connectionID: UUID
    @Binding var path: [UUID]

    @State private var apiKeyText = ""
    @State private var hasKey = false
    @State private var fetchStatus: String?
    @State private var fetching = false
    @State private var manualModel = ""
    @State private var keyError: String?
    @State private var editingModel: String?

    private var connection: Connection? { connections.connection(connectionID) }

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
                    GroupedSection(header: "Connection") {
                        SettingsFieldRow(title: "Name", prompt: "Name", text: binding(\.name, fallback: ""))
                        SettingsFieldRow(title: "Base URL", prompt: "https://host/v1", text: binding(\.baseURL, fallback: ""),
                                         keyboard: .URL)
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
                            SettingsRow(systemImage: "xmark.circle", title: "Remove key", isDestructive: true) { removeKey() }
                        }
                    }
                    if let keyError {
                        Text(keyError).font(DS.Typography.uiCaption).foregroundStyle(theme.destructive)
                    }

                    GroupedSection(header: "System prompt", footer: "Sent as the first message. Leave empty to send none. The default asks for [N] citations and tells the model not to invent ids.") {
                        SettingsFieldRow(title: "Prompt", prompt: "None", text: binding(\.systemPrompt, fallback: ""), multiline: true)
                        SettingsRow(systemImage: "arrow.counterclockwise", title: "Reset to default") {
                            var c = connection
                            c.systemPrompt = DefaultPrompts.citation
                            connections.upsert(c)
                        }
                    }

                    GroupedSection(header: "Models", footer: fetchStatus.map { LocalizedStringKey($0) }) {
                        ForEach(connection.models) { model in
                            SettingsRow(title: LocalizedStringKey(model.id), subtitle: ModelPickerSheet.capabilities(model),
                                        value: model.effectiveContextLength(default: AppSettings.defaultContextLength).formatted(),
                                        showsChevron: true) { editingModel = model.id }
                        }
                        SettingsRow(systemImage: "arrow.down.circle", title: fetching ? "Fetching…" : "Fetch models") {
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
                            SettingsRow(systemImage: "trash", title: "Delete connection", isDestructive: true) {
                                connections.delete(connectionID)
                                path.removeAll()
                            }
                        }
                    }
                }
                .padding(DS.Spacing.lg)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(connection.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { hasKey = connections.apiKey(for: connectionID) != nil }
            .sheet(item: Binding(get: { editingModel.map { ModelRef(id: $0) } }, set: { editingModel = $0?.id })) { ref in
                ModelEditor(connectionID: connectionID, modelID: ref.id)
            }
        }
    }

    private struct ModelRef: Identifiable { let id: String }

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
        } catch {
            fetchStatus = error.localizedDescription
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
    @Environment(ConnectionStore.self) private var connections
    let connectionID: UUID
    let modelID: String

    private var model: ModelInfo? { connections.connection(connectionID)?.models.first { $0.id == modelID } }

    private func update(_ change: (inout ModelInfo) -> Void) {
        guard var c = connections.connection(connectionID), let i = c.models.firstIndex(where: { $0.id == modelID }) else { return }
        change(&c.models[i])
        connections.upsert(c)
    }

    var body: some View {
        SheetScaffold(title: LocalizedStringKey(modelID)) {
            if let model {
                GroupedSection(header: "Context", footer: model.fetchedContextLength.map { LocalizedStringKey("The server reports \($0.formatted()) tokens. Leave blank to use it.") }) {
                    SettingsFieldRow(title: "Context length",
                                     prompt: LocalizedStringKey(model.fetchedContextLength.map(String.init) ?? String(AppSettings.defaultContextLength)),
                                     text: Binding(get: { model.contextLength.map(String.init) ?? "" },
                                                   set: { text in update { $0.contextLength = Int(text.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil } } }),
                                     keyboard: .numberPad)
                }
                GroupedSection(header: "Capabilities") {
                    SettingsToggleRow(title: "Supports images", isOn: Binding(get: { model.supportsImages }, set: { v in update { $0.supportsImages = v; $0.supportsImagesUserSet = true } }))
                    SettingsToggleRow(title: "Supports reasoning effort", subtitle: "Sends reasoning_effort with each request.",
                                      isOn: Binding(get: { model.supportsEffort }, set: { v in update { $0.supportsEffort = v } }))
                    SettingsToggleRow(title: "Supports tools", subtitle: "Sends the web_search and web_fetch tools.",
                                      isOn: Binding(get: { model.supportsTools }, set: { v in update { $0.supportsTools = v } }))
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
    }
}
