import SwiftUI

/// Open-source components bundled with the app.
struct LicenseEntry: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let version: String
    let license: String
    let copyright: String
    let url: String
    /// Bundled license text to show in full (the font's OFL), when there is one.
    var bundledText: String?

    static let all: [LicenseEntry] = [
        LicenseEntry(name: "MarkdownUI", version: "2.4.1", license: "MIT", copyright: "Guillermo Gonzalez",
                     url: "https://github.com/gonzalezreal/swift-markdown-ui"),
        LicenseEntry(name: "swift-cmark", version: "0.9.0", license: "BSD 2-Clause", copyright: "John MacFarlane and contributors",
                     url: "https://github.com/swiftlang/swift-cmark"),
        LicenseEntry(name: "NetworkImage", version: "6.0.1", license: "MIT", copyright: "Guillermo Gonzalez",
                     url: "https://github.com/gonzalezreal/NetworkImage"),
        LicenseEntry(name: "highlight.js", version: "11.10.0", license: "BSD 3-Clause", copyright: "Ivan Sagalaev and contributors",
                     url: "https://github.com/highlightjs/highlight.js"),
        LicenseEntry(name: "Readability.js", version: "0.6.0", license: "Apache 2.0", copyright: "Arc90 Inc",
                     url: "https://github.com/mozilla/readability"),
        LicenseEntry(name: "Pyodide", version: Pyodide.version, license: "Mozilla Public License 2.0",
                     copyright: "Pyodide contributors (includes CPython, PSF License)", url: "https://github.com/pyodide/pyodide",
                     bundledText: Pyodide.bundleRoot.flatMap { try? String(contentsOf: $0.appendingPathComponent("pyodide/LICENSE"), encoding: .utf8) }),
        LicenseEntry(name: "libssh2", version: "1.11.1", license: "BSD 3-Clause",
                     copyright: "Sara Golemon, Mikhail Gusarov, Daniel Stenberg, Simon Josefsson, Eli Fant and others",
                     url: "https://libssh2.org", bundledText: Self.bundledText(named: "LICENSE-libssh2")),
        LicenseEntry(name: "OpenSSL", version: "3.5.9", license: "Apache 2.0", copyright: "The OpenSSL Project Authors",
                     url: "https://www.openssl.org", bundledText: Self.bundledText(named: "LICENSE-OpenSSL")),
        LicenseEntry(name: "Pretendard", version: "1.3.9", license: "SIL Open Font License 1.1",
                     copyright: "Kil Hyung-jin", url: "https://github.com/orioncactus/pretendard",
                     bundledText: Self.bundledText(named: "Pretendard-OFL")),
    ]

    private static func bundledText(named name: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

struct LicensesView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                GroupedSection(header: "Open source", footer: "OmniChat includes these components under their licenses.") {
                    ForEach(LicenseEntry.all) { entry in
                        NavigationLink(value: entry) {
                            HStack(spacing: DS.Spacing.md) {
                                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                    Text(verbatim: entry.name).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                                    Text(verbatim: "\(entry.license) · \(entry.version)").font(DS.Typography.uiCaption)
                                        .foregroundStyle(theme.textSecondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: DS.IconSize.sm, weight: .semibold))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .padding(.horizontal, DS.Spacing.lg)
                            .padding(.vertical, DS.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Licenses")
        .inlineNavigationTitle()
        .navigationDestination(for: LicenseEntry.self) { LicenseDetail(entry: $0) }
    }
}

extension LicenseEntry: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

private struct LicenseDetail: View {
    @Environment(\.theme) private var theme
    let entry: LicenseEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text(verbatim: entry.name).font(DS.Typography.largeTitle).foregroundStyle(theme.textPrimary)
                Text(verbatim: "\(entry.version) · \(entry.license)").font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                Text(verbatim: "Copyright \u{00A9} \(entry.copyright)").font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                if let url = URL(string: entry.url) { Link(entry.url, destination: url).font(DS.Typography.uiSmall) }
                if let text = entry.bundledText {
                    Text(verbatim: text).font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                        .dsLeading(.thinking).textSelection(.enabled).padding(.top, DS.Spacing.md)
                }
            }
            .padding(DS.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.background.ignoresSafeArea())
        .inlineNavigationTitle()
    }
}
