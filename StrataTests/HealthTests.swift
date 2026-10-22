import Testing
import Foundation
import SwiftData
@testable import Strata

/// A Health store in memory: raw samples per metric, summed up the way HealthKit's statistics queries do.
final class FakeHealthStore: HealthDataSource, @unchecked Sendable {
    var available = true
    var units = HealthUnits.metric
    var quantities: [HealthMetric: [HealthSample]] = [:]
    var categories: [HealthMetric: [HealthSample]] = [:]
    var workoutList: [HealthWorkout] = []
    /// Metrics never asked for (the system sheet would show).
    var unasked: Set<HealthMetric> = []
    private(set) var requested: [[HealthMetric]] = []

    var isAvailable: Bool { available }
    func needsAuthorization(for metrics: [HealthMetric]) async -> Bool { metrics.contains(where: unasked.contains) }
    func requestAuthorization(for metrics: [HealthMetric]) async throws {
        requested.append(metrics)
        unasked.subtract(metrics)
    }
    func units(for metrics: [HealthMetric]) async -> HealthUnits { units }

    func statistics(_ metric: HealthMetric, in interval: DateInterval, bucket: HealthBucket, calendar: Calendar) async throws -> [HealthStat] {
        let samples = (quantities[metric] ?? []).filter { $0.start >= interval.start && $0.start < interval.end }
        return HealthCalendar.periods(interval, bucket: bucket, calendar: calendar).map { period in
            let inside = samples.filter { $0.start >= period.start && $0.start < period.end }
            var stat = HealthStat(start: period.start, end: period.end)
            guard !inside.isEmpty else { return stat }
            if metric.shape == .cumulative {
                stat.sum = inside.map(\.value).reduce(0, +)
            } else {
                stat.average = inside.map(\.value).reduce(0, +) / Double(inside.count)
                stat.min = inside.map(\.value).min()
                stat.max = inside.map(\.value).max()
                let second = inside.compactMap(\.value2)
                if !second.isEmpty {
                    stat.average2 = second.reduce(0, +) / Double(second.count)
                    stat.min2 = second.min()
                    stat.max2 = second.max()
                }
            }
            return stat
        }
    }

    func samples(_ metric: HealthMetric, in interval: DateInterval, limit: Int) async throws -> [HealthSample] {
        let list = categories[metric] ?? quantities[metric] ?? []
        return Array(list.filter { $0.end > interval.start && $0.start < interval.end }.sorted { $0.start > $1.start }.prefix(limit))
    }

    func workouts(in interval: DateInterval, limit: Int) async throws -> [HealthWorkout] {
        Array(workoutList.filter { interval.contains($0.start) && $0.start < interval.end }.sorted { $0.start > $1.start }.prefix(limit))
    }
}

/// Seoul time, weeks from Sunday; "now" is Thursday 2026-10-22 14:00.
private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Seoul")!
    c.firstWeekday = 1
    return c
}()
private let now = date(2026, 10, 22, 14)

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func parse(_ json: String) -> Result<HealthRequest, HealthArguments.Problem> {
    HealthArguments.parse(json, now: now, calendar: calendar)
}

private func report(_ store: FakeHealthStore, _ json: String) async throws -> String {
    let request = try parse(json).get()
    switch try await HealthReport(source: store, calendar: calendar, now: now).run(request) {
    case .text(let text): return text
    case .empty: return "<empty>"
    }
}

struct HealthArgumentTests {
    @Test func metricsAndAliases() throws {
        #expect(try parse(#"{"metric":"sleep"}"#).get().metric == .sleep)
        #expect(try parse(#"{"metric":"Heart Rate"}"#).get().metric == .heartRate)
        #expect(try parse(#"{"metric":"spo2"}"#).get().metric == .bloodOxygen)
        #expect(try parse(#"{"metric":"resting-heart-rate"}"#).get().metric == .restingHeartRate)
        #expect(try parse(#"{"metric":"list_available"}"#).get().mode == .listAvailable)
        guard case .failure(let problem) = parse(#"{"metric":"mood"}"#) else { Issue.record("mood parsed"); return }
        #expect(problem.message.hasPrefix("Error: unknown metric \"mood\"") && problem.message.contains("blood_glucose"))
        guard case .failure(let missing) = parse("{}") else { Issue.record("no metric parsed"); return }
        #expect(missing.message.hasPrefix("Error: missing \"metric\""))
    }

    @Test func aggregations() throws {
        #expect(try parse(#"{"metric":"steps","aggregation":"average"}"#).get().aggregation == .avg)
        #expect(try parse(#"{"metric":"steps","aggregation":"per week"}"#).get().aggregation == .weekly)
        #expect(try parse(#"{"metric":"steps"}"#).get().aggregation == nil)
        guard case .failure(let problem) = parse(#"{"metric":"steps","aggregation":"median"}"#) else { Issue.record("median parsed"); return }
        #expect(problem.message.contains("unknown aggregation"))
    }

    @Test func relativeRangesIncludeToday() throws {
        let week = try parse(#"{"metric":"steps","start":"last_7_days"}"#).get()
        #expect(week.interval == DateInterval(start: date(2026, 10, 16), end: now))
        #expect(week.rangeLabel == "last 7 days")
        #expect(try parse(#"{"metric":"steps","start":"7d"}"#).get().interval == week.interval)
        #expect(try parse(#"{"metric":"steps","start":"past 7 days"}"#).get().interval == week.interval)
        #expect(try parse(#"{"metric":"steps","start":"last_2_weeks"}"#).get().interval.start == date(2026, 10, 9))
        #expect(try parse(#"{"metric":"steps","start":"last_3_months"}"#).get().interval.start == date(2026, 7, 23))
        #expect(try parse(#"{"metric":"steps","start":"yesterday"}"#).get().interval == DateInterval(start: date(2026, 10, 21), end: date(2026, 10, 22)))
        #expect(try parse(#"{"metric":"steps","start":"today"}"#).get().interval == DateInterval(start: date(2026, 10, 22), end: now))
        #expect(try parse(#"{"metric":"steps","start":"this_week"}"#).get().interval.start == date(2026, 10, 18), "weeks start on Sunday here")
        #expect(try parse(#"{"metric":"steps","start":"last_week"}"#).get().interval == DateInterval(start: date(2026, 10, 11), end: date(2026, 10, 18)))
        #expect(try parse(#"{"metric":"steps","start":"last_month"}"#).get().interval == DateInterval(start: date(2026, 9, 1), end: date(2026, 10, 1)))
        #expect(try parse(#"{"metric":"sleep","start":"last_night"}"#).get().interval == DateInterval(start: date(2026, 10, 21, 18), end: now))
    }

    @Test func defaultRangesFollowTheMetric() throws {
        #expect(try parse(#"{"metric":"steps"}"#).get().interval.start == date(2026, 10, 16))
        #expect(try parse(#"{"metric":"weight"}"#).get().rangeLabel == "last 90 days")
        #expect(try parse(#"{"metric":"workouts"}"#).get().rangeLabel == "last 30 days")
    }

    @Test func isoDatesIncludeTheEndDay() throws {
        let r = try parse(#"{"metric":"steps","start":"2026-10-01","end":"2026-10-14"}"#).get()
        #expect(r.interval == DateInterval(start: date(2026, 10, 1), end: date(2026, 10, 15)))
        #expect(r.rangeLabel == "2026-10-01 to 2026-10-14")
        let t = try parse(#"{"metric":"heart_rate","start":"2026-10-20T08:00","end":"2026-10-20T09:30"}"#).get()
        #expect(t.interval == DateInterval(start: date(2026, 10, 20, 8), end: date(2026, 10, 20, 9, 30)))
        #expect(try parse(#"{"metric":"steps","start":"2026-10"}"#).get().interval == DateInterval(start: date(2026, 10, 1), end: now),
                "a month, clipped to now")
        #expect(try parse(#"{"metric":"steps","start":"2026-10-20","end":"2030-01-01"}"#).get().interval.end == now)
    }

    @Test func badRangesSaySo() {
        guard case .failure(let bad) = parse(#"{"metric":"steps","start":"last fortnight"}"#) else { Issue.record(); return }
        #expect(bad.message.contains("couldn't read start") && bad.message.contains("last_7_days"))
        guard case .failure(let backwards) = parse(#"{"metric":"steps","start":"2026-10-10","end":"2026-10-01"}"#) else { Issue.record(); return }
        #expect(backwards.message.contains("range is empty"))
        guard case .failure(let future) = parse(#"{"metric":"steps","start":"2027-01-01"}"#) else { Issue.record(); return }
        #expect(future.message.contains("range is empty"))
        guard case .failure(let long) = parse(#"{"metric":"steps","start":"2000-01-01"}"#) else { Issue.record(); return }
        #expect(long.message.contains("10 years"))
        #expect(HealthArguments.isoDate("2026-02-30", calendar: calendar) == nil)
    }

    @Test func theFeedLineNamesMetricAndRange() {
        #expect(HealthArguments.summary(of: #"{"metric":"sleep","start":"last_14_days"}"#, now: now, calendar: calendar) == "sleep, last 14 days")
        #expect(HealthArguments.summary(of: #"{"metric":"steps","start":"2026-10-01","end":"2026-10-07"}"#, now: now, calendar: calendar)
                == "steps, 2026-10-01 to 2026-10-07")
        #expect(HealthArguments.summary(of: #"{"metric":"list_available"}"#) == "list_available")
        #expect(HealthCallLabel.title(summary: "sleep, last 14 days", running: false, failed: false) == "Read sleep, last 14 days")
        #expect(HealthCallLabel.title(summary: "sleep, last 14 days", running: true, failed: false) == "Reading sleep, last 14 days…")
        #expect(HealthCallLabel.title(summary: "sleep", running: false, failed: false, empty: true) == "No data for sleep")
        #expect(ToolCallRecord(id: "c", name: ToolNames.healthQuery, arguments: #"{"metric":"hrv"}"#, result: "", isError: false)
            .primaryArgument.hasPrefix("heart rate variability (SDNN), last 7 days"))
    }
}

struct HealthReportTests {
    private func steps(_ store: FakeHealthStore) {
        // 1000 steps a day times the day of the month, logged by two sources in halves; none on Oct 18.
        var list: [HealthSample] = []
        for day in 9...22 where day != 18 {
            let start = date(2026, 10, day, 9)
            list.append(HealthSample(start: start, end: start.addingTimeInterval(3600), value: Double(day * 500)))
            list.append(HealthSample(start: start.addingTimeInterval(7200), end: start.addingTimeInterval(9000), value: Double(day * 500)))
        }
        store.quantities[.steps] = list
    }

    @Test func dailyRowsAndTotals() async throws {
        let store = FakeHealthStore()
        steps(store)
        let text = try await report(store, #"{"metric":"steps","start":"last_7_days"}"#)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "Apple Health data: steps, last 7 days, 2026-10-16 to 2026-10-22. Read-only, from the user's Health app.")
        #expect(lines[1] == "date            steps")
        #expect(lines[2] == "2026-10-16 Fri  16000")
        #expect(lines[4] == "2026-10-18 Sun  —", "a day without data isn't a zero")
        #expect(lines[8] == "2026-10-22 Thu  22000 (today so far)")
        #expect(lines[9] == "total 115000 steps · daily average 19167 over 6 days with data · highest 2026-10-22 Thu (22000) · lowest 2026-10-16 Fri (16000)")
    }

    @Test func weeklyAndOneFigure() async throws {
        let store = FakeHealthStore()
        steps(store)
        let weekly = try await report(store, #"{"metric":"steps","start":"last_14_days","aggregation":"weekly"}"#)
        #expect(weekly.contains("week of         total steps  daily avg  days with data"))
        #expect(weekly.contains("2026-10-04 Sun  19000        9500       2"))
        #expect(weekly.contains("2026-10-11 Sun  98000        14000      7"))
        #expect(weekly.contains("2026-10-18 Sun  82000        20500      4"))
        let sum = try await report(store, #"{"metric":"steps","start":"last_7_days","aggregation":"sum"}"#)
        #expect(sum.split(separator: "\n").count == 2 && sum.contains("total 115000 steps"))
        let max = try await report(store, #"{"metric":"steps","start":"last_7_days","aggregation":"max"}"#)
        #expect(max.contains("highest day: 2026-10-22 Thu, 22000 steps (today so far)"))
    }

    @Test func longRangesSwitchToLongerRows() async throws {
        let store = FakeHealthStore()
        steps(store)
        let text = try await report(store, #"{"metric":"steps","start":"last_6_months"}"#)
        #expect(text.contains("week of") && text.contains("one row per week instead"))
        let year = try await report(store, #"{"metric":"steps","start":"last_2_years"}"#)
        #expect(year.contains("month  ") && year.contains("2026-10  "))
    }

    @Test func measurementsShowAverageLowHigh() async throws {
        let store = FakeHealthStore()
        store.quantities[.heartRate] = [
            HealthSample(start: date(2026, 10, 21, 8), end: date(2026, 10, 21, 8), value: 60),
            HealthSample(start: date(2026, 10, 21, 12), end: date(2026, 10, 21, 12), value: 100),
            HealthSample(start: date(2026, 10, 22, 9), end: date(2026, 10, 22, 9), value: 72),
        ]
        let text = try await report(store, #"{"metric":"heart_rate","start":"last_7_days"}"#)
        #expect(text.contains("date            avg bpm  min  max\n2026-10-21 Wed  80       60   100\n2026-10-22 Thu  72       72   72"))
        #expect(text.hasSuffix("average 77 bpm · lowest 60 (2026-10-21 Wed) · highest 100 (2026-10-21 Wed) · 2 days with data"))
        let latest = try await report(store, #"{"metric":"heart_rate","start":"last_7_days","aggregation":"latest"}"#)
        #expect(latest.contains("latest 3 readings") && latest.contains("2026-10-22 Thu 09:00  72"))
        let summed = try await report(store, #"{"metric":"heart_rate","aggregation":"sum"}"#)
        #expect(summed.contains("is a measurement, not an amount"))
    }

    @Test func occasionalMeasurementsKeepDailyRowsOverLongRanges() async throws {
        let store = FakeHealthStore()
        store.quantities[.weight] = [10, 40, 80].map { HealthSample(start: now.addingTimeInterval(-Double($0) * 86_400), end: now, value: 72) }
        let text = try await report(store, #"{"metric":"weight"}"#)
        #expect(text.contains("date            avg kg") && !text.contains("week of"))
    }

    @Test func bloodPressurePairsItsValues() async throws {
        let store = FakeHealthStore()
        store.quantities[.bloodPressure] = [
            HealthSample(start: date(2026, 10, 20, 9), end: date(2026, 10, 20, 9), value: 120, value2: 80),
            HealthSample(start: date(2026, 10, 21, 9), end: date(2026, 10, 21, 9), value: 130, value2: 84),
        ]
        let text = try await report(store, #"{"metric":"blood_pressure","start":"last_7_days"}"#)
        #expect(text.contains("2026-10-21 Wed  130/84    130–130         84–84"))
        #expect(text.contains("average 125/82 mmHg · systolic 120–130 · diastolic 80–84"))
        let latest = try await report(store, #"{"metric":"blood_pressure","aggregation":"latest"}"#)
        #expect(latest.contains("2026-10-21 Wed 09:00  130/84"))
    }

    @Test func unitsFollowTheUser() {
        let us = HealthUnits.us
        #expect(HealthFormat(metric: .distance, units: us).number(5000) == "3.11" && HealthFormat(metric: .distance, units: us).unit == "mi")
        #expect(HealthFormat(metric: .weight, units: us).number(72) == "158.7")
        #expect(HealthFormat(metric: .weight, units: HealthUnits(mass: .st)).number(72) == "11 st 5 lb")
        #expect(HealthFormat(metric: .height, units: us).number(1.78) == "5 ft 10 in")
        #expect(HealthFormat(metric: .height, units: .metric).number(1.78) == "178")
        #expect(HealthFormat(metric: .water, units: us).number(500) == "16.9")
        #expect(HealthFormat(metric: .bloodGlucose, units: HealthUnits(glucose: .mmolL)).number(99) == "5.5")
        #expect(HealthFormat(metric: .activeEnergy, units: HealthUnits(energy: .kJ)).number(100) == "418")
        #expect(HealthFormat(metric: .bloodOxygen, units: .metric).number(0.97) == "97.0")
        #expect(HealthUnits.locale(Locale(identifier: "en_US")) == .us)
        #expect(HealthUnits.locale(Locale(identifier: "ko_KR")) == .metric)
        #expect(HealthUnits.locale(Locale(identifier: "de_DE")).glucose == .mgdL && HealthUnits.locale(Locale(identifier: "en_CA")).glucose == .mmolL)
    }

    @Test func workoutsAreListedWithTotals() async throws {
        let store = FakeHealthStore()
        store.workoutList = [
            HealthWorkout(start: date(2026, 10, 21, 7, 15), end: date(2026, 10, 21, 7, 54), activity: "running", energy: 408, distance: 6420,
                          averageHeartRate: 151, maxHeartRate: 169),
            HealthWorkout(start: date(2026, 10, 19, 18, 30), end: date(2026, 10, 19, 19, 15), activity: "strength training", energy: 278),
        ]
        let text = try await report(store, #"{"metric":"workouts","start":"last_7_days"}"#)
        #expect(text.contains("when                  type               duration  kcal  km    avg HR  max HR"))
        #expect(text.contains("2026-10-21 Wed 07:15  running            39m       408   6.42  151     169"))
        #expect(text.contains("2026-10-19 Mon 18:30  strength training  45m       278   —     —       —"))
        #expect(text.hasSuffix("2 workouts · total 1h 24m · average 42m · 686 kcal · by type: running 1, strength training 1"))
        store.workoutList = (0..<50).map { i in
            let start = now.addingTimeInterval(-Double(i + 1) * 7200)
            return HealthWorkout(start: start, end: start.addingTimeInterval(1800), activity: "walking")
        }
        let many = try await report(store, #"{"metric":"workouts","start":"last_7_days"}"#)
        #expect(many.contains("(10 older workouts not listed"))
    }

    @Test func emptyRangesAreEmpty() async throws {
        let store = FakeHealthStore()
        #expect(try await report(store, #"{"metric":"steps"}"#) == "<empty>")
        #expect(try await report(store, #"{"metric":"sleep"}"#) == "<empty>")
        #expect(try await report(store, #"{"metric":"workouts"}"#) == "<empty>")
        #expect(try await report(store, #"{"metric":"heart_rate","aggregation":"latest"}"#) == "<empty>")
    }

    @Test func listAvailableSaysWhatItKnows() async throws {
        let store = FakeHealthStore()
        store.unasked = [.sleep]
        store.quantities[.steps] = [HealthSample(start: date(2026, 10, 20, 9), end: date(2026, 10, 20, 10), value: 100)]
        let text = try await report(store, #"{"metric":"list_available"}"#)
        #expect(text.contains("steps               has data, latest 2026-10-20"))
        #expect(text.contains("sleep               not asked yet"))
        #expect(text.contains("heart_rate          no data or not allowed"))
        #expect(store.requested.isEmpty, "listing never shows the sheet")
    }

    @Test func outputIsCapped() {
        let long = (0..<1000).map { "row \($0) with some padding text" }.joined(separator: "\n")
        let capped = HealthReport.capped(long)
        #expect(capped.count < HealthReport.maxCharacters + 120)
        #expect(capped.hasSuffix("more lines. Ask for a shorter range, or weekly or monthly rows.]"))
        #expect(HealthReport.capped("short") == "short")
    }
}

struct HealthSleepTests {
    private func s(_ stage: HealthCategory.Sleep, _ start: Date, _ minutes: Double) -> HealthSample {
        HealthSample(start: start, end: start.addingTimeInterval(minutes * 60), value: Double(stage.rawValue))
    }

    @Test func stagesAreSummedPerNightWithoutDoubleCounting() {
        let bed = date(2026, 10, 21, 23)
        let samples = [
            s(.inBed, bed, 480),
            s(.core, bed.addingTimeInterval(600), 120), s(.deep, bed.addingTimeInterval(600 + 7200), 60),
            s(.awake, bed.addingTimeInterval(600 + 10800), 10), s(.rem, bed.addingTimeInterval(600 + 11400), 90),
            // A phone app logs the same night as plain "asleep", overlapping the watch's stages, and an awake the
            // watch saw as core.
            s(.asleepUnspecified, bed.addingTimeInterval(1200), 120), s(.awake, bed.addingTimeInterval(1800), 5),
            // An evening nap the next day belongs to the same date, a nap after 6 PM to the next.
            s(.asleepUnspecified, date(2026, 10, 22, 15), 30), s(.asleepUnspecified, date(2026, 10, 22, 19), 20),
        ]
        let nights = HealthSleep.nights(samples, calendar: calendar)
        #expect(nights.map(\.night) == [date(2026, 10, 22), date(2026, 10, 23)])
        let night = nights[0]
        #expect(night.core == 7200 && night.deep == 3600 && night.rem == 5400)
        #expect(night.asleep == (180 + 90 + 30) * 60, "23:10-02:10 and 02:20-03:50 once, plus the 3 PM nap")
        #expect(night.awake == 600, "the awake inside another source's asleep doesn't count")
        #expect(night.inBed == 480 * 60)
        #expect(night.bedtime == bed && night.hasStages)
        #expect(nights[1].asleep == 1200 && !nights[1].hasStages)
    }

    @Test func unionMergesOverlaps() {
        let a = date(2026, 10, 22, 1)
        let set = HealthIntervals([DateInterval(start: a, duration: 3600), DateInterval(start: a.addingTimeInterval(1800), duration: 3600),
                                   DateInterval(start: a.addingTimeInterval(10_000), duration: 100)])
        #expect(set.intervals.count == 2 && set.length == 5400 + 100)
        let cut = set.subtracting(HealthIntervals([DateInterval(start: a.addingTimeInterval(600), duration: 600)]))
        #expect(cut.length == 4900)
    }

    @Test func theTableShowsStagesOrDashes() async throws {
        let store = FakeHealthStore()
        store.categories[.sleep] = [s(.core, date(2026, 10, 21, 23, 30), 420), s(.deep, date(2026, 10, 22, 6, 30), 30),
                                    s(.asleepUnspecified, date(2026, 10, 20, 23), 400)]
        let text = try await report(store, #"{"metric":"sleep","start":"last_7_days"}"#)
        #expect(text.contains("night           bed    wake   asleep  core    deep  REM  awake  in bed"))
        #expect(text.contains("2026-10-21 Wed  23:00  05:40  6h 40m  —       —     —    —      —"))
        #expect(text.contains("2026-10-22 Thu  23:30  07:00  7h 30m  7h 00m  30m   0m   0m     —"))
        #expect(text.contains("average asleep 7h 05m over 2 nights"))
        let last = try await report(store, #"{"metric":"sleep","start":"last_night"}"#)
        #expect(last.contains("2026-10-22 Thu") && !last.contains("2026-10-21 Wed"))
    }
}

struct HealthToolTests {
    private let remote = ToolDestination(name: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1"), kind: .openAICompatible)
    private let home = ToolDestination(name: "Ollama", baseURL: URL(string: "http://192.168.0.20:11434/v1"), kind: .openAICompatible)

    @Test func localDestinations() {
        for host in ["localhost", "127.0.0.1", "10.1.2.3", "172.20.0.1", "192.168.1.5", "169.254.10.1", "100.64.0.1", "100.127.255.254",
                     "mac-studio.local", "box.tail1234.ts.net", "::1", "fd7a:115c:a1e0::1", "fe80::1", "[::1]", "::ffff:192.168.0.1"] {
            #expect(HealthPrivacy.isLocalHost(host), "\(host)")
        }
        for host in ["api.openai.com", "8.8.8.8", "172.32.0.1", "100.128.0.1", "192.169.0.1", "2001:4860::1", "localhost.example.com", "ts.net.evil.com"] {
            #expect(!HealthPrivacy.isLocalHost(host), "\(host)")
        }
        #expect(HealthPrivacy.isLocal(home) && !HealthPrivacy.isLocal(remote) && !HealthPrivacy.isLocal(nil))
        #expect(HealthPrivacy.isLocal(ToolDestination(name: "Apple", baseURL: nil, kind: .appleOnDevice)))
        #expect(!HealthPrivacy.isLocal(ToolDestination(name: "ChatGPT", baseURL: URL(string: "http://localhost"), kind: .chatGPT)))
    }

    @Test func localOnlyRefusesRemoteModels() async {
        let store = FakeHealthStore()
        store.quantities[.steps] = [HealthSample(start: date(2026, 10, 22, 9), end: date(2026, 10, 22, 10), value: 100)]
        let refused = await HealthQueryTool(source: store, localOnly: true, destination: remote, now: now, calendar: calendar, ask: { _ in true })
            .run(arguments: #"{"metric":"steps"}"#, conversation: nil, callID: nil)
        #expect(refused.isError && refused.text.contains("only for on-device or local models") && refused.text.contains("(OpenAI)"))
        #expect(HealthCallLabel.declined(refused.text))
        let local = await HealthQueryTool(source: store, localOnly: true, destination: home, now: now, calendar: calendar, ask: { _ in true })
            .run(arguments: #"{"metric":"steps"}"#, conversation: nil, callID: nil)
        #expect(!local.isError && local.text.hasPrefix(HealthReport.marker))
        let off = await HealthQueryTool(source: store, localOnly: false, destination: remote, now: now, calendar: calendar, ask: { _ in true })
            .run(arguments: #"{"metric":"steps"}"#, conversation: nil, callID: nil)
        #expect(!off.isError)
    }

    @Test func theFirstReadAsksThenRequests() async {
        let store = FakeHealthStore()
        store.unasked = [.sleep]
        let asked = HealthAskLog()
        let declined = await HealthQueryTool(source: store, localOnly: false, destination: home, now: now, calendar: calendar,
                                             ask: { asked.add($0); return false })
            .run(arguments: #"{"metric":"sleep"}"#, conversation: UUID(), callID: "c1")
        #expect(declined.isError && declined.text.hasPrefix("Error: the user didn't allow") && store.requested.isEmpty)
        #expect(asked.requests.first?.metrics == [.sleep] && asked.requests.first?.destination == "Ollama" && asked.requests.first?.callID == "c1")
        let allowed = await HealthQueryTool(source: store, localOnly: false, destination: home, now: now, calendar: calendar,
                                            ask: { asked.add($0); return true })
            .run(arguments: #"{"metric":"sleep"}"#, conversation: UUID(), callID: "c2")
        #expect(store.requested == [[.sleep]])
        #expect(!allowed.isError && allowed.text.hasPrefix("No sleep data or not allowed"), "denied looks like no data")
        _ = await HealthQueryTool(source: store, localOnly: false, destination: home, now: now, calendar: calendar,
                                  ask: { asked.add($0); return true })
            .run(arguments: #"{"metric":"sleep"}"#, conversation: nil, callID: nil)
        #expect(asked.requests.count == 2, "asked once per type")
    }

    @Test func unavailableAndBadArguments() async {
        let store = FakeHealthStore()
        store.available = false
        let out = await HealthQueryTool(source: store, localOnly: false, destination: nil, ask: { _ in true })
            .run(arguments: #"{"metric":"steps"}"#, conversation: nil, callID: nil)
        #expect(out.isError && out.text.contains("isn't available on this device"))
        let bad = await HealthQueryTool(source: FakeHealthStore(), localOnly: false, destination: nil, ask: { _ in true })
            .run(arguments: #"{"metric":"steps","start":"soon"}"#, conversation: nil, callID: nil)
        #expect(bad.isError && bad.text.contains("couldn't read start"))
    }

    @MainActor
    @Test func requestsAreKeyedByChatAndCall() async {
        let requests = HealthRequests()
        let a = UUID(), b = UUID()
        let first = Task { await requests.ask(HealthRequests.Request(conversationID: a, callID: "call_0", metrics: [.sleep])) }
        let second = Task { await requests.ask(HealthRequests.Request(conversationID: b, callID: "call_0", metrics: [.steps])) }
        while requests.pending(conversation: a).isEmpty || requests.pending(conversation: b).isEmpty { await Task.yield() }
        #expect(requests.request(forCall: "call_0", conversation: b)?.metrics == [.steps])
        requests.answer(requests.request(forCall: "call_0", conversation: a)!.id, allowed: true)
        requests.answer(requests.request(forCall: "call_0", conversation: b)!.id, allowed: false)
        let (one, two) = (await first.value, await second.value)
        #expect(one && !two)
        #expect(requests.pending(conversation: a).isEmpty)
    }

    @Test func debugBundlesMaskHealthResults() {
        let result = "Apple Health data: sleep, last 7 days, 2026-10-16 to 2026-10-22.\nnight  asleep\n2026-10-22 Thu  7h 30m \"quoted\""
        let chat = try! JSONSerialization.data(withJSONObject: ["messages": [
            ["role": "tool", "tool_call_id": "c1", "content": result],
            ["role": "tool", "tool_call_id": "c2", "content": "Results from Bing: unrelated"],
        ]], options: [.sortedKeys])
        let redacted = String(decoding: DebugRedaction.redact(chat), as: UTF8.self)
        #expect(!redacted.contains("7h 30m") && !redacted.contains("sleep, last 7 days"))
        #expect(redacted.contains(DebugRedaction.healthPlaceholder) && redacted.contains("Results from Bing: unrelated"))
        #expect((try? JSONSerialization.jsonObject(with: Data(redacted.utf8))) != nil, "still valid JSON")
        // The Responses API's shape.
        let responses = try! JSONSerialization.data(withJSONObject: ["input": [["type": "function_call_output", "call_id": "c1", "output": result]]])
        #expect(!String(decoding: DebugRedaction.redact(responses), as: UTF8.self).contains("7h 30m"))
    }

    @MainActor
    @Test func theGroupIsOffMostlyAndNamesItsTool() {
        #expect(ToolGroup.group(of: ToolNames.healthQuery) == .health)
        #expect(ToolGroup.health.isSupported && ToolGroup.supported.contains(.health), "the iOS test host has HealthKit")
        #expect(!AppSettings(defaults: UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!).defaultToolGroups.contains(.health))
        let names = ToolDefinition.available(groups: [.web, .health], images: false).map(\.function.name)
        #expect(names.last == ToolNames.healthQuery)
        #expect(!ToolDefinition.available(groups: [.web], images: false).map(\.function.name).contains(ToolNames.healthQuery))
        #expect(ToolNames.isSafeToRetry(ToolNames.healthQuery) && ToolNames.hasOwnCard(ToolNames.healthQuery))
        let record = ToolCallRecord(id: "c", name: ToolNames.healthQuery, arguments: "{}", result: "Apple Health data: x", isError: false)
        #expect(record.displayOnly.result == "Apple Health data: x", "the line opens to the table")
        #expect(AppPrompt.text(tools: true, python: false, health: true).contains(AppPrompt.health))
        #expect(!AppPrompt.text(tools: true, python: false).contains("health_query"))
    }

    @Test func theFeedGivesItsOwnLine() {
        let record = ToolCallRecord(id: "c1", name: ToolNames.healthQuery, arguments: #"{"metric":"sleep","start":"last_14_days"}"#,
                                    result: "Apple Health data: sleep", isError: false)
        let cards = ActivityFeed.cards(calls: [FeedCall(record: record)], sources: [:])
        #expect(cards.count == 1 && cards[0].output == "Apple Health data: sleep")
        guard case .health(let summary) = cards[0].kind else { Issue.record("kind \(cards[0].kind)"); return }
        #expect(summary.hasPrefix("sleep, last 14 days"))
    }
}

/// Records what a tool asked, from any thread.
final class HealthAskLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [HealthRequests.Request] = []
    var requests: [HealthRequests.Request] { lock.withLock { list } }
    func add(_ r: HealthRequests.Request) { lock.withLock { list.append(r) } }
}

@MainActor
struct HealthToolSwitchTests {
    private func rig() throws -> (ChatController, AppSettings, ModelContext, ProgrammableStreamer, ModelContainer) {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let defaults = UserDefaults(suiteName: "strata.tests.\(UUID().uuidString)")!
        let connections = ConnectionStore(defaults: defaults, keys: InMemoryKeyStore())
        try connections.setAPIKey("k", for: Connection.testID)
        var gateway = connections.testGateway()
        gateway.models = [ModelInfo(id: "m", supportsTools: true)]
        connections.upsert(gateway)
        let settings = AppSettings(defaults: defaults)
        settings.pythonEnabled = false
        settings.browserEnabled = false
        settings.videoTranscriptsEnabled = false
        settings.interactiveViewsEnabled = false
        settings.generateTitles = false
        let streamer = ProgrammableStreamer([])
        let controller = ChatController(connections: connections, settings: settings, streamer: streamer, tools: FakeTools())
        controller.skills = SkillStore(builtIn: [], directory: nil)
        return (controller, settings, container.mainContext, streamer, container)
    }

    private func system(_ request: ChatRequest) -> String {
        guard let first = request.messages.first, first.role == "system", case .text(let t) = first.content else { return "" }
        return t
    }

    private func names(_ request: ChatRequest) -> [String] { (request.tools ?? []).map(\.function.name) }

    @Test func offInNewChatsAndFrozenOnceOffered() async throws {
        let (controller, settings, context, streamer, container) = try rig()
        _ = container
        let chat = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
        context.insert(chat)
        controller.send(text: "hi", images: [], conversation: chat, context: context)
        await controller.waitUntilIdle()
        #expect(!names(streamer.requests[0]).contains(ToolNames.healthQuery) && !system(streamer.requests[0]).contains(AppPrompt.health))

        controller.setTool(.health, on: true, conversation: chat)
        controller.send(text: "how did I sleep", images: [], conversation: chat, context: context)
        await controller.waitUntilIdle()
        let on = streamer.requests[1]
        #expect(names(on).last == ToolNames.healthQuery && system(on).contains(AppPrompt.health))

        controller.setTool(.health, on: false, conversation: chat)
        controller.send(text: "thanks", images: [], conversation: chat, context: context)
        await controller.waitUntilIdle()
        let off = streamer.requests[2]
        #expect(try ChatRequest.encoder.encode(off.tools ?? []) == ChatRequest.encoder.encode(on.tools ?? []), "the prefix holds")
        #expect(system(off) == system(on))
        let lastUser = off.messages.last { $0.role == "user" }
        #expect(lastUser?.content == .text("thanks\n\n[Apple Health: off]"))
        #expect(ToolGroup.health.refusal == "The user turned off Apple Health for this chat. Answer without it, or ask them to turn it on.")

        settings.healthEnabled = true
        let fresh = Conversation(connectionID: Connection.testID, modelID: "m", effort: .medium)
        context.insert(fresh)
        #expect(controller.toolSwitches(fresh).contains(.health))
    }
}
