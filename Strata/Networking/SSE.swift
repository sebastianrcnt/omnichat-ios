import Foundation

struct SSEEvent: Equatable, Sendable {
    var event: String?
    var data: String
}

/// Incremental Server-Sent Events parser. Feed arbitrary byte chunks; complete events come back.
/// Handles chunk boundaries inside lines or UTF-8 sequences, LF / CRLF / CR line endings, comments
/// and multi-line `data:` fields.
struct SSEParser: Sendable {
    private var buffer = Data()
    private var dataLines: [String] = []
    private var eventName: String?
    private var lastWasCR = false

    init() {}

    mutating func feed(_ chunk: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in chunk {
            if byte == 0x0A { // LF
                if lastWasCR { lastWasCR = false; continue } // second half of CRLF
                processLine(into: &events)
            } else if byte == 0x0D { // CR
                lastWasCR = true
                processLine(into: &events)
            } else {
                lastWasCR = false
                buffer.append(byte)
            }
        }
        return events
    }

    mutating func feed(_ string: String) -> [SSEEvent] { feed(Data(string.utf8)) }

    /// Flush a trailing event that was not terminated by a blank line.
    mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !buffer.isEmpty { processLine(into: &events) }
        dispatch(into: &events)
        return events
    }

    private mutating func processLine(into events: inout [SSEEvent]) {
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        if line.isEmpty { dispatch(into: &events); return }
        if line.hasPrefix(":") { return }
        let field: String
        var value: String
        if let idx = line.firstIndex(of: ":") {
            field = String(line[..<idx])
            value = String(line[line.index(after: idx)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }
        switch field {
        case "data": dataLines.append(value)
        case "event": eventName = value
        default: break
        }
    }

    private mutating func dispatch(into events: inout [SSEEvent]) {
        defer { dataLines.removeAll(); eventName = nil }
        guard !dataLines.isEmpty else { return }
        events.append(SSEEvent(event: eventName, data: dataLines.joined(separator: "\n")))
    }
}
