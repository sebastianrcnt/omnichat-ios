import Testing
import Foundation
import SwiftData
@testable import Strata

/// The chat screen's transcript cache (`ChatTranscriptCache`): worked out once per `TranscriptVersion`, again only when
/// the conversation really changed.
@MainActor
struct ChatTranscriptCacheTests {
    private struct Rig {
        let container: ModelContainer
        let context: ModelContext
        let conversation: Conversation
        let messages: [Message]
    }

    /// A linked chat of `count` messages, alternating question and answer.
    private func rig(count: Int = 6) throws -> Rig {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let c = Conversation(modelID: "m")
        context.insert(c)
        var made: [Message] = []
        for i in 0..<count {
            let m = Message(role: i.isMultiple(of: 2) ? .user : .assistant, text: "t\(i)", sortIndex: i)
            m.createdAt = Date(timeIntervalSince1970: Double(i))
            context.insert(m)
            c.attach(m, parent: made.last)
            made.append(m)
        }
        return Rig(container: container, context: context, conversation: c, messages: made)
    }

    @Test func aRedrawWithNothingChangedReusesTheTranscript() throws {
        let r = try rig()
        let cache = ChatTranscriptCache()
        let first = cache.transcript(for: r.conversation)
        for _ in 0..<5 { _ = cache.transcript(for: r.conversation) }
        #expect(cache.transcriptBuilds == 1)
        #expect(first.items.map(\.text) == ["t0", "t1", "t2", "t3", "t4", "t5"])
        #expect(first.activePath.map(\.id) == r.conversation.activePath.map(\.id))
        // Text streaming into the last answer is the row's to read: it is not a new version.
        r.messages.last?.text += " more"
        _ = cache.transcript(for: r.conversation)
        #expect(cache.transcriptBuilds == 1)
    }

    @Test func aNewMessageIsANewVersion() throws {
        let r = try rig()
        let cache = ChatTranscriptCache()
        _ = cache.transcript(for: r.conversation)
        let m = Message(role: .user, text: "next", sortIndex: 6)
        r.context.insert(m)
        r.conversation.attach(m, parent: r.messages.last)
        let after = cache.transcript(for: r.conversation)
        #expect(cache.transcriptBuilds == 2)
        #expect(after.items.last?.text == "next")
        _ = cache.transcript(for: r.conversation)
        #expect(cache.transcriptBuilds == 2)
    }

    @Test func anEditedMessageIsANewVersion() throws {
        let r = try rig()
        let cache = ChatTranscriptCache()
        _ = cache.transcript(for: r.conversation)
        // Editing a question adds a sibling and moves the leaf to it.
        let edited = Message(role: .user, text: "t2 edited", sortIndex: 6)
        edited.createdAt = Date(timeIntervalSince1970: 100)
        r.context.insert(edited)
        r.conversation.attach(edited, parent: r.messages[1])
        let after = cache.transcript(for: r.conversation)
        #expect(cache.transcriptBuilds == 2)
        #expect(after.items.map(\.text) == ["t0", "t1", "t2 edited"])
        #expect(after.tree.branch(of: edited.id) == BranchPosition(index: 2, count: 2))
        // Switching back to the first branch moves only the leaf: still a new version.
        r.conversation.switchBranch(of: edited, by: -1)
        let back = cache.transcript(for: r.conversation)
        #expect(cache.transcriptBuilds == 3)
        #expect(back.items.map(\.text) == ["t0", "t1", "t2", "t3", "t4", "t5"])
    }

    @Test func aFinishedTurnIsANewVersionForTheSources() throws {
        let r = try rig()
        let cache = ChatTranscriptCache()
        #expect(cache.allSources(for: r.conversation).isEmpty)
        #expect(cache.allSources(for: r.conversation).isEmpty)
        #expect(cache.sourceBuilds == 1)
        // The engine saves a turn's sources and then stamps the conversation (`ChatController.finish`).
        r.conversation.sources = [SourceInfo(id: 1, title: "A", url: "https://a.example", snippet: "")]
        r.conversation.updatedAt = .now.addingTimeInterval(1)
        #expect(cache.allSources(for: r.conversation).map(\.id) == [1])
        #expect(cache.sourceBuilds == 2)
        #expect(cache.allSources(for: r.conversation).map(\.id) == [1])
        #expect(cache.sourceBuilds == 2)
    }

    @Test func aHiddenInstructionIsOnThePathButNotARow() throws {
        let r = try rig(count: 2)
        let hidden = Message(role: .user, text: AnswerNow.instruction, sortIndex: 2)
        hidden.hiddenInstruction = true
        r.context.insert(hidden)
        r.conversation.attach(hidden, parent: r.messages.last)
        let t = ChatTranscriptCache().transcript(for: r.conversation)
        #expect(t.activePath.count == 3)
        #expect(t.items.count == 2)
    }

    @Test func versionsDifferOnlyWhenAFieldDoes() throws {
        let r = try rig()
        let v = TranscriptVersion(r.conversation)
        #expect(TranscriptVersion(r.conversation) == v)
        r.conversation.leafID = r.messages[3].id
        #expect(TranscriptVersion(r.conversation) != v)
    }
}

struct DecodeCacheValidityTests {
    @Test func theSameStorageIsAHitWithoutComparingBytes() {
        let a = Data(repeating: 7, count: 4096)
        let copy = a // shares the storage
        #expect(DecodeCache<Int>.same(a, copy))
    }

    @Test func aChangeIsAMissWhetherOrNotTheLengthDiffers() {
        var b = Data(repeating: 7, count: 4096)
        let a = b
        b[100] = 8 // same length, another value
        #expect(!DecodeCache<Int>.same(a, b))
        #expect(!DecodeCache<Int>.same(a, a + Data([1])))
        #expect(DecodeCache<Int>.same(a, Data(repeating: 7, count: 4096))) // equal bytes in other storage
    }

    @Test func aChangedValueIsDecodedAgain() {
        let cache = DecodeCache<Int>()
        let id = UUID()
        var decodes = 0
        let one = Data("[1,2,3]".utf8)
        #expect(cache.value(for: id, source: one) { decodes += 1; return 1 } == 1)
        #expect(cache.value(for: id, source: one) { decodes += 1; return 1 } == 1)
        #expect(decodes == 1)
        #expect(cache.value(for: id, source: Data("[1,2,4]".utf8)) { decodes += 1; return 2 } == 2)
        #expect(decodes == 2)
    }
}
