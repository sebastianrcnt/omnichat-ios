import Foundation

// Apple Health as a read-only model tool (`health_query`). This file holds what every platform compiles: the metrics,
// the values a store hands back, and the store's protocol. The HealthKit store (`HealthKitStore.swift`) is iOS only;
// the Mac has no HealthKit, so the tool group is never offered there (`ToolGroup.isSupported`).

/// What `health_query` can read. The raw values are the tool's `metric` enum.
enum HealthMetric: String, CaseIterable, Sendable, Codable {
    case steps, distance
    case activeEnergy = "active_energy", restingEnergy = "resting_energy"
    case exerciseMinutes = "exercise_minutes", standHours = "stand_hours"
    case heartRate = "heart_rate", restingHeartRate = "resting_heart_rate", hrv
    case respiratoryRate = "respiratory_rate", bloodOxygen = "blood_oxygen"
    case sleep, workouts
    case weight, bodyFat = "body_fat", bmi, height, vo2max
    case mindfulMinutes = "mindful_minutes", menstrualFlow = "menstrual_flow"
    case water, caffeine
    case bloodPressure = "blood_pressure", bloodGlucose = "blood_glucose"

    /// How the values are read and summed up.
    enum Shape: Sendable, Equatable {
        /// Amounts that add up over a day (steps, energy, water): sums per period, sources deduplicated by HealthKit.
        case cumulative
        /// Measurements at a moment (heart rate, weight): average, lowest and highest per period, and the latest ones.
        case discrete
        /// Category samples summed per night by stage (`HealthSleep`).
        case sleep
        /// Hours with a stand (Apple Watch), counted per day.
        case standHours
        /// Mindful sessions, minutes per day.
        case mindful
        /// Menstrual flow level per day.
        case menstrual
        case workouts
    }

    var shape: Shape {
        switch self {
        case .steps, .distance, .activeEnergy, .restingEnergy, .exerciseMinutes, .water, .caffeine: .cumulative
        case .heartRate, .restingHeartRate, .hrv, .respiratoryRate, .bloodOxygen, .weight, .bodyFat, .bmi, .height, .vo2max,
             .bloodPressure, .bloodGlucose: .discrete
        case .sleep: .sleep
        case .standHours: .standHours
        case .mindfulMinutes: .mindful
        case .menstrualFlow: .menstrual
        case .workouts: .workouts
        }
    }

    /// The name in text the model and the user read ("resting heart rate").
    var displayName: String {
        switch self {
        case .hrv: "heart rate variability (SDNN)"
        case .bmi: "BMI"
        case .vo2max: "VO2 max"
        default: rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// The range a call without `start` reads: a week for daily things, longer for what is measured now and then.
    var defaultDays: Int {
        switch self {
        case .weight, .bodyFat, .bmi, .vo2max, .bloodPressure, .bloodGlucose: 90
        case .height: 3650
        case .workouts, .menstrualFlow: 30
        default: 7
        }
    }
}

/// How `health_query` sums up a range: one figure, or a row per day, week or month.
enum HealthAggregation: String, CaseIterable, Sendable {
    case sum, avg, min, max, latest, daily, weekly, monthly

    var isRows: Bool { self == .daily || self == .weekly || self == .monthly }
}

/// A period statistics are grouped by.
enum HealthBucket: Sendable, Equatable {
    case day, week, month
    /// The whole range in one.
    case whole
}

/// One period's statistics of a quantity, in the metric's canonical unit (`HealthUnits`). Nil where there was no data.
/// Blood pressure carries the systolic values, and the diastolic ones in `average2`/`min2`/`max2`.
struct HealthStat: Sendable, Equatable {
    var start: Date
    var end: Date
    var sum: Double?
    var average: Double?
    var min: Double?
    var max: Double?
    var average2: Double?
    var min2: Double?
    var max2: Double?

    init(start: Date, end: Date, sum: Double? = nil, average: Double? = nil, min: Double? = nil, max: Double? = nil,
         average2: Double? = nil, min2: Double? = nil, max2: Double? = nil) {
        self.start = start
        self.end = end
        self.sum = sum
        self.average = average
        self.min = min
        self.max = max
        self.average2 = average2
        self.min2 = min2
        self.max2 = max2
    }

    var hasData: Bool { sum != nil || average != nil || min != nil || max != nil }
}

/// One sample: a quantity (canonical unit) or a category value (`HealthCategory`). Blood pressure: systolic in `value`,
/// diastolic in `value2`.
struct HealthSample: Sendable, Equatable {
    var start: Date
    var end: Date
    var value: Double
    var value2: Double?

    init(start: Date, end: Date, value: Double, value2: Double? = nil) {
        self.start = start
        self.end = end
        self.value = value
        self.value2 = value2
    }
}

/// Raw category values, as HealthKit numbers them (stable across releases).
enum HealthCategory {
    /// `HKCategoryValueSleepAnalysis`.
    enum Sleep: Int, Sendable { case inBed = 0, asleepUnspecified = 1, awake = 2, core = 3, deep = 4, rem = 5 }
    /// `HKCategoryValueAppleStandHour`.
    static let stood = 0
    /// `HKCategoryValueVaginalBleeding` (menstrual flow): 1 unspecified, 2 light, 3 medium, 4 heavy, 5 none.
    static func flowName(_ value: Int) -> String {
        switch value {
        case 2: "light"
        case 3: "medium"
        case 4: "heavy"
        case 5: "none"
        default: "flow (unspecified)"
        }
    }
}

/// A workout, with its totals in canonical units (kcal, meters, bpm).
struct HealthWorkout: Sendable, Equatable {
    var start: Date
    var end: Date
    /// "running", "strength training", ...
    var activity: String
    var energy: Double?
    var distance: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// The units values are shown in: the user's choices in the Health app when HealthKit tells them, else the locale's.
/// Values arrive in canonical units: meters, kcal, kg, meters (height), mL, mg/dL, fractions for percentages.
struct HealthUnits: Sendable, Equatable {
    enum Distance: Sendable { case km, mi }
    enum Energy: Sendable { case kcal, kJ }
    enum Mass: Sendable { case kg, lb, st }
    enum Length: Sendable { case cm, ftIn }
    enum Volume: Sendable { case mL, flOz }
    enum Glucose: Sendable { case mgdL, mmolL }

    var distance: Distance = .km
    var energy: Energy = .kcal
    var mass: Mass = .kg
    var height: Length = .cm
    var water: Volume = .mL
    var glucose: Glucose = .mgdL

    static let metric = HealthUnits()
    static let us = HealthUnits(distance: .mi, energy: .kcal, mass: .lb, height: .ftIn, water: .flOz, glucose: .mgdL)

    /// The locale's usual units (US customary in the US, the UK's miles and stones, metric elsewhere). Blood glucose is
    /// mg/dL where that is the custom (the US, Korea, Japan, ...), mmol/L elsewhere.
    static func locale(_ locale: Locale = .current) -> HealthUnits {
        let region = locale.region?.identifier ?? ""
        let mgdL: Set<String> = ["US", "KR", "JP", "IN", "FR", "DE", "IT", "ES", "BE", "AT", "PT", "BR", "MX", "IL", "EG", "TW", "TH", "PH", "ID", "VN"]
        var units: HealthUnits = switch locale.measurementSystem {
        case .us: .us
        case .uk: HealthUnits(distance: .mi, energy: .kcal, mass: .st, height: .ftIn, water: .mL, glucose: .mmolL)
        default: .metric
        }
        units.glucose = mgdL.contains(region) ? .mgdL : .mmolL
        return units
    }
}

/// Where health data is read from. HealthKit on iPhone (`HealthKitStore`); a fake in tests. Read permission is per
/// type, and HealthKit never says whether reading was denied: a denied type looks exactly like one with no data.
protocol HealthDataSource: Sendable {
    /// Health data exists on this device (false on iPad without Health, on the Mac, and in tests that say so).
    var isAvailable: Bool { get }
    /// Whether asking for these metrics would show the system sheet (some type was never asked for).
    func needsAuthorization(for metrics: [HealthMetric]) async -> Bool
    /// Shows the system sheet for the types never asked for. Throws when the sheet could not be shown.
    func requestAuthorization(for metrics: [HealthMetric]) async throws
    /// The units to show values in.
    func units(for metrics: [HealthMetric]) async -> HealthUnits
    /// Statistics of a quantity metric (`.cumulative` or `.discrete`) per period over `interval`, oldest first; periods
    /// start at `interval.start` (`HealthCalendar.periods`).
    func statistics(_ metric: HealthMetric, in interval: DateInterval, bucket: HealthBucket, calendar: Calendar) async throws -> [HealthStat]
    /// Samples overlapping `interval`, newest first, at most `limit`: quantities, or category samples whose `value` is
    /// the raw category value.
    func samples(_ metric: HealthMetric, in interval: DateInterval, limit: Int) async throws -> [HealthSample]
    /// Workouts that started in `interval`, newest first, at most `limit`.
    func workouts(in interval: DateInterval, limit: Int) async throws -> [HealthWorkout]
}

/// Days, weeks and months as the user's calendar has them.
enum HealthCalendar {
    /// The periods covering `interval`: whole days, weeks (from the calendar's first weekday) or months, the first one
    /// starting at or before `interval.start`. `.whole` is the interval itself.
    static func periods(_ interval: DateInterval, bucket: HealthBucket, calendar: Calendar) -> [DateInterval] {
        let component: Calendar.Component
        switch bucket {
        case .whole: return [interval]
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        guard let first = calendar.dateInterval(of: component, for: interval.start) else { return [interval] }
        var out: [DateInterval] = []
        var cursor = first.start
        while cursor < interval.end, out.count < 4000 {
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            out.append(DateInterval(start: cursor, end: next))
            cursor = next
        }
        return out
    }

    /// The night a sleep sample belongs to: the day it ends on, counting from 6 PM the evening before (as Health does),
    /// so a night from 11 PM to 7 AM and an evening nap both land on the morning's date.
    static func night(of date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(6 * 3600))
    }
}
