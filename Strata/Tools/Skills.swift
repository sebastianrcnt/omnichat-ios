import Foundation
import Observation

// Skills: Markdown documents that teach the model a task (which pages to open, which scripts to run). The system prompt
// lists only each skill's name and one-line description; `load_skill` returns the body. Built-in skills ship in the app
// bundle (`Resources/Skills`); the model can write new ones with `save_skill`, which the user must approve, and those
// live in Application Support.

/// One skill: `---` front matter with `name` and `description`, then the Markdown body.
struct Skill: Sendable, Equatable, Identifiable, Codable {
    var name: String
    /// One line, shown to the model in the system prompt.
    var description: String
    var body: String
    var isBuiltIn = false

    var id: String { name }

    static let nameLimit = 40
    static let descriptionLimit = 200
    static let bodyLimit = 40_000

    enum Problem: Error, LocalizedError, Equatable {
        case badName, badDescription, emptyBody, bodyTooLong, builtInName(String)

        // Read by the model, so each says what to do instead.
        var errorDescription: String? {
            switch self {
            case .badName: "The name must be 1 to \(Skill.nameLimit) lowercase letters, digits or hyphens, starting with a letter (like naver-places)."
            case .badDescription: "The description must be one line of at most \(Skill.descriptionLimit) characters."
            case .emptyBody: "The skill body is empty."
            case .bodyTooLong: "The skill body is longer than \(Skill.bodyLimit) characters."
            case .builtInName(let name): "\(name) is a built-in skill and can't be replaced. Save it under another name."
            }
        }
    }

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= nameLimit, ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    func validate() throws {
        guard Self.isValidName(name) else { throw Problem.badName }
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty, !d.contains("\n"), d.count <= Self.descriptionLimit else { throw Problem.badDescription }
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { throw Problem.emptyBody }
        guard b.count <= Self.bodyLimit else { throw Problem.bodyTooLong }
    }

    /// The skill as a Markdown file.
    var document: String {
        "---\nname: \(name)\ndescription: \(description.trimmingCharacters(in: .whitespacesAndNewlines))\n---\n\n"
            + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Reads a skill file. Nil when the front matter lacks a name or description.
    static func parse(_ text: String, isBuiltIn: Bool = false) -> Skill? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil) else {
            return nil
        }
        var fields: [String: String] = [:]
        for line in rest[..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let name = fields["name"], let description = fields["description"], !name.isEmpty, !description.isEmpty else { return nil }
        let body = String(rest[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Skill(name: name, description: description, body: body, isBuiltIn: isBuiltIn)
    }
}

/// The skills on this device: the built-in ones, then the saved ones. Thread-safe; the Settings list observes `version`.
final class SkillStore: @unchecked Sendable {
    static let shared = SkillStore()

    private let lock = NSLock()
    private let builtIn: [Skill]
    /// Where saved skills live (one `<name>.md` each). Nil keeps them in memory only (tests).
    private let directory: URL?
    private var saved: [String: Skill] = [:]
    private var loaded = false

    init(builtIn: [Skill] = SkillStore.bundled(), directory: URL? = SkillStore.defaultDirectory) {
        self.builtIn = builtIn.sorted { $0.name < $1.name }
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skills", isDirectory: true)
    }

    /// The `*.md` files in the bundle's `Skills` folder.
    static func bundled(_ bundle: Bundle = .main) -> [Skill] {
        let urls = bundle.urls(forResourcesWithExtension: "md", subdirectory: "Skills") ?? []
        return urls.compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).flatMap { Skill.parse($0, isBuiltIn: true) } }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "md" {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let skill = Skill.parse(text),
                  file.deletingPathExtension().lastPathComponent == skill.name, !builtIn.contains(where: { $0.name == skill.name }) else { continue }
            saved[skill.name] = skill
        }
    }

    /// Every skill, built-in first, each group by name.
    var all: [Skill] {
        lock.withLock {
            loadIfNeeded()
            return builtIn + saved.values.sorted { $0.name < $1.name }
        }
    }

    func skill(named name: String) -> Skill? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.name == key }
    }

    /// Saves (or replaces) a skill of the user's. Throws `Skill.Problem` for a bad skill or a built-in's name.
    func save(_ skill: Skill) throws {
        var skill = skill
        skill.isBuiltIn = false
        skill.description = skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
        skill.body = skill.body.trimmingCharacters(in: .whitespacesAndNewlines)
        try skill.validate()
        guard !builtIn.contains(where: { $0.name == skill.name }) else { throw Skill.Problem.builtInName(skill.name) }
        try lock.withLock {
            loadIfNeeded()
            if let directory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(skill.document.utf8).write(to: directory.appendingPathComponent(skill.name + ".md"), options: .atomic)
            }
            saved[skill.name] = skill
        }
        SkillsVersion.bump()
    }

    func delete(named name: String) {
        lock.withLock {
            loadIfNeeded()
            guard saved.removeValue(forKey: name) != nil else { return }
            if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + ".md")) }
        }
        SkillsVersion.bump()
    }

    /// The system prompt's skill list (see `SkillIndex`).
    var index: String { SkillIndex.text(for: all) }
}

/// Changes when a skill is saved or deleted, so the Settings list redraws.
@MainActor
@Observable
final class SkillsVersion {
    static let shared = SkillsVersion()
    private(set) var value = 0

    nonisolated static func bump() { Task { @MainActor in shared.value += 1 } }
}

enum SkillIndex {
    /// The skills section of the system prompt: names and descriptions only, sorted, so the same skills always give the
    /// same text. "" when there are none.
    static func text(for skills: [Skill]) -> String {
        guard !skills.isEmpty else { return "" }
        var lines = ["Skills: instructions for specific tasks. When a task matches a skill, call load_skill with its name first and follow what it says."]
        for skill in skills.sorted(by: { $0.name < $1.name }) {
            let d = skill.description.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            lines.append("- \(skill.name): \(d)")
        }
        return lines.joined(separator: "\n")
    }
}

/// `load_skill(name)`: the skill's body.
struct LoadSkillTool {
    var store: SkillStore = .shared

    func run(name: String) -> ToolOutput {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let skill = store.skill(named: trimmed) else {
            let names = store.all.map(\.name)
            let list = names.isEmpty ? "No skills exist." : "Available skills: " + names.joined(separator: ", ") + "."
            return ToolOutput(text: "Error: there is no skill named \"\(trimmed)\". " + list, isError: true)
        }
        return ToolOutput(text: "Skill: \(skill.name)\n\n" + skill.body)
    }
}
