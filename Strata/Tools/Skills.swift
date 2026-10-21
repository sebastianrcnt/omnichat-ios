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

    /// A named script: a fenced code block whose info line reads `js script=NAME`.
    struct Script: Equatable, Sendable {
        var name: String
        var code: String
        /// The block's lines in the body, fences included.
        var lines: ClosedRange<Int>
    }

    static func isValidScriptName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// The named scripts in the body, in order. A name used twice keeps its first block.
    var scripts: [Script] {
        let lines = body.components(separatedBy: "\n")
        var out: [Script] = []
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("```"), let name = Self.scriptName(info: String(line.dropFirst(3))),
                  let close = lines[(i + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) else {
                i += 1
                continue
            }
            if !out.contains(where: { $0.name == name }) {
                out.append(Script(name: name, code: lines[(i + 1)..<close].joined(separator: "\n"), lines: i...close))
            }
            i = close + 1
        }
        return out
    }

    func script(named name: String) -> Script? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        return scripts.first { $0.name == wanted } ?? scripts.first { $0.name.lowercased() == wanted.lowercased() }
    }

    /// `script=NAME` (or `script: NAME`) in a fence's info line.
    static func scriptName(info: String) -> String? {
        guard let range = info.range(of: #"script\s*[=:]\s*"?([A-Za-z0-9_-]+)"?"#, options: .regularExpression) else { return nil }
        let token = info[range].replacingOccurrences(of: #"^script\s*[=:]\s*"?|"$"#, with: "", options: .regularExpression)
        return isValidScriptName(token) ? token : nil
    }

    /// The body as `load_skill` returns it: each named script's code replaced by a line saying how to run it.
    var bodyForModel: String {
        let found = scripts
        guard !found.isEmpty else { return body }
        var lines = body.components(separatedBy: "\n")
        for s in found.reversed() {
            let count = s.code.components(separatedBy: "\n").count
            lines.replaceSubrange(s.lines, with: [
                "[Script \(s.name), \(count) lines: run it with run_skill_script(skill: \"\(name)\", script: \"\(s.name)\"). "
                    + "To read or adapt its code, call load_skill with script: \"\(s.name)\".]"])
        }
        return lines.joined(separator: "\n")
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
        self.builtIn = builtIn.map { var s = $0; s.isBuiltIn = true; return s }.sorted { $0.name < $1.name }
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

/// `load_skill(name, script?)`: the skill's body with its scripts as run instructions, or one script's code.
struct LoadSkillTool {
    var store: SkillStore = .shared

    func run(name: String, script: String? = nil) -> ToolOutput {
        let skill: Skill
        switch SkillLookup.find(name, in: store) {
        case .failure(let error): return error.output
        case .success(let found): skill = found
        }
        if let script, !script.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let s = skill.script(named: script) else { return SkillLookup.noScript(script, in: skill).output }
            return ToolOutput(text: "Script \(s.name) of skill \(skill.name):\n\n```js\n\(s.code)\n```")
        }
        return ToolOutput(text: "Skill: \(skill.name)\n\n" + skill.bodyForModel)
    }
}

/// Finding a skill or one of its scripts by name, with errors that say what exists.
enum SkillLookup {
    struct Failure: Error {
        let text: String
        var output: ToolOutput { ToolOutput(text: text, isError: true) }
    }

    static func find(_ name: String, in store: SkillStore) -> Result<Skill, Failure> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let skill = store.skill(named: trimmed) else {
            let names = store.all.map(\.name)
            let list = names.isEmpty ? "No skills exist." : "Available skills: " + names.joined(separator: ", ") + "."
            return .failure(Failure(text: "Error: there is no skill named \"\(trimmed)\". " + list))
        }
        return .success(skill)
    }

    static func noScript(_ name: String, in skill: Skill) -> Failure {
        let names = skill.scripts.map(\.name)
        let list = names.isEmpty ? "It has no named scripts." : "Its scripts: " + names.joined(separator: ", ") + "."
        return Failure(text: "Error: skill \(skill.name) has no script named \"\(name)\". " + list)
    }
}

/// `run_skill_script(skill, script, args?)`: runs a skill's named script in the chat's browser page, like `browser_eval`,
/// with `args` (a JSON object) available to it as `args`.
struct RunSkillScriptTool {
    var store: SkillStore = .shared
    var eval = BrowserEvalTool()

    /// The script with its arguments declared first. `args` must be a JSON object (or nothing).
    static func code(_ script: String, argsJSON: String?) -> Result<String, SkillLookup.Failure> {
        var json = "{}"
        if let raw = argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw != "null" {
            guard let data = raw.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                return .failure(.init(text: "Error: args must be a JSON object, like {\"placeId\": \"123\"}."))
            }
            json = raw
        }
        return .success("const args = \(json);\n\(script)")
    }

    @MainActor
    func run(skill name: String, script: String, argsJSON: String?, conversation: UUID?) async -> ToolOutput {
        let skill: Skill
        switch SkillLookup.find(name, in: store) {
        case .failure(let error): return error.output
        case .success(let found): skill = found
        }
        guard let s = skill.script(named: script) else { return SkillLookup.noScript(script, in: skill).output }
        switch Self.code(s.code, argsJSON: argsJSON) {
        case .failure(let error): return error.output
        case .success(let code): return await eval.run(code: code, conversation: conversation)
        }
    }
}

/// The skills waiting for the user's answer: `save_skill` asks here, and the chat the request came from shows it as a
/// sheet (`pending(for:)`); another chat's request waits until that chat is open.
@MainActor
@Observable
final class SkillApprovals {
    static let shared = SkillApprovals()

    struct Request: Identifiable {
        let id = UUID()
        let skill: Skill
        /// The saved skill of the same name it would replace.
        let replaces: Skill?
        /// The chat whose reply asked; nil shows in any chat.
        var conversationID: UUID? = ToolContext.conversationID
    }

    private var queue: [(request: Request, answer: CheckedContinuation<Bool, Never>)] = []

    /// The oldest request, from any chat.
    var pending: Request? { queue.first?.request }

    /// The request the chat shows now: its own oldest one (or one that belongs to no chat).
    func pending(for conversationID: UUID?) -> Request? {
        queue.first { $0.request.conversationID == nil || $0.request.conversationID == conversationID }?.request
    }

    /// Waits for the user's answer. A cancelled turn counts as "no".
    func ask(_ request: Request) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled { cont.resume(returning: false); return }
                queue.append((request, cont))
            }
        } onCancel: {
            Task { @MainActor in self.answer(request.id, approved: false) }
        }
    }

    /// Ignored for a request already answered.
    func answer(_ id: UUID, approved: Bool) {
        guard let i = queue.firstIndex(where: { $0.request.id == id }) else { return }
        queue.remove(at: i).answer.resume(returning: approved)
    }
}

/// `save_skill(name, description, body)`: saves a skill only after the user approved it as shown in full. Pages the
/// model read may hold instructions meant for it, so a skill is never saved without that answer.
struct SaveSkillTool {
    var store: SkillStore = .shared
    var approve: @Sendable (SkillApprovals.Request) async -> Bool = { await SkillApprovals.shared.ask($0) }

    func run(name: String, description: String, body: String) async -> ToolOutput {
        let skill = Skill(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                          description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                          body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            try skill.validate()
            if store.skill(named: skill.name)?.isBuiltIn == true { throw Skill.Problem.builtInName(skill.name) }
        } catch {
            return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
        }
        let existing = store.skill(named: skill.name)
        guard await approve(SkillApprovals.Request(skill: skill, replaces: existing)) else {
            return ToolOutput(text: "Error: the user declined to save the skill. Do not try again unless they ask.", isError: true)
        }
        do { try store.save(skill) }
        catch { return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true) }
        return ToolOutput(text: "Saved skill \(skill.name). New chats list it; load_skill loads it in this chat too.")
    }
}
