import Foundation

/// Package tool calls as the feed, the Timeline and the Live Activity show them: `<namespace>__<tool>`, looked up in
/// the installed packages for a title. A call of a package removed since keeps a plain line.
enum PackageToolNames {
    static func covers(_ name: String) -> Bool { PackageRender.split(toolName: name) != nil }

    static func lookup(_ name: String, store: PackageStore = .shared) -> (package: InstalledPackage, tool: PackageTool)? {
        guard let parts = PackageRender.split(toolName: name), let package = store.package(namespace: parts.namespace),
              let tool = package.tool(named: parts.tool) else { return nil }
        return (package, tool)
    }

    /// The package's name ("Wikipedia"), or its namespace when it isn't installed.
    static func packageName(of name: String) -> String {
        lookup(name)?.package.name ?? PackageRender.split(toolName: name)?.namespace ?? name
    }

    /// The tool's title ("Wikipedia article"), or its own name.
    static func toolTitle(of name: String) -> String {
        lookup(name)?.tool.displayTitle ?? PackageRender.split(toolName: name)?.tool ?? name
    }

    /// The argument the feed shows (the manifest's `display.argument`, else the first string argument).
    static func displayArgument(name: String, arguments: String) -> String {
        guard let object = (try? PackageJSON.parse(arguments))?.objectValue else { return "" }
        if let key = lookup(name)?.tool.display?.argument, let value = object[key]?.templateText { return value }
        return object.keys.sorted().lazy.compactMap { object[$0]?.stringValue }.first ?? ""
    }

    /// Only reads, so it is safe to run again after the app was suspended mid-call.
    static func isReadOnly(_ name: String) -> Bool { lookup(name)?.tool.isReadOnly ?? false }

    /// The chat's feed keeps the whole (capped) result, not only the call's line.
    static func keepsResult(_ name: String) -> Bool { lookup(name)?.tool.keepsResult ?? false }

    /// "Used Wikipedia article · Alan Turing".
    static func title(_ name: String, argument: String, running: Bool, failed: Bool) -> String {
        let tool = toolTitle(of: name)
        let base = running ? String(localized: "Using \(tool)…") : failed ? String(localized: "\(tool) failed") : String(localized: "Used \(tool)")
        return argument.isEmpty ? base : base + " · " + argument
    }

    static let icon = "shippingbox"
}
