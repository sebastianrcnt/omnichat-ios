import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.ocpkg`: an OmniChat package, a zip archive (declared in Info.plist).
    static let omniChatPackage = UTType(exportedAs: PackageFileType.identifier, conformingTo: .zip)
    /// The same files as typed by builds from before the rename to OmniChat (imported in Info.plist).
    static let legacyPackages = PackageFileType.legacyIdentifiers.sorted().map { UTType(importedAs: $0, conformingTo: .zip) }
}

/// Settings › Packages: the built-in packages and those the user installed, each with "On in new chats", and Import.
struct PackagesSettingsView: View {
    @Environment(\.theme) private var theme
    @State private var importing = false
    @State private var review: PackageReview?
    @State private var error: String?

    private var store: PackageStore { .shared }

    var body: some View {
        let _ = PackagesVersion.shared.value // redraw when a package changes
        let all = store.all
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                GroupedSection(header: "Packages", footer: "Packages add tools, skills and instructions to chats. A chat keeps the packages it started with; turn one on or off in a chat from the + menu.") {
                    ForEach(all.filter(\.isBuiltIn)) { row($0) }
                }
                GroupedSection(header: "Installed", footer: "Install only packages you or your assistant made, or from people you trust. Open a .ocpkg file or an add-package link, or import one here.") {
                    ForEach(all.filter { !$0.isBuiltIn }) { row($0) }
                    SettingsRow(systemImage: "square.and.arrow.down", title: "Import package") { importing = true }
                }
                if let error {
                    Text(verbatim: error).font(DS.Typography.uiCaption).foregroundStyle(theme.destructive)
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Packages")
        .inlineNavigationTitle()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.omniChatPackage] + UTType.legacyPackages + [.zip, .folder]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                review = PackageReview(candidate: try PackageInstaller().candidate(file: url))
                error = nil
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        .sheet(item: $review) { review in PackageReviewSheet(candidate: review.candidate).environment(\.theme, theme) }
    }

    private func row(_ package: InstalledPackage) -> some View {
        NavigationLink { PackageDetailView(id: package.id) } label: {
            SettingsRow(systemImage: package.isBuiltIn ? "shippingbox.fill" : "shippingbox", title: "",
                        subtitle: "\(package.version) · \(package.trust.title)" + (package.record.onInNewChats && package.addsToChats ? " · " + String(localized: "On in new chats") : ""),
                        showsChevron: true, verbatimTitle: package.name)
        }
        .buttonStyle(.plain)
    }
}

/// One package: what it adds and can reach, its secrets, "Always" approvals and activity, and revert or remove.
struct PackageDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var secretDrafts: [String: String] = [:]
    @State private var confirmRemove = false
    @State private var showPrompt = false
    @State private var error: String?

    private var store: PackageStore { .shared }
    private var secrets: PackageSecretStore { .shared }

    var body: some View {
        let _ = PackagesVersion.shared.value
        if let package = store.package(id: id) {
            content(package)
        } else {
            Text("This package was removed.").font(DS.Typography.ui).foregroundStyle(theme.textSecondary).padding()
        }
    }

    private func content(_ package: InstalledPackage) -> some View {
        let m = package.manifest
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(verbatim: m.description).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                    PackageTrustBadge(trust: package.trust, fingerprint: package.bundle.verification.signingKey?.fingerprint)
                    Text(verbatim: "\(m.id) · \(package.version) · \(m.publisher?.name ?? String(localized: "Unknown publisher"))")
                        .font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                }
                .padding(.horizontal, DS.Spacing.lg)

                if package.addsToChats {
                    GroupedSection(footer: package.requiredGroups.isEmpty ? nil : LocalizedStringKey(String(localized: "Needs \(package.requiredGroups.map(\.title).sorted().formatted()) on in the chat."))) {
                        SettingsToggleRow(title: "On in new chats", isOn: Binding(get: { package.record.onInNewChats },
                                                                                  set: { store.setOnInNewChats($0, id: package.id) }))
                    }
                }
                PackageContentsSections(manifest: m, bundle: package.bundle, namespace: package.namespace, showPrompt: $showPrompt)

                if !m.secrets.isEmpty {
                    GroupedSection(header: "Secrets", footer: "Kept in the Keychain on this device. The model never sees them; they go only into this package's requests.") {
                        ForEach(m.secrets, id: \.name) { secret in
                            let saved = secrets.hasValue(secret.name, package: package.id)
                            SettingsFieldRow(title: LocalizedStringKey(secret.label), prompt: saved ? "Saved" : "Not set",
                                             text: Binding(get: { secretDrafts[secret.name] ?? "" }, set: { secretDrafts[secret.name] = $0 }),
                                             isSecure: true)
                            if let help = secret.help { Text(verbatim: help).font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary).padding(.horizontal, DS.Spacing.lg) }
                            HStack(spacing: DS.Spacing.lg) {
                                Button("Save") { save(secret.name, package: package.id) }.buttonStyle(.quietLink(.accent))
                                    .disabled((secretDrafts[secret.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                                if saved { Button("Clear") { try? secrets.setValue(nil, name: secret.name, package: package.id) }.buttonStyle(.quietLink(.secondary)) }
                            }
                            .padding(.horizontal, DS.Spacing.lg)
                            .padding(.vertical, DS.Spacing.sm)
                        }
                    }
                }

                let always = secrets.alwaysAllowedTools(package: package.id)
                if !always.isEmpty {
                    GroupedSection(header: "Runs without asking") {
                        ForEach(always, id: \.self) { tool in
                            HStack {
                                Text(verbatim: package.tool(named: tool)?.displayTitle ?? tool).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                                Spacer()
                                Button("Revoke") { try? secrets.setAlwaysAllowed(false, package: package.id, tool: tool) }.buttonStyle(.quietLink(.accent))
                            }
                            .padding(.horizontal, DS.Spacing.lg)
                            .padding(.vertical, DS.Spacing.sm)
                        }
                    }
                }

                if !package.tools.isEmpty {
                    NavigationLink { PackageActivityView(package: package) } label: {
                        SettingsRow(systemImage: "list.bullet.rectangle", title: "Activity", subtitle: String(localized: "The tool calls of the last 30 days"),
                                    showsChevron: true)
                    }
                    .buttonStyle(.plain)
                }

                if !package.isBuiltIn {
                    GroupedSection {
                        if let previous = package.record.previousVersion {
                            SettingsRow(systemImage: "arrow.uturn.backward", title: "", verbatimTitle: String(localized: "Revert to \(previous)")) {
                                do { try store.revert(id: package.id) } catch { self.error = error.localizedDescription }
                            }
                        }
                        SettingsRow(systemImage: "trash", title: "Remove package", isDestructive: true) { confirmRemove = true }
                    }
                }
                if let error { Text(verbatim: error).font(DS.Typography.uiCaption).foregroundStyle(theme.destructive) }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(Text(verbatim: package.name))
        .inlineNavigationTitle()
        .confirmationDialog("Remove \(package.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove package", role: .destructive) {
                do { try PackageInstaller().remove(id: package.id); dismiss() } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("Its secrets and approvals are deleted. Chats that used it can't call its tools anymore.")
        }
    }

    private func save(_ name: String, package: String) {
        do {
            try secrets.setValue(secretDrafts[name], name: name, package: package)
            secretDrafts[name] = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// What a package adds and what it can reach: shared by the detail page and the review sheet.
struct PackageContentsSections: View {
    @Environment(\.theme) private var theme
    let manifest: PackageManifest
    let bundle: PackageBundle
    let namespace: String
    @Binding var showPrompt: Bool
    /// Hosts, secrets and private network access an update adds (highlighted).
    var newHosts: Set<String> = []
    var newSecrets: Set<String> = []
    var newPrivateNetwork = false

    var body: some View {
        let tools = bundle.usableTools
        if !tools.isEmpty {
            GroupedSection(header: "Tools") {
                ForEach(tools, id: \.name) { tool in
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        HStack(spacing: DS.Spacing.xs) {
                            Text(verbatim: tool.displayTitle).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                            if tool.confirmLevel != "never" {
                                Text("Asks before running").font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                            }
                        }
                        Text(verbatim: PackageRender.toolName(namespace: namespace, tool: tool.name))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(theme.textTertiary)
                        Text(verbatim: tool.description).font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                }
            }
        }
        if !bundle.skills.isEmpty {
            GroupedSection(header: "Skills") {
                ForEach(bundle.skills, id: \.name) { skill in
                    SettingsRow(title: "", subtitle: skill.description, verbatimTitle: "\(namespace):\(skill.name)")
                }
            }
        }
        if let prompt = bundle.promptText, !prompt.isEmpty {
            GroupedSection(header: "Instructions", footer: LocalizedStringKey(String(localized: "Added to the system prompt of chats that use it: \(prompt.count) characters, about \(max(1, prompt.count / 4)) tokens."))) {
                Button { showPrompt.toggle() } label: {
                    Text(verbatim: showPrompt ? prompt : String(prompt.prefix(160)) + (prompt.count > 160 ? "…" : ""))
                        .font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.sm)
                }
                .buttonStyle(.plain)
            }
        }
        if !manifest.commands.isEmpty {
            GroupedSection(header: "Commands") {
                ForEach(manifest.commands, id: \.name) { command in
                    SettingsRow(title: "", subtitle: command.title, verbatimTitle: "/" + command.name)
                }
            }
        }
        if !manifest.connections.isEmpty {
            GroupedSection(header: "Connection presets", footer: "Offered in Add connection. Presets never carry keys.") {
                ForEach(manifest.connections) { preset in
                    SettingsRow(title: "", subtitle: preset.url, verbatimTitle: preset.name)
                }
            }
        }
        if !manifest.network.isEmpty || !manifest.secrets.isEmpty || manifest.privateNetwork {
            GroupedSection(header: "Can reach") {
                ForEach(manifest.network, id: \.self) { host in
                    permission(host, systemImage: "network", isNew: newHosts.contains(host))
                }
                if manifest.privateNetwork {
                    permission(String(localized: "Local network and private addresses"), systemImage: "wifi.router", isNew: newPrivateNetwork)
                }
                ForEach(manifest.secrets, id: \.name) { secret in
                    permission(String(localized: "Your \(secret.label)"), systemImage: "key", isNew: newSecrets.contains(secret.name))
                }
            }
        }
    }

    private func permission(_ text: String, systemImage: String, isNew: Bool) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: systemImage).foregroundStyle(isNew ? theme.warning : theme.textSecondary)
            Text(verbatim: text).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
            if isNew { Text("New").font(DS.Typography.uiCaption).foregroundStyle(theme.warning) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
    }
}

/// The audit log's entries for one package (calls level: which tool, where, how it ended; never arguments).
struct PackageActivityView: View {
    @Environment(\.theme) private var theme
    let package: InstalledPackage
    @State private var events: [PackageAudit.Event] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                GroupedSection(footer: "Kept on this device for 30 days. Arguments and results are never recorded, only a fingerprint of the arguments.") {
                    if events.isEmpty { SettingsRow(title: "No calls yet") }
                    ForEach(events.indices, id: \.self) { i in
                        let e = events[i]
                        SettingsRow(title: "", subtitle: [e.method, e.host, e.status.map(String.init), e.milliseconds.map { "\($0) ms" }]
                                        .compactMap { $0 }.joined(separator: " · "),
                                    value: e.outcome.rawValue,
                                    verbatimTitle: (package.tool(named: e.tool)?.displayTitle ?? e.tool) + " · " + e.time.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if !events.isEmpty {
                    SettingsRow(systemImage: "trash", title: "Clear activity", isDestructive: true) {
                        PackageAudit.shared.clear(package: package.id)
                        events = []
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Activity")
        .inlineNavigationTitle()
        .task { events = PackageAudit.shared.events(package: package.id, limit: 200) }
    }
}

/// A package waiting for review.
struct PackageReview: Identifiable {
    let id = UUID()
    let candidate: PackageCandidate
}

/// Review before install (docs/PACKAGES.md 5.3): who made it, what it adds, what it can reach (new permissions marked on
/// an update), its files, then Install with "On in new chats". Nothing is written before Install.
struct PackageReviewSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let candidate: PackageCandidate
    @State private var onInNewChats: Bool
    @State private var trustKey = true
    @State private var showPrompt = false
    @State private var error: String?
    @State private var file: String?

    init(candidate: PackageCandidate) {
        self.candidate = candidate
        _onInNewChats = State(initialValue: candidate.onInNewChatsByDefault)
        _trustKey = State(initialValue: !candidate.keyDeclined)
    }

    private var title: LocalizedStringKey {
        switch candidate.change {
        case .new: "Install package?"
        case .update: "Update package?"
        case .reinstall: "Reinstall package?"
        case .downgrade: "Go back to an older version?"
        }
    }

    var body: some View {
        let m = candidate.manifest
        SheetScaffold(title: title) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(verbatim: m.name).font(DS.Typography.title).foregroundStyle(theme.textPrimary)
                Text(verbatim: m.description).font(DS.Typography.ui).foregroundStyle(theme.textSecondary)
                PackageTrustBadge(trust: candidate.trust, fingerprint: candidate.bundle.verification.signingKey?.fingerprint)
                Text(verbatim: versionLine).font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                if candidate.trust == .unsigned {
                    Text("Not signed. Only install packages you or your assistant made, or from people you trust.")
                        .font(DS.Typography.uiCaption).foregroundStyle(theme.warning)
                }
                if candidate.namespace != m.namespace {
                    Text("Another package uses \(m.namespace), so its tools are named \(candidate.namespace)__… here.")
                        .font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                }
            }
            if let blocker = candidate.blocker {
                Label { Text(verbatim: blocker) } icon: { Image(systemName: "xmark.octagon.fill") }
                    .font(DS.Typography.ui).foregroundStyle(theme.destructive)
            }
            PackageContentsSections(manifest: m, bundle: candidate.bundle, namespace: candidate.namespace, showPrompt: $showPrompt,
                                    newHosts: candidate.change == .new ? [] : Set(candidate.newHosts),
                                    newSecrets: candidate.change == .new ? [] : Set(candidate.newSecrets),
                                    newPrivateNetwork: candidate.change != .new && candidate.newPrivateNetwork)
            GroupedSection(header: candidate.change == .new ? "Files" : "Changed files") {
                ForEach(candidate.change == .new ? candidate.bundle.files.keys.sorted() : candidate.changedFiles, id: \.self) { path in
                    SettingsRow(title: "", value: (candidate.bundle.files[path]?.count).map { $0.formatted(.byteCount(style: .file)) } ?? String(localized: "Removed"),
                                showsChevron: candidate.bundle.files[path] != nil, verbatimTitle: path) {
                        if candidate.bundle.files[path] != nil { file = file == path ? nil : path }
                    }
                    if file == path, let data = candidate.bundle.files[path] {
                        let text = String(decoding: data.prefix(20_000), as: UTF8.self)
                        CodeBlockView(content: CodeBlockContent(language: (path as NSString).pathExtension, code: text))
                            .padding(.horizontal, DS.Spacing.sm)
                    }
                }
            }
            if candidate.blocker == nil {
                GroupedSection {
                    if candidate.manifest.tools.isEmpty == false || !candidate.bundle.skills.isEmpty || candidate.bundle.promptText != nil {
                        SettingsToggleRow(title: "On in new chats", isOn: $onInNewChats)
                    }
                    if candidate.asksToTrustKey {
                        SettingsToggleRow(title: "Trust this publisher's key", subtitle: "Later versions signed with it update without this warning.", isOn: $trustKey)
                    }
                }
                if let error { Text(verbatim: error).font(DS.Typography.uiCaption).foregroundStyle(theme.destructive) }
                HStack(spacing: DS.Spacing.lg) {
                    Button(candidate.change == .new ? "Install" : "Update") { install() }.buttonStyle(.quietLink(.accent))
                    Button("Cancel") { dismiss() }.buttonStyle(.quietLink(.secondary))
                }
                .padding(.horizontal, DS.Spacing.lg)
            }
        }
    }

    private var versionLine: String {
        let m = candidate.manifest
        let change = switch candidate.change {
        case .new, .reinstall: m.version
        case .update(let from), .downgrade(let from): "\(from) → \(m.version)"
        }
        return "\(m.id) · \(change) · \(m.publisher?.name ?? String(localized: "Unknown publisher"))"
    }

    private func install() {
        do {
            try PackageInstaller().install(candidate, onInNewChats: onInNewChats, trustKey: trustKey)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Links and files

/// A package the app was asked to open (an `omnichat://add-package` link, or a `.ocpkg` file), waiting for its review.
@MainActor
@Observable
final class PackageLinks {
    static let shared = PackageLinks()

    struct Pending: Identifiable {
        let id = UUID()
        let result: Result<PackageCandidate, Error>
    }

    var pending: Pending?
    var loading = false

    /// Takes an add-package link or a package file; false for any other URL.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        if url.isFileURL, url.pathExtension.lowercased() == PackageFileType.fileExtension {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pending = Pending(result: Result { try PackageInstaller().candidate(file: url) })
            return true
        }
        guard AppURLScheme.matches(url), url.host()?.lowercased() == AddPackageLink.host else { return false }
        guard let link = AddPackageLink(url) else {
            pending = Pending(result: .failure(PackageError.invalid(String(localized: "The add-package link needs an https url of at most 2 KB, and an optional 64-character sha256."))))
            return true
        }
        loading = true
        Task {
            let result: Result<PackageCandidate, Error>
            do { result = .success(try await PackageInstaller().candidate(link: link)) } catch { result = .failure(error) }
            loading = false
            pending = Pending(result: result)
        }
        return true
    }
}

/// Opens package links and files in the review sheet, at the root of the window (like `ConnectionLinkHandler`).
private struct PackageLinkHandler: ViewModifier {
    @Environment(\.theme) private var theme
    @Binding var closing: Bool
    @State private var links = PackageLinks.shared
    @State private var shown: PackageLinks.Pending?

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
                Group {
                    switch pending.result {
                    case .success(let candidate): PackageReviewSheet(candidate: candidate)
                    case .failure(let error): PackageErrorSheet(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    }
                }
                .environment(\.theme, theme)
            }
    }
}

/// A package that couldn't be read or downloaded.
private struct PackageErrorSheet: View {
    @Environment(\.theme) private var theme
    let message: String

    var body: some View {
        SheetScaffold(title: "Can't open the package") {
            Text(verbatim: message).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
        }
    }
}

extension View {
    /// Handles add-package links and package files opened with the app (see `PackageLinkHandler`).
    func packageLinks(closing: Binding<Bool>) -> some View { modifier(PackageLinkHandler(closing: closing)) }
}
