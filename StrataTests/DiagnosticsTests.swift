import Testing
import Foundation
import SwiftData
@testable import Strata

private func body(_ messages: [APIMessage], tools: Bool = true) throws -> Data {
    var r = ChatRequest(model: "m", messages: messages)
    if tools { r.tools = ToolDefinition.standard }
    return try r.encoded()
}

private let user1 = APIMessage.user("hello")
private let reply1 = APIMessage.assistant("", toolCalls: [ToolCall(id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}")])
private let result1 = APIMessage.tool(callID: "c1", content: "result")

struct PrefixNoteTests {
    @Test func firstRequestHasNoNote() throws {
        #expect(PrefixNote.describe(previous: nil, current: try body([user1])) == nil)
    }

    @Test func appendedMessagesAreTheSamePrefix() throws {
        let r = try #require(PrefixNote.describe(previous: try body([user1]), current: try body([user1, reply1, result1])))
        #expect(r.note == "same prefix, +2 messages")
        #expect(!r.toolsDiffer)
        #expect(r.text == "same prefix, +2 messages")
        let one = try #require(PrefixNote.describe(previous: try body([user1]), current: try body([user1, reply1])))
        #expect(one.note == "same prefix, +1 message")
    }

    @Test func identicalRequestsAddNothing() throws {
        let r = try #require(PrefixNote.describe(previous: try body([user1]), current: try body([user1])))
        #expect(r.note == "same prefix, +0 messages")
    }

    @Test func aChangedMessageNamesTheIndexAndRole() throws {
        let r = try #require(PrefixNote.describe(previous: try body([user1, reply1, result1]),
                                                  current: try body([user1, reply1, .user("different")])))
        #expect(r.note == "diverges at message 2 (user)")
    }

    @Test func aShorterRequestSaysSo() throws {
        let r = try #require(PrefixNote.describe(previous: try body([user1, reply1, result1]), current: try body([user1, reply1])))
        #expect(r.note == "shorter than the previous request (2 of its 3 messages)")
    }

    @Test func differentToolsAreFlaggedSeparately() throws {
        let r = try #require(PrefixNote.describe(previous: try body([user1], tools: true), current: try body([user1, reply1], tools: false)))
        #expect(r.note == "same prefix, +1 message")
        #expect(r.toolsDiffer)
        #expect(r.text == "same prefix, +1 message; tools differ")
    }

    @Test func keyOrderAndSpacingDoNotCount() {
        let a = Data(#"{"messages":[{"role":"user","content":"x"}],"tools":[1,2]}"#.utf8)
        let b = Data(#"{ "tools": [1, 2], "messages": [ {"content": "x", "role": "user"} ] }"#.utf8)
        let r = PrefixNote.describe(previous: a, current: b)
        #expect(r == PrefixNote.Result(note: "same prefix, +0 messages", toolsDiffer: false))
    }

    @Test func responseStyleBodiesUseInput() {
        #expect(RequestInspection.messages(in: Data(#"{"input":[{"role":"user"},{"role":"user"}]}"#.utf8)).count == 2)
        #expect(RequestInspection.messages(in: Data("not json".utf8)).isEmpty)
    }
}

struct RedactionTests {
    @Test func imagesBecomeTheirSize() {
        let jpeg = Data(repeating: 9, count: 300)
        let text = #"{"content":[{"type":"image_url","image_url":{"url":"\#(ContentPart.dataURLString(jpeg: jpeg))"}},{"type":"text","text":"hi"}]}"#
        let out = DebugRedaction.redact(text)
        #expect(out.contains("<image 300 bytes>"))
        #expect(!out.contains("base64"))
        #expect(out.hasSuffix(#""}},{"type":"text","text":"hi"}]}"#))
    }

    @Test func escapedSlashesInsideThePayloadAreHandled() {
        let payload = Data((0..<255).map(UInt8.init)).base64EncodedString() // contains "/" and "+"
        let escaped = payload.replacingOccurrences(of: "/", with: "\\/")
        let out = DebugRedaction.redact(#"{"u":"data:image\/jpeg;base64,\#(escaped)","after":1}"#)
        #expect(out == #"{"u":"<image 255 bytes>","after":1}"#)
    }

    @Test func keepingImagesLeavesThemAlone() {
        let text = #"{"u":"data:image/jpeg;base64,AAAA"}"#
        #expect(DebugRedaction.redact(text, options: .init(stripImages: false)) == text)
    }

    @Test func authorizationAndKeysAreRemoved() {
        let text = #"{"Authorization":"Bearer abcdefghijklmnop","api_key":"sk-abcdefghijklmnopqrstuv","x-api-key":"zzz","note":"use sk-abcdefghijklmnopqrstuv or Bearer ABCDEFGH12345678"}"#
        let out = DebugRedaction.redact(text)
        #expect(!out.contains("abcdefghijklmnop"))
        #expect(!out.contains("ABCDEFGH12345678"))
        #expect(!out.contains("zzz"))
        #expect(out.contains(#""Authorization":"<redacted>""#))
        #expect(out.contains("sk-<redacted>"))
    }

    @Test func ordinaryRequestsPassThroughByteForByte() throws {
        let data = try body([user1, reply1, result1])
        #expect(DebugRedaction.redact(data) == data)
    }
}

@MainActor
struct RequestRingTests {
    private func ring(keep: Int = 6, cap: Int = 2_000_000) -> RequestRing {
        let r = RequestRing(keepRecent: keep, byteCap: cap)
        r.compressesInline = true
        return r
    }

    @Test func keepsTheLastSixPerConversation() throws {
        let r = ring()
        let conv = UUID()
        for i in 0..<9 { r.record(conversationID: conv, url: "u", body: try body([.user("m\(i)")]), time: Date(timeIntervalSince1970: Double(i))) }
        let kept = r.recent(for: conv)
        #expect(kept.count == 6)
        #expect(kept.first?.time == Date(timeIntervalSince1970: 3))
        #expect(kept.last?.time == Date(timeIntervalSince1970: 8))
    }

    @Test func bodiesRoundTripThroughCompression() throws {
        let r = ring()
        let conv = UUID()
        let original = try body([.user(String(repeating: "lorem ipsum ", count: 2000))])
        r.record(conversationID: conv, url: "u", body: original)
        let record = try #require(r.recent(for: conv).first)
        #expect(record.storedBytes < original.count / 4)
        #expect(record.bodyBytes == original.count)
        #expect(record.messageCount == 1)
        #expect(RequestRing.body(of: record) == original)
    }

    @Test func totalSizeStaysUnderTheCapByDroppingTheOldest() throws {
        let r = ring(cap: 20_000)
        let a = UUID(), b = UUID()
        func noise(_ seed: Int) -> String { // does not compress well
            var g = SystemRandomNumberGenerator()
            return Data((0..<4000).map { _ in UInt8.random(in: 0...255, using: &g) }).base64EncodedString() + "\(seed)"
        }
        for i in 0..<8 {
            r.record(conversationID: i % 2 == 0 ? a : b, url: "u", body: try body([.user(noise(i))]), time: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(r.totalBytes <= 20_000)
        let all = (r.recent(for: a) + r.recent(for: b)).map(\.time)
        #expect(all.contains(Date(timeIntervalSince1970: 7)))
        #expect(!all.contains(Date(timeIntervalSince1970: 0)))
    }

    @Test func theNewestRequestSurvivesEvenWhenItAloneIsOverTheCap() throws {
        let r = ring(cap: 100)
        let conv = UUID()
        r.record(conversationID: conv, url: "u", body: try body([.user("one")]), time: Date(timeIntervalSince1970: 1))
        r.record(conversationID: conv, url: "u", body: try body([.user("two")]), time: Date(timeIntervalSince1970: 2))
        #expect(r.recent(for: conv).count == 1)
        #expect(r.recent(for: conv).first?.time == Date(timeIntervalSince1970: 2))
    }

    @Test func completionFillsTheFinishReasonAndUsage() throws {
        let r = ring()
        let conv = UUID()
        let id = r.record(conversationID: conv, url: "u", body: try body([user1]))
        r.complete(id, finishReason: "stop", usage: Usage(promptTokens: 10, completionTokens: 2, cachedTokens: 8))
        let record = try #require(r.recent(for: conv).first)
        #expect(record.finishReason == "stop" && record.usage?.cachedTokens == 8)
    }

    @Test func backgroundCompressionFinishesAndSettles() async throws {
        let r = RequestRing()
        let conv = UUID()
        r.record(conversationID: conv, url: "u", body: try body([.user(String(repeating: "x", count: 50_000))]))
        await r.settle()
        let record = try #require(r.recent(for: conv).first)
        guard case .deflated = record.storage else { Issue.record("not compressed"); return }
        #expect(record.messageCount == 1)
    }

    @Test func removingAConversationForgetsItsRequests() throws {
        let r = ring()
        let conv = UUID()
        r.record(conversationID: conv, url: "u", body: try body([user1]))
        r.removeConversation(conv)
        #expect(r.recent(for: conv).isEmpty && r.totalBytes == 0)
    }

    @Test func theControllerLogsEachRequestOfATurnWithItsNote() async throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.strataID)
        var strata = connections.connection(Connection.strataID)!
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let call = ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: "c1", name: "web_search", arguments: "{\"query\":\"q\"}")])
        let streamer = ProgrammableStreamer([
            ([call, ChatDelta(finishReason: "tool_calls")], .finish),
            ([ChatDelta(content: "Answer"), ChatDelta(usage: Usage(promptTokens: 30, completionTokens: 4, cachedTokens: 20)),
              ChatDelta(finishReason: "stop")], .finish),
        ])
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults), streamer: streamer, tools: FakeTools())
        let ring = RequestRing()
        ring.compressesInline = true
        controller.requestRing = ring
        let conversation = Conversation(connectionID: Connection.strataID, modelID: "m", effort: .medium)
        context.insert(conversation)
        controller.send(text: "hi", images: [], conversation: conversation, context: context)
        await controller.waitUntilIdle()

        let records = ring.recent(for: conversation.id)
        #expect(records.count == 2)
        #expect(records.map(\.finishReason) == ["tool_calls", "stop"])
        #expect(records[1].usage?.cachedTokens == 20)
        #expect(records[0].url.hasSuffix("/chat/completions"))
        let summaries = ConversationDiagnostics.requestSummaries(records, conversation: conversation.id)
        #expect(summaries[0].note == nil)
        #expect(summaries[1].note == "same prefix, +2 messages")
        #expect(summaries[1].messageCount == 4) // system, user, assistant tool call, tool result
    }
}

@MainActor
struct DebugBundleTests {
    private func makeRing(_ conv: UUID, images: Bool) throws -> RequestRing {
        let ring = RequestRing()
        ring.compressesInline = true
        let first = try body([.user("hello")])
        var parts: [ContentPart] = [.text("look")]
        if images { parts.append(.jpegDataURL(Data(repeating: 3, count: 600))) }
        ring.record(conversationID: conv, url: "https://gw.example/v1/chat/completions", body: first, time: Date(timeIntervalSince1970: 1_700_000_000))
        ring.record(conversationID: conv, url: "https://gw.example/v1/chat/completions",
                    body: try body([.user("hello"), .assistant("hi"), .user(parts: parts)]), time: Date(timeIntervalSince1970: 1_700_000_060))
        return ring
    }

    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bundle-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func writesTheFilesWithAttoFormattedIndex() throws {
        let conv = UUID()
        let ring = try makeRing(conv, images: true)
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_100)
        let folder = try DebugBundle.write(app: AppDiagnostics(), conversations: [ConversationDiagnostics(id: conv, title: "T")],
                                           ring: ring, root: root, now: date)
        #expect(folder.lastPathComponent == DebugBundle.folderName(for: date))
        let fm = FileManager.default
        for name in ["report.json", "memstats.txt", "index.txt"] { #expect(fm.fileExists(atPath: folder.appendingPathComponent(name).path)) }
        let stem = ConversationDiagnostics.fileStem(for: conv)
        let second = folder.appendingPathComponent("requests/\(stem)-2.json")
        let written = try String(contentsOf: second, encoding: .utf8)
        #expect(written.contains("<image 600 bytes>") && !written.contains("base64"))

        let index = try String(contentsOf: folder.appendingPathComponent("index.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(index.count == 2)
        #expect(index[0].hasPrefix("requests/\(stem)-1.json  "))
        #expect(index[0].contains("  https://gw.example/v1/chat/completions  "))
        #expect(index[0].hasSuffix(" bytes, 1 messages"))
        #expect(index[1].contains(" bytes, 3 messages; same prefix, +2 messages"))
        // The size in the index is the size that was sent, not the stripped file's.
        let sentBytes = try #require(ring.recent(for: conv).last?.bodyBytes)
        #expect(index[1].contains("  \(sentBytes) bytes, "))
    }

    @Test func imagesCanBeKept() throws {
        let conv = UUID()
        let ring = try makeRing(conv, images: true)
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try DebugBundle.write(app: AppDiagnostics(), conversations: [], ring: ring,
                                           options: .init(stripImages: false), root: root)
        let stem = ConversationDiagnostics.fileStem(for: conv)
        let written = try String(contentsOf: folder.appendingPathComponent("requests/\(stem)-2.json"), encoding: .utf8)
        #expect(written.contains("data:image/jpeg;base64,"))
    }

    @Test func theReportDecodesAndCarriesNoSecrets() throws {
        let conv = UUID()
        let ring = try makeRing(conv, images: false)
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let details = ConversationDiagnostics(id: conv, title: "my key is sk-abcdefghijklmnopqrstuv")
        let folder = try DebugBundle.write(app: AppDiagnostics(), conversations: [details], ring: ring, root: root)
        let json = try Data(contentsOf: folder.appendingPathComponent("report.json"))
        let text = String(decoding: json, as: UTF8.self)
        #expect(!text.contains("abcdefghijklmnopqrstuv"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DebugBundle.Report.self, from: json)
        #expect(report.conversations.count == 1)
        #expect(report.conversations[0].requests.count == 2) // taken from the ring
        #expect(report.imagesStripped)
    }

    @Test func twoBundlesInTheSameSecondDoNotCollide() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let ring = RequestRing()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try DebugBundle.write(app: AppDiagnostics(), conversations: [], ring: ring, root: root, now: now)
        let b = try DebugBundle.write(app: AppDiagnostics(), conversations: [], ring: ring, root: root, now: now)
        #expect(a != b)
    }

    @Test func indexLineMatchesAttoFormat() {
        let r = ConversationDiagnostics.Request(file: "requests/ab-3.json", time: Date(timeIntervalSince1970: 0), url: "http://x/y",
                                                bodyBytes: 1234, storedBytes: 300, messageCount: 7, note: "diverges at message 2 (user)", toolsDiffer: true)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(DebugBundle.indexLine(r, calendar: cal) == "requests/ab-3.json  00:00:00  http://x/y  1234 bytes, 7 messages; diverges at message 2 (user); tools differ")
    }
}

@MainActor
struct ConversationDiagnosticsTests {
    @Test func measuresStorageContextAndStructure() throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let c = Conversation(title: "t", modelID: "m")
        context.insert(c)
        let u = Message(role: .user, text: "abcd", sortIndex: 0)
        u.conversation = c
        context.insert(u)
        let a = Attachment(jpegData: Data(repeating: 1, count: 200_000), sortIndex: 0)
        a.message = u
        context.insert(a)
        let m = Message(role: .assistant, text: "answer!!", sortIndex: 1)
        m.reasoning = "think"
        m.stepsData = Data(repeating: 0, count: 10)
        m.conversation = c
        context.insert(m)
        c.apply(Usage(promptTokens: 200, completionTokens: 20, cachedTokens: 150))

        let d = ConversationDiagnostics.make(for: c, window: 1000, ring: RequestRing(), counters: DiagnosticCounters())
        #expect(d.structure.messages == 2 && d.structure.userMessages == 1 && d.structure.assistantMessages == 1)
        #expect(d.structure.activePathLength == 2 && d.structure.branches == 1)
        #expect(d.storage.textBytes == 12 && d.storage.reasoningBytes == 5 && d.storage.stepsBytes == 10)
        #expect(d.storage.attachments == 1 && d.storage.attachmentFullBytes == 200_000)
        #expect(d.storage.externalValues == 1 && d.storage.externalBytes == 200_000)
        #expect(d.context.cacheHitPercent == 75)
        #expect(d.context.windowTokens == 1000)
        #expect(d.context.estimatedTokens == 12 / 4 + ContextEstimate.tokensPerImage)
    }

    @Test func checkpointStatsComeFromTheCounters() {
        let counters = DiagnosticCounters()
        let conv = UUID()
        counters.beginTurn(conversation: conv)
        counters.recordCheckpointWrite(conversation: conv, staticBytes: 5000, dynamicBytes: 100, at: Date(timeIntervalSince1970: 5))
        counters.recordCheckpointWrite(conversation: conv, staticBytes: nil, dynamicBytes: 120, at: Date(timeIntervalSince1970: 6))
        let s = counters.checkpointStats(for: conv)
        #expect(s == DiagnosticCounters.CheckpointStats(staticBytes: 5000, dynamicBytes: 120, flushCount: 2, bytesWritten: 5220, lastFlush: Date(timeIntervalSince1970: 6)))
        #expect(counters.checkpointBytesWritten == 5220 && counters.checkpointSaves == 2)
        counters.beginTurn(conversation: conv)
        #expect(counters.checkpointStats(for: conv)?.flushCount == 0)
        counters.forget(conversation: conv)
        #expect(counters.checkpointStats(for: conv) == nil)
    }
}

struct DiskAndMemoryTests {
    @Test func measuresTheStoreAndItsExternalFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let external = root.appendingPathComponent(".default_SUPPORT/_EXTERNAL_DATA", isDirectory: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: root.appendingPathComponent("default.store"))
        try Data(repeating: 1, count: 5_000).write(to: root.appendingPathComponent("default.store-wal"))
        try Data(repeating: 1, count: 20_000).write(to: external.appendingPathComponent("A"))
        try Data(repeating: 1, count: 30_000).write(to: external.appendingPathComponent("B"))
        try Data(repeating: 1, count: 99).write(to: root.appendingPathComponent("unrelated.txt"))
        let sizes = DiskUsage.swiftDataStore(in: root)
        #expect(sizes.store.files == 2 && sizes.store.bytes >= 15_000)
        #expect(sizes.external.files == 2 && sizes.external.bytes >= 50_000)
        #expect(DiskUsage.size(of: root.appendingPathComponent("missing")).files == 0)
    }

    @Test func processMemoryReportsAFootprint() {
        let s = ProcessMemory.snapshot()
        #expect(s.footprintBytes > 1_000_000)
        #expect(s.peakBytes >= s.footprintBytes)
    }
}
