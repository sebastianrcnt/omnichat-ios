#if DEBUG && os(iOS)
import Foundation
import HealthKit

/// Debug-only: sample Apple Health data for the simulator, and a self-test of `health_query`. Release builds never ask
/// to write to Health (and carry no NSHealthUpdateUsageDescription).
///   -StrataSeedHealth 1          write two weeks of steps, distance, energy, heart rate, HRV, sleep with stages,
///                                workouts, weight and blood pressure (once; `reset` deletes the earlier seed first)
///   -StrataHealthSelfTest "sleep;steps,last_14_days;heart_rate,last_7_days,latest;workouts;list_available"
///                                run those queries (metric[,start[,aggregation]]) and print the results to stderr
enum HealthSeed {
    static let metadataKey = "StrataSeed"
    private static func say(_ text: String) { FileHandle.standardError.write(Data("[health] \(text)\n".utf8)) }

    @MainActor
    static func runIfRequested() {
        let seed = UserDefaults.standard.string(forKey: "StrataSeedHealth")
        let selfTest = UserDefaults.standard.string(forKey: "StrataHealthSelfTest")
        guard seed != nil || selfTest != nil else { return }
        Task {
            if let seed, seed != "0" {
                do { try await write(reset: seed == "reset") } catch { say("seed failed: \(error)") }
            }
            if let selfTest { await runSelfTest(selfTest) }
        }
    }

    static func runSelfTest(_ spec: String) async {
        for query in spec.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !query.isEmpty {
            let parts = query.split(separator: ",").map(String.init)
            var args: [String: String] = ["metric": parts[0]]
            if parts.count > 1, !parts[1].isEmpty { args["start"] = parts[1] }
            if parts.count > 2 { args["aggregation"] = parts[2] }
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            let tool = HealthQueryTool(localOnly: false, destination: nil, ask: { _ in true })
            let out = await tool.run(arguments: json, conversation: nil, callID: nil)
            say("query \(json)\(out.isError ? " (error)" : "")\n\(out.text)\n")
        }
        say("self-test done")
    }

    private static let quantityTypes: [HKQuantityTypeIdentifier] = [
        .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .heartRate, .restingHeartRate, .heartRateVariabilitySDNN,
        .bodyMass, .bloodPressureSystolic, .bloodPressureDiastolic, .oxygenSaturation,
    ]

    static func write(reset: Bool) async throws {
        let store = HealthKitStore.shared.store
        var types = Set<HKSampleType>(quantityTypes.map { HKQuantityType($0) })
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKObjectType.workoutType())
        let read = Set<HKObjectType>(types.map { $0 as HKObjectType }).union(HealthKitStore.readTypes(HealthMetric.allCases))
        try await store.requestAuthorization(toShare: types, read: read)
        let seeded = HKQuery.predicateForObjects(withMetadataKey: metadataKey)
        if reset {
            for type in types { _ = try? await store.deleteObjects(of: type, predicate: seeded) }
            say("deleted the earlier seed")
        } else {
            let existing = try await HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.stepCount), predicate: seeded)],
                                                             sortDescriptors: [], limit: 1).result(for: store)
            if !existing.isEmpty { say("already seeded"); return }
        }
        var rng = SeededRandom(seed: 42)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let meta: [String: Any] = [metadataKey: true]
        var samples: [HKSample] = []
        func quantity(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, _ start: Date, _ end: Date? = nil) -> HKQuantitySample {
            HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value), start: start, end: end ?? start, metadata: meta)
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        for offset in (0..<14).reversed() {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let isToday = offset == 0
            // Steps, distance and energy in hourly blocks, 8 AM to 9 PM (today only up to now).
            for hour in 8...21 {
                let start = day.addingTimeInterval(Double(hour) * 3600)
                let end = start.addingTimeInterval(3600)
                if isToday && end > .now { break }
                let steps = Double(Int(rng.next(150, 1100)))
                samples.append(quantity(.stepCount, .count(), steps, start, end))
                samples.append(quantity(.distanceWalkingRunning, .meter(), steps * 0.72, start, end))
                samples.append(quantity(.activeEnergyBurned, .kilocalorie(), steps * 0.04 + rng.next(2, 12), start, end))
            }
            // Heart rate every 30 minutes through the day, lower at night.
            var t = day
            while t < day.addingTimeInterval(86_400), t < .now {
                let hour = calendar.component(.hour, from: t)
                let base = hour < 7 ? 55.0 : hour < 22 ? 74.0 : 62.0
                samples.append(quantity(.heartRate, bpm, (base + rng.next(-8, 14)).rounded(), t))
                t = t.addingTimeInterval(1800)
            }
            samples.append(quantity(.restingHeartRate, bpm, (58 + rng.next(-3, 4)).rounded(), day.addingTimeInterval(8 * 3600)))
            samples.append(quantity(.heartRateVariabilitySDNN, .secondUnit(with: .milli), (46 + rng.next(-12, 15)).rounded(), day.addingTimeInterval(4 * 3600)))
            samples.append(quantity(.oxygenSaturation, .percent(), (96.5 + rng.next(-1.5, 2)) / 100, day.addingTimeInterval(3 * 3600)))
            if offset % 2 == 0 {
                samples.append(quantity(.bodyMass, .gramUnit(with: .kilo), 72.4 - Double(13 - offset) * 0.05 + rng.next(-0.3, 0.3), day.addingTimeInterval(7.5 * 3600)))
            }
            if offset % 3 == 0 {
                let when = day.addingTimeInterval(9 * 3600)
                let sys = quantity(.bloodPressureSystolic, .millimeterOfMercury(), (118 + rng.next(-6, 9)).rounded(), when)
                let dia = quantity(.bloodPressureDiastolic, .millimeterOfMercury(), (76 + rng.next(-5, 6)).rounded(), when)
                samples.append(HKCorrelation(type: HKCorrelationType(.bloodPressure), start: when, end: when, objects: [sys, dia], metadata: meta))
            }
            // The night that ended this morning: in bed, then sleep cycles of core, deep, REM with a short wake.
            let bed = day.addingTimeInterval(-3600 + rng.next(-40, 50) * 60) // around 11 PM the evening before
            var cursor = bed.addingTimeInterval(rng.next(8, 25) * 60)
            let wake = day.addingTimeInterval(7 * 3600 + rng.next(-35, 40) * 60)
            func sleep(_ value: HKCategoryValueSleepAnalysis, _ start: Date, _ end: Date) {
                samples.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: value.rawValue, start: start, end: end, metadata: meta))
            }
            sleep(.inBed, bed, wake.addingTimeInterval(6 * 60))
            var cycle = 0
            while cursor < wake {
                let plan: [(HKCategoryValueSleepAnalysis, Double)] = [(.asleepCore, rng.next(25, 45)), (.asleepDeep, cycle < 2 ? rng.next(20, 35) : rng.next(5, 12)),
                                                                     (.asleepCore, rng.next(10, 20)), (.asleepREM, cycle < 2 ? rng.next(10, 18) : rng.next(20, 32)),
                                                                     (.awake, rng.next(1, 5))]
                for (stage, minutes) in plan {
                    let end = min(cursor.addingTimeInterval(minutes * 60), wake)
                    if end > cursor { sleep(stage, cursor, end) }
                    cursor = end
                    if cursor >= wake { break }
                }
                cycle += 1
            }
        }
        try await store.save(samples)
        say("saved \(samples.count) samples")
        // Workouts: a run every other day, strength training on the others now and then.
        for offset in stride(from: 13, through: 1, by: -1) where offset % 2 == 1 || offset % 5 == 0 {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let running = offset % 2 == 1
            let start = day.addingTimeInterval((running ? 7 : 18.5) * 3600 + rng.next(0, 30) * 60)
            let minutes = running ? rng.next(26, 42) : rng.next(35, 55)
            let end = start.addingTimeInterval(minutes * 60)
            let config = HKWorkoutConfiguration()
            config.activityType = running ? .running : .traditionalStrengthTraining
            config.locationType = running ? .outdoor : .indoor
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
            try await builder.beginCollection(at: start)
            var parts: [HKSample] = [quantity(.activeEnergyBurned, .kilocalorie(), minutes * (running ? 10.5 : 6.2), start, end)]
            if running { parts.append(quantity(.distanceWalkingRunning, .meter(), minutes * 165, start, end)) }
            var t = start
            while t < end {
                parts.append(quantity(.heartRate, bpm, ((running ? 148 : 112) + rng.next(-12, 22)).rounded(), t))
                t = t.addingTimeInterval(120)
            }
            try await builder.addSamples(parts)
            try await builder.addMetadata(meta)
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        }
        say("saved workouts")
    }
}

/// Repeatable numbers for the sample data.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ low: Double, _ high: Double) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return low + Double(state >> 11) / Double(1 << 53) * (high - low)
    }
}
#endif
