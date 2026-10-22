import SwiftUI

/// Settings > iCloud: the account, the last sync, and what syncs (`CloudSync`).
struct ICloudSettingsView: View {
    @Environment(\.theme) private var theme
    @State private var confirmChatSync = false
    @State private var confirmRemoval = false
    @State private var removing = false
    @State private var removalResult: String?

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
                                      isOn: chatSyncBinding)
                    SettingsToggleRow(title: "Sync settings and connections",
                                      subtitle: "Preferences, tool defaults, plugins and your connection list.",
                                      isOn: $sync.settingsSyncSwitch)
                }

                GroupedSection(footer: "API keys, ChatGPT and OpenCode sign-ins, SSH credentials and custom headers. Off, this device keeps its own copy of each one; copies already in iCloud Keychain stay for your other devices until you remove them.") {
                    SettingsToggleRow(title: "Sync secrets with iCloud Keychain", isOn: $sync.secretSyncSwitch)
                    if !sync.secretSyncSwitch {
                        SettingsRow(systemImage: "icloud.slash", title: "Remove Secrets from iCloud", subtitle: removalResult,
                                    isDestructive: true) { confirmRemoval = true }
                            .disabled(removing)
                    }
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
        .confirmationDialog("Turn on chat sync?", isPresented: $confirmChatSync, titleVisibility: .visible) {
            Button("Turn On Chat Sync") { CloudSync.shared.chatSyncSwitch = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apple Health can't be used on this device while chat sync is on, so no health data goes to iCloud. Health data the assistant already read is removed from your chats first; the replies stay.")
        }
        .confirmationDialog("Remove secrets from iCloud?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove from iCloud", role: .destructive) { removeSecrets() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device keeps its own copy of each secret. Your other devices lose the ones they get from iCloud, so their API keys, sign-ins and SSH credentials need to be entered again there.")
        }
    }

    /// Keychain calls can wait on the system, so they run off the main thread.
    private func removeSecrets() {
        removing = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { KeychainSync.removeFromICloud() }.value
            removing = false
            removalResult = result.kept > 0
                ? String(localized: "Some secrets couldn't be copied to this device, so they stay in iCloud. Try again later.")
                : result.removed == 0 ? String(localized: "No secrets were in iCloud.")
                : String(localized: "Removed \(result.removed) from iCloud. This device keeps its copies.")
        }
    }

    /// Where Apple Health exists, turning chat sync on asks first: the two exclude each other (`HealthSettings.blockedBySync`).
    private var chatSyncBinding: Binding<Bool> {
        Binding {
            CloudSync.shared.chatSyncSwitch
        } set: { on in
            if on && HealthSettings.isSupported { confirmChatSync = true } else { CloudSync.shared.chatSyncSwitch = on }
        }
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
            : HealthSettings.isSupported
                ? "Off by default. Chats sync in the background; turning chat sync off or on applies the next time OpenChat opens. While it is on, Apple Health can't be used on this device."
                : "Off by default. Chats sync in the background; turning chat sync off or on applies the next time OpenChat opens."
    }
}
