import Testing
import Foundation
@testable import Strata

struct SSEParserTests {
    @Test func parsesCompleteEvents() {
        var p = SSEParser()
        let events = p.feed("data: {\"a\":1}\n\ndata: [DONE]\n\n")
        #expect(events.map(\.data) == ["{\"a\":1}", "[DONE]"])
    }

    @Test func eventSplitAcrossChunks() {
        var p = SSEParser()
        var all: [SSEEvent] = []
        for chunk in ["da", "ta: {\"x\"", ":2}\n", "\n", "data: tw", "o\n\n"] { all += p.feed(chunk) }
        #expect(all.map(\.data) == ["{\"x\":2}", "two"])
    }

    @Test func handlesCRLFAndComments() {
        var p = SSEParser()
        let events = p.feed(": keep-alive\r\ndata: hello\r\n\r\n")
        #expect(events.map(\.data) == ["hello"])
    }

    @Test func multiLineDataJoinedWithNewline() {
        var p = SSEParser()
        #expect(p.feed("data: a\ndata: b\n\n").map(\.data) == ["a\nb"])
    }

    @Test func utf8SplitMidCharacter() {
        var p = SSEParser()
        let bytes = Array("data: 안녕\n\n".utf8)
        var out: [SSEEvent] = []
        for b in bytes { out += p.feed(Data([b])) }
        #expect(out.map(\.data) == ["안녕"])
    }

    @Test func finishFlushesUnterminatedEvent() {
        var p = SSEParser()
        #expect(p.feed("data: tail").isEmpty)
        #expect(p.finish().map(\.data) == ["tail"])
    }
}

struct ChatStreamTests {
    private func chunk(_ delta: String, finish: String? = nil, usage: String? = nil) -> String {
        let f = finish.map { "\"\($0)\"" } ?? "null"
        let u = usage.map { ",\"usage\":\($0)" } ?? ""
        return "data: {\"choices\":[{\"index\":0,\"delta\":\(delta),\"finish_reason\":\(f)}]\(u)}\n\n"
    }

    /// Run a whole SSE transcript through the parser (in `size`-byte pieces), decoder and accumulator.
    private func run(_ transcript: String, pieceSize: Int) throws -> StreamAccumulator {
        var parser = SSEParser()
        var acc = StreamAccumulator()
        let bytes = Array(transcript.utf8)
        var i = 0
        while i < bytes.count {
            let end = min(bytes.count, i + pieceSize)
            for e in parser.feed(Data(bytes[i..<end])) { acc.apply(try ChatChunkDecoder.decode(e.data)) }
            i = end
        }
        for e in parser.finish() { acc.apply(try ChatChunkDecoder.decode(e.data)) }
        return acc
    }

    private var transcript: String {
        chunk("{\"role\":\"assistant\",\"reasoning_content\":\"Let me \"}")
        + chunk("{\"reasoning_content\":\"think.\"}")
        + chunk("{\"content\":\"Hel\"}")
        + chunk("{\"content\":\"lo\"}")
        + chunk("{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"type\":\"function\",\"function\":{\"name\":\"web_sea\",\"arguments\":\"\"}}]}")
        + chunk("{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"rch\",\"arguments\":\"{\\\"que\"}}]}")
        + chunk("{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"ry\\\":\\\"swift\\\"}\"}}]}")
        + chunk("{\"tool_calls\":[{\"index\":1,\"id\":\"call_b\",\"function\":{\"name\":\"web_fetch\",\"arguments\":\"{\\\"url\\\":\\\"https://e.com\\\"}\"}}]}", finish: "tool_calls")
        + "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":120,\"completion_tokens\":30,\"prompt_tokens_details\":{\"cached_tokens\":100},\"completion_tokens_details\":{\"reasoning_tokens\":12}}}\n\n"
        + "data: [DONE]\n\n"
    }

    @Test(arguments: [1, 3, 7, 64, 100_000])
    func accumulatesDeltasSplitAnywhere(pieceSize: Int) throws {
        let acc = try run(transcript, pieceSize: pieceSize)
        #expect(acc.content == "Hello")
        #expect(acc.reasoning == "Let me think.")
        #expect(acc.finishReason == "tool_calls")
        #expect(acc.toolCalls == [
            ToolCall(id: "call_a", name: "web_search", arguments: "{\"query\":\"swift\"}"),
            ToolCall(id: "call_b", name: "web_fetch", arguments: "{\"url\":\"https://e.com\"}"),
        ])
        #expect(acc.usage == Usage(promptTokens: 120, completionTokens: 30, cachedTokens: 100, reasoningTokens: 12))
    }

    @Test func usageWithoutCacheDetails() throws {
        let d = try ChatChunkDecoder.decode("{\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}")
        #expect(d.usage?.cachedTokens == nil)
        #expect(d.usage?.reasoningTokens == nil)
        #expect(d.usage?.totalTokens == 7)
    }

    @Test func reasoningFieldAlias() throws {
        let d = try ChatChunkDecoder.decode("{\"choices\":[{\"delta\":{\"reasoning\":\"hmm\"}}]}")
        #expect(d.reasoning == "hmm")
    }

    @Test func doneMarkerAndInBandError() throws {
        #expect(try ChatChunkDecoder.decode("[DONE]").isDone)
        #expect(throws: APIError.self) { try ChatChunkDecoder.decode("{\"error\":{\"message\":\"boom\"}}") }
    }

    @Test func missingToolCallIdGetsSyntheticId() {
        var acc = StreamAccumulator()
        acc.apply(ChatDelta(toolCalls: [ToolCallDelta(index: 0, id: nil, name: "web_search", arguments: "{}")]))
        #expect(acc.toolCalls.first?.id == "call_0")
    }
}

struct ModelsAPITests {
    @Test func parsesContextLengthVariants() throws {
        let json = """
        {"object":"list","data":[{"id":"a","max_model_len":131072},{"id":"b","context_length":8192},{"id":"c"}]}
        """
        let entries = try ModelsAPI.parse(Data(json.utf8))
        #expect(entries == [.init(id: "a", contextLength: 131072), .init(id: "b", contextLength: 8192), .init(id: "c", contextLength: nil)])
    }
}
