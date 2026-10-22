#if STRATA_HEALTH && os(iOS)
import Foundation
import HealthKit

/// Apple Health through HealthKit, read-only. Quantities come from statistics queries, so a day's steps logged by both
/// the iPhone and an Apple Watch count once (HealthKit picks a source per moment); samples and workouts from sample
/// queries, newest first.
final class HealthKitStore: HealthDataSource, @unchecked Sendable {
    static let shared = HealthKitStore()

    let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Types

    /// The quantity type and the canonical unit of a quantity metric (`HealthUnits`). Blood pressure has two.
    static func quantities(_ metric: HealthMetric) -> [(HKQuantityTypeIdentifier, HKUnit)] {
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        return switch metric {
        case .steps: [(.stepCount, .count())]
        case .distance: [(.distanceWalkingRunning, .meter())]
        case .activeEnergy: [(.activeEnergyBurned, .kilocalorie())]
        case .restingEnergy: [(.basalEnergyBurned, .kilocalorie())]
        case .exerciseMinutes: [(.appleExerciseTime, .minute())]
        case .heartRate: [(.heartRate, perMinute)]
        case .restingHeartRate: [(.restingHeartRate, perMinute)]
        case .hrv: [(.heartRateVariabilitySDNN, .secondUnit(with: .milli))]
        case .respiratoryRate: [(.respiratoryRate, perMinute)]
        case .bloodOxygen: [(.oxygenSaturation, .percent())]
        case .weight: [(.bodyMass, .gramUnit(with: .kilo))]
        case .bodyFat: [(.bodyFatPercentage, .percent())]
        case .bmi: [(.bodyMassIndex, .count())]
        case .height: [(.height, .meter())]
        case .vo2max: [(.vo2Max, HKUnit(from: "ml/kg*min"))]
        case .water: [(.dietaryWater, .literUnit(with: .milli))]
        case .caffeine: [(.dietaryCaffeine, .gramUnit(with: .milli))]
        case .bloodPressure: [(.bloodPressureSystolic, .millimeterOfMercury()), (.bloodPressureDiastolic, .millimeterOfMercury())]
        case .bloodGlucose: [(.bloodGlucose, HKUnit(from: "mg/dL"))]
        case .sleep, .workouts, .standHours, .mindfulMinutes, .menstrualFlow: []
        }
    }

    static func category(_ metric: HealthMetric) -> HKCategoryTypeIdentifier? {
        switch metric {
        case .sleep: .sleepAnalysis
        case .standHours: .appleStandHour
        case .mindfulMinutes: .mindfulSession
        case .menstrualFlow: .menstrualFlow
        default: nil
        }
    }

    /// The distances a workout may carry.
    static let workoutDistances: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming,
                                                               .distanceWheelchair, .distanceDownhillSnowSports]

    /// What reading a metric asks permission for. A workout's energy, distance and heart rate are read with it.
    static func readTypes(_ metrics: [HealthMetric]) -> Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for metric in metrics {
            for (id, _) in quantities(metric) { types.insert(HKQuantityType(id)) }
            if let id = category(metric) { types.insert(HKCategoryType(id)) }
            if metric == .workouts {
                types.insert(HKObjectType.workoutType())
                types.insert(HKQuantityType(.activeEnergyBurned))
                types.insert(HKQuantityType(.heartRate))
                for id in workoutDistances { types.insert(HKQuantityType(id)) }
            }
        }
        return types
    }

    // MARK: Permission

    func needsAuthorization(for metrics: [HealthMetric]) async -> Bool {
        let types = Self.readTypes(metrics)
        guard isAvailable, !types.isEmpty else { return false }
        guard let status = try? await store.statusForAuthorizationRequest(toShare: [], read: types) else { return false }
        return status != .unnecessary
    }

    func requestAuthorization(for metrics: [HealthMetric]) async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes(metrics))
    }

    /// The units chosen in the Health app, where HealthKit tells them; the locale's otherwise.
    func units(for metrics: [HealthMetric]) async -> HealthUnits {
        var units = HealthUnits.locale()
        let types = Set(metrics.flatMap { Self.quantities($0).map { HKQuantityType($0.0) } }
                        + (metrics.contains(.workouts) ? [HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceWalkingRunning)] : []))
        guard !types.isEmpty, let preferred = try? await store.preferredUnits(for: types) else { return units }
        for (type, unit) in preferred {
            let name = unit.unitString
            switch HKQuantityTypeIdentifier(rawValue: type.identifier) {
            case .distanceWalkingRunning: units.distance = unit == .mile() ? .mi : .km
            case .activeEnergyBurned, .basalEnergyBurned: units.energy = name.lowercased().contains("j") ? .kJ : .kcal
            case .bodyMass: units.mass = unit == .pound() ? .lb : unit == .stone() ? .st : .kg
            case .height: units.height = unit == .inch() || unit == .foot() ? .ftIn : .cm
            case .dietaryWater: units.water = name.contains("oz") ? .flOz : .mL
            case .bloodGlucose: units.glucose = name.contains("mol") ? .mmolL : .mgdL
            default: break
            }
        }
        return units
    }

    // MARK: Reading

    func statistics(_ metric: HealthMetric, in interval: DateInterval, bucket: HealthBucket, calendar: Calendar) async throws -> [HealthStat] {
        let quantities = Self.quantities(metric)
        guard let (first, unit) = quantities.first else { return [] }
        var stats = try await statistics(first, unit: unit, cumulative: metric.shape == .cumulative, interval: interval, bucket: bucket, calendar: calendar)
        if quantities.count == 2 { // blood pressure: the diastolic values ride along
            let (second, unit2) = quantities[1]
            let other = try await statistics(second, unit: unit2, cumulative: false, interval: interval, bucket: bucket, calendar: calendar)
            let byStart = Dictionary(other.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
            for i in stats.indices {
                let d = byStart[stats[i].start]
                stats[i].average2 = d?.average
                stats[i].min2 = d?.min
                stats[i].max2 = d?.max
            }
        }
        return stats
    }

    private func statistics(_ id: HKQuantityTypeIdentifier, unit: HKUnit, cumulative: Bool, interval: DateInterval,
                            bucket: HealthBucket, calendar: Calendar) async throws -> [HealthStat] {
        let type = HKQuantityType(id)
        let predicate = HKSamplePredicate.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: interval.start, end: interval.end))
        let options: HKStatisticsOptions = cumulative ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax]
        func stat(_ s: HKStatistics?, _ period: DateInterval) -> HealthStat {
            HealthStat(start: period.start, end: period.end, sum: s?.sumQuantity()?.doubleValue(for: unit),
                       average: s?.averageQuantity()?.doubleValue(for: unit), min: s?.minimumQuantity()?.doubleValue(for: unit),
                       max: s?.maximumQuantity()?.doubleValue(for: unit))
        }
        let periods = HealthCalendar.periods(interval, bucket: bucket, calendar: calendar)
        do {
            if bucket == .whole {
                let result = try await HKStatisticsQueryDescriptor(predicate: predicate, options: options).result(for: store)
                return [stat(result, interval)]
            }
            guard let anchor = periods.first?.start else { return [] }
            let step: DateComponents = switch bucket { case .week: DateComponents(day: 7); case .month: DateComponents(month: 1); default: DateComponents(day: 1) }
            let collection = try await HKStatisticsCollectionQueryDescriptor(predicate: predicate, options: options, anchorDate: anchor,
                                                                           intervalComponents: step).result(for: store)
            return periods.map { stat(collection.statistics(for: $0.start), $0) }
        } catch let error as HKError where error.code == .errorNoData {
            return periods.map { HealthStat(start: $0.start, end: $0.end) }
        }
    }

    func samples(_ metric: HealthMetric, in interval: DateInterval, limit: Int) async throws -> [HealthSample] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        if let id = Self.category(metric) {
            let descriptor = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(id), predicate: predicate)],
                                                     sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: limit)
            return try await descriptor.result(for: store).map { HealthSample(start: $0.startDate, end: $0.endDate, value: Double($0.value)) }
        }
        let quantities = Self.quantities(metric)
        guard let (first, unit) = quantities.first else { return [] }
        func read(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) async throws -> [HealthSample] {
            let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)],
                                                     sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: limit)
            return try await descriptor.result(for: store).map {
                HealthSample(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit))
            }
        }
        var out = try await read(first, unit)
        if quantities.count == 2 { // a blood pressure reading saves both values with the same time
            let diastolic = try await read(quantities[1].0, quantities[1].1)
            let byStart = Dictionary(diastolic.map { ($0.start, $0.value) }, uniquingKeysWith: { a, _ in a })
            for i in out.indices { out[i].value2 = byStart[out[i].start] }
        }
        return out
    }

    func workouts(in interval: DateInterval, limit: Int) async throws -> [HealthWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
                                                 limit: limit)
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        return try await descriptor.result(for: store).map { w in
            let distance = Self.workoutDistances.lazy.compactMap { w.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter()) }.first
            let heart = w.statistics(for: HKQuantityType(.heartRate))
            return HealthWorkout(start: w.startDate, end: w.endDate, activity: Self.name(w.workoutActivityType),
                                 energy: w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
                                 distance: distance, averageHeartRate: heart?.averageQuantity()?.doubleValue(for: perMinute),
                                 maxHeartRate: heart?.maximumQuantity()?.doubleValue(for: perMinute))
        }
    }

    // MARK: Words

    static func name(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: "running"
        case .walking: "walking"
        case .cycling: "cycling"
        case .swimming: "swimming"
        case .hiking: "hiking"
        case .yoga: "yoga"
        case .pilates: "pilates"
        case .dance, .socialDance, .cardioDance: "dance"
        case .functionalStrengthTraining: "functional strength training"
        case .traditionalStrengthTraining: "strength training"
        case .highIntensityIntervalTraining: "HIIT"
        case .coreTraining: "core training"
        case .elliptical: "elliptical"
        case .rowing: "rowing"
        case .stairClimbing, .stairs, .stepTraining: "stairs"
        case .mixedCardio: "mixed cardio"
        case .crossTraining: "cross training"
        case .cooldown: "cooldown"
        case .flexibility: "flexibility"
        case .mindAndBody: "mind and body"
        case .martialArts: "martial arts"
        case .boxing, .kickboxing: "boxing"
        case .climbing: "climbing"
        case .tennis: "tennis"
        case .badminton: "badminton"
        case .tableTennis: "table tennis"
        case .soccer: "soccer"
        case .basketball: "basketball"
        case .golf: "golf"
        case .baseball: "baseball"
        case .volleyball: "volleyball"
        case .snowboarding: "snowboarding"
        case .downhillSkiing: "skiing"
        case .crossCountrySkiing: "cross-country skiing"
        case .wheelchairWalkPace, .wheelchairRunPace: "wheelchair"
        case .handCycling: "hand cycling"
        case .paddleSports: "paddling"
        case .surfingSports: "surfing"
        default: "other workout"
        }
    }

    /// An error in words the model can pass on.
    static func describe(_ error: Error) -> String {
        guard let error = error as? HKError else { return error.localizedDescription }
        switch error.code {
        case .errorDatabaseInaccessible: return "the iPhone is locked, and health data can only be read while it's unlocked."
        case .errorHealthDataUnavailable: return "Apple Health isn't available on this device."
        case .errorAuthorizationDenied, .errorAuthorizationNotDetermined: return "OpenChat isn't allowed to read it."
        default: return error.localizedDescription
        }
    }
}
#endif
