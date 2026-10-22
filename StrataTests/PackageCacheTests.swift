import Testing
import Foundation
import SwiftData
import CryptoKit
@testable import Strata

/// The prompt cache rules for packages (docs/PACKAGES.md 4.3, R1–R7).
@MainActor
struct PackageCacheGoldenTests {
    /// R1: a chat without packages sends the bytes it sent before packages existed, for every combination of tool
    /// groups, with and without image input. The digest was taken from the code before packages were added.
    @Test func chatsWithoutPackagesSendTheSameBytes() async throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var hasher = SHA256()
        for images in [false, true] {
            let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
            let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
            try connections.setAPIKey("k", for: Connection.testID)
            var gateway = connections.testGateway()
            gateway.models = [ModelInfo(id: "m", supportsImages: images, supportsTools: true)]
            connections.upsert(gateway)
            let settings = AppSettings(defaults: defaults)
            settings.generateTitles = false
            let streamer = ProgrammableStreamer([])
            let controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
            controller.skills = SkillStore(builtIn: [], directory: nil)
            controller.packages = PackageStore(directory: nil, builtIn: [])
            let all = ToolGroup.allCases
            for mask in 0..<(1 << all.count) {
                let groups = Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
                let chat = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
                chat.createdDay = "2026-01-01"
                container.mainContext.insert(chat)
                chat.toolSwitches = groups
                controller.send(text: "hi", images: [], conversation: chat, context: container.mainContext)
                await controller.waitUntilIdle()
            }
            for request in streamer.requests { hasher.update(data: try request.encoded()) }
            #expect(streamer.requests.count == 1 << all.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(digest == "5fa4258899a536e50b2a7d2800b37c2f829816bfd0cddca7a6dbe723894eb010")
    }
}
