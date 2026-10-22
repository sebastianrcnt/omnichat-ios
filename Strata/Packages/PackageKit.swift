// The package format lives in OpenChatPackageKit (MIT, Packages/OpenChatPackageKit), shared with the openchat-pkg CLI.
// Re-exported, so the app's files and its tests see the kit's types without importing it each time.
@_exported import OpenChatPackageKit

/// The kit's JSON value. The app has a `JSONValue` of its own (`AnthropicMessages`, encode-only), which wins inside
/// this module, so package code names the kit's by this alias.
typealias PackageJSON = OpenChatPackageKit.JSONValue
