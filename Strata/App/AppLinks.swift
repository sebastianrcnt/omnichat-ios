import Foundation

/// The app's URL scheme: `omnichat://` for add-connection, add-package, share and Live Activity links. Links made
/// before the rename to OmniChat use `openchat://`, which stays registered (project.yml) and opens the same way.
enum AppURLScheme {
    static let current = "omnichat"
    /// Schemes earlier builds wrote: still accepted, never written.
    static let legacy: Set<String> = ["openchat"]

    /// Whether `url` uses one of the app's schemes, in any case.
    static func matches(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == current || legacy.contains(scheme)
    }
}

/// The package file type (`.ocpkg`, a zip; docs/PACKAGES.md 5.2). Builds from before the rename to OmniChat declared
/// it as `cc.coolservices.openchat.package`, which is still accepted wherever the type is checked.
enum PackageFileType {
    static let identifier = "cc.coolservices.omnichat.package"
    static let legacyIdentifiers: Set<String> = ["cc.coolservices.openchat.package"]
    static let fileExtension = "ocpkg"

    /// Whether a type identifier is the package type, current or legacy.
    static func matches(identifier: String) -> Bool { identifier == Self.identifier || legacyIdentifiers.contains(identifier) }
}
