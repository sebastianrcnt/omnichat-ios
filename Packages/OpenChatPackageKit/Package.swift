// swift-tools-version: 6.0
// OpenChatPackageKit: the package format of OpenChat (manifest, validation, signatures, URL templates, response
// projection, rendering). MIT licensed and Foundation/CryptoKit only, so the app and the `openchat-pkg` CLI share it.
import PackageDescription

let package = Package(
    name: "OpenChatPackageKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OpenChatPackageKit", targets: ["OpenChatPackageKit"])],
    targets: [.target(name: "OpenChatPackageKit")]
)
