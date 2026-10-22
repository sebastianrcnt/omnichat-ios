// The package format lives in OmniChatPackageKit (MIT, Packages/OmniChatPackageKit), shared with the omnichat-pkg CLI.
// Re-exported, so the app's files and its tests see the kit's types without importing it each time.
@_exported import OmniChatPackageKit

/// The kit's JSON value. The app has a `JSONValue` of its own (`AnthropicMessages`, encode-only), which wins inside
/// this module, so package code names the kit's by this alias.
typealias PackageJSON = OmniChatPackageKit.JSONValue
