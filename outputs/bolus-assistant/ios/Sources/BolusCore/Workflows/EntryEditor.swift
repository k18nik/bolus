import Foundation

/// Corrections of saved diary entries. A corrected record keeps its identity (id, client id,
/// creation time, dedupe key), gets a higher version and passes the same validation as a new
/// entry. Pure: the caller persists the result.
public struct EntryEditor {
    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date = Date(), timeZone: TimeZone) {
        self.now = now
        self.timeZone = timeZone
    }

    var factory: EntryFactory { EntryFactory(now: now, timeZone: timeZone) }

    /// Apple Health data is updated by the sync (by workout UUID or day), not by hand.
    public static func isEditable(_ record: DiaryRecord) -> Bool {
        switch record.kind {
        case .glucose, .insulin, .meal, .note: return true
        case .activity: return record.activity.map { !$0.isFromAppleHealth } ?? false
        case .activitySummary: return false
        }
    }

    func corrected(_ original: DiaryRecord, kind: EntryKind, with fresh: DiaryRecord) throws -> DiaryRecord {
        guard original.kind == kind, Self.isEditable(original) else { throw BolusError.validation("Эту запись нельзя изменить") }
        var record = original
        record.occurredAt = fresh.occurredAt
        record.data = fresh.data
        record.updatedAt = now
        record.version = original.version + 1
        return record
    }

    public func glucose(_ original: DiaryRecord, value: Double, unit: GlucoseUnit, measuredAt: Date, note: String) throws -> DiaryRecord {
        guard let payload = original.glucose else { throw BolusError.validation("Эту запись нельзя изменить") }
        let fresh = try factory.glucose(value: value, unit: unit, measuredAt: measuredAt, source: payload.source, trend: payload.trend, note: note)
        return try corrected(original, kind: .glucose, with: fresh)
    }

    /// Dose, time and note. Type, name, step, DIA and action model stay as at administration,
    /// so IOB of the corrected dose still uses the DIA saved with it.
    /// - Parameter maxUnits: the snapshot limit when the dose confirms a bolus calculation.
    public func insulin(_ original: DiaryRecord, units: Double, administeredAt: Date, note: String, maxUnits: Double? = nil) throws -> DiaryRecord {
        guard var payload = original.insulin else { throw BolusError.validation("Эту запись нельзя изменить") }
        guard units.isFinite, units > 0, units <= 200 else { throw BolusError.validation("Доза должна быть больше 0 и не больше 200 ЕД") }
        if let maxUnits, units > maxUnits {
            throw BolusError.validation("Доза больше максимального болюса расчёта (\(BolusFormat.number(maxUnits)) ЕД)")
        }
        let step = payload.doseIncrement ?? BolusEngine.legacyIncrement
        guard InsulinCatalog.isDoseMultiple(units, step: step) else {
            throw BolusError.validation("Доза должна быть кратна шагу устройства \(BolusFormat.number(step)) ЕД")
        }
        try factory.checkNote(note)
        try factory.checkTime(administeredAt)
        payload.units = units
        payload.note = note
        var fresh = original
        fresh.occurredAt = administeredAt
        fresh.data = try JSONValue.encode(payload)
        return try corrected(original, kind: .insulin, with: fresh)
    }

    public func meal(_ original: DiaryRecord, name: String, mealType: MealType, eatenAt: Date, items: [MealItem], note: String) throws -> DiaryRecord {
        let fresh = try factory.meal(name: name, mealType: mealType, eatenAt: eatenAt, items: items, note: note)
        return try corrected(original, kind: .meal, with: fresh)
    }

    public func activity(_ original: DiaryRecord, name: String, durationMinutes: Int, intensity: String, occurredAt: Date,
                         note: String) throws -> DiaryRecord {
        let fresh = try factory.activity(name: name, durationMinutes: durationMinutes, occurredAt: occurredAt, intensity: intensity, note: note)
        return try corrected(original, kind: .activity, with: fresh)
    }

    public func note(_ original: DiaryRecord, text: String, occurredAt: Date) throws -> DiaryRecord {
        let fresh = try factory.note(text, occurredAt: occurredAt)
        return try corrected(original, kind: .note, with: fresh)
    }
}

extension MealItem {
    /// The line the unified form adds for carbohydrates typed by hand.
    public static let manualCarbsName = "Углеводы, введённые вручную"

    public var isManualCarbs: Bool { foodSource == "manual" && nameSnapshot == Self.manualCarbsName }

    /// The same food in another amount: nutrients scale with the amount, so the meal snapshot
    /// stays self-contained (the food itself may have changed since).
    public func rescaled(to newAmount: Double) -> MealItem {
        guard amount > 0, newAmount.isFinite, newAmount > 0 else { return self }
        let factor = newAmount / amount
        var copy = self
        copy.amount = newAmount
        switch unit {
        case .g: copy.grams = newAmount
        case .ml: copy.grams = nil
        case .serving: copy.grams = grams.map { $0 * factor }
        }
        copy.carbs = carbs * factor
        copy.protein = protein * factor
        copy.fat = fat * factor
        copy.calories = calories * factor
        copy.fiber = fiber.map { $0 * factor }
        copy.sugar = sugar.map { $0 * factor }
        return copy
    }
}
