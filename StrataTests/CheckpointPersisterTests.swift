import Foundation
import Testing
import UIKit
@testable import Strata

@MainActor
struct CheckpointPersisterTests {
    private final class Clock { var t: TimeInterval = 100 }

    private struct Rig {
        var clock = Clock()
        var persister: CheckpointPersister
        var center: NotificationCenter
        var snapshots: Box
        final class Box { var all: [CheckpointPersister.Snapshot] = [] }
    }

    private func rig(minInterval: TimeInterval = 1) -> Rig {
        let clock = Clock()
        let box = Rig.Box()
        let center = NotificationCenter()
        let p = CheckpointPersister(minInterval: minInterval, now: { clock.t }, center: center, autoTrailing: false) { box.all.append($0) }
        return Rig(clock: clock, persister: p, center: center, snapshots: box)
    }

    private func checkpoint(_ messages: [APIMessage] = [.user("hi")], round: Int = 0) throws -> TurnCheckpoint {
        var cp = try TurnCheckpoint(messages: messages)
        cp.round = round
        cp.requestData = try ChatRequest(model: "m", messages: messages).encoded()
        cp.submissionStarted = true
        return cp
    }

    @Test func staticPartIsEncodedOncePerRound() throws {
        let r = rig()
        var cp = try checkpoint()
        for seq in 1...200 {
            _ = try cp.apply(ChatDelta(content: "x", requestID: "req_a", sequence: seq))
            r.clock.t += 0.011
            r.persister.update(cp)
        }
        #expect(r.persister.staticEncodeCount == 1)
        #expect(r.snapshots.all.compactMap(\.staticData).count == 1)
        // A new round has a new history and request: one more static encode.
        let next = try checkpoint([.user("hi"), .assistant("x")], round: 1)
        r.persister.update(next)
        #expect(r.persister.staticEncodeCount == 2)
    }

    @Test func aRoundIsNotPersistedUntilItsRequestIsSubmitted() throws {
        let r = rig()
        r.persister.update(try checkpoint())
        #expect(r.snapshots.all.count == 1)
        var fresh = try TurnCheckpoint(messages: [.user("hi"), .assistant("x")])
        fresh.round = 1
        r.persister.update(fresh) // round start: nothing written, the previous round still recovers the turn
        #expect(r.snapshots.all.count == 1 && r.persister.staticEncodeCount == 1)
    }

    @Test func toolResultsAreSmallAndWrittenAtOnceWithoutReencodingTheRequest() throws {
        let r = rig()
        var cp = try checkpoint()
        r.persister.update(cp)
        cp.records = [ToolCallRecord(id: "c", name: "web_search", arguments: "{}", result: "r", isError: false)]
        r.persister.update(cp)
        #expect(r.snapshots.all.count == 2) // written immediately
        #expect(r.persister.staticEncodeCount == 1) // the request body was not encoded again
        let restored = try TurnCheckpoint.restore(staticData: #require(r.snapshots.all[0].staticData), dynamicData: r.snapshots.all[1].dynamicData)
        #expect(restored.records.map(\.id) == ["c"])
    }

    @Test func dynamicWritesAreThrottled() throws {
        let r = rig()
        var cp = try checkpoint()
        r.persister.update(cp) // first write is immediate
        #expect(r.snapshots.all.count == 1)
        for seq in 1...20 {
            _ = try cp.apply(ChatDelta(content: "x", requestID: "req_a", sequence: seq))
            r.clock.t += 0.04 // 0.8 s in total
            r.persister.update(cp)
        }
        #expect(r.snapshots.all.count == 1)
        r.clock.t += 0.3
        _ = try cp.apply(ChatDelta(content: "y", sequence: 21))
        r.persister.update(cp)
        #expect(r.snapshots.all.count == 2)
        let dynamic = try JSONDecoder().decode(CheckpointDynamic.self, from: r.snapshots.all[1].dynamicData)
        #expect(dynamic.lastSequence == 21)
        #expect(dynamic.accumulator.content == String(repeating: "x", count: 20) + "y")
    }

    @Test func flushWritesPendingStateImmediately() throws {
        let r = rig()
        var cp = try checkpoint()
        r.persister.update(cp)
        _ = try cp.apply(ChatDelta(content: "x", requestID: "req_a", sequence: 1))
        r.persister.update(cp)
        #expect(r.snapshots.all.count == 1)
        r.persister.flush()
        #expect(r.snapshots.all.count == 2)
        r.persister.flush() // nothing new
        #expect(r.snapshots.all.count == 2)
    }

    @Test(arguments: [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification])
    func backgroundingFlushes(name: Notification.Name) throws {
        let r = rig()
        var cp = try checkpoint()
        r.persister.update(cp)
        _ = try cp.apply(ChatDelta(content: "x", requestID: "req_a", sequence: 1))
        r.persister.update(cp)
        #expect(r.snapshots.all.count == 1)
        r.center.post(name: name, object: nil)
        #expect(r.snapshots.all.count == 2)
        #expect(r.snapshots.all.last?.checkpoint.lastSequence == 1)
    }

    @Test func streamCompletionWritesAtOnce() throws {
        let r = rig()
        var cp = try checkpoint()
        r.persister.update(cp)
        _ = try cp.apply(ChatDelta(content: "x", requestID: "req_a", sequence: 1))
        _ = try cp.apply(ChatDelta(isDone: true, sequence: 2))
        r.persister.update(cp)
        #expect(r.snapshots.all.count == 2)
    }

    @Test func closedPersisterWritesNothing() throws {
        let r = rig()
        var cp = try checkpoint()
        r.persister.update(cp)
        _ = try cp.apply(ChatDelta(content: "x", requestID: "req_a", sequence: 1))
        r.persister.update(cp)
        r.persister.close()
        r.persister.flush()
        r.persister.update(cp)
        r.center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(r.snapshots.all.count == 1)
    }

    @Test func restoreCombinesBothHalvesAndAcceptsLegacyData() throws {
        let r = rig()
        var cp = try checkpoint()
        r.persister.update(cp)
        _ = try cp.apply(ChatDelta(content: "abc", requestID: "req_a", sequence: 1))
        r.persister.update(cp)
        r.persister.flush()
        let first = try #require(r.snapshots.all.first?.staticData)
        let last = try #require(r.snapshots.all.last)
        let restored = try TurnCheckpoint.restore(staticData: first, dynamicData: last.dynamicData)
        #expect(restored.lastSequence == 1 && restored.requestID == "req_a" && restored.accumulator.content == "abc")
        #expect(try restored.messages == cp.messages)
        #expect(restored.idempotencyKey == cp.idempotencyKey)
        // A checkpoint saved whole (before the split) still restores.
        let legacy = try JSONEncoder().encode(cp)
        let old = try TurnCheckpoint.restore(staticData: legacy, dynamicData: nil)
        #expect(old.lastSequence == 1 && old.accumulator.content == "abc")
    }
}
