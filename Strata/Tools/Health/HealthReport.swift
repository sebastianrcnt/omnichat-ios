import Foundation

/// Turns a `health_query` request into the compact text the model reads: a header line naming the data and its range,
/// a table (a row per day, night, week, month or workout), and a line of totals. Values are in the user's units;
/// dates are ISO with the weekday, times 24-hour, in the device's time zone. Capped (`maxRows`, `maxCharacters`).
struct HealthReport {
    let source: any HealthDataSource
    var calendar: Calendar = .current
    var now: Date = .now

    /// Every result with data starts with this, so debug bundles can mask it (`DebugRedaction`).
    static let marker = "Apple Health data"
    /// Rows before a table switches to the next longer period (daily → weekly → monthly).
    static let maxRows = 62
    static let maxCharacters = 6000
    /// Samples and workouts listed one by one.
    static let maxListed = 40

    enum Outcome: Equatable {
        case text(String)
        /// Nothing in the range: no data, or reading isn't allowed (HealthKit doesn't say which).
        case empty
    }

    func run(_ request: HealthRequest) async throws -> Outcome {
        guard let metric = request.metric else { return .text(try await listAvailable()) }
        let units = await source.units(for: [metric])
        let text: String? = switch metric.shape {
        case .cumulative: try await cumulative(metric, request, units)
        case .discrete: try await discrete(metric, request, units)
        case .sleep: try await sleep(request)
        case .standHours, .mindful, .menstrual: try await categoryDays(metric, request)
        case .workouts: try await workouts(request, units)
        }
        guard let text else { return .empty }
        return .text(Self.capped(text))
    }

    // MARK: Which summary

    /// What a call without `aggregation` gets: rows for a range short enough, else one figure. Height: the latest.
    static func defaultAggregation(_ metric: HealthMetric) -> HealthAggregation {
        metric == .height ? .latest : .daily
    }

    /// The period for rows: the one asked for, made longer while it would give more than `maxRows` rows.
    func rowBucket(_ aggregation: HealthAggregation, interval: DateInterval) -> (bucket: HealthBucket, note: String?) {
        var bucket: HealthBucket = switch aggregation { case .weekly: .week; case .monthly: .month; default: .day }
        var note: String?
        while HealthCalendar.periods(interval, bucket: bucket, calendar: calendar).count > Self.maxRows, bucket != .month {
            bucket = bucket == .day ? .week : .month
            note = "(Too many rows for that range: one row per \(bucket == .week ? "week" : "month") instead. Ask for a shorter range for more detail.)"
        }
        return (bucket, note)
    }

    private func header(_ metric: HealthMetric, _ request: HealthRequest, extra: String = "") -> String {
        let range = request.rangeLabel.contains(" to ") ? request.rangeLabel : "\(request.rangeLabel), \(span(request.interval))"
        return "\(Self.marker): \(metric.displayName), \(range)\(extra). Read-only, from the user's Health app."
    }

    private func span(_ interval: DateInterval) -> String {
        let first = HealthArguments.dayString(interval.start, calendar: calendar)
        let last = HealthArguments.dayString(interval.end.addingTimeInterval(-1), calendar: calendar)
        return first == last ? first : "\(first) to \(last)"
    }

    // MARK: Cumulative (steps, energy, water...)

    private func cumulative(_ metric: HealthMetric, _ request: HealthRequest, _ units: HealthUnits) async throws -> String? {
        let f = HealthFormat(metric: metric, units: units)
        let aggregation = request.aggregation ?? Self.defaultAggregation(metric)
        let days = try await source.statistics(metric, in: request.interval, bucket: .day, calendar: calendar)
        let withData = days.filter { $0.sum != nil }
        guard !withData.isEmpty else { return nil }
        let total = withData.compactMap(\.sum).reduce(0, +)
        let average = total / Double(withData.count)
        let highest = withData.max { ($0.sum ?? 0) < ($1.sum ?? 0) }!
        let lowest = withData.min { ($0.sum ?? 0) < ($1.sum ?? 0) }!
        let today = calendar.startOfDay(for: now)
        func soFar(_ s: HealthStat) -> String { s.start == today ? " (today so far)" : "" }
        let summary = "total \(f.number(total)) \(f.unit) · daily average \(f.number(average)) over \(withData.count) day\(withData.count == 1 ? "" : "s") with data"
            + " · highest \(day(highest.start)) (\(f.number(highest.sum!))) · lowest \(day(lowest.start)) (\(f.number(lowest.sum!)))"
        var lines = [header(metric, request)]
        switch aggregation {
        case .sum, .avg:
            lines.append(summary)
        case .min:
            lines.append("lowest day: \(day(lowest.start)), \(f.number(lowest.sum!)) \(f.unit)\(soFar(lowest))")
            lines.append(summary)
        case .max:
            lines.append("highest day: \(day(highest.start)), \(f.number(highest.sum!)) \(f.unit)\(soFar(highest))")
            lines.append(summary)
        case .latest:
            let last = withData.last!
            lines.append("latest day with data: \(day(last.start)), \(f.number(last.sum!)) \(f.unit)\(soFar(last))")
        case .daily, .weekly, .monthly:
            let (bucket, note) = rowBucket(aggregation, interval: request.interval)
            if bucket == .day {
                lines.append(Self.table([["date", f.unit]] + days.map { s in [day(s.start), s.sum.map { f.number($0) + soFar(s) } ?? "—"] }))
            } else {
                let periods = try await source.statistics(metric, in: request.interval, bucket: bucket, calendar: calendar)
                let name = bucket == .week ? "week of" : "month"
                lines.append(Self.table([[name, "total \(f.unit)", "daily avg", "days with data"]] + periods.map { p in
                    let inPeriod = withData.filter { $0.start >= p.start && $0.start < p.end }
                    let avg = inPeriod.isEmpty ? nil : inPeriod.compactMap(\.sum).reduce(0, +) / Double(inPeriod.count)
                    return [bucket == .week ? day(p.start) : month(p.start), p.sum.map(f.number) ?? "—", avg.map(f.number) ?? "—", "\(inPeriod.count)"]
                }))
            }
            if let note { lines.append(note) }
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Discrete (heart rate, weight, blood pressure...)

    private func discrete(_ metric: HealthMetric, _ request: HealthRequest, _ units: HealthUnits) async throws -> String? {
        let f = HealthFormat(metric: metric, units: units)
        let aggregation = request.aggregation ?? Self.defaultAggregation(metric)
        let bp = metric == .bloodPressure
        if aggregation == .latest {
            let samples = try await source.samples(metric, in: request.interval, limit: 10)
            guard !samples.isEmpty else { return nil }
            var lines = [header(metric, request, extra: ", latest \(samples.count) reading\(samples.count == 1 ? "" : "s")")]
            lines.append(Self.table([["when", f.unit]] + samples.map { [stamp($0.start), bp ? f.pair($0.value, $0.value2) : f.number($0.value)] }))
            return lines.joined(separator: "\n")
        }
        let whole = try await source.statistics(metric, in: request.interval, bucket: .whole, calendar: calendar).first
        guard let whole, whole.hasData else { return nil }
        let days = try await source.statistics(metric, in: request.interval, bucket: .day, calendar: calendar).filter(\.hasData)
        let lowest = days.min { ($0.min ?? .infinity) < ($1.min ?? .infinity) }
        let highest = days.max { ($0.max ?? -.infinity) < ($1.max ?? -.infinity) }
        var summary: String
        if bp {
            summary = "average \(f.pair(whole.average, whole.average2)) \(f.unit) · systolic \(f.number(whole.min))–\(f.number(whole.max))"
                + " · diastolic \(f.number(whole.min2))–\(f.number(whole.max2))"
        } else {
            summary = "average \(f.number(whole.average)) \(f.unit) · lowest \(f.number(whole.min))"
                + (lowest.map { " (\(day($0.start)))" } ?? "") + " · highest \(f.number(whole.max))" + (highest.map { " (\(day($0.start)))" } ?? "")
        }
        summary += " · \(days.count) day\(days.count == 1 ? "" : "s") with data"
        var lines = [header(metric, request)]
        switch aggregation {
        case .sum, .avg, .min, .max, .latest:
            if aggregation == .sum { lines.append("(\(metric.displayName) is a measurement, not an amount: showing its average.)") }
            lines.append(summary)
        case .daily, .weekly, .monthly:
            // Measurements list only the days that have one, so a long range with few readings keeps daily rows.
            let (bucket, note) = aggregation == .daily && days.count <= Self.maxRows ? (HealthBucket.day, nil)
                : rowBucket(aggregation, interval: request.interval)
            let rows = bucket == .day ? days
                : try await source.statistics(metric, in: request.interval, bucket: bucket, calendar: calendar).filter(\.hasData)
            let first = bucket == .day ? "date" : bucket == .week ? "week of" : "month"
            func label(_ s: HealthStat) -> String { bucket == .month ? month(s.start) : day(s.start) }
            if bp {
                lines.append(Self.table([[first, "avg \(f.unit)", "systolic range", "diastolic range"]] + rows.map { s in
                    [label(s), f.pair(s.average, s.average2), "\(f.number(s.min))–\(f.number(s.max))", "\(f.number(s.min2))–\(f.number(s.max2))"]
                }))
            } else {
                lines.append(Self.table([[first, "avg \(f.unit)", "min", "max"]] + rows.map { s in
                    [label(s), f.number(s.average), f.number(s.min), f.number(s.max)]
                }))
            }
            if let note { lines.append(note) }
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Sleep

    private func sleep(_ request: HealthRequest) async throws -> String? {
        let firstNight = HealthCalendar.night(of: request.interval.start, calendar: calendar)
        let lastNight = HealthCalendar.night(of: request.interval.end.addingTimeInterval(-1), calendar: calendar)
        // Samples from 6 PM before the first night to 6 PM of the last day.
        let query = DateInterval(start: firstNight.addingTimeInterval(-6 * 3600),
                                 end: max(calendar.date(byAdding: .day, value: 1, to: lastNight)!.addingTimeInterval(-6 * 3600), request.interval.end))
        let samples = try await source.samples(.sleep, in: query, limit: 50_000)
        let nights = HealthSleep.nights(samples, calendar: calendar).filter { $0.night >= firstNight && $0.night <= lastNight }
        guard !nights.isEmpty else { return nil }
        let aggregation = request.aggregation ?? .daily
        var lines = [header(.sleep, request, extra: " (each night is dated by the morning it ended)")]
        let asleepNights = nights.filter { $0.asleep > 0 }
        let summaryBase = asleepNights.isEmpty ? nights : asleepNights
        let avgAsleep = asleepNights.isEmpty ? 0 : asleepNights.map(\.asleep).reduce(0, +) / Double(asleepNights.count)
        var summary = "average asleep \(Self.duration(avgAsleep)) over \(asleepNights.count) night\(asleepNights.count == 1 ? "" : "s")"
        if let short = asleepNights.min(by: { $0.asleep < $1.asleep }), let long = asleepNights.max(by: { $0.asleep < $1.asleep }), asleepNights.count > 1 {
            summary += " · shortest \(day(short.night)) (\(Self.duration(short.asleep))) · longest \(day(long.night)) (\(Self.duration(long.asleep)))"
        }
        let staged = asleepNights.filter(\.hasStages)
        if !staged.isEmpty {
            func avg(_ key: KeyPath<HealthSleep.Night, TimeInterval>) -> String {
                Self.duration(staged.map { $0[keyPath: key] }.reduce(0, +) / Double(staged.count))
            }
            summary += " · average stages: core \(avg(\.core)), deep \(avg(\.deep)), REM \(avg(\.rem)), awake \(avg(\.awake))"
        }
        if summaryBase.isEmpty { return nil }
        switch aggregation {
        case .latest:
            lines.append(sleepTable([nights.last!]))
        case .sum, .avg, .min, .max:
            if aggregation == .min, let n = asleepNights.min(by: { $0.asleep < $1.asleep }) { lines.append("shortest night: " + day(n.night)) }
            if aggregation == .max, let n = asleepNights.max(by: { $0.asleep < $1.asleep }) { lines.append("longest night: " + day(n.night)) }
            lines.append(summary)
        case .daily, .weekly, .monthly:
            let (bucket, note) = rowBucket(aggregation, interval: DateInterval(start: firstNight, end: calendar.date(byAdding: .day, value: 1, to: lastNight)!))
            if bucket == .day {
                lines.append(sleepTable(nights))
            } else {
                let periods = HealthCalendar.periods(DateInterval(start: firstNight, end: calendar.date(byAdding: .day, value: 1, to: lastNight)!),
                                                     bucket: bucket, calendar: calendar)
                lines.append(Self.table([[bucket == .week ? "week of" : "month", "nights", "avg asleep", "avg in bed", "avg deep", "avg REM"]] + periods.compactMap { p in
                    let inPeriod = nights.filter { p.contains($0.night) && $0.asleep > 0 }
                    guard !inPeriod.isEmpty else { return nil }
                    func avg(_ values: [TimeInterval]) -> String { values.isEmpty ? "—" : Self.duration(values.reduce(0, +) / Double(values.count)) }
                    let stagedNights = inPeriod.filter(\.hasStages)
                    return [bucket == .week ? day(p.start) : month(p.start), "\(inPeriod.count)", avg(inPeriod.map(\.asleep)),
                            avg(inPeriod.filter { $0.inBed > 0 }.map(\.inBed)), avg(stagedNights.map(\.deep)), avg(stagedNights.map(\.rem))]
                }))
            }
            if let note { lines.append(note) }
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }

    private func sleepTable(_ nights: [HealthSleep.Night]) -> String {
        let f = DateFormatter.healthTime
        f.timeZone = calendar.timeZone
        return Self.table([["night", "bed", "wake", "asleep", "core", "deep", "REM", "awake", "in bed"]] + nights.map { n in
            func stage(_ v: TimeInterval) -> String { n.hasStages ? Self.duration(v) : "—" }
            return [day(n.night), n.bedtime.map(f.string(from:)) ?? "—", n.wake.map(f.string(from:)) ?? "—",
                    n.asleep > 0 ? Self.duration(n.asleep) : "—", stage(n.core), stage(n.deep), stage(n.rem), stage(n.awake),
                    n.inBed > 0 ? Self.duration(n.inBed) : "—"]
        })
    }

    // MARK: Stand hours, mindful minutes, menstrual flow

    private func categoryDays(_ metric: HealthMetric, _ request: HealthRequest) async throws -> String? {
        let samples = try await source.samples(metric, in: request.interval, limit: 50_000)
        guard !samples.isEmpty else { return nil }
        var lines = [header(metric, request)]
        let aggregation = request.aggregation ?? .daily
        switch metric {
        case .menstrualFlow:
            // The heaviest flow logged each day; "none" days only when nothing else was logged that day.
            var byDay: [Date: Int] = [:]
            for s in samples {
                let day = calendar.startOfDay(for: s.start)
                let level = Int(s.value)
                let rank = { (v: Int) in v == 5 ? 0 : v == 1 ? 1 : v }
                if let old = byDay[day], rank(old) >= rank(level) { continue }
                byDay[day] = level
            }
            let days = byDay.keys.sorted()
            let flowDays = days.filter { byDay[$0] != 5 }
            lines.append(Self.table([["date", "flow"]] + days.suffix(Self.maxRows).map { [day($0), HealthCategory.flowName(byDay[$0]!)] }))
            // A period starts on a flow day after at least two days without one.
            var starts: [Date] = []
            var previous: Date?
            for d in flowDays {
                if let previous, (calendar.dateComponents([.day], from: previous, to: d).day ?? 0) <= 2 {} else { starts.append(d) }
                previous = d
            }
            lines.append("\(flowDays.count) day\(flowDays.count == 1 ? "" : "s") with flow" + (starts.isEmpty ? "" : " · periods started " + starts.map(day).joined(separator: ", ")))
        case .standHours, .mindfulMinutes:
            var perDay: [Date: Double] = [:]
            if metric == .standHours {
                // One count per clock hour, whichever source logged it.
                var hours = Set<Date>()
                for s in samples where Int(s.value) == HealthCategory.stood {
                    hours.insert(calendar.dateInterval(of: .hour, for: s.start)?.start ?? s.start)
                }
                for h in hours { perDay[calendar.startOfDay(for: h), default: 0] += 1 }
            } else {
                for (day, set) in Dictionary(grouping: samples, by: { calendar.startOfDay(for: $0.start) }) {
                    perDay[day] = HealthIntervals(set.map { DateInterval(start: $0.start, end: max($0.end, $0.start)) }).length / 60
                }
            }
            let unit = metric == .standHours ? "hours stood" : "minutes"
            let days = HealthCalendar.periods(request.interval, bucket: .day, calendar: calendar)
            let total = perDay.values.reduce(0, +)
            let summary = "total \(Int(total.rounded())) \(unit) · daily average \(String(format: "%.1f", total / Double(max(perDay.count, 1)))) over \(perDay.count) day\(perDay.count == 1 ? "" : "s") with data"
            if aggregation.isRows {
                let (bucket, note) = rowBucket(aggregation, interval: request.interval)
                if bucket == .day {
                    lines.append(Self.table([["date", unit]] + days.map { d in [day(d.start), perDay[d.start].map { "\(Int($0.rounded()))" } ?? "—"] }))
                } else {
                    let periods = HealthCalendar.periods(request.interval, bucket: bucket, calendar: calendar)
                    lines.append(Self.table([[bucket == .week ? "week of" : "month", "total \(unit)", "days with data"]] + periods.map { p in
                        let inPeriod = perDay.filter { p.contains($0.key) && $0.key < p.end }
                        return [bucket == .week ? day(p.start) : month(p.start), "\(Int(inPeriod.values.reduce(0, +).rounded()))", "\(inPeriod.count)"]
                    }))
                }
                if let note { lines.append(note) }
            }
            lines.append(summary)
        default:
            return nil
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Workouts

    private func workouts(_ request: HealthRequest, _ units: HealthUnits) async throws -> String? {
        let all = try await source.workouts(in: request.interval, limit: 2000)
        guard !all.isEmpty else { return nil }
        let energy = HealthFormat(metric: .activeEnergy, units: units)
        let distance = HealthFormat(metric: .distance, units: units)
        let listed = all.prefix(Self.maxListed)
        var lines = [header(.workouts, request, extra: ", \(all.count) workout\(all.count == 1 ? "" : "s")")]
        let aggregation = request.aggregation ?? .daily
        if aggregation == .weekly || aggregation == .monthly {
            let bucket: HealthBucket = aggregation == .weekly ? .week : .month
            let periods = HealthCalendar.periods(request.interval, bucket: bucket, calendar: calendar)
            lines.append(Self.table([[bucket == .week ? "week of" : "month", "workouts", "time", energy.unit]] + periods.map { p in
                let inPeriod = all.filter { p.contains($0.start) && $0.start < p.end }
                return [bucket == .week ? day(p.start) : month(p.start), "\(inPeriod.count)", Self.duration(inPeriod.map(\.duration).reduce(0, +)),
                        energy.number(inPeriod.compactMap(\.energy).reduce(0, +))]
            }))
        } else if aggregation != .sum && aggregation != .avg {
            let rows = aggregation == .latest ? Array(listed.prefix(1)) : Array(listed)
            lines.append(Self.table([["when", "type", "duration", energy.unit, distance.unit, "avg HR", "max HR"]] + rows.map { w in
                [stamp(w.start), w.activity, Self.duration(w.duration), w.energy.map(energy.number) ?? "—", w.distance.map(distance.number) ?? "—",
                 w.averageHeartRate.map { "\(Int($0.rounded()))" } ?? "—", w.maxHeartRate.map { "\(Int($0.rounded()))" } ?? "—"]
            }))
            if all.count > rows.count, aggregation != .latest {
                lines.append("(\(all.count - rows.count) older workouts not listed; ask for a shorter range, or aggregation weekly.)")
            }
        }
        let byType = Dictionary(grouping: all, by: \.activity).map { ($0.key, $0.value.count) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        let totalTime = all.map(\.duration).reduce(0, +)
        lines.append("\(all.count) workouts · total \(Self.duration(totalTime)) · average \(Self.duration(totalTime / Double(all.count)))"
                     + " · \(energy.number(all.compactMap(\.energy).reduce(0, +))) \(energy.unit) · by type: "
                     + byType.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    // MARK: list_available

    private func listAvailable() async throws -> String {
        let interval = DateInterval(start: calendar.date(byAdding: .year, value: -2, to: now)!, end: now)
        var rows: [[String]] = [["metric", "status"]]
        for metric in HealthMetric.allCases {
            let status: String
            if await source.needsAuthorization(for: [metric]) {
                status = "not asked yet (the first query asks the user)"
            } else if let latest = try await latestDate(metric, in: interval) {
                status = "has data, latest \(HealthArguments.dayString(latest, calendar: calendar))"
            } else {
                status = "no data or not allowed"
            }
            rows.append([metric.rawValue, status])
        }
        return "\(Self.marker) types (read-only). iOS doesn't tell apps whether the user denied reading a type, so \"no data or not allowed\" can mean either; the user can change it in the Settings app > Health > Data Access & Devices > OpenChat.\n"
            + Self.table(rows)
    }

    private func latestDate(_ metric: HealthMetric, in interval: DateInterval) async throws -> Date? {
        if metric == .workouts { return try await source.workouts(in: interval, limit: 1).first?.start }
        return try await source.samples(metric, in: interval, limit: 1).first?.start
    }

    // MARK: Formatting

    private func day(_ date: Date) -> String { Self.dayString(date, calendar: calendar) }

    private func month(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    private func stamp(_ date: Date) -> String {
        let f = DateFormatter.healthTime
        f.timeZone = calendar.timeZone
        return day(date) + " " + f.string(from: date)
    }

    /// "2026-10-15 Wed".
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let weekday = calendar.component(.weekday, from: date)
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return HealthArguments.dayString(date, calendar: calendar) + " " + names[(weekday - 1) % 7]
    }

    /// "7h 03m", "32m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? String(format: "%dh %02dm", minutes / 60, minutes % 60) : "\(minutes)m"
    }

    /// Columns padded with two spaces, the first left-aligned, the others too (numbers read fine either way).
    static func table(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "" }
        var widths = Array(repeating: 0, count: first.count)
        for row in rows { for (i, cell) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], cell.count) } }
        return rows.map { row in
            row.enumerated().map { i, cell in
                i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    /// At most `maxCharacters`, cut at a line, with a note saying so.
    static func capped(_ text: String, limit: Int = maxCharacters) -> String {
        guard text.count > limit else { return text }
        var kept = String(text.prefix(limit))
        if let newline = kept.lastIndex(of: "\n") { kept = String(kept[..<newline]) }
        let dropped = text.dropFirst(kept.count).split(separator: "\n").count
        return kept + "\n[cut: \(dropped) more lines. Ask for a shorter range, or weekly or monthly rows.]"
    }
}

extension DateFormatter {
    /// "23:41" (callers set the calendar's time zone).
    fileprivate static var healthTime: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }
}

/// Values in the user's units, and the unit's short name.
struct HealthFormat {
    let metric: HealthMetric
    let units: HealthUnits

    var unit: String {
        switch metric {
        case .steps: "steps"
        case .distance: units.distance == .mi ? "mi" : "km"
        case .activeEnergy, .restingEnergy: units.energy == .kJ ? "kJ" : "kcal"
        case .exerciseMinutes, .mindfulMinutes: "min"
        case .standHours: "hours"
        case .heartRate, .restingHeartRate: "bpm"
        case .hrv: "ms"
        case .respiratoryRate: "breaths/min"
        case .bloodOxygen, .bodyFat: "%"
        case .weight: switch units.mass { case .kg: "kg"; case .lb: "lb"; case .st: "st" }
        case .bmi: "BMI"
        case .height: units.height == .ftIn ? "ft/in" : "cm"
        case .vo2max: "mL/kg/min"
        case .water: units.water == .flOz ? "fl oz" : "mL"
        case .caffeine: "mg"
        case .bloodPressure: "mmHg"
        case .bloodGlucose: units.glucose == .mmolL ? "mmol/L" : "mg/dL"
        case .sleep, .workouts, .menstrualFlow: ""
        }
    }

    /// A canonical value (`HealthUnits`) in the shown unit, without the unit; "—" for nil.
    func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        switch metric {
        case .distance: return fixed(units.distance == .mi ? value / 1609.344 : value / 1000, 2)
        case .activeEnergy, .restingEnergy: return fixed(units.energy == .kJ ? value * 4.184 : value, 0)
        case .weight:
            switch units.mass {
            case .kg: return fixed(value, 1)
            case .lb: return fixed(value * 2.204_622_6, 1)
            case .st:
                let pounds = value * 2.204_622_6
                return "\(Int(pounds / 14)) st \(fixed(pounds.truncatingRemainder(dividingBy: 14), 0)) lb"
            }
        case .height:
            guard units.height == .ftIn else { return fixed(value * 100, 0) }
            let inches = Int((value / 0.0254).rounded())
            return "\(inches / 12) ft \(inches % 12) in"
        case .bloodOxygen, .bodyFat: return fixed(value * 100, 1)
        case .water: return fixed(units.water == .flOz ? value / 29.573_53 : value, units.water == .flOz ? 1 : 0)
        case .bloodGlucose: return units.glucose == .mmolL ? fixed(value / 18.0156, 1) : fixed(value, 0)
        case .respiratoryRate, .bmi, .vo2max: return fixed(value, 1)
        default: return fixed(value, 0)
        }
    }

    /// Blood pressure: "118/76".
    func pair(_ systolic: Double?, _ diastolic: Double?) -> String { "\(number(systolic))/\(number(diastolic))" }

    private func fixed(_ value: Double, _ digits: Int) -> String {
        let s = String(format: "%.\(digits)f", value)
        return s == "-0" ? "0" : s
    }
}

/// Sleep samples summed per night (`HealthCalendar.night`). Sources overlap (a watch and a phone app both log the same
/// night), so each stage is the union of its intervals rather than a sum, and awake time inside an asleep interval of
/// another source doesn't count.
enum HealthSleep {
    struct Night: Equatable, Sendable {
        var night: Date
        var asleep: TimeInterval = 0
        var core: TimeInterval = 0
        var deep: TimeInterval = 0
        var rem: TimeInterval = 0
        var awake: TimeInterval = 0
        var inBed: TimeInterval = 0
        var bedtime: Date?
        var wake: Date?

        /// Core, deep or REM was logged (an Apple Watch), not only "asleep".
        var hasStages: Bool { core + deep + rem > 0 }
    }

    static func nights(_ samples: [HealthSample], calendar: Calendar) -> [Night] {
        let grouped = Dictionary(grouping: samples.filter { $0.end > $0.start }, by: { HealthCalendar.night(of: $0.start, calendar: calendar) })
        return grouped.keys.sorted().map { key in
            let list = grouped[key]!
            func intervals(_ kinds: Set<HealthCategory.Sleep>) -> HealthIntervals {
                HealthIntervals(list.filter { HealthCategory.Sleep(rawValue: Int($0.value)).map(kinds.contains) ?? false }
                    .map { DateInterval(start: $0.start, end: $0.end) })
            }
            let asleep = intervals([.asleepUnspecified, .core, .deep, .rem])
            let inBed = intervals([.inBed])
            var night = Night(night: key)
            night.asleep = asleep.length
            night.core = intervals([.core]).length
            night.deep = intervals([.deep]).length
            night.rem = intervals([.rem]).length
            night.awake = intervals([.awake]).subtracting(asleep).length
            night.inBed = inBed.length
            night.bedtime = (inBed.intervals + asleep.intervals).map(\.start).min()
            night.wake = (asleep.intervals.isEmpty ? inBed.intervals : asleep.intervals).map(\.end).max()
            return night
        }
    }
}

/// A set of time intervals, merged where they overlap or touch.
struct HealthIntervals: Equatable, Sendable {
    private(set) var intervals: [DateInterval] = []

    init(_ list: [DateInterval]) {
        for interval in list.sorted(by: { $0.start < $1.start }) {
            if let last = intervals.last, interval.start <= last.end {
                intervals[intervals.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                intervals.append(interval)
            }
        }
    }

    var length: TimeInterval { intervals.reduce(0) { $0 + $1.duration } }

    /// What is left of these intervals outside `other`.
    func subtracting(_ other: HealthIntervals) -> HealthIntervals {
        var out: [DateInterval] = []
        for interval in intervals {
            var pieces = [interval]
            for cut in other.intervals {
                pieces = pieces.flatMap { piece -> [DateInterval] in
                    guard cut.start < piece.end, cut.end > piece.start else { return [piece] }
                    var left: [DateInterval] = []
                    if cut.start > piece.start { left.append(DateInterval(start: piece.start, end: cut.start)) }
                    if cut.end < piece.end { left.append(DateInterval(start: cut.end, end: piece.end)) }
                    return left
                }
            }
            out += pieces
        }
        return HealthIntervals(out)
    }
}
