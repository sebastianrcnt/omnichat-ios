import Testing
import Foundation
import SwiftData
@testable import Strata

struct AutoRenameCleanTests {
    @Test(arguments: [
        ("Docker Compose Networking Basics", "Docker Compose Networking Basics"),
        ("  \"Docker Compose Networking\"  ", "Docker Compose Networking"),
        ("Title: Fixing the Login Bug", "Fixing the Login Bug"),
        ("name:   Fixing the Login Bug", "Fixing the Login Bug"),
        ("TITLE:\tFixing", "Fixing"),
        ("# **Streaming Markdown Perf**", "Streaming Markdown Perf"),
        ("`Rust Borrow Checker`", "Rust Borrow Checker"),
        ("Planning a trip to Kyoto.", "Planning a trip to Kyoto"),
        ("\u{201C}SQL NULL handling\u{201D}", "SQL NULL handling"),
        ("First line\nSecond line", "First line"),
        ("\n\n  Leading blanks\nrest", "Leading blanks"),
        ("Too    many     spaces", "Too many spaces"),
        ("SQL 집계 함수와 NULL 처리", "SQL 집계 함수와 NULL 처리"),
        ("", ""),
        ("   \n  ", ""),
        ("\"\"", ""),
        ("Title:", ""),
    ])
    func cleans(input: String, expected: String) {
        #expect(AutoRename.cleanName(input) == expected)
    }

    @Test func clipsToEightyCharactersAndTrims() {
        let long = String(repeating: "word ", count: 30)
        let cleaned = AutoRename.cleanName(long)
        #expect(cleaned.count <= 80)
        #expect(!cleaned.hasSuffix(" "))
    }
}

struct AutoRenamePromptTests {
    private func lines(_ n: Int) -> [AutoRename.Line] {
        (0..<n).map { AutoRename.Line(role: $0 % 2 == 0 ? .user : .assistant, text: "m\($0)") }
    }

    @Test func listsRolesLatestLastAndEndsWithTitle() throws {
        let p = try #require(AutoRename.prompt(currentTitle: nil, lines: [
            .init(role: .user, text: "How do I center a div?"), .init(role: .assistant, text: "Use flexbox."),
        ]))
        #expect(p == "The conversation so far (latest last):\n\nUser: How do I center a div?\n\nAssistant: Use flexbox.\n\nTitle:")
    }

    @Test func includesTheExistingTitleLineOnlyWhenThereIsOne() throws {
        let with = try #require(AutoRename.prompt(currentTitle: "Centering divs", lines: lines(2)))
        #expect(with.hasPrefix("The conversation is named \"Centering divs\" now.\n\nThe conversation so far"))
        let empty = try #require(AutoRename.prompt(currentTitle: "  ", lines: lines(2)))
        #expect(empty.hasPrefix("The conversation so far"))
        let none = try #require(AutoRename.prompt(currentTitle: "", lines: lines(2)))
        #expect(none == empty)
    }

    @Test func clipsUserTo600AndAssistantTo300WithAnEllipsis() throws {
        let p = try #require(AutoRename.prompt(currentTitle: nil, lines: [
            .init(role: .user, text: String(repeating: "u", count: 700)),
            .init(role: .assistant, text: String(repeating: "a", count: 400)),
        ]))
        #expect(p.contains("User: " + String(repeating: "u", count: 600) + "\u{2026}"))
        #expect(!p.contains(String(repeating: "u", count: 601)))
        #expect(p.contains("Assistant: " + String(repeating: "a", count: 300) + "\u{2026}"))
        #expect(!p.contains(String(repeating: "a", count: 301)))
        let short = try #require(AutoRename.prompt(currentTitle: nil, lines: [.init(role: .user, text: String(repeating: "u", count: 600))]))
        #expect(!short.contains("\u{2026}"), "exactly at the limit is not clipped")
    }

    @Test func usesOnlyTheLastThirtyMessages() throws {
        let p = try #require(AutoRename.prompt(currentTitle: nil, lines: lines(40)))
        #expect(!p.contains("m9\n") && !p.contains("User: m0\n"))
        #expect(p.contains("User: m10\n\n") && p.contains("Assistant: m39\n\nTitle:"))
        #expect(p.components(separatedBy: "\n\n").filter { $0.hasPrefix("User:") || $0.hasPrefix("Assistant:") }.count == 30)
    }

    @Test func nothingToNameWithoutAUserMessage() {
        #expect(AutoRename.prompt(currentTitle: nil, lines: []) == nil)
        #expect(AutoRename.prompt(currentTitle: nil, lines: [.init(role: .assistant, text: "hi")]) == nil)
    }

    @Test func requestIsStandaloneAndSmall() throws {
        let r = AutoRename.request(model: "m", prompt: "P", effort: "none")
        #expect(r.maxTokens == 64 && r.reasoningEffort == "none" && r.tools == nil && r.toolChoice == nil)
        #expect(r.messages.count == 2)
        let json = try String(decoding: r.encoded(), as: UTF8.self)
        #expect(json.contains("\"max_tokens\":64") && json.contains(AutoRename.system))
        // Chat requests do not mention max_tokens, so their bytes are unchanged.
        let chat = try String(decoding: ChatRequest(model: "m", messages: [.user("hi")]).encoded(), as: UTF8.self)
        #expect(!chat.contains("max_tokens"))
    }
}

struct AutoRenameTriggerTests {
    @Test func runsOnlyAfterTheFirstAnswerAndNeverOverAUserTitle() {
        #expect(AutoRename.shouldRunAutomatically(titleIsUserSet: false, alreadyAutoNamed: false, completedAnswers: 1))
        #expect(!AutoRename.shouldRunAutomatically(titleIsUserSet: false, alreadyAutoNamed: false, completedAnswers: 0))
        #expect(!AutoRename.shouldRunAutomatically(titleIsUserSet: false, alreadyAutoNamed: false, completedAnswers: 2))
        #expect(!AutoRename.shouldRunAutomatically(titleIsUserSet: true, alreadyAutoNamed: false, completedAnswers: 1))
        #expect(!AutoRename.shouldRunAutomatically(titleIsUserSet: false, alreadyAutoNamed: true, completedAnswers: 1))
    }

    @Test func userTitlesSetTheFlagAndStoppedOrFailedAnswersDoNotCount() {
        let c = Conversation()
        #expect(!c.titleIsUserSet && !c.autoRenameDone)
        c.setUserTitle("Mine")
        #expect(c.titleIsUserSet && c.title == "Mine")
        let ok = Message(role: .assistant, text: "answer", sortIndex: 1)
        let stopped = Message(role: .assistant, text: "part", sortIndex: 2); stopped.stoppedByUser = true
        let failed = Message(role: .assistant, text: "", sortIndex: 3); failed.errorText = "boom"
        c.messages = [ok, stopped, failed, Message(role: .user, text: "q", sortIndex: 0)]
        #expect(c.completedAnswerCount == 1)
        #expect(c.namingLines.map(\.role) == [.user, .assistant, .assistant])
    }
}

@MainActor
struct AutoRenameFlowTests {
    private func endpoint(effort: Bool) -> Endpoint {
        Endpoint(connectionID: UUID(), connectionName: "c", baseURL: URL(string: "https://x.test/v1")!, apiKey: "k", headers: [:],
                 model: ModelInfo(id: "m", supportsEffort: effort))
    }

    @Test func retriesOnceWithoutReasoningEffortAfterAFailure() async {
        let streamer = ProgrammableStreamer([
            ([], .fail(APIError.http(status: 400, message: "reasoning_effort not supported"))),
            ([ChatDelta(content: "\"Fixing Login Bug\"\n")], .finish),
        ])
        let name = await AutoRename.generate(prompt: "P", endpoint: endpoint(effort: true), streamer: streamer)
        #expect(name == "Fixing Login Bug")
        #expect(streamer.requests.count == 2)
        #expect(streamer.requests[0].reasoningEffort == "none" && streamer.requests[1].reasoningEffort == nil)
    }

    @Test func modelsWithoutEffortNeverSendIt() async {
        let streamer = ProgrammableStreamer([([ChatDelta(content: "Name")], .finish)])
        _ = await AutoRename.generate(prompt: "P", endpoint: endpoint(effort: false), streamer: streamer)
        #expect(streamer.requests.map(\.reasoningEffort) == [nil])
    }

    @Test func failureTwiceOrAnEmptyNameChangesNothing() async {
        let failing = ProgrammableStreamer([([], .fail(APIError.transport("x"))), ([], .fail(APIError.transport("y")))])
        #expect(await AutoRename.generate(prompt: "P", endpoint: endpoint(effort: true), streamer: failing) == nil)
        let blank = ProgrammableStreamer([([ChatDelta(content: "  \"\" ")], .finish)])
        #expect(await AutoRename.generate(prompt: "P", endpoint: endpoint(effort: false), streamer: blank) == nil)
    }

    @Test func aHungRequestTimesOutWithoutBlocking() async {
        let hang = ProgrammableStreamer([([], .hang), ([], .hang)])
        let started = ContinuousClock.now
        let name = await AutoRename.generate(prompt: "P", endpoint: endpoint(effort: true), streamer: hang, timeout: .milliseconds(100))
        #expect(name == nil)
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}
