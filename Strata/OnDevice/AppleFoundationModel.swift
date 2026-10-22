import Foundation
import FoundationModels
import CoreGraphics
import ImageIO

/// The system's on-device model through the Foundation Models framework (iOS 26 / macOS 26, the app's minimum).
/// Newer systems add what they offer: a reported context size and token usage, and image input where the model has
/// vision (27).
struct AppleFoundationModel: OnDeviceLanguageModel {
    var availability: OnDeviceAvailability { Self.availability(SystemLanguageModel.default.availability) }

    static func availability(_ availability: SystemLanguageModel.Availability) -> OnDeviceAvailability {
        switch availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        }
    }

    var contextSize: Int {
        let size = SystemLanguageModel.default.contextSize
        return size > 0 ? size : OnDevice.fallbackContextSize
    }

    var readsImages: Bool {
        if #available(iOS 27.0, macOS 27.0, *) {
            return SystemLanguageModel.default.capabilities.contains(.vision)
        }
        return false
    }

    func respond(to prompt: OnDevicePrompt, tools specs: [OnDeviceToolSpec]) -> AsyncThrowingStream<OnDeviceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let calls = ToolCallRecorder()
                do {
                    let tools = try specs.map { try StoppingTool(spec: $0, calls: calls) }
                    let session = LanguageModelSession(model: .default, tools: tools,
                                                       transcript: Self.transcript(prompt, tools: tools))
                    let options = GenerationOptions(maximumResponseTokens: prompt.maxTokens)
                    var sent = ""
                    var usage: (Int, Int)?
                    for try await snapshot in session.streamResponse(to: Self.makePrompt(prompt), options: options) {
                        let text = snapshot.content
                        // Snapshots carry the whole answer so far; a snapshot that rewrote earlier text (never seen)
                        // can't be taken back from the chat, so only growth is sent.
                        if text.count > sent.count, text.hasPrefix(sent) {
                            continuation.yield(.text(String(text.dropFirst(sent.count))))
                            sent = text
                        }
                        if #available(iOS 27.0, macOS 27.0, *) {
                            let u = snapshot.usage
                            if u.input.totalTokenCount > 0 { usage = (u.input.totalTokenCount, u.output.totalTokenCount) }
                        }
                    }
                    if let usage { continuation.yield(.usage(prompt: usage.0, completion: usage.1)) }
                    continuation.finish()
                } catch {
                    // A tool stopped the answer on purpose: hand on the calls it recorded.
                    let recorded = calls.all
                    if !recorded.isEmpty, Self.isStop(error) {
                        for call in recorded { continuation.yield(.toolCall(name: call.name, arguments: call.arguments)) }
                        continuation.finish()
                    } else if error is CancellationError || Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: Self.failure(error))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Prompt

    private static func transcript(_ prompt: OnDevicePrompt, tools: [StoppingTool]) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [.text(.init(content: prompt.instructions))],
                                                  toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) })),
        ]
        for turn in prompt.history {
            let segments: [Transcript.Segment] = [.text(.init(content: turn.text))]
            switch turn.role {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: segments)))
            case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: segments)))
            }
        }
        return Transcript(entries: entries)
    }

    /// The message to answer, with its images where the model reads them.
    private static func makePrompt(_ request: OnDevicePrompt) -> Prompt {
        let text = request.prompt
        if #available(iOS 27.0, macOS 27.0, *), !request.images.isEmpty {
            let attachments: [FoundationModels.Attachment<ImageAttachmentContent>] = request.images.compactMap(cgImage).map { FoundationModels.Attachment($0) }
            return Prompt {
                attachments
                text
            }
        }
        return Prompt(text)
    }

    private static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Errors

    private static func isStop(_ error: Error) -> Bool {
        if error is ToolStop { return true }
        if let toolError = error as? LanguageModelSession.ToolCallError { return toolError.underlyingError is ToolStop }
        return false
    }

    /// The framework's errors as the app tells them. Systems from 27 throw `LanguageModelError` and friends; 26
    /// throws `GenerationError`.
    static func failure(_ error: Error) -> OnDeviceFailure {
        if let failure = error as? OnDeviceFailure { return failure }
        if #available(iOS 27.0, macOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return .contextExceeded
                case .guardrailViolation: return .guardrailViolation
                case .unsupportedLanguageOrLocale: return .unsupportedLanguage
                case .rateLimited: return .rateLimited
                case .refusal: return .refusal(nil)
                default: return .other(error.localizedDescription)
                }
            }
            if error is SystemLanguageModel.Error { return .assetsUnavailable }
            if let error = error as? LanguageModelSession.Error, case .concurrentRequests = error { return .rateLimited }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return .contextExceeded
            case .guardrailViolation: return .guardrailViolation
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .rateLimited, .concurrentRequests: return .rateLimited
            case .assetsUnavailable: return .assetsUnavailable
            case .refusal: return .refusal(nil)
            default: return .other(error.localizedDescription)
            }
        }
        if let toolError = error as? LanguageModelSession.ToolCallError {
            return .other(toolError.underlyingError.localizedDescription)
        }
        return .other(error.localizedDescription)
    }
}

// MARK: - Tools

/// Thrown by a `StoppingTool` to end the response at its call.
private struct ToolStop: Error {}

/// The calls the session made, in order. The framework may call tools side by side.
private final class ToolCallRecorder: @unchecked Sendable {
    struct Call { var name: String; var arguments: String }
    private let lock = NSLock()
    private var calls: [Call] = []

    func record(_ call: Call) { lock.withLock { calls.append(call) } }
    var all: [Call] { lock.withLock { calls } }
}

/// A tool the session may call, which records the call and stops the response there, so the app runs it.
private struct StoppingTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let calls: ToolCallRecorder

    init(spec: OnDeviceToolSpec, calls: ToolCallRecorder) throws {
        name = spec.name
        description = spec.description
        self.calls = calls
        let properties = spec.parameters.map { p in
            DynamicGenerationSchema.Property(name: p.name, description: p.description, schema: Self.schema(p.kind),
                                             isOptional: p.optional)
        }
        parameters = try GenerationSchema(root: DynamicGenerationSchema(name: spec.name, properties: properties),
                                          dependencies: [])
    }

    private static func schema(_ kind: OnDeviceToolSpec.Parameter.Kind) -> DynamicGenerationSchema {
        switch kind {
        case .string: DynamicGenerationSchema(type: String.self)
        case .integer: DynamicGenerationSchema(type: Int.self)
        case .number: DynamicGenerationSchema(type: Double.self)
        case .boolean: DynamicGenerationSchema(type: Bool.self)
        }
    }

    func call(arguments: GeneratedContent) async throws -> String {
        calls.record(.init(name: name, arguments: arguments.jsonString))
        throw ToolStop()
    }
}
