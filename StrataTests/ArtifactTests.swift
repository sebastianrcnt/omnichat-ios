import Foundation
import Testing
@testable import Strata

private func tempStore() -> ArtifactStore {
    ArtifactStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("artifacts-\(UUID().uuidString)", isDirectory: true))
}

struct ArtifactStoreTests {
    @Test func newArtifactsGetIdsUniqueWithinTheChat() throws {
        let store = tempStore()
        let chat = UUID(), other = UUID()
        let one = try store.save(title: "Chart", html: "<p>1</p>", conversationID: chat)
        let two = try store.save(title: "Game", html: "<p>2</p>", conversationID: chat)
        let elsewhere = try store.save(title: "Notes", html: "<p>3</p>", conversationID: other)
        #expect(one.id == "a1" && two.id == "a2" && elsewhere.id == "a1")
        #expect(one.version == 1 && two.version == 1)
        #expect(store.artifacts(conversationID: chat).map(\.id) == ["a1", "a2"])
        #expect(store.html(id: "a2", conversationID: chat) == "<p>2</p>")
    }

    @Test func anUpdateReplacesTheHTMLAndCountsTheVersion() throws {
        let store = tempStore()
        let chat = UUID()
        let start = Date(timeIntervalSince1970: 1_000_000)
        try store.save(title: "Chart", html: "<p>old</p>", conversationID: chat, callID: "c1", now: start)
        let second = try store.save(title: "", html: "<p>new</p>", id: "a1", conversationID: chat, callID: "c2", now: start + 60)
        #expect(second.version == 2 && second.title == "Chart", "a blank title keeps the old one")
        #expect(second.created == start && second.updated == start + 60 && second.callID == "c2")
        let third = try store.save(title: "Better chart", html: "<p>newer</p>", id: " A1 ", conversationID: chat)
        #expect(third.version == 3 && third.title == "Better chart")
        #expect(store.artifacts(conversationID: chat).count == 1, "only the newest version is kept")
        #expect(store.html(id: "a1", conversationID: chat) == "<p>newer</p>")
    }

    @Test func itSurvivesARelaunch() throws {
        let store = tempStore()
        let chat = UUID()
        try store.save(title: "Chart", html: "<p>x</p>", conversationID: chat)
        try store.save(title: "Chart", html: "<p>y</p>", id: "a1", conversationID: chat)
        let reopened = ArtifactStore(root: store.root)
        #expect(reopened.artifact(id: "a1", conversationID: chat)?.version == 2)
        #expect(reopened.html(id: "a1", conversationID: chat) == "<p>y</p>")
        #expect(try reopened.save(title: "Next", html: "<p>z</p>", conversationID: chat).id == "a2")
    }

    @Test func badSavesSayWhatIsWrong() throws {
        let store = tempStore()
        let chat = UUID()
        #expect(throws: ArtifactError.emptyHTML) { try store.save(title: "x", html: "  \n", conversationID: chat) }
        #expect(throws: ArtifactError.unknownID("a9", known: [])) { try store.save(title: "x", html: "<p/>", id: "a9", conversationID: chat) }
        try store.save(title: "x", html: "<p/>", conversationID: chat)
        #expect(throws: ArtifactError.unknownID("a9", known: ["a1"])) { try store.save(title: "x", html: "<p/>", id: "a9", conversationID: chat) }
        #expect(throws: ArtifactError.unknownID("../index", known: ["a1"])) {
            try store.save(title: "x", html: "<p/>", id: "../index", conversationID: chat)
        }
    }

    @Test func theSizeIsCapped() throws {
        let store = tempStore()
        let chat = UUID()
        let limit = ArtifactStore.maxBytes
        #expect(throws: ArtifactError.tooLarge(bytes: limit + 1)) {
            try store.save(title: "Big", html: String(repeating: "a", count: limit + 1), conversationID: chat)
        }
        #expect(store.artifacts(conversationID: chat).isEmpty)
        #expect(try store.save(title: "Fits", html: String(repeating: "a", count: limit), conversationID: chat).id == "a1")
        // Multi-byte text counts in bytes, not characters.
        #expect(throws: ArtifactError.self) {
            try store.save(title: "Big", html: String(repeating: "가", count: limit / 3 + 1), conversationID: chat)
        }
        let message = ArtifactError.tooLarge(bytes: 3 * 1024 * 1024 + 300_000).errorDescription ?? ""
        #expect(message.hasPrefix("The HTML is 3.3 MB; an artifact can be at most 2 MB."))
    }

    @Test func idsNeverNameAPath() {
        #expect(ArtifactStore.normalizedID("a3") == "a3")
        #expect(ArtifactStore.normalizedID(" A3 ") == "a3")
        #expect(ArtifactStore.normalizedID("3") == "a3")
        #expect(ArtifactStore.normalizedID("../a1") == nil)
        #expect(ArtifactStore.normalizedID("a0") == nil)
        #expect(ArtifactStore.normalizedID("index") == nil)
    }

    @Test func deletingAChatDeletesItsArtifacts() throws {
        let store = tempStore()
        let chat = UUID(), kept = UUID()
        try store.save(title: "Gone", html: "<p/>", conversationID: chat)
        try store.save(title: "Kept", html: "<p/>", conversationID: kept)
        store.removeAll(conversationID: chat)
        #expect(store.artifacts(conversationID: chat).isEmpty)
        #expect(store.html(id: "a1", conversationID: chat) == nil)
        #expect(store.allArtifacts().map(\.artifact.title) == ["Kept"])
    }

    @Test func theListCoversEveryChatNewestFirstAndOnlyChatsThatExist() throws {
        let store = tempStore()
        let a = UUID(), b = UUID(), deleted = UUID()
        let t = Date(timeIntervalSince1970: 2_000_000)
        try store.save(title: "Oldest", html: "<p/>", conversationID: a, now: t)
        try store.save(title: "Middle", html: "<p/>", conversationID: b, now: t + 10)
        try store.save(title: "Stray", html: "<p/>", conversationID: deleted, now: t + 15)
        try store.save(title: "Newest", html: "<p/>", conversationID: a, now: t + 20)
        // Updating moves an artifact to the top.
        try store.save(title: "", html: "<p>2</p>", id: "a1", conversationID: b, now: t + 30)
        #expect(store.allArtifacts().count == 4)
        let listed = store.allArtifacts(existing: [a, b])
        #expect(listed.map(\.artifact.title) == ["Middle", "Newest", "Oldest"])
        #expect(listed.first?.conversationID == b && listed.first?.ref.version == 2)
        #expect(Set(listed.map(\.id)).count == 3, "entries of different chats never share an id")
    }
}

struct ShowHTMLToolTests {
    @Test func theResultTellsTheModelHowToUpdate() {
        let store = tempStore()
        let chat = UUID()
        let tool = ShowHTMLTool(store: store)
        let first = tool.run(arguments: ["title": "Mortgage calculator", "html": "<h1>Hi</h1>"], conversationID: chat, callID: "c1")
        #expect(!first.isError)
        #expect(first.text == #"Shown to the user as artifact "Mortgage calculator" (id: a1, version 1). To change it, call show_html again with id "a1" and the full new HTML."#)
        #expect(first.artifact == ArtifactRef(conversationID: chat, id: "a1", title: "Mortgage calculator", version: 1))
        let second = tool.run(arguments: ["title": "Mortgage calculator", "html": "<h1>Hi again</h1>", "id": "a1"], conversationID: chat, callID: "c2")
        #expect(second.text.hasPrefix(#"Shown to the user as artifact "Mortgage calculator" (id: a1, version 2)."#))
        #expect(store.artifact(id: "a1", conversationID: chat)?.callID == "c2")
        let byNumber = tool.run(arguments: ["title": "", "html": "<h1>3</h1>", "id": 1], conversationID: chat, callID: nil)
        #expect(byNumber.artifact?.version == 3)
        let blankID = tool.run(arguments: ["title": "Other", "html": "<p/>", "id": " "], conversationID: chat, callID: nil)
        #expect(blankID.artifact?.id == "a2", "a blank id makes a new artifact")
    }

    @Test func badArgumentsAreErrors() {
        let store = tempStore()
        let chat = UUID()
        let tool = ShowHTMLTool(store: store)
        let missing = tool.run(arguments: ["title": "x"], conversationID: chat, callID: nil)
        #expect(missing.isError && missing.text == #"Error: missing required argument "html"."#)
        let unknown = tool.run(arguments: ["title": "x", "html": "<p/>", "id": "a7"], conversationID: chat, callID: nil)
        #expect(unknown.isError && unknown.text.contains(#"No artifact with id "a7""#) && unknown.artifact == nil)
        let tooBig = tool.run(arguments: ["title": "x", "html": String(repeating: "a", count: ArtifactStore.maxBytes + 1)],
                              conversationID: chat, callID: nil)
        #expect(tooBig.isError && tooBig.text.contains("at most 2 MB"))
        let nowhere = tool.run(arguments: ["title": "x", "html": "<p/>"], conversationID: nil, callID: nil)
        #expect(nowhere.isError)
        #expect(store.allArtifacts().isEmpty)
    }

    @Test func theRouterRunsItForTheChat() async {
        let store = tempStore()
        let chat = UUID()
        let router = ToolRouter(artifacts: store)
        let out = await ToolContext.$conversationID.withValue(chat) {
            await ToolContext.$callID.withValue("call_1") {
                await router.execute(name: "show_html", arguments: #"{"title": "Demo", "html": "<p>demo</p>"}"#)
            }
        }
        #expect(!out.isError && out.artifact?.conversationID == chat)
        #expect(store.artifact(id: "a1", conversationID: chat)?.callID == "call_1")
    }

    @Test func itIsOfferedWheneverToolsAre() throws {
        for python in [false, true] {
            for images in [false, true] {
                for browser in [false, true] {
                    let names = ToolDefinition.available(python: python, images: images, browser: browser).map(\.function.name)
                    #expect(names.filter { $0 == "show_html" }.count == 1)
                    #expect(Array(names.prefix(4)) == ["web_search", "web_fetch", "run_plugin", "show_html"])
                }
            }
        }
        let definition = ToolDefinition.showHTML.function
        #expect(definition.parameters.required == ["title", "html"])
        #expect(definition.parameters.properties["id"] != nil)
        #expect(definition.description.contains("complete"))
    }

    @Test func theCardKeepsTheArtifact() throws {
        let chat = UUID()
        var record = ToolCallRecord(id: "c1", name: ToolNames.showHTML, arguments: #"{"title": "Demo", "html": "<p/>"}"#,
                                    result: "Shown…", isError: false)
        record.artifact = ArtifactRef(conversationID: chat, id: "a1", title: "Demo", version: 2)
        let decoded = try JSONDecoder().decode(ToolCallRecord.self, from: JSONEncoder().encode(record.displayOnly))
        #expect(decoded.artifact == record.artifact)
        #expect(decoded.primaryArgument == "Demo")
        let raw = RawToolResult(callID: "c1", output: record.output)
        #expect(raw.output.artifact == record.artifact)
        let cards = ActivityFeed.cards(calls: [FeedCall(record: decoded)], sources: [:])
        #expect(cards.count == 1 && cards[0].kind == .artifact(title: "Demo") && cards[0].artifact?.version == 2)
        #expect(ProcessSegment.toolTitle(calls: [record]).contains("Made an artifact"))
    }
}

struct ArtifactHTMLTests {
    @Test func aFragmentBecomesADocument() {
        let page = ArtifactHTML.prepared("<h1>Hi</h1>")
        #expect(page.hasPrefix("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\""))
        #expect(page.hasSuffix("<body><h1>Hi</h1></body></html>"))
    }

    @Test func aDocumentGetsAViewportOnlyWhenItHasNone() {
        let bare = "<!DOCTYPE html><html><HEAD lang=\"en\"><title>x</title></HEAD><body></body></html>"
        #expect(ArtifactHTML.prepared(bare).contains("<HEAD lang=\"en\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>"))
        let fitted = "<html><head><meta name=\"viewport\" content=\"width=600\"></head></html>"
        #expect(ArtifactHTML.prepared(fitted) == fitted)
    }
}
