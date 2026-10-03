import Foundation

/// Port of `backend/app/analytics/engine.py` (summarize, hourly profile, daily
/// breakdown, activity/glucose observations) plus food/insulin/activity statistics.
///
/// Values computed from existing records are bit-identical to Python. One deliberate
/// difference: when a period has no insulin/meal/activity records, Swift returns
/// `nil` instead of Python's `0.0` — absence of data is never presented as zero.
public enum AnalyticsEngine {
    public static let rangeLow = 3.9
    public static let rangeHigh = 10.0

    public struct Summary: Codable, Equatable, Sendable {
        public var sampleSize: Int
        public var coverageMethod: String
        public var meanGlucose: Double?
        public var medianGlucose: Double?
        public var min: Double?
        public var max: Double?
        public var standardDeviation: Double?
        public var coefficientOfVariation: Double?
        public var tir: Double?
        public var tbr: Double?
        public var tar: Double?
        public var dailyInsulin: Double?
        public var basalInsulin: Double?
        public var bolusInsulin: Double?
        public var carbsPerDay: Double?
        public var caloriesPerDay: Double?
        public var correctionsPerDay: Double?
        public var days: Int
        public var insulinRecords: Int
        public var basalRecords: Int
        public var bolusRecords: Int
        public var mealRecords: Int

        enum CodingKeys: String, CodingKey {
            case sampleSize = "sample_size", coverageMethod = "coverage_method", meanGlucose = "mean_glucose"
            case medianGlucose = "median_glucose", min, max, standardDeviation = "standard_deviation"
            case coefficientOfVariation = "coefficient_of_variation", tir, tbr, tar, dailyInsulin = "daily_insulin"
            case basalInsulin = "basal_insulin", bolusInsulin = "bolus_insulin", carbsPerDay = "carbs_per_day"
            case caloriesPerDay = "calories_per_day", correctionsPerDay = "corrections_per_day", days
            case insulinRecords = "insulin_records", basalRecords = "basal_records", bolusRecords = "bolus_records"
            case mealRecords = "meal_records"
        }
    }

    public struct HourlyPoint: Codable, Equatable, Sendable {
        public var hour: Int
        public var mean: Double
        public var count: Int
    }

    public struct DailyRow: Codable, Equatable, Sendable {
        public var date: LocalDate
        public var summary: Summary
        /// `nil` when the day has no activity records.
        public var activityMinutes: Double?
    }

    public struct ActivityObservation: Codable, Equatable, Sendable {
        public var activityID: String
        public var name: String
        public var before: Double
        public var after: Double
        public var change: Double
        public var source: String
    }

    // MARK: Python-compatible core

    static func values(_ entries: [DiaryRecord], _ kind: EntryKind, _ key: String) -> [Double] {
        entries.filter { $0.kind == kind }.compactMap { $0.data.double(key) }
    }

    /// Workout durations typed as the reference stores them: `int` for manual entries
    /// (`duration_minutes: int`), `float` for Apple Health workouts.
    static func durations(_ entries: [DiaryRecord]) -> [PyNumber] {
        entries.filter { $0.kind == .activity }.compactMap { entry in
            guard let minutes = entry.data.double("duration_minutes") else { return nil }
            let fromHealth = entry.data.string("source") == "apple_health"
            if !fromHealth, minutes.rounded(.towardZero) == minutes, Swift.abs(minutes) < 1e15 { return .int(Int(minutes)) }
            return .float(minutes)
        }
    }

    public static func summarize(_ entries: [DiaryRecord], days: Int) -> Summary {
        let glucose = values(entries, .glucose, "value_mmol")
        let doses = entries.filter { $0.kind == .insulin }.compactMap(\.data.objectValue)
        let meals = entries.filter { $0.kind == .meal }.compactMap(\.data.objectValue)
        let n = glucose.count
        let average = PyStatistics.mean(glucose)
        let sd = PyStatistics.pstdev(glucose)
        let perDay = Double(days)
        func share(_ predicate: (Double) -> Bool) -> Double? {
            n == 0 ? nil : PyFloat.round(Double(glucose.filter(predicate).count) / Double(n) * 100, 1)
        }
        func units(_ list: [[String: JSONValue]]) -> Double { PyFloat.sum(list.map { $0["units"]?.doubleValue ?? 0 }) }
        let basal = doses.filter { $0["insulin_type"]?.stringValue == "basal" }
        let bolus = doses.filter { $0["insulin_type"]?.stringValue != "basal" }
        let corrections = doses.filter { ["correction", "meal_and_correction"].contains($0["purpose"]?.stringValue ?? "") }.count
        var cv: Double?
        if let sd, let average, average != 0 { cv = PyFloat.round(sd / average * 100, 1) }
        return Summary(
            sampleSize: n, coverageMethod: "sample_based",
            meanGlucose: average.map { PyFloat.round($0, 2) }, medianGlucose: PyStatistics.median(glucose),
            min: glucose.min(), max: glucose.max(), standardDeviation: sd.map { PyFloat.round($0, 2) },
            coefficientOfVariation: cv,
            tir: share { $0 >= rangeLow && $0 <= rangeHigh }, tbr: share { $0 < rangeLow }, tar: share { $0 > rangeHigh },
            dailyInsulin: doses.isEmpty ? nil : PyFloat.round(units(doses) / perDay, 2),
            basalInsulin: basal.isEmpty ? nil : PyFloat.round(units(basal) / perDay, 2),
            bolusInsulin: bolus.isEmpty ? nil : PyFloat.round(units(bolus) / perDay, 2),
            carbsPerDay: meals.isEmpty ? nil : PyFloat.round(PyFloat.sum(meals.map { $0["total_carbs"]?.doubleValue ?? 0 }) / perDay, 1),
            caloriesPerDay: meals.isEmpty ? nil : PyFloat.round(PyFloat.sum(meals.map { $0["total_calories"]?.doubleValue ?? 0 }) / perDay, 1),
            correctionsPerDay: doses.isEmpty ? nil : PyFloat.round(Double(corrections) / perDay, 2),
            days: days, insulinRecords: doses.count, basalRecords: basal.count, bolusRecords: bolus.count, mealRecords: meals.count)
    }

    public static func hourlyProfile(_ entries: [DiaryRecord], timeZone: TimeZone) -> [HourlyPoint] {
        var buckets = [[Double]](repeating: [], count: 24)
        for entry in entries where entry.kind == .glucose {
            guard let value = entry.data.double("value_mmol") else { continue }
            buckets[WallClock.hour(entry.occurredAt, timeZone: timeZone)].append(value)
        }
        return buckets.enumerated().compactMap { hour, values in
            guard let mean = PyStatistics.mean(values) else { return nil }
            return HourlyPoint(hour: hour, mean: PyFloat.round(mean, 2), count: values.count)
        }
    }

    public static func dailyBreakdown(_ entries: [DiaryRecord], from: LocalDate, to: LocalDate, timeZone: TimeZone) -> [DailyRow] {
        guard from <= to else { return [] }
        var byDay: [LocalDate: [DiaryRecord]] = [:]
        for entry in entries { byDay[LocalDate(date: entry.occurredAt, timeZone: timeZone), default: []].append(entry) }
        return (0...to.days(since: from)).map { offset in
            let day = from.adding(days: offset)
            let rows = byDay[day] ?? []
            let activities = durations(rows)
            return DailyRow(date: day, summary: summarize(rows, days: 1),
                            activityMinutes: activities.isEmpty ? nil : PyFloat.sum(activities))
        }
    }

    /// Last glucose within 60 minutes before the start and first within 2 hours after the
    /// end of each activity. Descriptive only: no causal claims, no dosing modifiers.
    public static func activityResponse(_ entries: [DiaryRecord]) -> [ActivityObservation] {
        let glucose = entries.filter { $0.kind == .glucose }
        var result: [ActivityObservation] = []
        for entry in entries where entry.kind == .activity {
            guard let minutes = entry.data.double("duration_minutes") else { continue }
            let start = Micros.from(entry.occurredAt)
            let end = start + Micros.pythonTimedelta(minutes: minutes)
            let before = glucose.filter { let t = Micros.from($0.occurredAt); return start - 3_600_000_000 <= t && t <= start }
            let after = glucose.filter { let t = Micros.from($0.occurredAt); return end <= t && t <= end + 7_200_000_000 }
            guard let a = before.last?.data.double("value_mmol"), let b = after.first?.data.double("value_mmol") else { continue }
            result.append(ActivityObservation(activityID: entry.id.uuidString.lowercased(), name: entry.data.string("name") ?? "",
                                              before: a, after: b, change: PyFloat.round(b - a, 2),
                                              source: entry.data.string("source") ?? "manual"))
        }
        return result
    }

    // MARK: Period report used by the analytics screen, AI context and reports

    public struct FoodStat: Codable, Equatable, Sendable {
        public var name: String
        public var count: Int
        public var meanCarbs: Double
    }

    public struct Report: Equatable, Sendable {
        public var from: LocalDate
        public var to: LocalDate
        public var entries: [DiaryRecord]
        public var metrics: Summary
        public var daily: [DailyRow]
        public var hourly: [HourlyPoint]
        public var activityResponse: [ActivityObservation]
        public var activityMinutes: Double?
        public var workouts: Int
        public var appleHealthWorkouts: Int
        public var daysWithSteps: Int
        public var meanStepsOnRecordedDays: Double?
        public var activeEnergyPerRecordedDay: Double?
        public var insulinByPurpose: [InsulinPurpose: Double]
        public var carbsByMealType: [MealType: Double]
        public var proteinPerDay: Double?
        public var fatPerDay: Double?
        public var mealsPerDay: Double?
        public var topFoods: [FoodStat]
    }

    /// Entries in `[from 00:00, to+1 00:00)` of the time zone, ordered by time.
    public static func entries(_ all: [DiaryRecord], from: LocalDate, to: LocalDate, timeZone: TimeZone) -> [DiaryRecord] {
        let start = from.startOfDay(in: timeZone)
        let end = to.adding(days: 1).startOfDay(in: timeZone)
        return all.filter { $0.occurredAt >= start && $0.occurredAt < end }
            .sorted { ($0.occurredAt, $0.createdAt, $0.id.uuidString) < ($1.occurredAt, $1.createdAt, $1.id.uuidString) }
    }

    /// `GET /analytics`: `hours` limits metrics to the last N hours (the 24 h view).
    public static func report(_ all: [DiaryRecord], from: LocalDate, to: LocalDate, timeZone: TimeZone,
                              now: Date = Date(), hours: Int? = nil) -> Report {
        var rows = entries(all, from: from, to: to, timeZone: timeZone)
        if let hours { rows = rows.filter { $0.occurredAt >= now.addingTimeInterval(-Double(hours) * 3600) } }
        let days = hours == nil ? to.days(since: from) + 1 : 1
        let metrics = summarize(rows, days: days)
        let activities = rows.filter { $0.kind == .activity }
        let minutes = durations(rows)
        let summaries = rows.compactMap(\.activitySummary)
        let steps = summaries.compactMap(\.steps)
        let energy = summaries.compactMap(\.activeEnergy)
        var byPurpose: [InsulinPurpose: Double] = [:]
        for insulin in rows.compactMap(\.insulin) { byPurpose[insulin.purpose, default: 0] += insulin.units }
        let meals = rows.compactMap(\.meal)
        var byMealType: [MealType: Double] = [:]
        var foods: [String: [Double]] = [:]
        for meal in meals {
            byMealType[meal.mealType, default: 0] += meal.totalCarbs
            for item in meal.items { foods[item.nameSnapshot, default: []].append(item.carbs) }
        }
        let topFoods = foods.map { FoodStat(name: $0.key, count: $0.value.count, meanCarbs: PyStatistics.mean($0.value) ?? 0) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        let perDay = Double(days)
        return Report(
            from: from, to: to, entries: rows, metrics: metrics,
            daily: dailyBreakdown(rows, from: from, to: to, timeZone: timeZone),
            hourly: hourlyProfile(rows, timeZone: timeZone), activityResponse: activityResponse(rows),
            activityMinutes: minutes.isEmpty ? nil : PyFloat.sum(minutes), workouts: activities.count,
            appleHealthWorkouts: activities.filter { $0.data.string("source") == "apple_health" }.count,
            daysWithSteps: steps.count,
            meanStepsOnRecordedDays: steps.isEmpty ? nil : (PyFloat.sum(steps) / Double(steps.count)).rounded(.toNearestOrEven),
            activeEnergyPerRecordedDay: energy.isEmpty ? nil : PyFloat.round(PyFloat.sum(energy) / Double(energy.count), 1),
            insulinByPurpose: byPurpose, carbsByMealType: byMealType,
            proteinPerDay: meals.isEmpty ? nil : PyFloat.round(PyFloat.sum(meals.map(\.totalProtein)) / perDay, 1),
            fatPerDay: meals.isEmpty ? nil : PyFloat.round(PyFloat.sum(meals.map(\.totalFat)) / perDay, 1),
            mealsPerDay: meals.isEmpty ? nil : PyFloat.round(Double(meals.count) / perDay, 2),
            topFoods: Array(topFoods.prefix(40)))
    }

    /// Latest glucose by measurement time, then creation time (`/glucose/latest`).
    public static func latestGlucose(_ entries: [DiaryRecord]) -> DiaryRecord? {
        entries.filter { $0.kind == .glucose }.max { ($0.occurredAt, $0.createdAt) < ($1.occurredAt, $1.createdAt) }
    }
}

extension Micros {
    /// Exact `timedelta(minutes=x)` in microseconds, reproducing CPython's float
    /// accumulation and round-half-even of the leftover fraction.
    public static func pythonTimedelta(minutes: Double) -> Int64 {
        let factor: Int64 = 60_000_000
        let integral = minutes.rounded(.towardZero)
        let fraction = minutes - integral
        var micros = Int64(integral) * factor
        guard fraction != 0 else { return micros }
        let scaled = Double(factor) * fraction
        let scaledIntegral = scaled.rounded(.towardZero)
        micros += Int64(scaledIntegral)
        let leftover = scaled - scaledIntegral
        var whole = leftover.rounded(.toNearestOrAwayFromZero)
        if abs(whole - leftover) == 0.5 {
            let odd: Double = micros % 2 != 0 ? 1 : 0
            whole = 2 * ((leftover + odd) * 0.5).rounded(.toNearestOrAwayFromZero) - odd
        }
        return micros + Int64(whole)
    }
}
