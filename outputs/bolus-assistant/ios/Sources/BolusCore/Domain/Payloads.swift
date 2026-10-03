import Foundation

/// Diary entry types (`kind`). Raw values match the reference backend and backups.
public enum EntryKind: String, Codable, CaseIterable, Sendable {
    case glucose
    case insulin
    case meal
    case activity
    case activitySummary = "activity_summary"
    case note
}

public enum GlucoseUnit: String, Codable, CaseIterable, Sendable {
    case mmol = "mmol/L"
    case mgdl = "mg/dL"

    /// Display factor relative to mmol/L.
    public var factor: Double { self == .mgdl ? 18 : 1 }
    public var label: String { self == .mgdl ? "мг/дл" : "ммоль/л" }

    /// Python: `value / (18 if unit == 'mg/dL' else 1)`.
    public func toMmol(_ value: Double) -> Double { value / factor }
    public func fromMmol(_ value: Double) -> Double { value * factor }
}

public enum InsulinPurpose: String, Codable, CaseIterable, Sendable {
    case meal
    case correction
    case mealAndCorrection = "meal_and_correction"
    case basal
    case manual
    case other

    public var label: String {
        switch self {
        case .meal: return "На еду"
        case .correction: return "Коррекция"
        case .mealAndCorrection: return "Еда и коррекция"
        case .basal: return "Базальный"
        case .manual: return "Ручная запись"
        case .other: return "Другое"
        }
    }
}

public enum MealType: String, Codable, CaseIterable, Sendable {
    case breakfast, lunch, dinner, snack

    public var label: String {
        switch self {
        case .breakfast: return "Завтрак"
        case .lunch: return "Обед"
        case .dinner: return "Ужин"
        case .snack: return "Перекус"
        }
    }
}

public enum MealItemUnit: String, Codable, CaseIterable, Sendable {
    case g, ml, serving
}

/// Helper for tolerant decoding of legacy payloads.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

public struct GlucosePayload: Codable, Equatable, Sendable {
    public var value: Double
    public var unit: GlucoseUnit
    public var source: String
    public var trend: String
    public var note: String
    public var valueMmol: Double

    public init(value: Double, unit: GlucoseUnit, source: String = "manual", trend: String = "unknown", note: String = "") {
        self.value = value
        self.unit = unit
        self.source = source
        self.trend = trend
        self.note = note
        valueMmol = unit.toMmol(value)
    }

    enum CodingKeys: String, CodingKey { case value, unit, source, trend, note, valueMmol = "value_mmol" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        valueMmol = try c.decode(Double.self, forKey: .valueMmol)
        unit = try c.value(.unit, default: GlucoseUnit.mmol)
        value = try c.value(.value, default: unit.fromMmol(valueMmol))
        source = try c.value(.source, default: "manual")
        trend = try c.value(.trend, default: "unknown")
        note = try c.value(.note, default: "")
    }

    public static let trendArrows: [String: String] = [
        "rapid_down": "↓↓", "down": "↓", "slight_down": "↘", "stable": "→", "slight_up": "↗", "up": "↑", "rapid_up": "↑↑", "unknown": "",
    ]
}

public struct InsulinPayload: Codable, Equatable, Sendable {
    public var units: Double
    public var insulinType: InsulinType
    public var insulinName: String
    public var purpose: InsulinPurpose
    public var note: String
    public var insulinID: String
    public var activeIngredient: String
    public var doseIncrement: Double?
    /// DIA saved at administration time (rapid only).
    public var dia: Double?
    public var actionModel: String?
    public var relatedBolusCalculationID: String?
    public var relatedMealID: String?

    public init(units: Double, insulinType: InsulinType, insulinName: String, purpose: InsulinPurpose, note: String,
                insulinID: String, activeIngredient: String, doseIncrement: Double?, dia: Double?, actionModel: String?,
                relatedBolusCalculationID: String? = nil, relatedMealID: String? = nil) {
        self.units = units
        self.insulinType = insulinType
        self.insulinName = insulinName
        self.purpose = purpose
        self.note = note
        self.insulinID = insulinID
        self.activeIngredient = activeIngredient
        self.doseIncrement = doseIncrement
        self.dia = dia
        self.actionModel = actionModel
        self.relatedBolusCalculationID = relatedBolusCalculationID
        self.relatedMealID = relatedMealID
    }

    enum CodingKeys: String, CodingKey {
        case units, insulinType = "insulin_type", insulinName = "insulin_name", purpose, note
        case insulinID = "insulin_id", activeIngredient = "active_ingredient", doseIncrement = "dose_increment"
        case dia, actionModel = "action_model", relatedBolusCalculationID = "related_bolus_calculation_id"
        case relatedMealID = "related_meal_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        units = try c.decode(Double.self, forKey: .units)
        insulinType = try c.value(.insulinType, default: InsulinType.rapid)
        insulinName = try c.value(.insulinName, default: "")
        purpose = try c.value(.purpose, default: insulinType == .basal ? InsulinPurpose.basal : .manual)
        note = try c.value(.note, default: "")
        insulinID = try c.value(.insulinID, default: "custom")
        activeIngredient = try c.value(.activeIngredient, default: "")
        doseIncrement = try c.decodeIfPresent(Double.self, forKey: .doseIncrement)
        dia = try c.decodeIfPresent(Double.self, forKey: .dia)
        actionModel = try c.decodeIfPresent(String.self, forKey: .actionModel)
        relatedBolusCalculationID = try c.decodeIfPresent(String.self, forKey: .relatedBolusCalculationID)
        relatedMealID = try c.decodeIfPresent(String.self, forKey: .relatedMealID)
    }
}

/// Nutrition snapshot of one meal component; old meals never change when a food changes.
public struct MealItem: Codable, Equatable, Hashable, Sendable {
    public var nameSnapshot: String
    public var foodSource: String
    public var foodID: String
    /// Mass in grams; `nil` for liquids measured in ml (density is never invented).
    public var grams: Double?
    public var amount: Double
    public var unit: MealItemUnit
    public var carbs: Double
    public var protein: Double
    public var fat: Double
    public var calories: Double
    /// `nil` = unknown (never substituted by zero).
    public var fiber: Double?
    public var sugar: Double?

    public init(nameSnapshot: String, foodSource: String = "manual", foodID: String = "", grams: Double?, amount: Double,
                unit: MealItemUnit, carbs: Double, protein: Double = 0, fat: Double = 0, calories: Double = 0,
                fiber: Double? = nil, sugar: Double? = nil) {
        self.nameSnapshot = nameSnapshot
        self.foodSource = foodSource
        self.foodID = foodID
        self.grams = grams
        self.amount = amount
        self.unit = unit
        self.carbs = carbs
        self.protein = protein
        self.fat = fat
        self.calories = calories
        self.fiber = fiber
        self.sugar = sugar
    }

    enum CodingKeys: String, CodingKey {
        case nameSnapshot = "name_snapshot", foodSource = "food_source", foodID = "food_id", grams, amount, unit
        case carbs, protein, fat, calories, fiber, sugar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nameSnapshot = try c.decode(String.self, forKey: .nameSnapshot)
        foodSource = try c.value(.foodSource, default: "manual")
        foodID = try c.value(.foodID, default: "")
        grams = try c.decodeIfPresent(Double.self, forKey: .grams)
        unit = try c.value(.unit, default: MealItemUnit.g)
        amount = try c.value(.amount, default: grams ?? 100)
        carbs = try c.decode(Double.self, forKey: .carbs)
        protein = try c.value(.protein, default: 0)
        fat = try c.value(.fat, default: 0)
        calories = try c.value(.calories, default: 0)
        fiber = try c.decodeIfPresent(Double.self, forKey: .fiber)
        sugar = try c.decodeIfPresent(Double.self, forKey: .sugar)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nameSnapshot, forKey: .nameSnapshot)
        try c.encode(foodSource, forKey: .foodSource)
        try c.encode(foodID, forKey: .foodID)
        try c.encode(grams, forKey: .grams)
        try c.encode(amount, forKey: .amount)
        try c.encode(unit, forKey: .unit)
        try c.encode(carbs, forKey: .carbs)
        try c.encode(protein, forKey: .protein)
        try c.encode(fat, forKey: .fat)
        try c.encode(calories, forKey: .calories)
        try c.encode(fiber, forKey: .fiber)
        try c.encode(sugar, forKey: .sugar)
    }
}

public struct MealPayload: Codable, Equatable, Sendable {
    public var name: String
    public var mealType: MealType
    public var items: [MealItem]
    public var note: String
    public var totalCarbs: Double
    public var totalProtein: Double
    public var totalFat: Double
    public var totalCalories: Double

    /// Totals are `round(sum, 4)` exactly like the reference backend.
    public init(name: String, mealType: MealType, items: [MealItem], note: String = "") {
        self.name = name
        self.mealType = mealType
        self.items = items
        self.note = note
        totalCarbs = PyFloat.round(items.reduce(0) { $0 + $1.carbs }, 4)
        totalProtein = PyFloat.round(items.reduce(0) { $0 + $1.protein }, 4)
        totalFat = PyFloat.round(items.reduce(0) { $0 + $1.fat }, 4)
        totalCalories = PyFloat.round(items.reduce(0) { $0 + $1.calories }, 4)
    }

    enum CodingKeys: String, CodingKey {
        case name, mealType = "meal_type", items, note, totalCarbs = "total_carbs", totalProtein = "total_protein"
        case totalFat = "total_fat", totalCalories = "total_calories"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.value(.name, default: "Приём пищи")
        mealType = try c.value(.mealType, default: MealType.snack)
        items = try c.value(.items, default: [])
        note = try c.value(.note, default: "")
        totalCarbs = try c.decode(Double.self, forKey: .totalCarbs)
        totalProtein = try c.value(.totalProtein, default: 0)
        totalFat = try c.value(.totalFat, default: 0)
        totalCalories = try c.value(.totalCalories, default: 0)
    }
}

public struct ActivityPayload: Codable, Equatable, Sendable {
    public var name: String
    public var durationMinutes: Double
    public var intensity: String
    public var note: String
    public var source: String
    public var sourceName: String?
    public var sourceKind: String?
    public var externalID: String?
    public var endedAt: String?
    public var activeEnergy: Double?
    public var distanceKm: Double?

    public init(name: String, durationMinutes: Double, intensity: String, note: String, source: String = "manual",
                sourceName: String? = nil, sourceKind: String? = nil, externalID: String? = nil, endedAt: String? = nil,
                activeEnergy: Double? = nil, distanceKm: Double? = nil) {
        self.name = name
        self.durationMinutes = durationMinutes
        self.intensity = intensity
        self.note = note
        self.source = source
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.externalID = externalID
        self.endedAt = endedAt
        self.activeEnergy = activeEnergy
        self.distanceKm = distanceKm
    }

    enum CodingKeys: String, CodingKey {
        case name, durationMinutes = "duration_minutes", intensity, note, source, sourceName = "source_name"
        case sourceKind = "source_kind", externalID = "external_id", endedAt = "ended_at"
        case activeEnergy = "active_energy", distanceKm = "distance_km"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.value(.name, default: "Активность")
        durationMinutes = try c.decode(Double.self, forKey: .durationMinutes)
        intensity = try c.value(.intensity, default: "unknown")
        note = try c.value(.note, default: "")
        source = try c.value(.source, default: "manual")
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        sourceKind = try c.decodeIfPresent(String.self, forKey: .sourceKind)
        externalID = try c.decodeIfPresent(String.self, forKey: .externalID)
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
        activeEnergy = try c.decodeIfPresent(Double.self, forKey: .activeEnergy)
        distanceKm = try c.decodeIfPresent(Double.self, forKey: .distanceKm)
    }

    public var isFromAppleHealth: Bool { source == "apple_health" }

    public static let intensityLabels: [String: String] = ["low": "Лёгкая", "moderate": "Умеренная", "high": "Высокая", "unknown": "Не указана"]
}

/// Daily Apple Health aggregate; never summed with workouts.
public struct ActivitySummaryPayload: Codable, Equatable, Sendable {
    public var name: String
    public var steps: Double?
    public var activeEnergy: Double?
    public var exerciseMinutes: Double?
    public var distanceKm: Double?
    public var energyUnit: String?
    public var source: String
    public var sourceKind: String?
    public var localDate: String?
    public var timezone: String?
    public var note: String

    enum CodingKeys: String, CodingKey {
        case name, steps, activeEnergy = "active_energy", exerciseMinutes = "exercise_minutes", distanceKm = "distance_km"
        case energyUnit = "energy_unit", source, sourceKind = "source_kind", localDate = "local_date", timezone, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.value(.name, default: "Активность за день")
        steps = try c.decodeIfPresent(Double.self, forKey: .steps)
        activeEnergy = try c.decodeIfPresent(Double.self, forKey: .activeEnergy)
        exerciseMinutes = try c.decodeIfPresent(Double.self, forKey: .exerciseMinutes)
        distanceKm = try c.decodeIfPresent(Double.self, forKey: .distanceKm)
        energyUnit = try c.decodeIfPresent(String.self, forKey: .energyUnit)
        source = try c.value(.source, default: "apple_health")
        sourceKind = try c.decodeIfPresent(String.self, forKey: .sourceKind)
        localDate = try c.decodeIfPresent(String.self, forKey: .localDate)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
        note = try c.value(.note, default: "")
    }
}

public struct NotePayload: Codable, Equatable, Sendable {
    public var note: String
    public init(note: String) { self.note = note }
}
