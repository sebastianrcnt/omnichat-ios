import SwiftUI

/// Settings > Health: the switches for `health_query`, what it shares, and which connections would receive it.
struct HealthSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.appSettings) private var settings
    @Environment(\.connectionStore) private var connections
    @AppStorage(HealthSettings.localOnlyKey) private var localOnly = false

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                if blocked { syncSection }

                GroupedSection(header: "Apple Health", footer: "The assistant can read the Apple Health data you allow, to answer questions about your own health and fitness. It never writes to Health. iOS asks the first time a chat reads each type; change it any time in the Settings app > Health > Data Access & Devices > OmniChat. A chat turns Apple Health on or off from the + menu.") {
                    SettingsToggleRow(title: "Apple Health in new chats", isOn: $settings.healthEnabled)
                    SettingsToggleRow(title: "Only send health data to on-device or local models",
                                      subtitle: "Chats whose model runs on a remote server can't read Health, and a chat that read Health can't be sent to one.", isOn: $localOnly)
                }
                .disabled(blocked)

                GroupedSection(header: "What's shared", footer: "Health data is not sent to OmniChat's developer and not used for advertising. Debug bundles leave it out. The answers stay in your chats on this device until you delete them. Health data never goes to iCloud: Apple Health can't be used while chat sync is on.") {
                    SettingsRow(title: "Only what a question needs",
                                subtitle: String(localized: "When the assistant reads Health, the summary it reads (daily totals, nights of sleep, workouts) goes to the chat's model connection with your message, and stays in that chat."))
                    SettingsRow(title: "Not medical advice",
                                subtitle: String(localized: "The assistant is told not to diagnose, and to suggest a healthcare professional when values look concerning."))
                }

                GroupedSection(header: "Where it goes", footer: "Local means a model on this device, or a server on your own network or tailnet (localhost, private and Tailscale addresses, .local and .ts.net names). Each chat sends to the connection it uses.") {
                    if connections.connections.isEmpty { SettingsRow(title: "No connections yet") }
                    ForEach(connections.connections) { connection in
                        let local = HealthPrivacy.isLocal(ToolDestination(connection))
                        SettingsRow(title: "", subtitle: status(local: local), verbatimTitle: connection.name,
                                    detail: connection.kind == .appleOnDevice ? nil : URL(string: connection.baseURL)?.host(percentEncoded: false))
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Health")
        .inlineNavigationTitle()
    }

    /// Apple Health and chat sync exclude each other (`HealthSettings.blockedBySync`). Observed through `CloudSync`.
    private var blocked: Bool { CloudSync.shared.chatSyncSwitch || CloudSync.shared.chatsSyncing }

    /// Shown while chat sync blocks Health: the way out, and whether it waits for a relaunch.
    private var syncSection: some View {
        let switchOn = CloudSync.shared.chatSyncSwitch
        return GroupedSection(header: "Off while chat sync is on",
                              footer: switchOn
                                  ? "Chats sync through iCloud on this device, and health data never goes to iCloud. Turn off chat sync to use Apple Health; this device's chats stay, and stop syncing the next time OmniChat opens."
                                  : "Chat sync is off. Close and reopen OmniChat to use Apple Health.") {
            if switchOn {
                SettingsRow(systemImage: "icloud.slash", title: "Turn Off Chat Sync") { CloudSync.shared.chatSyncSwitch = false }
            } else {
                SettingsRow(systemImage: "arrow.clockwise", title: "Applies when OmniChat reopens")
            }
        }
    }

    private func status(local: Bool) -> String {
        if local { return String(localized: "Local: can read Health") }
        return localOnly ? String(localized: "Remote server: Health is blocked") : String(localized: "Remote server: receives Health data in chats that read it")
    }
}
