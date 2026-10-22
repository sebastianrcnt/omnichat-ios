// swift-tools-version: 6.0
// OmniChatPackageKit: the package format of OmniChat (manifest, validation, signatures, URL templates, response
// projection, rendering). MIT licensed and Foundation/CryptoKit only, so the app and the `omnichat-pkg` CLI share it.
import PackageDescription

let package = Package(
    name: "OmniChatPackageKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OmniChatPackageKit", targets: ["OmniChatPackageKit"])],
    targets: [.target(name: "OmniChatPackageKit")]
)
