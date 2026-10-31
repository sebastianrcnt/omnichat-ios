import SwiftUI

/// Settings > Connections > Apple Intelligence: whether the on-device model can run here (and what to do if not),
/// what it can do, and the web tools switch. No key, address or model list: there is one model, the system's. Being
/// added (`draft`), it needs nothing more: Add is on from the start.
struct OnDeviceConnectionEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.connectionStore) private var connections
    let connectionID: UUID
    @Binding var path: [UUID]
    var draft: ConnectionDraft?

    @State private var availability = OnDevice.system.availability

    private var connection: Connection? { connections.connection(connectionID, draft: draft) }

    var body: some View {
        if let connection {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    GroupedSection(header: "On this device", footer: "Apple's on-device model answers without an API key or an account. Your messages never leave this device, and it works offline. It's a small model with a short memory: good for quick questions, rewriting and summaries. For long chats or hard questions, use a larger model.") {
                        SettingsRow(systemImage: availability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle",
                                    title: "", subtitle: availability.isAvailable ? nil : availability.message,
                                    verbatimTitle: availability.shortStatus)
                    }

                    if let model = connection.models.first {
                        GroupedSection(header: "Model", footer: "Web search and page reading send your search terms and the pages' addresses to the web; the model itself still runs on this device. Older turns of a long chat are left out to fit the model's context.") {
                            SettingsRow(title: "", subtitle: capabilities(model),
                                        value: String(localized: "\(model.effectiveContextLength(default: OnDevice.fallbackContextSize).formatted()) tokens"),
                                        verbatimTitle: connection.displayName(forModel: model.id))
                            SettingsToggleRow(title: "Web search", subtitle: "Lets the model search the web and read pages.",
                                              isOn: Binding(get: { model.supportsTools }, set: { on in setTools(on) }))
                        }
                    }

                    GroupedSection(header: "Connection") {
                        SettingsFieldRow(title: "Name", prompt: "Name", text: Binding(
                            get: { connection.name },
                            set: { value in connections.edit(connectionID, draft: draft) { $0.name = value } }))
                    }

                    if draft == nil {
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
            .inlineNavigationTitle()
            .onAppear {
                availability = OnDevice.system.availability
                if let draft {
                    connections.edit(connectionID, draft: draft) { c in
                        c.models = [OnDevice.modelInfo(OnDevice.system, keeping: c.models.first { $0.id == OnDevice.modelID })]
                    }
                } else {
                    connections.refreshOnDeviceModels()
                }
            }
        }
    }

    /// "Text only · Web search" or "Images · Web search".
    private func capabilities(_ model: ModelInfo) -> String {
        var parts = [model.supportsImages ? String(localized: "Images") : String(localized: "Text only")]
        if model.supportsTools { parts.append(String(localized: "Web search")) }
        return parts.joined(separator: " · ")
    }

    private func setTools(_ on: Bool) {
        connections.edit(connectionID, draft: draft) { c in
            if let i = c.models.firstIndex(where: { $0.id == OnDevice.modelID }) { c.models[i].supportsTools = on }
        }
    }
}

/// "Apple Intelligence · Free, private, on this device": the first choice in "Add a connection" and on the first-run
/// screen, on a device that supports it.
struct OnDeviceOfferSection: View {
    @Environment(\.connectionStore) private var connections
    /// Opens the new connection's editor (as a draft: `ConnectionDraft`).
    var onPick: () -> Void

    var body: some View {
        let availability = OnDevice.system.availability
        if OnDevice.offersConnection(availability: availability, connections: connections.connections) {
            GroupedSection(header: "On this device", footer: availability.isAvailable
                           ? "No API key or account. Your messages stay on this device, and it works offline."
                           : LocalizedStringKey(availability.message)) {
                SettingsRow(systemImage: "apple.intelligence", title: "", subtitle: String(localized: "Free, private, on this device"),
                            showsChevron: true, verbatimTitle: String(localized: "Apple Intelligence")) {
                    onPick()
                }
            }
        }
    }
}
