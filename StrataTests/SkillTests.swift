import Foundation
import SwiftData
import Testing
@testable import Strata

private func skill(_ name: String, _ description: String = "Does a thing.", body: String = "Step one.") -> Skill {
    Skill(name: name, description: description, body: body)
}

/// The fenced ```js block of a bundled skill that starts with `// <marker>`.
func skillScript(_ skill: Skill, marker: String) -> String? {
    let parts = skill.body.components(separatedBy: "```js\n")
    for part in parts.dropFirst() {
        guard let end = part.range(of: "\n```") else { continue }
        let code = String(part[..<end.lowerBound])
        if code.hasPrefix("// " + marker) { return code }
    }
    return nil
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
        let listed = await BrowserEvalTool().run(code: try #require(skillScript(naver, marker: "naver-places:list")), conversation: chat)
        print("LIVE list \(query): \(body(listed).prefix(1500))")
        let places = try JSONDecoder().decode([Place].self, from: Data(body(listed).utf8))
        #expect(places.count >= 3)
        let first = try #require(places.first)

        _ = await BrowserOpenTool().run(urlString: "https://m.place.naver.com/place/\(first.placeId)/home", conversation: chat)
        let detailed = await BrowserEvalTool().run(code: try #require(skillScript(naver, marker: "naver-places:details")), conversation: chat)
        print("LIVE details \(first.name): \(body(detailed))")
        let details = try JSONDecoder().decode(Details.self, from: Data(body(detailed).utf8))
        #expect(details.lat != nil && details.lng != nil && details.address != nil)

        _ = await BrowserOpenTool().run(urlString: "https://m.place.naver.com/place/\(first.placeId)/review/visitor", conversation: chat)
        let reviews = await BrowserEvalTool().run(code: try #require(skillScript(naver, marker: "naver-places:reviews")), conversation: chat)
        print("LIVE reviews \(first.name): \(body(reviews).prefix(800))")
        #expect(body(reviews).hasPrefix("[{"))
    }
}
