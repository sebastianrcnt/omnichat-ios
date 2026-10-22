#if DEBUG
import Foundation

/// Debug-only launch arguments for the on-device model:
///   -StrataOnDevice 1            add the Apple Intelligence connection (as the first-run button does) and select it
///   -StrataOnDeviceSelfTest 1    real requests through `ChatClient` (plain, a tool call, a tool result, an overflow),
///                                reported to stderr
enum OnDeviceDebug {
    @MainActor
    static func applyLaunchConfiguration(connections: ConnectionStore, settings: AppSettings) {
        if UserDefaults.standard.bool(forKey: "StrataOnDevice") {
            let c = connections.addOnDeviceConnection()
            settings.lastConnectionID = c.id
            settings.lastModelID = OnDevice.modelID
        }
        if UserDefaults.standard.bool(forKey: "StrataOnDeviceSelfTest") { Task { await selfTest() } }
    }

    private static func log(_ text: String) { FileHandle.standardError.write(Data("[OnDeviceSelfTest] \(text)\n".utf8)) }

    static func selfTest() async {
        let model = OnDevice.system
        log("availability=\(model.availability) context=\(model.contextSize) images=\(model.readsImages)")
        let endpoint = OnDevice.endpoint(Connection.appleOnDevice())
        let system = ConversationDate.systemPrompt(base: AppPrompt.text(tools: true, python: false), day: "2026-10-22")
        let tools = ToolDefinition.available(python: false, images: false)
        let cases: [(String, ChatRequest)] = [
            ("plain", ChatRequest(model: OnDevice.modelID, messages: [.system(system), .user("In one sentence: what is SwiftUI?")])),
            ("tool call", ChatRequest(model: OnDevice.modelID, messages: [.system(system), .user("What happened in the news today?")], tools: tools)),
            ("tool result", ChatRequest(model: OnDevice.modelID, messages: [
                .system(system), .user("Who won the 2026 Tour de France?"),
                .assistant("", toolCalls: [ToolCall(id: "c1", name: "web_search", arguments: #"{"query":"2026 Tour de France winner"}"#)]),
                .tool(callID: "c1", content: #"<source id="1" title="Pogacar wins fifth Tour" url="https://example.com/tdf">Tadej Pogacar won the 2026 Tour de France on July 26.</source>"#),
            ], tools: tools)),
            ("long history", ChatRequest(model: OnDevice.modelID, messages: [.system(system)]
                + (0..<40).flatMap { i in [APIMessage.user("Message \(i): " + String(repeating: "filler text ", count: 120)), .assistant("Reply \(i).")] }
                + [.user("What number was the last message?")])),
        ]
        for (label, request) in cases {
            let start = Date()
            var text = "", calls: [String] = [], usage: Usage?, finish: String?
            do {
                for try await delta in ChatClient().stream(request, endpoint: endpoint) {
                    text += delta.content ?? ""
                    calls += delta.toolCalls.map { "\($0.name ?? "") \($0.arguments ?? "")" }
                    if let u = delta.usage { usage = u }
                    if let f = delta.finishReason { finish = f }
                }
                log("\(label): \(String(format: "%.1f", Date().timeIntervalSince(start)))s finish=\(finish ?? "-") usage=\(usage.map { "\($0.promptTokens)/\($0.completionTokens)" } ?? "-") calls=\(calls) text=\(text.prefix(200))")
            } catch {
                log("\(label): error \(error.localizedDescription)")
            }
        }
        log("done")
    }
}
#endif
