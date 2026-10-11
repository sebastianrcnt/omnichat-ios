import Foundation

/// A durable snapshot at an applied SSE boundary or completed tool boundary.
/// No credentials; the connection's current Keychain key is used on recovery.
struct TurnCheckpoint: Codable, Sendable {
    var messagesData: Data
    var round = 0
    var requestID: String?
    var submissionStarted = false
    var lastSequence = 0
    var accumulator = StreamAccumulator()
    var streamDone = false
    var steps: [ToolStep] = []
    var records: [ToolCallRecord] = []
    var priorReasoning = ""

    init(messages: [APIMessage]) throws {
        messagesData = try ChatRequest.encoder.encode(messages)
    }

    var messages: [APIMessage] {
        get throws { try JSONDecoder().decode([APIMessage].self, from: messagesData) }
    }

    /// Returns false for replayed/duplicate events; includes id-only comments in the cursor.
    mutating func apply(_ delta: ChatDelta) throws -> Bool {
        if let id = delta.requestID { requestID = id }
        if let seq = delta.sequence {
            if seq <= lastSequence { return false }
            guard seq == lastSequence + 1 else { throw APIError.server(String(localized: "Missing stream event; replay is not contiguous.")) }
            lastSequence = seq
        }
        accumulator.apply(delta)
        if delta.isDone { streamDone = true }
        return true
    }
}

extension APIMessage: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        if let text = try? c.decode(String.self, forKey: .content) {
            content = .text(text)
        } else {
            content = .parts(try c.decode([ContentPart].self, forKey: .content))
        }
        struct Call: Decodable {
            struct Function: Decodable { var name: String; var arguments: String }
            var id: String
            var function: Function
        }
        toolCalls = try c.decodeIfPresent([Call].self, forKey: .toolCalls)?.map {
            ToolCall(id: $0.id, name: $0.function.name, arguments: $0.function.arguments)
        } ?? []
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
    }
}

extension ContentPart: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        if type == "text" { self = .text(try c.decode(String.self, forKey: .text)) }
        else {
            let inner = try c.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageURL)
            self = .imageURL(try inner.decode(String.self, forKey: .url))
        }
    }
}
