import Foundation

/// A durable snapshot at an applied SSE boundary or completed tool boundary.
/// No credentials; the connection's current Keychain key is used on recovery.
struct TurnCheckpoint: Codable, Sendable {
    var messagesData: Data
    var round = 0
    var requestID: String?
    var idempotencyKey: String?
    /// Exact original body: connection/model/effort edits cannot change a retry.
    var requestData: Data?
    var submissionStarted = false
    var lastSequence = 0
    var accumulator = StreamAccumulator()
    var streamDone = false
    var steps: [ToolStep] = []
    var records: [ToolCallRecord] = []
    /// Results of this round's calls that finished ahead of an earlier call (calls run in parallel). Kept apart from
    /// `records` until they can be numbered in call order. Optional so older saved checkpoints still decode.
    var pendingResults: [RawToolResult]?
    var priorReasoning = ""

    init(messages: [APIMessage]) throws {
        messagesData = try ChatRequest.encoder.encode(messages)
        idempotencyKey = UUID().uuidString.lowercased()
    }

    /// A checkpoint whose history is held by the caller (the turn runner keeps the messages in memory and the request
    /// body already contains them), so nothing is encoded here.
    init(historyHeldByCaller: Void = ()) {
        messagesData = Data()
        idempotencyKey = UUID().uuidString.lowercased()
    }

    var messages: [APIMessage] {
        get throws {
            if messagesData.isEmpty, let body = requestData {
                struct Envelope: Decodable { var messages: [APIMessage] }
                return try JSONDecoder().decode(Envelope.self, from: body).messages
            }
            return try JSONDecoder().decode([APIMessage].self, from: messagesData)
        }
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

// MARK: - Static / dynamic split

/// The small, fast-changing part of a checkpoint (cursor, accumulator, this turn's finished tool rounds and results).
/// Always written as one unit, so the cursor and the accumulator it belongs to can never disagree.
struct CheckpointDynamic: Codable, Sendable {
    var requestID: String?
    var lastSequence: Int
    var accumulator: StreamAccumulator
    var streamDone: Bool
    var steps: [ToolStep] = []
    var records: [ToolCallRecord] = []
    var pendingResults: [RawToolResult]?
    var priorReasoning = ""

    init(requestID: String?, lastSequence: Int, accumulator: StreamAccumulator, streamDone: Bool,
         steps: [ToolStep], records: [ToolCallRecord], pendingResults: [RawToolResult]? = nil, priorReasoning: String) {
        self.requestID = requestID
        self.lastSequence = lastSequence
        self.accumulator = accumulator
        self.streamDone = streamDone
        self.steps = steps
        self.records = records
        self.pendingResults = pendingResults
        self.priorReasoning = priorReasoning
    }
}

/// Cheap fingerprint of the large part: the exact request body of the current round. Every field is an O(1) read.
struct CheckpointStaticKey: Hashable, Sendable {
    var round: Int
    var idempotencyKey: String?
    var requestBytes: Int?
}

/// What is persisted for the large half: a small JSON header and then the request body as raw bytes (no base64).
/// The body already contains the whole history, so the history is not stored a second time.
private struct PersistedStatic: Codable {
    var idempotencyKey: String?
    var round: Int
    var submissionStarted: Bool
}

private enum StaticFormat {
    static let magic = Data("STRATA-CKPT1\n".utf8)
}

extension TurnCheckpoint {
    var dynamicPart: CheckpointDynamic {
        CheckpointDynamic(requestID: requestID, lastSequence: lastSequence, accumulator: accumulator, streamDone: streamDone,
                          steps: steps, records: records, pendingResults: pendingResults, priorReasoning: priorReasoning)
    }

    var staticKey: CheckpointStaticKey {
        CheckpointStaticKey(round: round, idempotencyKey: idempotencyKey, requestBytes: requestData?.count)
    }

    /// Only a checkpoint whose request was submitted is worth persisting: before that, the turn is recoverable
    /// from the previous round's checkpoint (or, for the first round, from the saved conversation).
    var isPersistable: Bool { submissionStarted && requestData != nil }

    mutating func overlay(_ dynamic: CheckpointDynamic) {
        requestID = dynamic.requestID
        lastSequence = dynamic.lastSequence
        accumulator = dynamic.accumulator
        streamDone = dynamic.streamDone
        steps = dynamic.steps
        records = dynamic.records
        pendingResults = dynamic.pendingResults
        priorReasoning = dynamic.priorReasoning
    }

    /// Encodes the large half once per round.
    static func encodeStatic(_ checkpoint: TurnCheckpoint) throws -> Data {
        guard let body = checkpoint.requestData else { return try JSONEncoder().encode(checkpoint) }
        let header = try JSONEncoder().encode(PersistedStatic(idempotencyKey: checkpoint.idempotencyKey, round: checkpoint.round,
                                                              submissionStarted: checkpoint.submissionStarted))
        var out = StaticFormat.magic
        out.reserveCapacity(out.count + header.count + 1 + body.count)
        out.append(header)
        out.append(0x0A)
        out.append(body)
        return out
    }

    /// Rebuilds a checkpoint from its two persisted parts. A whole checkpoint saved before the split restores as is.
    static func restore(staticData: Data, dynamicData: Data?) throws -> TurnCheckpoint {
        var checkpoint: TurnCheckpoint
        if staticData.starts(with: StaticFormat.magic) {
            let rest = staticData.dropFirst(StaticFormat.magic.count)
            guard let newline = rest.firstIndex(of: 0x0A) else { throw APIError.server("Unreadable checkpoint.") }
            let persisted = try JSONDecoder().decode(PersistedStatic.self, from: rest[rest.startIndex..<newline])
            let body = Data(rest[rest.index(after: newline)...])
            struct Envelope: Decodable { var messages: [APIMessage] }
            let messages = try JSONDecoder().decode(Envelope.self, from: body).messages
            checkpoint = try TurnCheckpoint(messages: messages)
            checkpoint.requestData = body
            checkpoint.idempotencyKey = persisted.idempotencyKey
            checkpoint.round = persisted.round
            checkpoint.submissionStarted = persisted.submissionStarted
        } else {
            checkpoint = try JSONDecoder().decode(TurnCheckpoint.self, from: staticData)
        }
        if let dynamicData, let dynamic = try? JSONDecoder().decode(CheckpointDynamic.self, from: dynamicData) {
            checkpoint.overlay(dynamic)
        }
        return checkpoint
    }
}
