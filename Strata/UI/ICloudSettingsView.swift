import SwiftUI

/// Settings > iCloud: the account, the last sync, and what syncs (`CloudSync`).
struct ICloudSettingsView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var sync = CloudSync.shared
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                GroupedSection(header: "iCloud", footer: "Everything syncs through your private iCloud storage, between the devices signed in to your Apple Account. OpenChat's developer never sees it.") {
                    SettingsRow(title: "iCloud account", value: accountStatus)
                    // Without an account every attempt "fails"; that says nothing the account row doesn't.
                    SettingsRow(title: "Last synced",
                                subtitle: sync.account == .available ? sync.lastError.map { String(localized: "Last attempt failed: \($0)") } : nil,
                                value: lastSynced)
                }

                GroupedSection(footer: chatFooter) {
                    SettingsToggleRow(title: "Sync chats and skills",
                                      subtitle: "Messages, images, figures, artifacts and the skills you saved.",
                                      isOn: $sync.chatSyncSwitch)
                    SettingsToggleRow(title: "Sync settings and connections",
                                      subtitle: "Preferences, tool defaults, plugins and your connection list.",
                                      isOn: $sync.settingsSyncSwitch)
                }

                GroupedSection(footer: "API keys, ChatGPT and OpenCode sign-ins, SSH credentials and custom headers. Off, this device keeps its own copy of each one; copies already in iCloud Keychain stay for your other devices.") {
                    SettingsToggleRow(title: "Sync secrets with iCloud Keychain", isOn: $sync.secretSyncSwitch)
                }

                GroupedSection(header: "Stays on this device", footer: "Browser screenshots are not synced: a synced chat shows a placeholder for them. A reply that is still being written finishes on the device that started it.") {
                    SettingsRow(title: "Device settings",
                                subtitle: String(localized: "Text size, notifications, Live Activities, the background sound, dictation, Apple Health, developer mode and the model you last picked."))
                    SettingsRow(title: "On-device model",
                                subtitle: String(localized: "Each device has its own Apple Intelligence connection."))
                    SettingsRow(title: "Browsing data",
                                subtitle: String(localized: "Cookies, sign-ins in the browser, and downloaded Python packages."))
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("iCloud")
        .inlineNavigationTitle()
        .task { sync.refreshAccount() }
    }

    private var accountStatus: String {
        switch CloudSync.shared.account {
        case .checking: String(localized: "Checking…")
        case .available: String(localized: "Signed in")
        case .noAccount: String(localized: "Not signed in")
        case .restricted: String(localized: "Restricted")
        case .temporarilyUnavailable: String(localized: "Temporarily unavailable")
        case .unknown: String(localized: "Unknown")
        }
    }

    private var lastSynced: String {
        let sync = CloudSync.shared
        if !sync.chatsSyncing { return String(localized: "Off") }
        if sync.account != .available && sync.account != .checking { return String(localized: "Waiting for iCloud") }
        if sync.isSyncing { return String(localized: "Syncing…") }
        guard let date = sync.lastSync else { return String(localized: "Not yet") }
        return date.formatted(.relative(presentation: .named))
    }

    private var chatFooter: LocalizedStringKey {
        CloudSync.shared.needsRelaunch
            ? "Chat sync changes the next time OpenChat opens. Close and reopen it to apply."
            : "Chats sync in the background. Turning chat sync off or on applies the next time OpenChat opens; nothing is deleted either way."
    }
}
