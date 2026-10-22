import SwiftUI

/// "Run Create item from Acme Jira?" under a package tool call's line: the exact request (method, URL and body, without
/// credentials) and the answers its level allows.
struct PackageApprovalCard: View {
    @Environment(\.theme) private var theme
    let approval: PackageApproval
    let onAnswer: (PackageApprovalAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Run \(approval.toolTitle) from \(approval.packageName)?")
                .font(DS.Typography.feedEmphasis).foregroundStyle(theme.textPrimary)
            HStack(spacing: DS.Spacing.xs) {
                Text("Sends a request to \(approval.host).")
                if approval.trust == .unsigned {
                    Text("Not signed").foregroundStyle(theme.warning)
                }
            }
            .font(DS.Typography.feedMeta).foregroundStyle(theme.textSecondary)
            CodeBlockView(content: CodeBlockContent(language: "http", code: approval.request))
            HStack(spacing: DS.Spacing.lg) {
                switch approval.level {
                case .first:
                    Button("Allow in this chat") { onAnswer(.allowInChat) }.buttonStyle(.quietLink(.accent))
                    if approval.offersAlways { Button("Always") { onAnswer(.always) }.buttonStyle(.quietLink(.secondary)) }
                case .always:
                    Button("Run") { onAnswer(.run) }.buttonStyle(.quietLink(.accent))
                    if approval.offersAlways { Button("Always for this tool") { onAnswer(.always) }.buttonStyle(.quietLink(.secondary)) }
                }
                Button("Deny") { onAnswer(.deny) }.buttonStyle(.quietLink(.secondary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// A package's trust as a small label: built in, managed, signed (with the key's fingerprint) or not signed.
struct PackageTrustBadge: View {
    @Environment(\.theme) private var theme
    let trust: PackageTrust
    var fingerprint: String?

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: symbol)
            Text(verbatim: fingerprint.map { "\(trust.title) · \($0)" } ?? trust.title)
        }
        .font(DS.Typography.uiCaption)
        .foregroundStyle(trust == .unsigned ? theme.warning : theme.textSecondary)
    }

    private var symbol: String {
        switch trust {
        case .builtIn: "checkmark.seal"
        case .company: "building.2"
        case .trustedKey: "signature"
        case .unsigned: "exclamationmark.triangle"
        }
    }
}

/// A package command for the composer's `/` list.
struct PackageCommandItem: Identifiable, Equatable {
    var id: String { packageID + "/" + template.name }
    let packageID: String
    let packageName: String
    let template: PackageCommand

    /// Every installed package's commands, by name.
    @MainActor
    static func all(_ store: PackageStore) -> [PackageCommandItem] {
        let _ = PackagesVersion.shared.value
        return store.all.flatMap { p in p.manifest.commands.map { PackageCommandItem(packageID: p.id, packageName: p.name, template: $0) } }
            .sorted { ($0.template.name, $0.packageName) < ($1.template.name, $1.packageName) }
    }

    /// The commands a draft that is a single `/word` starts, at most 6.
    static func matches(_ commands: [PackageCommandItem], draft: String) -> [PackageCommandItem] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let word = draft.dropFirst().lowercased()
        return Array(commands.filter { $0.template.name.hasPrefix(word) }.prefix(6))
    }
}

/// The `/` list above the composer: a tap puts the command's text in the draft, its blanks named for the user to fill.
struct PackageCommandList: View {
    @Environment(\.theme) private var theme
    let commands: [PackageCommandItem]
    let onPick: (PackageCommandItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commands) { item in
                Button { onPick(item) } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        Text(verbatim: "/" + item.template.name).font(.system(.subheadline, design: .monospaced)).foregroundStyle(theme.textPrimary)
                        Text(verbatim: item.template.title).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary).lineLimit(1)
                        Spacer(minLength: DS.Spacing.sm)
                        Text(verbatim: item.packageName).font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .padding(.horizontal, DS.Spacing.lg)
    }
}
