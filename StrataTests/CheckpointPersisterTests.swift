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
            try r.persister.update(cp)
        }
        #expect(r.persister.staticEncodeCount == 1)
        #expect(r.snapshots.all.compactMap(\.staticData).count == 1)
        // A new round has a new history and request: one more static encode.
        let next = try checkpoint([.user("hi"), .assistant("x")], round: 1)
        try r.persister.update(next)
        #expect(r.persister.staticEncodeCount == 2)
    }

    @Test func aRoundIsNotPersistedUntilItsRequestIsSubmitted() throws {
        let r = rig()
        try r.persister.update(try checkpoint())
        #expect(r.snapshots.all.count == 1)
        var fresh = try TurnCheckpoint(messages: [.user("hi"), .assistant("x")])
        fresh.round = 1
        try r.persister.update(fresh) // round start: nothing written, the previous round still recovers the turn
        #expect(r.snapshots.all.count == 1 && r.persister.staticEncodeCount == 1)
    }

    @Test func toolResultsAreSmallAndWrittenAtOnceWithoutReencodingTheRequest() throws {
        let r = rig()
        var cp = try checkpoint()
        try r.persister.update(cp)
        cp.records = [ToolCallRecord(id: "c", name: "web_search", arguments: "{}", result: "r", isError: false)]
        try r.persister.update(cp)
        #expect(r.snapshots.all.count == 2) // written immediately
        #expect(r.persister.staticEncodeCount == 1) // the request body was not encoded again
        let restored = try TurnCheckpoint.restore(staticData: #require(r.snapshots.all[0].staticData), dynamicData: r.snapshots.all[1].dynamicData)
        #expect(restored.records.map(\.id) == ["c"])
    }

    @Test func dynamicWritesAreThrottled() throws {
        let r = rig()
        var cp = try checkpoint()
        try r.persister.update(cp) // first write is immediate
        #expect(r.snapshots.all.count == 1)
        for seq in 1...20 {
            _ = try cp.apply(ChatDelta(content: "x", requestID: "req_a", sequence: seq))
            r.clock.t += 0.04 // 0.8 s in total
            try r.persister.update(cp)
        }
        #expect(r.snapshots.all.count == 1)
        r.clock.t += 0.3
        _ = try cp.apply(ChatDelta(content: "y", sequence: 21))
        try r.persister.update(cp)
        #expect(r.snapshots.all.count == 2)
        let dynamic = try JSONDecoder().decode(CheckpointDynamic.self, from: r.snapshots.all[1].dynamicData)
        #expect(dynamic.lastSequence == 21)
        #expect(dynamic.accumulator.content == String(repeating: "x", count: 20) + "y")
    }

    @Test func flushWritesPendingStateImmediately() throws {
        let r = rig()
        var cp = try checkpoint()
        try r.persister.update(cp)
        _ = try cp.apply(ChatDelta(content: "x", requestID: "req_a", sequence: 1))
        try r.persister.update(cp)
        #expect(r.snapshots.all.count == 1)
        try r.persister.flush()
        #expect(r.snapshots.all.count == 2)
        try r.persister.flush() // nothing new
        #expect(r.snapshots.all.count == 2)
    }

    @Test(arguments: [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification])
    func backgroundingFlushes(name: Notification.Name) throws {
        let r = rig()
        var cp = try checkpoint()
        try r.persister.update(cp)
        _ = try cp.apply(ChatDelta(content: "x", requestID: "req_a", sequence: 1))
        try r.persister.update(cp)
        #expect(r.snapshots.all.count == 1)
        r.center.post(name: name, object: nil)
        #expect(r.snapshots.all.count == 2)
        #expect(r.snapshots.all.last?.checkpoint.lastSequence == 1)
    }

    @Test func streamCompletionWritesAtOnce() throws {
        let r = rig()
        var cp = try checkpoint()
        try r.persister.update(cp)
        _ = try cp.apply(ChatDelta(content: "x", requestID: "req_a", sequence: 1))
        _ = try cp.apply(ChatDelta(isDone: true, sequence: 2))
        try r.persister.update(cp)
        #expect(r.snapshots.all.count == 2)
    }

    @Test func closedPersisterWritesNothing() throws {
        let r = rig()
        var cp = try checkpoint()
        try r.persister.update(cp)
        _ = try cp.apply(ChatDelta(content: "x", requestID: "req_a", sequence: 1))
        try r.persister.update(cp)
        r.persister.close()
        try r.persister.flush()
        try r.persister.update(cp)
        r.center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(r.snapshots.all.count == 1)
    }

    /// From the audit: a failed save was swallowed and the persister marked clean, so the runner submitted a round a
    /// restart could not find. The failure reaches the caller, and the round's request is written again next time.
    @Test func aFailedWriteAtSubmissionIsThrownAndKeptDirty() throws {
        let box = Rig.Box()
        var failing = true
        let p = CheckpointPersister(minInterval: 1, now: { 100 }, center: NotificationCenter(), autoTrailing: false) { snapshot in
            if failing { throw CocoaError(.fileWriteOutOfSpace) }
            box.all.append(snapshot)
        }
        var cp = try checkpoint()
        #expect(throws: CheckpointWriteError.self) { try p.update(cp) }
        #expect(p.writeCount == 0 && box.all.isEmpty)
        failing = false
        try p.update(cp)
        #expect(p.writeCount == 1)
        #expect(box.all.first?.staticData != nil, "the round's request is written with the retry")
        // A throttled write (stream deltas) that fails is not thrown; it stays dirty for the next one.
        failing = true
        _ = try cp.apply(ChatDelta(content: "a", requestID: "req_a", sequence: 1))
        cp.streamDone = true
        try p.update(cp)
        failing = false
        try p.flush()
        #expect(p.writeCount == 2 && box.all.last?.dynamicData.isEmpty == false)
        // A tool-result boundary that fails is thrown.
        failing = true
        cp.records = [ToolCallRecord(id: "c1", name: "web_search", arguments: "{}", result: "r", isError: false, sourceIDs: [])]
        #expect(throws: CheckpointWriteError.self) { try p.update(cp) }
    }

    @Test func restoreCombinesBothHalvesAndAcceptsLegacyData() throws {
        let r = rig()
        var cp = try checkpoint()
        try r.persister.update(cp)
        _ = try cp.apply(ChatDelta(content: "abc", requestID: "req_a", sequence: 1))
        try r.persister.update(cp)
        try r.persister.flush()
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
