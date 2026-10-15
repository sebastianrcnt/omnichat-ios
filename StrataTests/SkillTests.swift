import Foundation
import SwiftData
import Testing
@testable import Strata

private func skill(_ name: String, _ description: String = "Does a thing.", body: String = "Step one.") -> Skill {
    Skill(name: name, description: description, body: body)
}

/// The fenced ```js block of a bundled skill that starts with `// <marker>`.
func skillScript(_ skill: Skill, marker: String) -> String? {
    skill.scripts.first { $0.code.hasPrefix("// " + marker) }?.code
}

struct SkillFormatTests {
    @Test func aSkillFileRoundTrips() throws {
        let s = skill("naver-places", "Find places.", body: "# Title\n\nBody --- with dashes.\n")
        let parsed = try #require(Skill.parse(s.document))
        #expect(parsed.name == "naver-places" && parsed.description == "Find places." && parsed.body == "# Title\n\nBody --- with dashes.")
        #expect(Skill.parse("no front matter") == nil)
        #expect(Skill.parse("---\nname: x\n---\nbody") == nil, "a description is required")
    }

    @Test func namesAndDescriptionsAreChecked() {
        #expect(Skill.isValidName("naver-places") && Skill.isValidName("a1"))
        #expect(!Skill.isValidName("Naver") && !Skill.isValidName("1abc") && !Skill.isValidName("a b") && !Skill.isValidName(""))
        #expect(throws: Skill.Problem.badDescription) { try skill("ok", "two\nlines").validate() }
        #expect(throws: Skill.Problem.emptyBody) { try skill("ok", body: "  ").validate() }
    }

    @Test func theIndexListsNamesAndDescriptionsSorted() {
        let text = SkillIndex.text(for: [skill("zeta", "Last."), skill("alpha", "First.", body: "SECRET BODY")])
        #expect(text.hasPrefix("Skills: "))
        #expect(text.hasSuffix("- alpha: First.\n- zeta: Last."))
        #expect(!text.contains("SECRET BODY"), "only the index, never a body")
        #expect(text == SkillIndex.text(for: [skill("alpha", "First."), skill("zeta", "Last.")]), "stable whatever the order")
        #expect(SkillIndex.text(for: []) == "")
    }

    @Test func theBuiltInNaverSkillShipsWithItsScripts() throws {
        let naver = try #require(SkillStore.bundled().first { $0.name == "naver-places" })
        try naver.validate()
        #expect(naver.isBuiltIn)
        for marker in ["naver-places:list", "naver-places:more", "naver-places:details", "naver-places:reviews"] {
            #expect(skillScript(naver, marker: marker) != nil, "\(marker)")
        }
        #expect(naver.scripts.map(\.name) == ["LIST", "MORE", "DETAILS", "REVIEWS"])
        // load_skill shows how to run them, not their code.
        let loaded = LoadSkillTool(store: SkillStore(builtIn: [naver], directory: nil)).run(name: "naver-places").text
        #expect(loaded.contains("[Script REVIEWS") && !loaded.contains("// naver-places:reviews"))
        #expect(loaded.count * 10 < naver.body.count * 7, "\(loaded.count) of \(naver.body.count)")
        for scheme in ["nmap://route/walk", "nmap://route/public", "nmap://route/car", "nmap://route/bicycle"] {
            #expect(naver.body.contains(scheme))
        }
    }
}

struct SkillStoreTests {
    @Test func loadSkillReturnsTheBody() {
        let store = SkillStore(builtIn: [skill("demo", body: "Open the page.")], directory: nil)
        let out = LoadSkillTool(store: store).run(name: " demo ")
        #expect(!out.isError && out.text == "Skill: demo\n\nOpen the page.")
        let missing = LoadSkillTool(store: store).run(name: "nope")
        #expect(missing.isError && missing.text.contains("Available skills: demo."))
    }

    @Test func savedSkillsPersistAndCannotReplaceBuiltIns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SkillStore(builtIn: [skill("built")], directory: dir)
        try store.save(skill("mine", "Mine.", body: "Do it."))
        #expect(throws: Skill.Problem.builtInName("built")) { try store.save(skill("built")) }
        let reopened = SkillStore(builtIn: [skill("built")], directory: dir)
        #expect(reopened.all.map(\.name) == ["built", "mine"])
        #expect(reopened.skill(named: "mine")?.body == "Do it.")
        reopened.delete(named: "mine")
        #expect(SkillStore(builtIn: [], directory: dir).all.isEmpty)
    }
}

@MainActor
struct SkillIndexFreezingTests {
    private func system(_ request: ChatRequest) -> String {
        guard let first = request.messages.first, first.role == "system", case .text(let t) = first.content else { return "" }
        return t
    }

    @Test func aChatKeepsTheSkillListItStartedWith() async throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.strataID)
        var strata = connections.connection(Connection.strataID)!
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let settings = AppSettings(defaults: defaults)
        settings.pythonEnabled = false
        settings.generateTitles = false
        let streamer = ProgrammableStreamer([])
        let controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
        let store = SkillStore(builtIn: [skill("first-skill", "The first.")], directory: nil)
        controller.skills = store
        let context = container.mainContext
        func newChat() -> Conversation {
            let c = Conversation(connectionID: Connection.strataID, modelID: "m", effort: .medium)
            context.insert(c)
            return c
        }

        let chat = newChat()
        controller.send(text: "hi", images: [], conversation: chat, context: context)
        await controller.waitUntilIdle()
        try store.save(skill("second-skill", "The second."))
        controller.send(text: "again", images: [], conversation: chat, context: context)
        await controller.waitUntilIdle()

        let first = system(streamer.requests[0])
        #expect(first.contains("- first-skill: The first."))
        #expect(!first.contains("second-skill"))
        #expect(system(streamer.requests[1]) == first, "byte-identical, so the cached prefix holds")

        let next = newChat()
        controller.send(text: "hi", images: [], conversation: next, context: context)
        await controller.waitUntilIdle()
        #expect(system(streamer.requests[2]).contains("- second-skill: The second."))

        settings.browserEnabled = false
        let off = newChat()
        controller.send(text: "hi", images: [], conversation: off, context: context)
        await controller.waitUntilIdle()
        #expect(!system(streamer.requests[3]).contains("Skills:"), "no list without the browser tools")
        #expect(off.skillIndexSnapshot == nil)
    }
}

/// Runs the naver-places scripts against the live site. Off by default (network); run with
/// `TEST_RUNNER_STRATA_LIVE_NAVER=1 xcodebuild test -only-testing:StrataTests/NaverLiveTests`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STRATA_LIVE_NAVER"] == "1"), .serialized)
struct NaverLiveTests {
    private struct Place: Decodable { var name: String; var category: String?; var placeId: String; var rating: Double?; var reviewCount: Double? }
    private struct Details: Decodable { var name: String; var address: String?; var lat: Double?; var lng: Double?; var rating: Double? }

    private func body(_ out: ToolOutput) -> String {
        guard let end = out.text.range(of: "\n\n") else { return out.text }
        return String(out.text[end.upperBound...])
    }

    @Test(arguments: ["성수 조용한 카페", "합정 저녁"])
    func theSkillScriptsReadLivePages(query: String) async throws {
        let naver = try #require(SkillStore.bundled().first { $0.name == "naver-places" })
        let chat = UUID()
        defer { BrowserSessions.shared.close(chat) }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let opened = await BrowserOpenTool().run(urlString: "https://m.search.naver.com/search.naver?query=" + encoded, conversation: chat)
        #expect(!opened.isError, "\(opened.text.prefix(300))")
        let store = SkillStore(builtIn: [naver], directory: nil)
        func run(_ script: String) async -> ToolOutput {
            await RunSkillScriptTool(store: store).run(skill: "naver-places", script: script, argsJSON: nil, conversation: chat)
        }
        let listed = await run("LIST")
        print("LIVE list \(query): \(body(listed).prefix(1500))")
        let places = try JSONDecoder().decode([Place].self, from: Data(body(listed).utf8))
        #expect(places.count >= 3)
        let first = try #require(places.first)

        _ = await BrowserOpenTool().run(urlString: "https://m.place.naver.com/place/\(first.placeId)/home", conversation: chat)
        let detailed = await run("DETAILS")
        print("LIVE details \(first.name): \(body(detailed))")
        let details = try JSONDecoder().decode(Details.self, from: Data(body(detailed).utf8))
        #expect(details.lat != nil && details.lng != nil && details.address != nil)

        _ = await BrowserOpenTool().run(urlString: "https://m.place.naver.com/place/\(first.placeId)/review/visitor", conversation: chat)
        let reviews = await run("REVIEWS")
        print("LIVE reviews \(first.name): \(body(reviews).prefix(800))")
        #expect(body(reviews).hasPrefix("[{"))
    }
}

private final class AskLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [SkillApprovals.Request] = []
    var asked: [SkillApprovals.Request] { lock.withLock { _asked } }
    func add(_ r: SkillApprovals.Request) { lock.withLock { _asked.append(r) } }
}

struct SaveSkillTests {
    private func tool(_ store: SkillStore, answer: Bool, log: AskLog) -> SaveSkillTool {
        SaveSkillTool(store: store) { request in log.add(request); return answer }
    }

    @Test func nothingIsSavedWithoutApproval() async {
        let store = SkillStore(builtIn: [], directory: nil)
        let log = AskLog()
        let out = await tool(store, answer: false, log: log).run(name: "bus-times", description: "Seoul bus times.", body: "Open the page.")
        #expect(out.isError && out.text.contains("declined"))
        #expect(store.all.isEmpty)
        #expect(log.asked.map(\.skill.body) == ["Open the page."], "the user saw the whole skill")
    }

    @Test func anApprovedSkillIsSaved() async {
        let store = SkillStore(builtIn: [], directory: nil)
        let log = AskLog()
        let out = await tool(store, answer: true, log: log).run(name: "bus-times", description: "Seoul bus times.", body: "Open the page.")
        #expect(!out.isError)
        #expect(store.skill(named: "bus-times")?.body == "Open the page.")
        #expect(log.asked.first?.replaces == nil)
        _ = await tool(store, answer: true, log: log).run(name: "bus-times", description: "Newer.", body: "Open it twice.")
        #expect(log.asked.last?.replaces?.body == "Open the page.", "the sheet says it replaces the saved one")
        #expect(store.skill(named: "bus-times")?.description == "Newer.")
    }

    @Test func badSkillsAndBuiltInNamesAreRefusedBeforeAsking() async {
        let store = SkillStore(builtIn: [skill("naver-places")], directory: nil)
        let log = AskLog()
        let builtIn = await tool(store, answer: true, log: log).run(name: "naver-places", description: "Mine.", body: "Mine.")
        #expect(builtIn.isError && builtIn.text.contains("built-in"))
        let badName = await tool(store, answer: true, log: log).run(name: "Bus Times", description: "x", body: "y")
        #expect(badName.isError)
        #expect(log.asked.isEmpty)
        #expect(store.skill(named: "naver-places")?.isBuiltIn == true)
    }

    @MainActor
    @Test func approvalsWaitForTheAnswerOneAtATime() async {
        let approvals = SkillApprovals()
        let first = SkillApprovals.Request(skill: skill("one"), replaces: nil)
        let second = SkillApprovals.Request(skill: skill("two"), replaces: nil)
        let a = Task { await approvals.ask(first) }
        while approvals.pending == nil { await Task.yield() }
        let b = Task { await approvals.ask(second) }
        for _ in 0..<20 { await Task.yield() }
        #expect(approvals.pending?.id == first.id, "the second waits its turn")
        approvals.answer(first.id, approved: true)
        #expect(await a.value == true)
        while approvals.pending?.id != second.id { await Task.yield() }
        b.cancel()
        #expect(await b.value == false, "a stopped turn counts as no")
        #expect(approvals.pending == nil)
    }
}

struct SkillScriptTests {
    private let body = """
    Open the page, then run LIST.

    ```js script=LIST
    return args.limit ?? 5;
    ```

    Not a script:

    ```js
    return 1;
    ```

    ```javascript script: "REV-2"
    return "reviews";
    ```
    """

    @Test func namedBlocksAreScripts() {
        let skill = Skill(name: "demo", description: "Demo.", body: body)
        #expect(skill.scripts.map(\.name) == ["LIST", "REV-2"])
        #expect(skill.script(named: "list")?.code == "return args.limit ?? 5;")
        #expect(skill.script(named: "nope") == nil)
        let shown = skill.bodyForModel
        #expect(shown.contains("[Script LIST, 1 lines: run it with run_skill_script(skill: \"demo\", script: \"LIST\")."))
        #expect(shown.contains("```js\nreturn 1;\n```"), "an unnamed block stays as it is")
        #expect(!shown.contains("args.limit"))
    }

    @Test func loadSkillGivesOneScriptsCode() {
        let store = SkillStore(builtIn: [Skill(name: "demo", description: "Demo.", body: body)], directory: nil)
        let out = LoadSkillTool(store: store).run(name: "demo", script: "REV-2")
        #expect(!out.isError && out.text.contains("return \"reviews\";"))
        let missing = LoadSkillTool(store: store).run(name: "demo", script: "X")
        #expect(missing.isError && missing.text.contains("Its scripts: LIST, REV-2."))
    }

    @Test func argsAreDeclaredFirstAndMustBeAnObject() throws {
        #expect(try RunSkillScriptTool.code("return args;", argsJSON: nil).get() == "const args = {};\nreturn args;")
        #expect(try RunSkillScriptTool.code("return args;", argsJSON: "{\"a\":1}").get() == "const args = {\"a\":1};\nreturn args;")
        #expect((try? RunSkillScriptTool.code("x", argsJSON: "[1]").get()) == nil)
        #expect((try? RunSkillScriptTool.code("x", argsJSON: "1); alert(1); (").get()) == nil)
    }

    @MainActor @Test func runningAMissingScriptSaysWhatExists() async {
        let store = SkillStore(builtIn: [Skill(name: "demo", description: "Demo.", body: body)], directory: nil)
        let out = await RunSkillScriptTool(store: store).run(skill: "demo", script: "GONE", argsJSON: nil, conversation: UUID())
        #expect(out.isError && out.text.contains("Its scripts: LIST, REV-2."))
        let noSkill = await RunSkillScriptTool(store: store).run(skill: "other", script: "LIST", argsJSON: nil, conversation: UUID())
        #expect(noSkill.isError && noSkill.text.contains("Available skills: demo."))
    }
}
