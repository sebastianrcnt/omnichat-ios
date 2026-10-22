import Foundation

/// Runs the package tools a chat offers (`<namespace>__<tool>`) and loads package skills (`load_skill` and
/// `run_skill_script` with `<namespace>:<skill>`); every other call goes to `base`. A call is checked against the chat's
/// frozen snapshot and the package installed now, in this order: the package is still there, the tool's schema hasn't
/// changed since the chat started, the arguments fit, the user approves (when the tool asks), then it runs. Every call
/// leaves a line in the audit log.
struct PackageToolRouter: ToolExecuting {
    let base: any ToolExecuting
    /// The chat's snapshot; nil or empty for a chat without packages (skill names of built-in packages still resolve).
    var snapshot: PackageSnapshot?
    var store: PackageStore = .shared
    var secrets: PackageSecretStore = .shared
    var audit: PackageAudit = .shared
    var http = HTTPToolRunner()
    /// Test seam for page tools; nil runs them like `run_plugin`.
    var pageExecutor: PluginExecutor?
    /// Test seam for approvals; nil asks `ToolApprovals.shared`.
    var approve: (@Sendable (PackageApproval, UUID?, String?) async -> PackageApprovalAnswer)?

    var usesWebKit: Bool { base.usesWebKit }

    func execute(name: String, arguments: String) async -> ToolOutput {
        if name.contains("__") { return await runPackageTool(name: name, arguments: arguments) }
        if name == ToolNames.loadSkill || name == ToolNames.runSkillScript, let skill = PackageSkillCall.skillName(tool: name, arguments: arguments),
           let resolved = resolveSkill(skill) {
            return await runSkill(tool: name, arguments: arguments, skill: resolved)
        }
        return await base.execute(name: name, arguments: arguments)
    }

    // MARK: Skills

    /// A package skill by its full name (`kr:naver-places`), from the chat's packages or a built-in one; or a skill
    /// that moved from the app into a built-in package, by its old bare name (`naver-places`), when no skill of the
    /// user's has that name: chats from before the move keep working.
    func resolveSkill(_ name: String) -> Skill? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let colon = key.firstIndex(of: ":") {
            let namespace = String(key[..<colon])
            let candidates = (snapshot?.entries.filter { $0.namespace == namespace }.compactMap { store.package(id: $0.id) } ?? [])
                + store.all.filter { $0.isBuiltIn && $0.namespace == namespace }
            return candidates.lazy.flatMap(\.skills).first { $0.name == key }
        }
        guard SkillStore.shared.skill(named: key) == nil else { return nil }
        return store.all.filter(\.isBuiltIn).lazy.flatMap(\.skills).first { $0.name.split(separator: ":").last.map(String.init) == key }
    }

    private func runSkill(tool: String, arguments: String, skill: Skill) async -> ToolOutput {
        let single = SkillStore(builtIn: [skill], directory: nil)
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        if tool == ToolNames.loadSkill {
            return LoadSkillTool(store: single).run(name: skill.name, script: args["script"] as? String)
        }
        guard let script = args["script"] as? String else {
            return ToolOutput(text: "Error: run_skill_script needs \"skill\" and \"script\".", isError: true)
        }
        let argsJSON: String? = switch args["args"] {
        case let s as String: s
        case let o as [String: Any]: (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) }
        default: nil
        }
        return await RunSkillScriptTool(store: single).run(skill: skill.name, script: script, argsJSON: argsJSON,
                                                           conversation: ToolContext.conversationID)
    }

    // MARK: Tools

    private func runPackageTool(name: String, arguments: String) async -> ToolOutput {
        guard let (entry, frozen) = snapshot?.tool(named: name) else {
            return ToolOutput(text: "Error: the tool \(name) is not available in this chat.", isError: true)
        }
        let conversation = ToolContext.conversationID
        let callID = ToolContext.callID
        var event = PackageAudit.Event(time: .now, conversation: conversation?.uuidString, package: entry.id, version: entry.version,
                                       tool: frozen.name, outcome: .refused, argsSha256: PackageAudit.hash(arguments))
        func refuse(_ text: String, _ outcome: PackageAudit.Event.Outcome = .refused) -> ToolOutput {
            event.outcome = outcome
            audit.record(event)
            return ToolOutput(text: text, isError: true)
        }
        guard let package = store.package(id: entry.id), let tool = package.tool(named: frozen.name) else {
            return refuse("The \(entry.name) package was removed, so \(name) can't run. Answer without it.")
        }
        event.version = package.version
        guard tool.effectiveSchemaVersion == frozen.schemaVersion else {
            return refuse("This tool changed since the chat started (\(name) \(frozen.schemaVersion) → \(tool.effectiveSchemaVersion)). "
                          + "Answer without it, or ask the user to start a new chat.")
        }
        guard tool.kind != "page" || package.isBuiltIn else {
            return refuse("Error: \(name) is a page tool, which only built-in packages may have.")
        }
        let parsed: [String: PackageJSON]
        do {
            let value = arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? PackageJSON.object([:]) : try PackageJSON.parse(arguments)
            parsed = try JSONSchemaSubset.validateArguments(value, schema: tool.parameters, tool: name)
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "Bad arguments for \(name): \(error)"
            return refuse(text, .error)
        }

        if tool.kind == "page" {
            let started = ContinuousClock.now
            let out = await runPage(tool: tool, package: package, arguments: parsed)
            event.host = PackageSkillCall.host(of: out)
            event.outcome = out.isError ? .error : .ok
            event.milliseconds = Self.milliseconds(since: started)
            audit.record(event)
            return out
        }

        let prepared: HTTPToolRunner.Prepared
        switch HTTPToolRunner.prepare(tool: tool, package: package, arguments: parsed, secrets: secrets) {
        case .failure(let failure): return refuse(failure.text, .error)
        case .success(let p): prepared = p
        }
        event.host = prepared.request.host
        event.method = prepared.request.method

        if let level = await approvalLevel(tool: tool, package: package, conversation: conversation) {
            let approval = PackageApproval(packageID: package.id, packageName: package.name, trust: package.trust, toolTitle: tool.displayTitle,
                                           toolName: name, host: prepared.request.host, request: prepared.request.preview,
                                           arguments: Self.pretty(parsed), level: level, offersAlways: true)
            let answer = if let approve { await approve(approval, conversation, callID) }
                         else { await ToolApprovals.shared.askPackage(approval, conversation: conversation, callID: callID) }
            switch answer {
            case .deny: return refuse("The user declined to run \(name). Don't retry it unless they ask.", .denied)
            case .run: break
            case .allowInChat: await ToolApprovals.shared.allowInChat("\(package.id)/\(tool.name)", conversation: conversation)
            case .always: try? secrets.setAlwaysAllowed(true, package: package.id, tool: tool.name)
            }
        }

        let started = ContinuousClock.now
        let out = await http.run(prepared, tool: tool, package: package)
        event.outcome = out.isError ? .error : .ok
        event.status = out.isError ? Self.status(in: out.text) : 200
        event.milliseconds = Self.milliseconds(since: started)
        audit.record(event)
        return out
    }

    /// Whether the call waits for the user, and at which level. An unsigned package's tool that writes asks at least on
    /// its first call in a chat, whatever its manifest says.
    func approvalLevel(tool: PackageTool, package: InstalledPackage, conversation: UUID?) async -> PackageApproval.Level? {
        var level = tool.confirmLevel
        if level == "never", !tool.isReadOnly, !package.trust.mayWriteWithoutAsking { level = "first" }
        switch level {
        case "never": return nil
        case "first":
            if secrets.isAlwaysAllowed(package: package.id, tool: tool.name) { return nil }
            if await ToolApprovals.shared.isAllowedInChat("\(package.id)/\(tool.name)", conversation: conversation) { return nil }
            return .first
        default:
            if secrets.isAlwaysAllowed(package: package.id, tool: tool.name) { return nil }
            return .always
        }
    }

    @MainActor
    private func runPage(tool: PackageTool, package: InstalledPackage, arguments: [String: PackageJSON]) async -> ToolOutput {
        guard let page = tool.page, let path = tool.script, let data = package.bundle.files[path],
              let script = String(data: data, encoding: .utf8) else {
            return ToolOutput(text: "Error: \(tool.name) has no page script.", isError: true)
        }
        let properties = tool.parameters?["properties"]?.objectValue ?? [:]
        let args = properties.keys.sorted().map { key in
            PluginArgument(name: key, description: properties[key]?["description"]?.stringValue ?? key, required: nil,
                           default: arguments[key]?.templateText)
        }
        let manifest = PluginManifest(name: tool.name, description: tool.description, args: args, url: page.url,
                                      hosts: package.manifest.network.map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 },
                                      settle: page.settle, waitFor: page.waitFor)
        let plugin = WebPlugin(manifest: manifest, script: script)
        let values = arguments.mapValues(\.templateText)
        let json = (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var runner = RunPluginTool(registry: PluginRegistry(plugins: [plugin]), enabled: [tool.name])
        runner.executor = pageExecutor
        return await runner.run(name: tool.name, arguments: json)
    }

    private static func pretty(_ arguments: [String: PackageJSON]) -> String {
        let object = PackageJSON.object(arguments)
        guard let data = try? JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: object.canonicalData),
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return object.canonical }
        return String(decoding: data, as: UTF8.self)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    /// The status of an HTTP error result ("HTTP 404: …").
    private static func status(in text: String) -> Int? {
        guard text.hasPrefix("HTTP ") else { return nil }
        return Int(text.dropFirst(5).prefix { $0.isNumber })
    }
}

/// Reading what a skill call or a page tool names.
enum PackageSkillCall {
    /// The skill a `load_skill` (`name`) or `run_skill_script` (`skill`) call names.
    static func skillName(tool: String, arguments: String) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] else { return nil }
        return obj[tool == ToolNames.loadSkill ? "name" : "skill"] as? String
    }

    /// The host of a page tool's source, for the audit log.
    static func host(of output: ToolOutput) -> String? {
        output.sources.first.flatMap { URL(string: $0.url)?.host(percentEncoded: false) }
    }
}
