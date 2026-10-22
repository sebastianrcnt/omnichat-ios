// swift-tools-version: 6.0
// omnichat-pkg: validate, pack, sign and try OmniChat packages on a Mac. MIT, built on OmniChatPackageKit.
//
//   swift run --package-path Tools/omnichat-pkg omnichat-pkg validate path/to/package
import PackageDescription

let package = Package(
    name: "omnichat-pkg",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/OmniChatPackageKit")],
    targets: [
        .executableTarget(name: "omnichat-pkg", dependencies: [.product(name: "OmniChatPackageKit", package: "OmniChatPackageKit")]),
    ]
)
