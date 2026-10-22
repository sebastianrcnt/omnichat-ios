import Testing
import Foundation
@testable import Strata

struct MessagesTranslationTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func translatesATurnWithToolsImagesAndThinking() throws {
        var assistant = APIMessage.assistant("Looking.", toolCalls: [
            ToolCall(id: "tu_1", name: "web_search", arguments: #"{"query":"swift","n":2}"#),
            ToolCall(id: "tu_2", name: "web_fetch", arguments: "not json"),
        ])
        assistant.reasoningItems = [ReasoningItem(summary: ["Plan."], encryptedContent: "sig-1"),
                                    ReasoningItem(summary: ["Unsigned."], encryptedContent: nil),
                                    ReasoningItem(summary: [], encryptedContent: MessagesRequest.redactedPrefix + "opaque")]
        var request = ChatRequest(model: "claude-haiku-5-5", messages: [
            .system("You are Strata."),
            .user(parts: [.text("What is this?"), .imageURL("data:image/jpeg;base64,QUJD"), .imageURL("https://x.test/a.png")]),
            assistant,
            .tool(callID: "tu_1", content: "results"),
            .tool(callID: "tu_2", content: "page"),
            .user("Thanks"),
            .system("Late note"),
        ])
        request.tools = ToolDefinition.standard
        request.toolChoice = "none"
        let sent = try object(MessagesRequest(request, effort: "high", maxOutputTokens: 64000).encoded())

        #expect(sent["model"] as? String == "claude-haiku-5-5")
        #expect(sent["system"] as? String == "You are Strata.")
        #expect(sent["max_tokens"] as? Int == 64000)
        #expect(sent["stream"] as? Bool == true)
        #expect((sent["output_config"] as? [String: String]) == ["effort": "high"])
        #expect((sent["tool_choice"] as? [String: String]) == ["type": "none"])
        let tools = try #require(sent["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["web_search", "web_fetch", "run_plugin"])
        #expect((tools[0]["input_schema"] as? [String: Any])?["type"] as? String == "object")

        let messages = try #require(sent["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let first = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(first[0]["text"] as? String == "What is this?")
        #expect((first[1]["source"] as? [String: String]) == ["type": "base64", "media_type": "image/jpeg", "data": "QUJD"])
        #expect((first[2]["source"] as? [String: String]) == ["type": "url", "url": "https://x.test/a.png"])

        let reply = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(reply.map { $0["type"] as? String } == ["thinking", "redacted_thinking", "text", "tool_use", "tool_use"])
        #expect(reply[0]["thinking"] as? String == "Plan." && reply[0]["signature"] as? String == "sig-1")
        #expect(reply[1]["data"] as? String == "opaque")
        #expect((reply[3]["input"] as? [String: Any])?["query"] as? String == "swift")
        #expect((reply[3]["input"] as? [String: Any])?["n"] as? Int == 2)
        #expect((reply[4]["input"] as? [String: Any])?.isEmpty == true) // unparseable arguments: an empty object

        // Both results and the later user and system text in one user message, results first.
        let results = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(results.map { $0["type"] as? String } == ["tool_result", "tool_result", "text", "text"])
        #expect(results[0]["tool_use_id"] as? String == "tu_1" && results[0]["content"] as? String == "results")
        #expect(results[3]["text"] as? String == "Late note")
    }

    @Test func capsAndDefaults() throws {
        var request = ChatRequest(model: "qwen3.7-plus", messages: [.user("Hi")])
        let plain = try object(MessagesRequest(request, effort: nil, maxOutputTokens: nil).encoded())
        #expect(plain["max_tokens"] as? Int == MessagesRequest.defaultMaxTokens)
        #expect(plain["system"] == nil && plain["output_config"] == nil && plain["tools"] == nil)
        request.maxTokens = 64
        #expect(try object(MessagesRequest(request, effort: nil, maxOutputTokens: 8000).encoded())["max_tokens"] as? Int == 64)
        // An assistant message with nothing to send is left out.
        let empty = MessagesRequest.messages([.user("a"), .assistant(""), .user("b")])
        #expect(empty.count == 1 && empty[0].content == [.text("a"), .text("b")])
    }
}

struct MessagesStreamTests {
    private func run(_ events: [String]) throws -> (deltas: [ChatDelta], finished: Bool) {
        var decoder = MessagesEventDecoder()
        let deltas = try events.map { try decoder.decode($0) }.filter { !$0.isEmpty }
        return (deltas, decoder.finished)
    }

    @Test func decodesTextThinkingToolsAndUsage() throws {
        let (deltas, finished) = try run([
            #"{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":0,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Need to "}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"search."}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"ping"}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me check."}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tu_1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"swift\"}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"tu_2","name":"web_fetch","input":{"url":"https://a.test"}}}"#,
            #"{"type":"content_block_stop","index":3}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(finished)
        var acc = StreamAccumulator()
        deltas.forEach { acc.apply($0) }
        #expect(acc.reasoning == "Need to search.")
        #expect(acc.content == "Let me check.")
        #expect(acc.reasoningItems == [ReasoningItem(summary: ["Need to search."], encryptedContent: "sig")])
        #expect(acc.toolCalls == [ToolCall(id: "tu_1", name: "web_search", arguments: #"{"query":"swift"}"#),
                                  ToolCall(id: "tu_2", name: "web_fetch", arguments: #"{"url":"https://a.test"}"#)])
        #expect(acc.usage == Usage(promptTokens: 1000, completionTokens: 42, cachedTokens: 900, cacheWriteTokens: 0))
        #expect(acc.finishReason == "tool_calls")
    }

    @Test func separatesThinkingBlocksAndMapsStopReasons() throws {
        let (deltas, _) = try run([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"A"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"thinking"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"B"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"redacted_thinking","data":"xyz"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":5}}"#,
        ])
        var acc = StreamAccumulator()
        deltas.forEach { acc.apply($0) }
        #expect(acc.reasoning == "A\n\nB")
        #expect(acc.reasoningItems.map(\.encryptedContent) == [nil, nil, MessagesRequest.redactedPrefix + "xyz"])
        #expect(acc.finishReason == "length")
        // An unsigned thinking block is not sent back; the redacted one is.
        var assistant = APIMessage.assistant("x")
        assistant.reasoningItems = acc.reasoningItems
        #expect(MessagesRequest.messages([assistant])[0].content == [.redactedThinking(data: "xyz"), .text("x")])
    }

    @Test func errorEventsThrow() {
        var decoder = MessagesEventDecoder()
        #expect(throws: APIError.server(MessagesEventDecoder.errorText(type: "overloaded_error", message: "Overloaded"))) {
            try decoder.decode(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
        #expect(throws: Never.self) { try decoder.decode("not json") }
    }

    @Test func openCodeSendsMessagesModelsToTheMessagesAPI() throws {
        var model = ModelInfo(id: "claude-haiku-5-5", supportsEffort: true)
        model.maxOutputTokens = 64000
        model.openCode = OpenCodeModelInfo(api: .messages, efforts: [.low, .medium, .high, .max])
        let endpoint = Endpoint(connectionID: UUID(), connectionName: "OpenCode", baseURL: OpenCodeGateway.go.baseURL,
                                apiKey: nil, headers: ["x-opencode-session": "s"], model: model, kind: .openCode)
        var request = ChatRequest(model: "claude-haiku-5-5", messages: [.system("S"), .user("Hi")])
        request.reasoningEffort = "xhigh"
        let sent = try #require(try JSONSerialization.jsonObject(with: OpenCodeClient.body(request, endpoint: endpoint)) as? [String: Any])
        #expect((sent["output_config"] as? [String: String]) == ["effort": "high"])
        #expect(sent["max_tokens"] as? Int == 64000 && sent["system"] as? String == "S")
        let req = OpenCodeClient.urlRequest(endpoint: endpoint, token: "tok", body: Data())
        #expect(req.url?.absoluteString == "https://opencode.ai/inference/go/v1/messages")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "tok")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }
}
