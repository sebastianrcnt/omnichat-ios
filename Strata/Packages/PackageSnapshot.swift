import Foundation

/// The packages a chat offers, frozen at its first request with the exact bytes of what they add: each tool's
/// definition and the package's prompt section. A chat keeps sending these bytes whatever happens to the installed
/// package later (an update, a removal, a changed default), so its cached prefix holds (docs/PACKAGES.md 4.3, R3).
/// Stored in `Conversation.packageSnapshotData`; nil there means the chat offers no packages.
struct PackageSnapshot: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var version: String
        /// SHA-256 of the version's CHECKSUMS.
        var digest: String
        /// After any local alias.
        var namespace: String
        var tools: [FrozenTool]
        /// The rendered prompt section ("" when the package has no prompt and no skills).
        var promptSection: String
        /// `<namespace>:<name>` of its skills.
        var skillNames: [String]
    }

    struct FrozenTool: Codable, Sendable, Equatable {
        /// The tool's own name, without the namespace.
        var name: String
        var schemaVersion: Int
        /// The canonical JSON of its definition (`PackageRender.toolDefinition`).
        var definition: String
    }

    /// Sorted by id (UTF-8 byte order), so the same packages give the same bytes whatever order they were turned on.
    var entries: [Entry]

    init(entries: [Entry]) { self.entries = entries.sorted { PackageJSON.byteOrder($0.id, $1.id) } }

    init(packages: [InstalledPackage]) {
        self.init(entries: packages.map(Self.entry))
    }

    static func entry(_ p: InstalledPackage) -> Entry {
        let tools = zip(p.tools, p.toolDefinitions).map { tool, definition in
            FrozenTool(name: tool.name, schemaVersion: tool.effectiveSchemaVersion, definition: definition.canonical)
        }
        return Entry(id: p.id, name: p.name, version: p.version, digest: p.bundle.digest, namespace: p.namespace, tools: tools,
                     promptSection: p.promptSection, skillNames: p.skills.map(\.name))
    }

    var ids: Set<String> { Set(entries.map(\.id)) }

    func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    /// The entry and tool a full tool name belongs to.
    func tool(named fullName: String) -> (entry: Entry, tool: FrozenTool)? {
        guard let parts = PackageRender.split(toolName: fullName), let entry = entries.first(where: { $0.namespace == parts.namespace }),
              let tool = entry.tools.first(where: { $0.name == parts.tool }) else { return nil }
        return (entry, tool)
    }

    /// The system prompt's package sections, in id order, joined like the other sections.
    var promptSections: String { entries.map(\.promptSection).filter { !$0.isEmpty }.joined(separator: "\n\n") }

    /// Whether some package has skills: then `load_skill` comes with the package tools if the browser isn't offered.
    var hasSkills: Bool { entries.contains { !$0.skillNames.isEmpty } }

    /// The tool definitions, in id order, each package's tools in manifest order.
    var toolDefinitions: [ToolDefinition] {
        entries.flatMap(\.tools).compactMap { (try? PackageJSON.parse($0.definition)).flatMap(ToolDefinition.package) }
    }

    /// The tools a chat sends after the built-in ones: `load_skill` when a package has skills and the browser's tools
    /// (which include it) aren't offered, then the package tools.
    func requestTools(browserOffered: Bool) -> [ToolDefinition] {
        (hasSkills && !browserOffered ? [ToolDefinition.loadSkill] : []) + toolDefinitions
    }

    /// The snapshot with `entry` added (or replacing one with its id).
    func adding(_ entry: Entry) -> PackageSnapshot {
        PackageSnapshot(entries: entries.filter { $0.id != entry.id } + [entry])
    }

    /// Built-in ids from before the rename to OmniChat read as the current ones (`BuiltInPackages.canonicalID`). The
    /// entries keep their stored order, so the bytes the chat sends don't move.
    static func decode(_ data: Data?) -> PackageSnapshot? {
        guard var snapshot = data.flatMap({ try? JSONDecoder().decode(PackageSnapshot.self, from: $0) }) else { return nil }
        for i in snapshot.entries.indices { snapshot.entries[i].id = BuiltInPackages.canonicalID(snapshot.entries[i].id) }
        return snapshot
    }

    var encoded: Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(self)
    }
}

/// One switch of a chat's "+" menu: a built-in tool group or a package. Stored together in the conversation's switch
/// fields, groups first in `ToolGroup.allCases` order, then `pkg:<id>` sorted. Older builds read the same fields with
/// `ToolGroup.decode`, which skips the package entries. `pkg:*` stands for "the defaults": a chat whose groups were set
/// before it sent (the composer, an intent) takes the package defaults at its first send, like a chat with no switches.
enum ToolSwitch: Hashable, Sendable {
    case group(ToolGroup)
    case package(String)

    static let packagePrefix = "pkg:"
    static let defaultsMarker = "pkg:*"

    /// - Parameter packages: nil writes the defaults marker.
    static func encode(groups: Set<ToolGroup>, packages: Set<String>?) -> String {
        let entries = packages.map { $0.sorted(by: PackageJSON.byteOrder).map { packagePrefix + $0 } } ?? [defaultsMarker]
        return (ToolGroup.allCases.filter(groups.contains).map(\.rawValue) + entries).joined(separator: ",")
    }

    /// The packages a field holds; nil when it holds the defaults marker. Legacy built-in ids read as the current ones.
    static func packages(in raw: String) -> Set<String>? {
        let entries = raw.split(separator: ",").filter { $0.hasPrefix(packagePrefix) }
        if entries.contains(where: { $0 == defaultsMarker }) { return nil }
        return Set(entries.map { BuiltInPackages.canonicalID(String($0.dropFirst(packagePrefix.count))) })
    }

    /// "[Package Acme Jira: off]": the note on a user message after the switch changed (`Message.apiNote`).
    static func packageNote(name: String, on: Bool) -> String {
        "[Package \(name.replacingOccurrences(of: "]", with: ")")): \(on ? "on" : "off")]"
    }

    /// The packages of the snapshot a note names (by their names, as the note does).
    static func packageIDs(inNote note: String?, snapshot: PackageSnapshot) -> Set<String> {
        guard let note else { return [] }
        return Set(snapshot.entries.filter { entry in
            [true, false].contains { note.contains(packageNote(name: entry.name, on: $0)) }
        }.map(\.id))
    }

    /// The notes for changed groups and packages, groups first in their order, then packages by id.
    static func note(groups: Set<ToolGroup>, enabled: Set<ToolGroup>, packages: [(id: String, name: String)], enabledPackages: Set<String>) -> String {
        let parts = [ToolGroup.note(groups, enabled: enabled)]
            + packages.sorted { PackageJSON.byteOrder($0.id, $1.id) }.map { packageNote(name: $0.name, on: enabledPackages.contains($0.id)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The refusal of a call to a package the user turned off in the chat.
    static func packageRefusal(name: String) -> String {
        "The user turned off the \(name) package for this chat. Answer without it, or ask them to turn it on."
    }
}
