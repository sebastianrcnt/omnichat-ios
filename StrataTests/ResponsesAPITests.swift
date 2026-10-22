import Testing
import Foundation
@testable import Strata

private func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

// MARK: - Request translation

struct ResponsesTranslationTests {
    private func toolTurn() -> [APIMessage] {
        var assistant = APIMessage.assistant("Let me check.", toolCalls: [ToolCall(id: "call_1", name: "web_search", arguments: #"{"query":"swift"}"#)])
        assistant.reasoningItems = [ReasoningItem(summary: ["Searching first."], encryptedContent: "ENC")]
        return [.system("You are Strata.\nBe brief."),
                .user(parts: [.imageURL("data:image/jpeg;base64,AAAA"), .text("What is this?")]),
                .assistant("A cat."),
                .user("Search swift"),
                assistant,
                .tool(callID: "call_1", content: "<source id=\"1\">…</source>")]
    }

    @Test func systemBecomesInstructionsUnchanged() throws {
        var request = ChatRequest(model: "gpt-6.1-sol", messages: toolTurn())
        request.tools = ToolDefinition.available(python: true, images: true)
        let body = ResponsesRequest(request, reasoning: true)
        #expect(body.instructions == "You are Strata.\nBe brief.")
        let json = object(try body.encoded())
        #expect(json["instructions"] as? String == "You are Strata.\nBe brief.")
        #expect(json["store"] as? Bool == false)
        #expect(json["stream"] as? Bool == true)
        #expect(json["model"] as? String == "gpt-6.1-sol")
        // None of the fields the plan route rejects.
        for key in ["temperature", "max_output_tokens", "previous_response_id", "metadata", "user", "top_p", "truncation",
                    "messages", "stream_options", "reasoning_effort"] {
            #expect(json[key] == nil, "unexpected \(key)")
        }
    }

    @Test func historyBecomesInputItems() throws {
        let body = ResponsesRequest(ChatRequest(model: "m", messages: toolTurn()), reasoning: true)
        let input = try #require(object(try body.encoded())["input"] as? [[String: Any]])
        let types = input.map { ($0["type"] as? String ?? "") + "/" + ($0["role"] as? String ?? "") }
        #expect(types == ["message/user", "message/assistant", "message/user", "reasoning/", "message/assistant",
                          "function_call/", "function_call_output/"])
        let image = (input[0]["content"] as? [[String: Any]])?[0]
        #expect(image?["type"] as? String == "input_image")
        #expect(image?["image_url"] as? String == "data:image/jpeg;base64,AAAA")
        #expect((input[0]["content"] as? [[String: Any]])?[1]["type"] as? String == "input_text")
        #expect((input[1]["content"] as? [[String: Any]])?[0]["type"] as? String == "output_text")
        #expect(input[3]["encrypted_content"] as? String == "ENC")
        #expect((input[3]["summary"] as? [[String: Any]])?[0]["text"] as? String == "Searching first.")
        #expect(input[3]["id"] == nil)
        #expect(input[5]["call_id"] as? String == "call_1")
        #expect(input[5]["name"] as? String == "web_search")
        #expect(input[5]["namespace"] as? String == "strata")
        #expect(input[5]["arguments"] as? String == #"{"query":"swift"}"#)
        #expect(input[6]["call_id"] as? String == "call_1")
        #expect(input[6]["output"] as? String == "<source id=\"1\">…</source>")
    }

    @Test func laterSystemMessageIsADeveloperMessage() throws {
        let body = ResponsesRequest(ChatRequest(model: "m", messages: [.user("hi"), .system("note")]), reasoning: false)
        #expect(body.instructions == nil)
        #expect(body.input == [.message(role: "user", content: [.inputText("hi")]),
                               .message(role: "developer", content: [.inputText("note")])])
    }

    @Test func toolsGoInOneNamespaceAsFlatFunctions() throws {
        var request = ChatRequest(model: "m", messages: [.user("hi")])
        request.tools = ToolDefinition.standard
        request.toolChoice = "none"
        let json = object(try ResponsesRequest(request, reasoning: false).encoded())
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "namespace")
        #expect(tools[0]["name"] as? String == "strata")
        let functions = try #require(tools[0]["tools"] as? [[String: Any]])
        #expect(functions.map { $0["name"] as? String } == ["web_search", "web_fetch", "run_plugin"])
        #expect(functions[0]["type"] as? String == "function")
        #expect(functions[0]["strict"] as? Bool == false)
        #expect(functions[0]["function"] == nil)
        let params = try #require(functions[0]["parameters"] as? [String: Any])
        #expect(params["required"] as? [String] == ["query"])
        #expect(((params["properties"] as? [String: Any])?["engine"] as? [String: Any])?["enum"] as? [String] == ["naver", "bing", "duckduckgo"])
        #expect(json["tool_choice"] as? String == "none")
    }

    @Test func effortAndEncryptedReasoning() throws {
        var request = ChatRequest(model: "m", messages: [.user("hi")])
        request.reasoningEffort = Effort.max.apiValue
        let json = object(try ResponsesRequest(request, reasoning: true).encoded())
        #expect(json["reasoning"] as? [String: String] == ["effort": "xhigh", "summary": "auto"])
        #expect(json["include"] as? [String] == ["reasoning.encrypted_content"])
        request.reasoningEffort = "medium"
        #expect(ResponsesRequest(request, reasoning: true).reasoning?.effort == "medium")
        // A model without effort gets neither.
        let plain = object(try ResponsesRequest(request, reasoning: false).encoded())
        #expect(plain["reasoning"] == nil && plain["include"] == nil)
    }

    @Test func encodingIsByteStable() throws {
        var request = ChatRequest(model: "m", messages: toolTurn())
        request.tools = ToolDefinition.standard
        let a = try ResponsesRequest(request, reasoning: true).encoded()
        let b = try ResponsesRequest(request, reasoning: true).encoded()
        #expect(a == b)
        // The instructions and the tools lead the body the same way on every request of a chat.
        request.messages.append(.user("more"))
        let c = try ResponsesRequest(request, reasoning: true).encoded()
        #expect(String(decoding: c, as: UTF8.self).contains(#""instructions":"You are Strata.\nBe brief.""#))
    }

    @Test func assistantMessageEncodingForChatCompletionsIgnoresReasoningItems() throws {
        var m = APIMessage.assistant("x", toolCalls: [ToolCall(id: "c", name: "web_search", arguments: "{}")])
        let plain = try ChatRequest.encoder.encode(m)
        m.reasoningItems = [ReasoningItem(summary: [], encryptedContent: "E")]
        #expect(try ChatRequest.encoder.encode(m) == plain)
    }
}

// MARK: - Stream events

/// A Responses stream with reasoning, text and a tool call, in the documented event shapes.
enum ResponsesSamples {
    static let toolCallStream = """
    event: response.created
    data: {"type":"response.created","sequence_number":0,"response":{"id":"resp_1","status":"in_progress","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[]}}

    event: response.reasoning_summary_part.added
    data: {"type":"response.reasoning_summary_part.added","sequence_number":2,"item_id":"rs_1","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""}}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","sequence_number":3,"item_id":"rs_1","output_index":0,"summary_index":0,"delta":"**Planning** the search"}

    event: response.reasoning_summary_part.added
    data: {"type":"response.reasoning_summary_part.added","sequence_number":4,"item_id":"rs_1","output_index":0,"summary_index":1,"part":{"type":"summary_text","text":""}}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","sequence_number":5,"item_id":"rs_1","output_index":0,"summary_index":1,"delta":"Then reading."}

    event: response.output_item.done
    data: {"type":"response.output_item.done","sequence_number":6,"output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"**Planning** the search"},{"type":"summary_text","text":"Then reading."}],"encrypted_content":"gAAAA-enc"}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","sequence_number":7,"output_index":1,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","sequence_number":8,"item_id":"msg_1","output_index":1,"content_index":0,"delta":"Checking "}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","sequence_number":9,"item_id":"msg_1","output_index":1,"content_index":0,"delta":"now."}

    event: response.output_item.added
    data: {"type":"response.output_item.added","sequence_number":10,"output_index":2,"item":{"id":"fc_1","type":"function_call","call_id":"call_A","name":"web_search","namespace":"strata","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","sequence_number":11,"item_id":"fc_1","output_index":2,"delta":"{\\"query\\":"}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","sequence_number":12,"item_id":"fc_1","output_index":2,"delta":"\\"swift 6\\"}"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","sequence_number":13,"output_index":2,"item":{"id":"fc_1","type":"function_call","call_id":"call_A","name":"web_search","namespace":"strata","arguments":"{\\"query\\":\\"swift 6\\"}"}}

    event: response.output_item.done
    data: {"type":"response.output_item.done","sequence_number":14,"output_index":3,"item":{"id":"fc_2","type":"function_call","call_id":"call_B","name":"strata.web_fetch","arguments":"{\\"url\\":\\"https://swift.org\\"}"}}

    event: response.completed
    data: {"type":"response.completed","sequence_number":15,"response":{"id":"resp_1","status":"completed","usage":{"input_tokens":1200,"input_tokens_details":{"cached_tokens":1024},"output_tokens":90,"output_tokens_details":{"reasoning_tokens":64},"total_tokens":1290}}}

    """

    static func deltas(_ sse: String) throws -> [ChatDelta] {
        var parser = SSEParser()
        var decoder = ResponsesEventDecoder()
        var out: [ChatDelta] = []
        for event in parser.feed(sse) + parser.finish() {
            let d = try decoder.decode(event.data)
            if !d.isEmpty { out.append(d) }
        }
        return out
    }
}

struct ResponsesStreamTests {
    @Test func eventsBecomeDeltas() throws {
        let deltas = try ResponsesSamples.deltas(ResponsesSamples.toolCallStream)
        var acc = StreamAccumulator()
        for d in deltas { acc.apply(d) }
        #expect(acc.reasoning == "**Planning** the search\n\nThen reading.")
        #expect(acc.content == "Checking now.")
        #expect(acc.toolCalls == [ToolCall(id: "call_A", name: "web_search", arguments: #"{"query":"swift 6"}"#),
                                  ToolCall(id: "call_B", name: "web_fetch", arguments: #"{"url":"https://swift.org"}"#)])
        #expect(acc.reasoningItems == [ReasoningItem(summary: ["**Planning** the search", "Then reading."], encryptedContent: "gAAAA-enc")])
        #expect(acc.usage == Usage(promptTokens: 1200, completionTokens: 90, cachedTokens: 1024, reasoningTokens: 64))
        #expect(acc.finishReason == "tool_calls")
    }

    @Test func aSummaryOnlyOnTheFinishedItemIsShown() throws {
        let sse = """
        data: {"type":"response.output_item.added","output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[]}}

        data: {"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"First"},{"type":"summary_text","text":"Second"}]}}

        data: {"type":"response.output_text.delta","output_index":1,"delta":"Answer"}

        data: {"type":"response.completed","response":{"usage":{"input_tokens":5,"output_tokens":1}}}

        """
        var acc = StreamAccumulator()
        for d in try ResponsesSamples.deltas(sse) { acc.apply(d) }
        #expect(acc.reasoning == "First\n\nSecond")
        #expect(acc.content == "Answer")
    }

    @Test func plainAnswerFinishesWithStop() throws {
        let sse = """
        data: {"type":"response.output_text.delta","output_index":0,"delta":"Hello"}

        data: {"type":"response.completed","response":{"usage":{"input_tokens":5,"output_tokens":1}}}

        """
        var acc = StreamAccumulator()
        for d in try ResponsesSamples.deltas(sse) { acc.apply(d) }
        #expect(acc.content == "Hello")
        #expect(acc.finishReason == "stop")
        #expect(acc.usage == Usage(promptTokens: 5, completionTokens: 1))
    }

    @Test func incompleteKeepsTextAndReportsLength() throws {
        let sse = """
        data: {"type":"response.output_text.delta","output_index":0,"delta":"Partial"}

        data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":5,"output_tokens":9}}}

        """
        let deltas = try ResponsesSamples.deltas(sse)
        #expect(deltas.last?.finishReason == "length")
    }

    @Test func usageLimitFailureIsAClearError() throws {
        let sse = """
        data: {"type":"response.output_text.delta","output_index":0,"delta":"Hi"}

        data: {"type":"response.failed","response":{"status":"failed","error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}}

        """
        #expect {
            try ResponsesSamples.deltas(sse)
        } throws: { error in
            // "Manage usage" (ChatGPT's usage settings) is the chat's action for it, so the text names ChatGPT, no URL.
            guard let api = error as? APIError, api == .chatGPTUsageLimit, api.managesUsage else { return false }
            return api.errorDescription?.contains("ChatGPT usage limit") == true
        }
    }

    @Test func errorEventKeepsServerTextForUnknownCodes() throws {
        let sse = "data: {\"type\":\"error\",\"code\":\"context_length_exceeded\",\"message\":\"Your input exceeds the context window of this model.\"}\n\n"
        #expect {
            try ResponsesSamples.deltas(sse)
        } throws: { error in
            Compaction.isContextOverflow(error)
        }
    }

    @Test func errorsBeforeTheStream() {
        let limit = ResponsesErrorMapper.error(status: 429, data: Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"x"}}"#.utf8))
        #expect(limit == .chatGPTUsageLimit && limit.managesUsage && !limit.needsSettings)
        // 429 with only an admission `detail` is the same limit.
        #expect(ResponsesErrorMapper.error(status: 429, data: Data(#"{"detail":"Too many"}"#.utf8)) == .chatGPTUsageLimit)
        let admission = ResponsesErrorMapper.error(status: 403, data: Data(#"{"detail":"Region not supported"}"#.utf8))
        #expect(admission == .http(status: 403, message: "ChatGPT refused the request: Region not supported"))
        let unsupported = ResponsesErrorMapper.error(status: 400, data: Data(#"{"error":{"code":"subscription_sharing_unsupported_capability","param":"tools[0]"}}"#.utf8))
        #expect(unsupported.errorDescription?.contains("tools[0]") == true)
    }
}

// MARK: - Through the turn engine

@MainActor
struct ResponsesTurnTests {
    /// The reasoning that led to a tool call goes back with the tool results in the turn's next request.
    @Test func reasoningItemsRideAlongWithinATurn() async throws {
        let first = try ResponsesSamples.deltas(ResponsesSamples.toolCallStream)
        let streamer = ScriptedStreamer([first, [ChatDelta(content: "Answer.")]])
        let runner = TurnRunner(streamer: streamer, tools: FakeTools())
        let endpoint = Endpoint(connectionID: UUID(), connectionName: "ChatGPT", baseURL: URL(string: ChatGPTOAuth.resource)!,
                                apiKey: nil, headers: [:], model: ModelInfo(id: "gpt-6.1-sol", supportsEffort: true, supportsTools: true),
                                kind: .chatGPT)
        let outcome = try await runner.run(endpoint: endpoint, messages: [.system("sys"), .user("q")], effort: .high) { _ in }
        #expect(outcome.finalContent == "Answer.")
        #expect(streamer.requests.count == 2)
        let second = ResponsesRequest(streamer.requests[1], reasoning: true)
        let types = second.input.map { item -> String in
            switch item {
            case .message(let role, _): "message/\(role)"
            case .reasoning: "reasoning"
            case .functionCall(_, let name, _): "call/\(name)"
            case .functionCallOutput(let id, _): "output/\(id)"
            }
        }
        #expect(types == ["message/user", "reasoning", "message/assistant", "call/web_search", "call/web_fetch",
                          "output/call_A", "output/call_B"])
        #expect(second.reasoning?.effort == "high")
        #expect(endpoint.requestURL.absoluteString == "https://api.openai.com/v1/responses")
    }
}
