import Testing
import Foundation
@testable import Strata

/// Stands in for Apple's on-device model: answers with scripted events, records what it was asked, and can say a
/// prompt doesn't fit until it is small enough.
final class FakeOnDeviceModel: OnDeviceLanguageModel, @unchecked Sendable {
    var availability: OnDeviceAvailability = .available
    var contextSize = 4096
    var readsImages = false
    var events: [OnDeviceEvent] = [.text("Hello"), .text(" there")]
    var failure: OnDeviceFailure?
    /// Throws `contextExceeded` for prompts longer than this many characters.
    var maxPromptChars: Int?
    /// Throws `contextExceeded` after the events (an answer that runs out of room).
    var overflowAfterEvents = false
    private(set) var prompts: [OnDevicePrompt] = []
    private(set) var offeredTools: [[OnDeviceToolSpec]] = []

    func respond(to prompt: OnDevicePrompt, tools: [OnDeviceToolSpec]) -> AsyncThrowingStream<OnDeviceEvent, Error> {
        prompts.append(prompt)
        offeredTools.append(tools)
        let size = prompt.instructions.count + prompt.prompt.count + prompt.history.reduce(0) { $0 + $1.text.count }
        let tooLong = maxPromptChars.map { size > $0 } ?? false
        let events = events, failure = failure, overflow = overflowAfterEvents
        return AsyncThrowingStream { continuation in
            if tooLong { continuation.finish(throwing: OnDeviceFailure.contextExceeded); return }
            if let failure { continuation.finish(throwing: failure); return }
            for e in events { continuation.yield(e) }
            continuation.finish(throwing: overflow ? OnDeviceFailure.contextExceeded : nil)
        }
    }
}

private let appSystem = ConversationDate.systemPrompt(
    base: AppPrompt.text(tools: true, python: true) + "\n\n" + AppPrompt.preferences("Call me Captain."), day: "2026-10-22")

private func endpoint() -> Endpoint { OnDevice.endpoint(Connection.appleOnDevice(model: FakeOnDeviceModel())) }

private func collect(_ client: OnDeviceClient, _ request: ChatRequest) async throws -> (StreamAccumulator, [ChatDelta]) {
    var acc = StreamAccumulator()
    var deltas: [ChatDelta] = []
    for try await delta in client.stream(request, endpoint: endpoint()) {
        acc.apply(delta)
        deltas.append(delta)
    }
    return (acc, deltas)
}

// MARK: - Prompt mapping

struct OnDevicePromptTests {
    @Test func appPromptBecomesShortInstructionsKeepingDateAndPreferences() {
        let text = OnDevicePromptBuilder.instructions(from: appSystem, tools: OnDevicePromptBuilder.toolSpecs)
        #expect(text.contains("Current date: 2026-10-22"))
        #expect(text.contains("Call me Captain."))
        #expect(text.contains("[1]"))
        #expect(!text.contains("run_python"))
        #expect(text.count < appSystem.count / 2)
        // No tools: no citation rule.
        #expect(!OnDevicePromptBuilder.instructions(from: appSystem, tools: []).contains("[1]"))
    }

    @Test func otherSystemMessagesAreKeptAsTheyAre() {
        #expect(OnDevicePromptBuilder.instructions(from: AutoRename.system, tools: []) == AutoRename.system)
    }

    @Test func historyKeepsTextAndTheLastUserMessageIsThePrompt() {
        let request = ChatRequest(model: OnDevice.modelID, messages: [
            .system(appSystem), .user("First question"),
            .assistant("", toolCalls: [ToolCall(id: "a", name: "web_search", arguments: "{}")]),
            .tool(callID: "a", content: "old result"),
            .assistant("First answer"), .user("Second question"),
        ])
        let prompt = OnDevicePromptBuilder.build(request, contextSize: 4096, readsImages: false, tools: [])
        #expect(prompt.history == [.init(role: .user, text: "First question"), .init(role: .assistant, text: "First answer")])
        #expect(prompt.prompt == "Second question")
        #expect(prompt.maxTokens == nil)
    }

    @Test func toolRoundsOfTheCurrentTurnAreWrittenIntoThePrompt() {
        let request = ChatRequest(model: OnDevice.modelID, messages: [
            .system(appSystem), .user("Who won?"),
            .assistant("", toolCalls: [ToolCall(id: "c1", name: "web_search", arguments: #"{"query":"winner"}"#)]),
            .tool(callID: "c1", content: #"<source id="1" title="T" url="https://x">Pogacar won.</source>"#),
        ])
        let prompt = OnDevicePromptBuilder.build(request, contextSize: 4096, readsImages: false, tools: [])
        #expect(prompt.prompt.hasPrefix("Who won?"))
        #expect(prompt.prompt.contains(#"web_search {"query":"winner"}"#))
        #expect(prompt.prompt.contains("Pogacar won."))
        #expect(prompt.history.isEmpty)
    }

    @Test func consecutiveMessagesOfOneRoleAreJoined() {
        // A compaction's replacement: recent user messages, then the notes, all as user messages.
        let request = ChatRequest(model: OnDevice.modelID, messages: [
            .user("Earlier ask"), .user(Compaction.summaryPrefix + "notes"), .assistant("Sure."), .user("Now"),
        ])
        let prompt = OnDevicePromptBuilder.build(request, contextSize: 4096, readsImages: false, tools: [])
        #expect(prompt.history.count == 2)
        #expect(prompt.history[0].text.contains("Earlier ask") && prompt.history[0].text.contains("notes"))
    }

    @Test func oldestTurnsAreDroppedToFitTheWindow() {
        var messages: [APIMessage] = [.system(appSystem)]
        for i in 0..<30 {
            messages += [.user("Question \(i) " + String(repeating: "word ", count: 80)), .assistant("Answer \(i)")]
        }
        messages.append(.user("Last"))
        let prompt = OnDevicePromptBuilder.build(ChatRequest(model: OnDevice.modelID, messages: messages),
                                                 contextSize: 4096, readsImages: false, tools: [])
        let estimate = ([prompt.instructions, prompt.prompt] + prompt.history.map(\.text))
            .reduce(0) { $0 + OnDevicePromptBuilder.estimateTokens($1) }
        #expect(estimate < 4096 - OnDevicePromptBuilder.answerRoom(contextSize: 4096, maxTokens: nil))
        #expect(prompt.history.count < 60 && prompt.history.count > 2)
        #expect(prompt.history.last?.text == "Answer 29")
        #expect(prompt.history.first?.role == .user)
        #expect(prompt.prompt == "Last")
    }

    @Test func longToolResultsAreCut() {
        let page = String(repeating: "Lorem ipsum dolor sit amet. ", count: 2000)
        let request = ChatRequest(model: OnDevice.modelID, messages: [
            .user("Summarize https://x"),
            .assistant("", toolCalls: [ToolCall(id: "c1", name: "web_fetch", arguments: #"{"url":"https://x"}"#)]),
            .tool(callID: "c1", content: page),
        ])
        let prompt = OnDevicePromptBuilder.build(request, contextSize: 4096, readsImages: false, tools: [])
        #expect(prompt.prompt.contains(OnDevicePromptBuilder.truncated))
        #expect(OnDevicePromptBuilder.estimateTokens(prompt.prompt) < 3072)
    }

    @Test func squeezingShrinksThePrompt() {
        let messages: [APIMessage] = (0..<20).flatMap { i in
            [APIMessage.user("Q\(i) " + String(repeating: "text ", count: 60)), .assistant("A\(i)")]
        } + [.user("Now")]
        let request = ChatRequest(model: OnDevice.modelID, messages: messages)
        let full = OnDevicePromptBuilder.build(request, contextSize: 4096, readsImages: false, tools: [])
        let squeezed = OnDevicePromptBuilder.build(request, contextSize: 4096, readsImages: false, tools: [], squeeze: 0.5)
        #expect(squeezed.history.count < full.history.count)
    }

    @Test func imagesGoToTheModelOnlyWhenItReadsThem() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let request = ChatRequest(model: OnDevice.modelID, messages: [
            .user(parts: [.imageURL(ContentPart.dataURLString(jpeg: jpeg)), .text("What is this?")]),
        ])
        let vision = OnDevicePromptBuilder.build(request, contextSize: 8192, readsImages: true, tools: [])
        #expect(vision.images == [jpeg])
        #expect(vision.prompt == "What is this?")
        let textOnly = OnDevicePromptBuilder.build(request, contextSize: 4096, readsImages: false, tools: [])
        #expect(textOnly.images.isEmpty)
        #expect(textOnly.prompt.contains(OnDevicePromptBuilder.unreadableImageNote))
    }

    @Test func titleRequestsKeepTheirCap() {
        let request = AutoRename.request(model: OnDevice.modelID, prompt: "User: hi", thinking: .off, supportsEffort: false)
        let prompt = OnDevicePromptBuilder.build(request, contextSize: 4096, readsImages: false, tools: [])
        #expect(prompt.maxTokens == AutoRename.maxTokens)
        #expect(prompt.instructions == AutoRename.system)
    }

    @Test func onlyWebToolsAreOfferedAndNoneWhenToolsAreOff() {
        var request = ChatRequest(model: OnDevice.modelID, messages: [.user("hi")],
                                  tools: ToolDefinition.available(python: true, images: false, browser: true))
        #expect(OnDevicePromptBuilder.tools(for: request).map(\.name) == ["web_search", "web_fetch"])
        request.toolChoice = "none"
        #expect(OnDevicePromptBuilder.tools(for: request).isEmpty)
        // A chat offered no web group: nothing to offer.
        request = ChatRequest(model: OnDevice.modelID, messages: [.user("hi")], tools: [ToolDefinition.showHTML])
        #expect(OnDevicePromptBuilder.tools(for: request).isEmpty)
    }
}

// MARK: - Client

struct OnDeviceClientTests {
    private let request = ChatRequest(model: OnDevice.modelID, messages: [.system(appSystem), .user("Hi")],
                                      tools: ToolDefinition.available(python: false, images: false))

    @Test func streamsTextThenUsageAndStop() async throws {
        let model = FakeOnDeviceModel()
        let (acc, deltas) = try await collect(OnDeviceClient(model: model), request)
        #expect(acc.content == "Hello there")
        #expect(acc.finishReason == "stop")
        #expect((acc.usage?.promptTokens ?? 0) > 0)
        #expect(deltas.compactMap(\.content) == ["Hello", " there"])
        #expect(model.offeredTools.first?.map(\.name) == ["web_search", "web_fetch"])
    }

    @Test func reportedUsageWins() async throws {
        let model = FakeOnDeviceModel()
        model.events = [.text("ok"), .usage(prompt: 321, completion: 7)]
        let (acc, _) = try await collect(OnDeviceClient(model: model), request)
        #expect(acc.usage == Usage(promptTokens: 321, completionTokens: 7))
    }

    @Test func toolCallsBecomeToolCallDeltas() async throws {
        let model = FakeOnDeviceModel()
        model.events = [.toolCall(name: "web_search", arguments: #"{"query":"news"}"#)]
        let (acc, _) = try await collect(OnDeviceClient(model: model), request)
        #expect(acc.finishReason == "tool_calls")
        #expect(acc.toolCalls.count == 1)
        #expect(acc.toolCalls[0].name == "web_search")
        #expect(acc.toolCalls[0].arguments == #"{"query":"news"}"#)
        #expect(acc.toolCalls[0].id.hasPrefix("call_"))
    }

    @Test(arguments: [OnDeviceAvailability.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady])
    func unavailableModelSaysWhy(_ availability: OnDeviceAvailability) async {
        let model = FakeOnDeviceModel()
        model.availability = availability
        await #expect(throws: APIError.server(availability.message)) { try await collect(OnDeviceClient(model: model), request) }
        #expect(model.prompts.isEmpty)
    }

    @Test func overflowRetriesWithLessRoomThenSucceeds() async throws {
        let model = FakeOnDeviceModel()
        let long: [APIMessage] = (0..<30).flatMap { i in
            [APIMessage.user("Q\(i) " + String(repeating: "text ", count: 60)), .assistant("A\(i)")]
        }
        let request = ChatRequest(model: OnDevice.modelID, messages: [.system(appSystem)] + long + [.user("Now")])
        let first = OnDevicePromptBuilder.build(request, contextSize: 4096, readsImages: false, tools: [])
        model.maxPromptChars = (first.instructions.count + first.prompt.count + first.history.reduce(0) { $0 + $1.text.count }) * 3 / 4
        let (acc, _) = try await collect(OnDeviceClient(model: model), request)
        #expect(acc.content == "Hello there")
        #expect(model.prompts.count >= 2)
        #expect(model.prompts.last!.history.count < model.prompts.first!.history.count)
    }

    @Test func overflowThatNeverFitsIsAContextError() async {
        let model = FakeOnDeviceModel()
        model.maxPromptChars = 1
        do {
            _ = try await collect(OnDeviceClient(model: model), request)
            Issue.record("expected an error")
        } catch {
            #expect(model.prompts.count == OnDeviceClient.attempts)
            // Recognized as an overflow, like a server's context-length error.
            #expect(Compaction.isContextOverflow(error))
        }
    }

    @Test func answerThatRunsOutOfRoomEndsCutOff() async throws {
        let model = FakeOnDeviceModel()
        model.overflowAfterEvents = true
        let (acc, _) = try await collect(OnDeviceClient(model: model), request)
        #expect(acc.content == "Hello there")
        #expect(acc.finishReason == "length")
        #expect(model.prompts.count == 1)
    }

    @Test(arguments: [OnDeviceFailure.guardrailViolation, .unsupportedLanguage, .rateLimited, .assetsUnavailable,
                      .refusal(nil), .other("boom")])
    func failuresBecomeClearMessages(_ failure: OnDeviceFailure) async {
        let model = FakeOnDeviceModel()
        model.failure = failure
        await #expect(throws: APIError.server(failure.message)) { try await collect(OnDeviceClient(model: model), request) }
        #expect(!failure.message.isEmpty)
        #expect(!Compaction.isContextOverflow(failure.apiError))
    }

    @Test func availabilityMessagesSayWhatToDo() {
        #expect(OnDeviceAvailability.appleIntelligenceNotEnabled.message.contains("Apple Intelligence"))
        #expect(OnDeviceAvailability.modelNotReady.message.contains("downloading"))
        #expect(OnDeviceAvailability.deviceNotEligible.message.contains("another connection"))
        #expect(!OnDeviceAvailability.deviceNotEligible.isSupported)
        #expect(OnDeviceAvailability.modelNotReady.isSupported && !OnDeviceAvailability.modelNotReady.isAvailable)
    }
}

// MARK: - Connection

@MainActor
struct OnDeviceConnectionTests {
    private func store() -> ConnectionStore {
        ConnectionStore(defaults: UserDefaults(suiteName: "od.\(UUID().uuidString)")!, keys: InMemoryKeyStore(),
                        chatGPT: ChatGPTAuth(store: .inMemory()), openCode: OpenCodeAuth(store: .inMemory()))
    }

    @Test func connectionKindRoundTrips() throws {
        let model = FakeOnDeviceModel()
        model.contextSize = 8192
        model.readsImages = true
        let c = Connection.appleOnDevice(model: model)
        let data = try JSONEncoder().encode(c)
        #expect(String(decoding: data, as: UTF8.self).contains("\"kind\":\"appleOnDevice\""))
        let decoded = try JSONDecoder().decode(Connection.self, from: data)
        #expect(decoded.kind == .appleOnDevice && decoded.isAppleOnDevice)
        #expect(decoded.models.map(\.id) == [OnDevice.modelID])
        #expect(decoded.models[0].fetchedContextLength == 8192)
        #expect(decoded.models[0].supportsImages)
        #expect(!decoded.models[0].supportsEffort)
        #expect(decoded.displayName(forModel: OnDevice.modelID) == OnDevice.modelName)
    }

    @Test func textOnlyModelIsMarkedTextOnly() {
        let c = Connection.appleOnDevice(model: FakeOnDeviceModel())
        #expect(c.models[0].supportsImages == false)
        #expect(c.models[0].fetchedContextLength == 4096)
    }

    @Test func storePersistsItAndBuildsAnOnDeviceEndpoint() throws {
        let defaults = UserDefaults(suiteName: "od.\(UUID().uuidString)")!
        let store = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore(), chatGPT: ChatGPTAuth(store: .inMemory()),
                                    openCode: OpenCodeAuth(store: .inMemory()))
        let added = store.addOnDeviceConnection(model: FakeOnDeviceModel())
        // Adding again opens the same one.
        #expect(store.addOnDeviceConnection(model: FakeOnDeviceModel()).id == added.id)
        #expect(store.connections.count == 1)
        let reloaded = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore(), chatGPT: ChatGPTAuth(store: .inMemory()),
                                       openCode: OpenCodeAuth(store: .inMemory()))
        #expect(reloaded.onDeviceConnection?.id == added.id)
        let endpoint = try #require(reloaded.endpoint(connectionID: added.id, modelID: OnDevice.modelID))
        #expect(endpoint.kind == .appleOnDevice)
        #expect(endpoint.apiKey == nil && !endpoint.supportsResumable)
        #expect(!ChatController.needsKey(endpoint, connections: reloaded))
        // Never cleaned up as an unconfigured server.
        reloaded.removeUnconfigured()
        #expect(reloaded.connections.count == 1)
        // New chats pick it when it's the only connection.
        #expect(ModelSelection.resolve(connections: reloaded.connections, preferredConnectionID: nil, preferredModelID: nil)
                == .init(connectionID: added.id, modelID: OnDevice.modelID))
    }

    @Test func refreshFollowsTheSystemAndKeepsUserChoices() {
        let store = store()
        let c = store.addOnDeviceConnection(model: FakeOnDeviceModel())
        store.setModelAlias("Local", connectionID: c.id, modelID: OnDevice.modelID)
        var edited = store.connection(c.id)!
        edited.models[0].supportsTools = false
        store.upsert(edited)
        let newer = FakeOnDeviceModel()
        newer.contextSize = 8192
        newer.readsImages = true
        store.refreshOnDeviceModels(model: newer)
        let model = store.connection(c.id)!.models[0]
        #expect(model.fetchedContextLength == 8192 && model.supportsImages)
        #expect(!model.supportsTools)
        #expect(store.connection(c.id)!.displayName(forModel: OnDevice.modelID) == "Local")
    }

    @Test func onboardingOffersItOnSupportedDevicesOnce() {
        #expect(OnDevice.offersConnection(availability: .available, connections: []))
        #expect(OnDevice.offersConnection(availability: .appleIntelligenceNotEnabled, connections: []))
        #expect(OnDevice.offersConnection(availability: .modelNotReady, connections: []))
        #expect(!OnDevice.offersConnection(availability: .deviceNotEligible, connections: []))
        #expect(!OnDevice.offersConnection(availability: .available, connections: [.appleOnDevice(model: FakeOnDeviceModel())]))
    }

    @Test func titlesGoOnDeviceOnlyWhenAskedAndAvailable() {
        let model = FakeOnDeviceModel()
        let other = Connection(name: "Server", baseURL: "https://example.com/v1")
        #expect(OnDevice.titleEndpoint(enabled: false, connections: [other], model: model) == nil)
        let endpoint = OnDevice.titleEndpoint(enabled: true, connections: [other], model: model)
        #expect(endpoint?.kind == .appleOnDevice)
        #expect(endpoint?.connectionID == OnDevice.titleConnectionID)
        let local = Connection.appleOnDevice(model: model)
        #expect(OnDevice.titleEndpoint(enabled: true, connections: [other, local], model: model)?.connectionID == local.id)
        model.availability = .appleIntelligenceNotEnabled
        #expect(OnDevice.titleEndpoint(enabled: true, connections: [local], model: model) == nil)
    }

    @Test func nameChatsOnDeviceIsOffByDefaultAndPersists() {
        let defaults = UserDefaults(suiteName: "od.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.nameChatsOnDevice)
        settings.nameChatsOnDevice = true
        #expect(AppSettings(defaults: defaults).nameChatsOnDevice)
    }
}
