import Foundation

/// Workout read from HealthKit (identified by its HealthKit UUID).
public struct HealthWorkout: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sourceName: String
    public var startedAt: Date
    public var endedAt: Date
    public var durationMinutes: Double
    public var activeEnergy: Double?
    public var distanceKm: Double?

    public init(id: String, name: String, sourceName: String, startedAt: Date, endedAt: Date, durationMinutes: Double,
                activeEnergy: Double?, distanceKm: Double?) {
        self.id = id.lowercased()
        self.name = String(name.prefix(100))
        self.sourceName = String(sourceName.prefix(100))
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMinutes = durationMinutes
        self.activeEnergy = activeEnergy
        self.distanceKm = distanceKm
    }
}

/// Daily HealthKit aggregates. Unavailable values stay `nil`: missing permission or
/// missing data is never turned into zero activity.
public struct HealthDay: Codable, Equatable, Sendable {
    public var date: String
    public var steps: Int?
    public var activeEnergy: Double?
    public var exerciseMinutes: Double?
    public var distanceKm: Double?

    public init(date: String, steps: Int? = nil, activeEnergy: Double? = nil, exerciseMinutes: Double? = nil, distanceKm: Double? = nil) {
        self.date = date
        self.steps = steps
        self.activeEnergy = activeEnergy
        self.exerciseMinutes = exerciseMinutes
        self.distanceKm = distanceKm
    }

    public var hasData: Bool { steps != nil || activeEnergy != nil || exerciseMinutes != nil || distanceKm != nil }
}

public struct HealthPayload: Codable, Equatable, Sendable {
    public var timezone: String
    public var workouts: [HealthWorkout]
    public var days: [HealthDay]

    public init(timezone: String, workouts: [HealthWorkout], days: [HealthDay]) {
        self.timezone = timezone
        self.workouts = workouts
        self.days = days
    }
}

/// HealthKit → local diary upsert (port of `POST /api/imports/healthkit`).
/// Workouts are matched by HealthKit UUID, daily summaries by local date, so a repeated
/// sync never creates copies. Observations never touch therapy, doses or IOB.
public enum HealthImportPlanner {
    public struct Plan: Equatable, Sendable {
        public var inserts: [DiaryRecord] = []
        public var updates: [DiaryRecord] = []
        public var unchanged = 0
        public var inserted: Int { inserts.count }
        public var updated: Int { updates.count }
    }

    public static func workoutKey(_ id: String) -> String { "healthkit-workout:" + id.lowercased() }
    public static func dayKey(_ date: String) -> String { "healthkit-day:" + date }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw BolusError.validation(message) }
    }

    static func validate(_ payload: HealthPayload) throws -> TimeZone {
        guard let zone = TimeZone(identifier: payload.timezone) else { throw BolusError.validation("Неизвестный часовой пояс") }
        try check(payload.workouts.count <= 1000, "Слишком много тренировок. Выберите меньший период.")
        try check(payload.days.count <= 90, "Не больше 90 дней за одну синхронизацию")
        try check(Set(payload.workouts.map(\.id)).count == payload.workouts.count && Set(payload.days.map(\.date)).count == payload.days.count,
                  "Повторные идентификаторы в одном пакете")
        for w in payload.workouts {
            try check(UUID(uuidString: w.id) != nil, "Некорректный идентификатор тренировки")
            try check(!w.name.isEmpty && !w.sourceName.isEmpty, "У тренировки нет названия или источника")
            let span = w.endedAt.timeIntervalSince(w.startedAt) / 60
            try check(w.endedAt > w.startedAt && w.durationMinutes.isFinite && w.durationMinutes > 0 && w.durationMinutes <= 1440
                      && w.durationMinutes <= span + 1, "Некорректное время тренировки")
            if let e = w.activeEnergy { try check(e.isFinite && e >= 0 && e <= 30000, "Некорректная энергия тренировки") }
            if let d = w.distanceKm { try check(d.isFinite && d >= 0 && d <= 2000, "Некорректная дистанция тренировки") }
        }
        for day in payload.days {
            try check(LocalDate(iso: day.date) != nil, "Некорректная дата сводки")
            try check(day.hasData, "В сводке нет доступных наблюдений")
            if let s = day.steps { try check((0...500_000).contains(s), "Некорректное число шагов") }
            if let e = day.activeEnergy { try check(e.isFinite && e >= 0 && e <= 30000, "Некорректная активная энергия") }
            if let m = day.exerciseMinutes { try check(m.isFinite && m >= 0 && m <= 1440, "Некорректные минуты упражнений") }
            if let d = day.distanceKm { try check(d.isFinite && d >= 0 && d <= 2000, "Некорректная дистанция") }
        }
        return zone
    }

    /// - Parameter existing: current diary entries by `dedupeKey`.
    public static func plan(_ payload: HealthPayload, existing: [String: DiaryRecord], now: Date) throws -> Plan {
        let zone = try validate(payload)
        var plan = Plan()
        func upsert(_ key: String, _ kind: EntryKind, _ at: Date, _ fields: [String: JSONValue], clientID: UUID) {
            var data = JSONValue.object(fields)
            if let row = existing[key] {
                if kind == .activitySummary { data = row.data.merging(data) }
                if row.data == data && Micros.from(row.occurredAt) == Micros.from(at) {
                    plan.unchanged += 1
                    return
                }
                var updated = row
                updated.data = data
                updated.occurredAt = at
                updated.version += 1
                updated.updatedAt = now
                plan.updates.append(updated)
            } else {
                plan.inserts.append(DiaryRecord(clientID: clientID, kind: kind, occurredAt: at, data: data, createdAt: now, dedupeKey: key))
            }
        }
        for w in payload.workouts {
            if w.endedAt > now.addingTimeInterval(EntryFactory.futureTolerance) { throw BolusError.validation("Тренировка находится в будущем") }
            var fields: [String: JSONValue] = [
                "name": .string(w.name), "source_name": .string(w.sourceName), "duration_minutes": .number(w.durationMinutes),
                "source": .string("apple_health"), "source_kind": .string("healthkit"), "external_id": .string(w.id),
                "ended_at": .string(ISODate.format(w.endedAt)), "intensity": .string("unknown"),
                "note": .string("Импортировано из Apple «Здоровье»"),
            ]
            if let e = w.activeEnergy { fields["active_energy"] = .number(e) }
            if let d = w.distanceKm { fields["distance_km"] = .number(d) }
            upsert(workoutKey(w.id), .activity, w.startedAt, fields, clientID: UUID(uuidString: w.id) ?? UUID())
        }
        let today = LocalDate.today(in: zone, now: now)
        for day in payload.days {
            guard let date = LocalDate(iso: day.date) else { continue }
            if date > today { throw BolusError.validation("Сводка активности находится в будущем") }
            var fields: [String: JSONValue] = [
                "name": .string("Активность за день"), "source": .string("apple_health"), "source_kind": .string("healthkit"),
                "local_date": .string(day.date), "timezone": .string(payload.timezone),
                "note": .string("Дневная сводка; не суммируется с тренировками"),
            ]
            if let s = day.steps { fields["steps"] = .number(Double(s)) }
            if let e = day.activeEnergy { fields["active_energy"] = .number(e); fields["energy_unit"] = .string("kcal") }
            if let m = day.exerciseMinutes { fields["exercise_minutes"] = .number(m) }
            if let d = day.distanceKm { fields["distance_km"] = .number(d) }
            upsert(dayKey(day.date), .activitySummary, date.startOfDay(in: zone), fields, clientID: UUID())
        }
        return plan
    }
}
