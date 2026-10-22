// swift-tools-version: 6.0
// openchat-pkg: validate, pack, sign and try OpenChat packages on a Mac. MIT, built on OpenChatPackageKit.
//
//   swift run --package-path Tools/openchat-pkg openchat-pkg validate path/to/package
import PackageDescription

let package = Package(
    name: "openchat-pkg",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/OpenChatPackageKit")],
    targets: [
        .executableTarget(name: "openchat-pkg", dependencies: [.product(name: "OpenChatPackageKit", package: "OpenChatPackageKit")]),
    ]
)
