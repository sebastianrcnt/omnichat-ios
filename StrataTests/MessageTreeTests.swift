import Testing
import Foundation
import SwiftData
@testable import Strata

private func node(_ id: UUID, parent: UUID?, order: Int, lastActive: UUID? = nil) -> TreeNode {
    TreeNode(id: id, parent: parent, created: Date(timeIntervalSince1970: Double(order)), order: order, lastActiveChild: lastActive)
}

struct MessageTreeIndexTests {
    // root -> a1 -> b1 -> c1
    //            \-> b2 -> c2 -> d2
    //     \-> a2
    private let root = UUID(), a1 = UUID(), a2 = UUID(), b1 = UUID(), b2 = UUID(), c1 = UUID(), c2 = UUID(), d2 = UUID()

    private func index(leaf: UUID?, lastActive: [UUID: UUID] = [:]) -> MessageTreeIndex {
        MessageTreeIndex([
            node(root, parent: nil, order: 0, lastActive: lastActive[root]),
            node(a1, parent: root, order: 1, lastActive: lastActive[a1]),
            node(b1, parent: a1, order: 2),
            node(c1, parent: b1, order: 3),
            node(b2, parent: a1, order: 4),
            node(c2, parent: b2, order: 5),
            node(d2, parent: c2, order: 6),
            node(a2, parent: root, order: 7),
        ], leaf: leaf)
    }

    @Test func pathRunsFromTheRootToTheLeaf() {
        #expect(index(leaf: d2).activePath == [root, a1, b2, c2, d2])
        #expect(index(leaf: c1).activePath == [root, a1, b1, c1])
        #expect(index(leaf: nil).activePath.isEmpty)
        #expect(index(leaf: UUID()).activePath.isEmpty)
    }

    @Test func siblingsAreInCreationOrderWithPositions() {
        let t = index(leaf: d2)
        #expect(t.siblings(of: b2) == [b1, b2])
        #expect(t.branch(of: b2) == BranchPosition(index: 2, count: 2))
        #expect(t.branch(of: b1) == BranchPosition(index: 1, count: 2))
        #expect(t.branch(of: a2) == BranchPosition(index: 2, count: 2))
        #expect(t.branch(of: c1) == nil) // an only child has no switcher
        #expect(t.sibling(of: b1, offset: 1) == b2)
        #expect(t.sibling(of: b1, offset: -1) == nil)
        #expect(t.sibling(of: b2, offset: 1) == nil)
    }

    @Test func descentFollowsTheLastActiveChild() {
        // a1's last active child is b1, so switching to a1 lands on c1, not the newer branch.
        #expect(index(leaf: a2, lastActive: [a1: b1]).deepest(from: a1) == c1)
        #expect(index(leaf: a2, lastActive: [a1: b2]).deepest(from: a1) == d2)
    }

    @Test func descentFallsBackToTheMostRecentChild() {
        #expect(index(leaf: a2).deepest(from: a1) == d2)
        // A remembered child that no longer exists falls back too.
        #expect(index(leaf: a2, lastActive: [a1: UUID()]).deepest(from: a1) == d2)
        #expect(index(leaf: a2).deepest(from: root) == a2)
        #expect(index(leaf: a2).deepest(from: a2) == a2)
    }

    @Test func aBrokenParentChainDoesNotLoop() {
        let x = UUID(), y = UUID()
        let t = MessageTreeIndex([node(x, parent: y, order: 0), node(y, parent: x, order: 1)], leaf: x)
        #expect(t.activePath.count == 2)
        #expect(t.deepest(from: x) == x || t.deepest(from: x) == y)
    }

    @Test func linearLinkingFollowsCreationOrder() {
        let ids = (0..<4).map { _ in UUID() }
        let shuffled = [2, 0, 3, 1].map { node(ids[$0], parent: nil, order: $0) }
        let linked = MessageTreeIndex.linearParents(shuffled)
        #expect(linked.map(\.id) == ids)
        #expect(linked.map(\.parent) == [nil, ids[0], ids[1], ids[2]])
    }

    @Test func leavesAreCounted() {
        #expect(index(leaf: d2).leafCount == 3) // c1, d2, a2
    }
}

@MainActor
struct ConversationBranchTests {
    private struct Rig {
        let container: ModelContainer
        let context: ModelContext
        let controller: ChatController
        let streamer: ProgrammableStreamer
        let conversation: Conversation
    }

    private func rig(_ plans: [([ChatDelta], ProgrammableStreamer.End)] = []) throws -> Rig {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.strataID)
        var strata = connections.connection(Connection.strataID)!
        strata.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(strata)
        let streamer = ProgrammableStreamer(plans)
        let controller = ChatController(connections: connections, settings: AppSettings(defaults: defaults), streamer: streamer, tools: FakeTools())
        let conversation = Conversation(connectionID: Connection.strataID, modelID: "m", effort: .medium)
        conversation.autoRenameDone = true // the title request would take a scripted answer
        context.insert(conversation)
        return Rig(container: container, context: context, controller: controller, streamer: streamer, conversation: conversation)
    }

    private func answer(_ text: String) -> ([ChatDelta], ProgrammableStreamer.End) { ([ChatDelta(content: text)], .finish) }

    private func say(_ r: Rig, _ text: String, editing: Message? = nil) async {
        r.controller.send(text: text, images: [], conversation: r.conversation, context: r.context, editing: editing)
        await r.controller.waitUntilIdle()
    }

    /// Chat requests (not the title request).
    private func chatRequests(_ r: Rig) -> [ChatRequest] { r.streamer.requests.filter { $0.maxTokens == nil } }

    private func texts(_ path: [Message]) -> [String] { path.map(\.text) }

    @Test func aLegacyConversationIsLinkedInCreationOrder() throws {
        let r = try rig()
        let c = Conversation(modelID: "m")
        c.treeLinked = false // as saved before branching
        r.context.insert(c)
        var made: [Message] = []
        for (i, role) in [MessageRole.user, .assistant, .user, .assistant].enumerated() {
            let m = Message(role: role, text: "t\(i)", sortIndex: i)
            m.createdAt = Date(timeIntervalSince1970: Double(i))
            m.conversation = c
            r.context.insert(m)
            made.append(m)
        }
        #expect(texts(c.activePath) == ["t0", "t1", "t2", "t3"]) // linear even before linking
        c.ensureTree()
        #expect(c.treeLinked)
        #expect(made.map(\.parentID) == [nil, made[0].id, made[1].id, made[2].id])
        #expect(made[0].lastActiveChildID == made[1].id)
        #expect(c.leafID == made[3].id)
        #expect(texts(c.activePath) == ["t0", "t1", "t2", "t3"])
        c.ensureTree() // idempotent
        #expect(made.map(\.parentID) == [nil, made[0].id, made[1].id, made[2].id])
    }

    @Test func aTurnBuildsALinearPathAndMovesTheLeaf() async throws {
        let r = try rig([answer("A1"), answer("A2")])
        await say(r, "one")
        await say(r, "two")
        #expect(texts(r.conversation.activePath) == ["one", "A1", "two", "A2"])
        #expect(r.conversation.leafMessage?.text == "A2")
        #expect(r.conversation.treeIndex.leafCount == 1)
    }

    @Test func editingCreatesASiblingAndKeepsTheOldBranch() async throws {
        let r = try rig([answer("A1"), answer("A2"), answer("B1")])
        await say(r, "one")
        await say(r, "two")
        let two = try #require(r.conversation.activePath.first { $0.text == "two" })
        await say(r, "two, edited", editing: two)

        #expect(texts(r.conversation.activePath) == ["one", "A1", "two, edited", "B1"])
        #expect(r.conversation.messages.count == 6) // the old "two" and "A2" are still there
        let edited = try #require(r.conversation.activePath.first { $0.text == "two, edited" })
        #expect(edited.parentID == two.parentID)
        #expect(r.conversation.treeIndex.branch(of: edited.id) == BranchPosition(index: 2, count: 2))
        #expect(r.conversation.treeIndex.branch(of: two.id) == BranchPosition(index: 1, count: 2))
    }

    @Test func editingTheFirstMessageMakesASecondRoot() async throws {
        let r = try rig([answer("A1"), answer("B1")])
        await say(r, "one")
        let one = try #require(r.conversation.activePath.first)
        await say(r, "uno", editing: one)
        #expect(texts(r.conversation.activePath) == ["uno", "B1"])
        let uno = r.conversation.activePath[0]
        #expect(uno.parentID == nil)
        #expect(r.conversation.treeIndex.branch(of: uno.id) == BranchPosition(index: 2, count: 2))
    }

    @Test func switchingBranchesFollowsTheLastActiveChild() async throws {
        let r = try rig([answer("A1"), answer("A2"), answer("B1"), answer("B2")])
        await say(r, "one")
        await say(r, "two")                    // branch X: one A1 two A2
        let two = try #require(r.conversation.activePath.first { $0.text == "two" })
        await say(r, "two edited", editing: two) // branch Y: one A1 two' B1
        let edited = try #require(r.conversation.activePath.first { $0.text == "two edited" })
        await say(r, "three")                  // branch Y continues: ... B1 three B2
        #expect(texts(r.conversation.activePath) == ["one", "A1", "two edited", "B1", "three", "B2"])

        #expect(r.conversation.switchBranch(of: edited, by: -1))
        #expect(texts(r.conversation.activePath) == ["one", "A1", "two", "A2"])
        #expect(!r.conversation.switchBranch(of: two, by: -1)) // already the first
        // Back again: lands at the end of the branch that was showing, not at "two edited".
        #expect(r.conversation.switchBranch(of: two, by: 1))
        #expect(texts(r.conversation.activePath) == ["one", "A1", "two edited", "B1", "three", "B2"])
    }

    @Test func regenerateAddsASiblingAnswer() async throws {
        let r = try rig([answer("first"), answer("second")])
        await say(r, "q")
        let first = try #require(r.conversation.leafMessage)
        r.controller.regenerate(conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()

        let second = try #require(r.conversation.leafMessage)
        #expect(second.text == "second" && second.id != first.id)
        #expect(second.parentID == first.parentID)
        #expect(r.conversation.treeIndex.branch(of: second.id) == BranchPosition(index: 2, count: 2))
        #expect(texts(r.conversation.activePath) == ["q", "second"])
        #expect(r.conversation.messages.contains { $0.id == first.id })
        // Both answers answered the same request.
        let sent = chatRequests(r)
        #expect(sent.count == 2)
        #expect(sent[0].messages == sent[1].messages)
        // Switching back to the first answer.
        r.conversation.switchBranch(of: second, by: -1)
        #expect(r.conversation.leafMessage?.id == first.id)
    }

    @Test func regeneratingAnEmptyFailedAnswerReplacesIt() async throws {
        let r = try rig([([], .fail(APIError.server("boom"))), answer("fine")])
        await say(r, "q")
        #expect(r.conversation.leafMessage?.errorText != nil)
        r.controller.regenerate(conversation: r.conversation, context: r.context)
        await r.controller.waitUntilIdle()
        #expect(texts(r.conversation.activePath) == ["q", "fine"])
        #expect(r.conversation.messages.count == 2) // no empty failed branch left behind
    }

    @Test func theSentRequestIsTheActivePath() async throws {
        let r = try rig([answer("A1"), answer("A2"), answer("B1")])
        await say(r, "one")
        await say(r, "two")
        let two = try #require(r.conversation.activePath.first { $0.text == "two" })
        await say(r, "two edited", editing: two)
        let last = try #require(chatRequests(r).last)
        let userAndAssistant = last.messages.filter { $0.role != "system" }
        #expect(userAndAssistant == [.user("one"), .assistant("A1"), .user("two edited")])
    }

    @Test func continuingAnOldBranchRepeatsItsOriginalRequestPrefixByteForByte() async throws {
        let r = try rig([answer("A1"), answer("A2"), answer("B1"), answer("A3")])
        await say(r, "one")
        await say(r, "two")
        let original = try #require(chatRequests(r).last) // [system, one, A1, two]
        let two = try #require(r.conversation.activePath.first { $0.text == "two" })
        await say(r, "two edited", editing: two)
        let edited = try #require(r.conversation.activePath.first { $0.text == "two edited" })
        // Away to the other branch and back again, then continue the first one.
        r.conversation.switchBranch(of: edited, by: -1)
        await say(r, "three")
        let continued = try #require(chatRequests(r).last)

        func prefix(_ request: ChatRequest) throws -> Data {
            var bytes = try ChatRequest.encoder.encode(request.messages)
            bytes.removeLast() // the closing "]"
            return bytes
        }
        let head = try prefix(original)
        let all = try ChatRequest.encoder.encode(continued.messages)
        #expect(all.prefix(head.count) == head)
        #expect(all[head.count] == UInt8(ascii: ","))
        #expect(continued.messages.map(\.role) == ["system", "user", "assistant", "user", "assistant", "user"])
        // The tools and the rest of the body are identical too.
        #expect(continued.tools == original.tools && continued.model == original.model)
    }

    @Test func transcriptAndNamingUseTheActivePathOnly() async throws {
        let r = try rig([answer("A1"), answer("B1")])
        await say(r, "one")
        let one = try #require(r.conversation.activePath.first)
        await say(r, "uno", editing: one)
        #expect(r.conversation.transcript.contains("uno"))
        #expect(!r.conversation.transcript.contains("You:\none"))
        #expect(r.conversation.namingLines.map(\.text) == ["uno", "B1"])
    }

    @Test func deletingAConversationDeletesEveryBranch() async throws {
        let r = try rig([answer("A1"), answer("B1")])
        await say(r, "one")
        let one = try #require(r.conversation.activePath.first)
        await say(r, "uno", editing: one)
        r.context.delete(r.conversation)
        try r.context.save()
        #expect(try r.context.fetch(FetchDescriptor<Message>()).isEmpty)
    }

    @Test func diagnosticsCountBranches() async throws {
        let r = try rig([answer("A1"), answer("B1")])
        await say(r, "one")
        let one = try #require(r.conversation.activePath.first)
        await say(r, "uno", editing: one)
        let d = ConversationDiagnostics.make(for: r.conversation, window: 1000, ring: RequestRing(), counters: DiagnosticCounters())
        #expect(d.structure.branches == 2 && d.structure.activePathLength == 2 && d.structure.messages == 4)
    }
}
