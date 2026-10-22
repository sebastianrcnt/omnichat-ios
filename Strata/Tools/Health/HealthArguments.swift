import Foundation

/// A `health_query` call, parsed: what to read, over which range, summed up how.
struct HealthRequest: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case query(HealthMetric)
        /// `metric: "list_available"`: which types were asked for and hold data.
        case listAvailable
    }

    var mode: Mode
    /// From the start of the first day to the end of the last one (or now, for a range that reaches today).
    var interval: DateInterval
    /// How the range was asked for, in words ("last 14 days", "2026-10-01 to 2026-10-14").
    var rangeLabel: String
    /// Nil: the metric's usual summary (`HealthReport.defaultAggregation`).
    var aggregation: HealthAggregation?

    var metric: HealthMetric? { if case .query(let m) = mode { m } else { nil } }
}

/// Parses `health_query`'s arguments. Errors are written for the model, so it can fix the call.
enum HealthArguments {
    static let listAvailable = "list_available"
    /// The longest range a call reads.
    static let maxDays = 3660

    struct Problem: Error, Equatable {
        var message: String
    }

    static func parse(_ arguments: String, now: Date = .now, calendar: Calendar = .current) -> Result<HealthRequest, Problem> {
        let args = (arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let rawMetric = normalized(args["metric"] as? String ?? args["mode"] as? String ?? "")
        let mode: HealthRequest.Mode
        if rawMetric == listAvailable || rawMetric == "list" {
            mode = .listAvailable
        } else if let metric = metric(rawMetric) {
            mode = .query(metric)
        } else if rawMetric.isEmpty {
            return .failure(Problem(message: "Error: missing \"metric\". Use one of: \(metricList), or \(listAvailable)."))
        } else {
            return .failure(Problem(message: "Error: unknown metric \"\(rawMetric)\". Use one of: \(metricList), or \(listAvailable)."))
        }
        var aggregation: HealthAggregation?
        if let raw = args["aggregation"] as? String, !normalized(raw).isEmpty {
            guard let parsed = Self.aggregation(raw) else {
                return .failure(Problem(message: "Error: unknown aggregation \"\(raw)\". Use one of: \(HealthAggregation.allCases.map(\.rawValue).joined(separator: ", "))."))
            }
            aggregation = parsed
        }
        let defaultDays = HealthRequest(mode: mode, interval: DateInterval(), rangeLabel: "").metric?.defaultDays ?? 7
        switch range(start: string(args["start"]), end: string(args["end"]), defaultDays: defaultDays, now: now, calendar: calendar) {
        case .failure(let problem): return .failure(problem)
        case .success(let (interval, label)):
            return .success(HealthRequest(mode: mode, interval: interval, rangeLabel: label, aggregation: aggregation))
        }
    }

    static var metricList: String { HealthMetric.allCases.map(\.rawValue).joined(separator: ", ") }

    /// A metric by its name, also in the forms models tend to write ("heart rate", "HRV", "spo2", "bp").
    static func metric(_ raw: String) -> HealthMetric? {
        let key = normalized(raw)
        if let metric = HealthMetric(rawValue: key) { return metric }
        let aliases: [String: HealthMetric] = [
            "step": .steps, "step_count": .steps, "walking_running_distance": .distance, "distance_walking_running": .distance,
            "active_calories": .activeEnergy, "calories": .activeEnergy, "basal_energy": .restingEnergy, "resting_calories": .restingEnergy,
            "exercise": .exerciseMinutes, "exercise_time": .exerciseMinutes, "stand": .standHours, "stand_hour": .standHours,
            "hr": .heartRate, "pulse": .heartRate, "resting_hr": .restingHeartRate, "rhr": .restingHeartRate,
            "heart_rate_variability": .hrv, "hrv_sdnn": .hrv, "respiration": .respiratoryRate, "breathing_rate": .respiratoryRate,
            "spo2": .bloodOxygen, "oxygen_saturation": .bloodOxygen, "oxygen": .bloodOxygen, "sleep_analysis": .sleep,
            "workout": .workouts, "body_mass": .weight, "body_fat_percentage": .bodyFat, "body_mass_index": .bmi,
            "vo2_max": .vo2max, "cardio_fitness": .vo2max, "mindful": .mindfulMinutes, "mindfulness": .mindfulMinutes,
            "period": .menstrualFlow, "menstruation": .menstrualFlow, "dietary_water": .water, "dietary_caffeine": .caffeine,
            "bp": .bloodPressure, "glucose": .bloodGlucose,
        ]
        return aliases[key]
    }

    static func aggregation(_ raw: String) -> HealthAggregation? {
        let key = normalized(raw)
        if let value = HealthAggregation(rawValue: key) { return value }
        let aliases: [String: HealthAggregation] = [
            "total": .sum, "average": .avg, "mean": .avg, "minimum": .min, "lowest": .min, "maximum": .max, "highest": .max,
            "last": .latest, "most_recent": .latest, "recent": .latest, "day": .daily, "per_day": .daily, "by_day": .daily,
            "week": .weekly, "per_week": .weekly, "by_week": .weekly, "month": .monthly, "per_month": .monthly, "by_month": .monthly,
        ]
        return aliases[key]
    }

    // MARK: Ranges

    /// The range `start`/`end` name. `start` may be a relative range ("last_14_days", "this_week", "yesterday") that
    /// sets both ends, or an ISO date or date-time; `end` defaults to now, and a date-only `end` includes that day.
    /// No `start`: the last `defaultDays` days, today included.
    static func range(start: String?, end: String?, defaultDays: Int, now: Date = .now,
                      calendar: Calendar = .current) -> Result<(DateInterval, String), Problem> {
        var from: Date
        var to = now
        var label: String
        if let start, !start.isEmpty {
            if let relative = relative(start, now: now, calendar: calendar) {
                (from, to, label) = (relative.interval.start, relative.interval.end, relative.label)
            } else if let date = isoDate(start, calendar: calendar) {
                from = date.start
                label = ""
            } else {
                return .failure(Problem(message: "Error: couldn't read start \"\(start)\". Use an ISO date like 2026-10-01 (or 2026-10-01T08:00), or a relative range like today, yesterday, last_night, last_7_days, last_4_weeks, last_3_months, this_week, last_month."))
            }
        } else {
            let relative = lastDays(defaultDays, now: now, calendar: calendar)
            (from, to, label) = (relative.interval.start, relative.interval.end, relative.label)
        }
        if let end, !end.isEmpty {
            if let relative = relative(end, now: now, calendar: calendar) {
                to = relative.interval.end
            } else if let date = isoDate(end, calendar: calendar) {
                to = date.isDateOnly ? date.end : date.start
            } else {
                return .failure(Problem(message: "Error: couldn't read end \"\(end)\". Use an ISO date like 2026-10-14, or leave it out for now."))
            }
            label = ""
        }
        to = min(to, now)
        guard from < to else {
            return .failure(Problem(message: "Error: the range is empty (start must be before end, and not in the future)."))
        }
        if let limit = calendar.date(byAdding: .day, value: -maxDays, to: to), from < limit {
            return .failure(Problem(message: "Error: the range is longer than 10 years. Ask for a shorter one."))
        }
        if label.isEmpty { label = "\(dayString(from, calendar: calendar)) to \(dayString(to.addingTimeInterval(-1), calendar: calendar))" }
        return .success((DateInterval(start: from, end: to), label))
    }

    struct Relative {
        var interval: DateInterval
        var label: String
    }

    /// A relative range: today, yesterday, last_night, this_/last_ week/month/year, last_N_days/weeks/months/years
    /// (also "past 7 days", "7d", "2w", "3m", "1y"). The last N days include today.
    static func relative(_ raw: String, now: Date, calendar: Calendar) -> Relative? {
        let key = normalized(raw)
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        func period(_ component: Calendar.Component, offset: Int) -> DateInterval? {
            guard let date = calendar.date(byAdding: component, value: offset, to: now),
                  let interval = calendar.dateInterval(of: component, for: date) else { return nil }
            return offset == 0 ? DateInterval(start: interval.start, end: now) : interval
        }
        switch key {
        case "today": return Relative(interval: DateInterval(start: today, end: now), label: "today")
        case "yesterday": return Relative(interval: DateInterval(start: day(-1), end: today), label: "yesterday")
        case "last_night", "tonight", "last_sleep":
            // 6 PM yesterday to 6 PM today: the night that ended this morning (`HealthCalendar.night`).
            let start = day(-1).addingTimeInterval(18 * 3600)
            return Relative(interval: DateInterval(start: start, end: min(now, today.addingTimeInterval(18 * 3600))), label: "last night")
        case "this_week": return period(.weekOfYear, offset: 0).map { Relative(interval: $0, label: "this week") }
        case "last_week", "previous_week": return period(.weekOfYear, offset: -1).map { Relative(interval: $0, label: "last week") }
        case "this_month": return period(.month, offset: 0).map { Relative(interval: $0, label: "this month") }
        case "last_month", "previous_month": return period(.month, offset: -1).map { Relative(interval: $0, label: "last month") }
        case "this_year": return period(.year, offset: 0).map { Relative(interval: $0, label: "this year") }
        case "last_year", "previous_year": return period(.year, offset: -1).map { Relative(interval: $0, label: "last year") }
        default: break
        }
        guard let (count, unit) = countAndUnit(key), count > 0, count <= maxDays else { return nil }
        switch unit {
        case "day": return lastDays(count, now: now, calendar: calendar)
        case "week":
            var r = lastDays(count * 7, now: now, calendar: calendar)
            r.label = count == 1 ? "last 7 days" : "last \(count) weeks"
            return r
        case "month", "year":
            let component: Calendar.Component = unit == "month" ? .month : .year
            guard let start = calendar.date(byAdding: component, value: -count, to: day(1)) else { return nil }
            return Relative(interval: DateInterval(start: start, end: now), label: count == 1 ? "last \(unit)" : "last \(count) \(unit)s")
        default: return nil
        }
    }

    static func lastDays(_ count: Int, now: Date, calendar: Calendar) -> Relative {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(count, 1) - 1), to: today)!
        return Relative(interval: DateInterval(start: start, end: now), label: count == 1 ? "today" : "last \(count) days")
    }

    /// "last_14_days" → (14, "day"); "past_2_weeks", "3_months", "7d", "1y" too.
    private static func countAndUnit(_ key: String) -> (Int, String)? {
        var rest = key
        for prefix in ["last_", "past_", "previous_"] where rest.hasPrefix(prefix) { rest.removeFirst(prefix.count) }
        let digits = rest.prefix { $0.isNumber }
        guard let count = Int(digits) else { return nil }
        var unit = String(rest.dropFirst(digits.count))
        if unit.hasPrefix("_") { unit.removeFirst() }
        switch unit {
        case "d", "day", "days": return (count, "day")
        case "w", "week", "weeks": return (count, "week")
        case "m", "mo", "month", "months": return (count, "month")
        case "y", "year", "years": return (count, "year")
        default: return nil
        }
    }

    struct ISODate {
        var start: Date
        /// The end of the day (or month) a date-only value names.
        var end: Date
        var isDateOnly: Bool
    }

    /// 2026-10-01 (that day, in the user's time zone), 2026-10 (that month), or a date-time like 2026-10-01T08:00,
    /// with or without seconds and a zone.
    static func isoDate(_ raw: String, calendar: Calendar) -> ISODate? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        if !text.contains("T"), !text.contains(" "), parts.count == 2 || parts.count == 3,
           let year = Int(parts[0]), let month = Int(parts[1]), parts[0].count == 4 {
            var c = DateComponents(year: year, month: month, day: 1)
            if parts.count == 3 { guard let day = Int(parts[2]) else { return nil }; c.day = day }
            guard let start = calendar.date(from: c),
                  calendar.component(.month, from: start) == month, calendar.component(.day, from: start) == c.day,
                  let end = calendar.date(byAdding: parts.count == 3 ? .day : .month, value: 1, to: start) else { return nil }
            return ISODate(start: start, end: end, isDateOnly: true)
        }
        let withZone = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            withZone.formatOptions = options
            if let date = withZone.date(from: text) { return ISODate(start: date, end: date, isDateOnly: false) }
        }
        let local = DateFormatter()
        local.calendar = calendar
        local.timeZone = calendar.timeZone
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return ISODate(start: date, end: date, isDateOnly: false) }
        }
        return nil
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Lowercased, with spaces and hyphens as underscores ("Last 7 days" → "last_7_days").
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    // MARK: The feed's line

    /// The feed's words for a call: "sleep, last 14 days", "steps, 2026-10-01 to 2026-10-14".
    static func summary(of arguments: String, now: Date = .now, calendar: Calendar = .current) -> String {
        let args = (arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let raw = args["metric"] as? String ?? args["mode"] as? String ?? ""
        if [listAvailable, "list"].contains(normalized(raw)) { return listAvailable }
        guard let metric = metric(raw) else { return raw }
        switch range(start: string(args["start"]), end: string(args["end"]), defaultDays: metric.defaultDays, now: now, calendar: calendar) {
        case .success(let (_, label)): return "\(metric.displayName), \(label)"
        case .failure: return metric.displayName
        }
    }
}
