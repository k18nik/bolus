import Foundation

/// Platform-independent diary entry (`DiaryEntry` in SwiftData).
public struct DiaryRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Idempotency key of the creating action (also the HealthKit UUID for workouts).
    public var clientID: UUID
    public var kind: EntryKind
    public var occurredAt: Date
    /// Payload in the reference backend format (`value_mmol`, `total_carbs`, …).
    public var data: JSONValue
    public var createdAt: Date
    public var updatedAt: Date
    public var version: Int
    /// Stable external identity for deduplication (`healthkit-workout:<uuid>`,
    /// `healthkit-day:<date>`, `bolus:<calculation id>`).
    public var dedupeKey: String?

    public init(id: UUID = UUID(), clientID: UUID = UUID(), kind: EntryKind, occurredAt: Date, data: JSONValue,
                createdAt: Date = Date(), updatedAt: Date? = nil, version: Int = 1, dedupeKey: String? = nil) {
        self.id = id
        self.clientID = clientID
        self.kind = kind
        self.occurredAt = occurredAt
        self.data = data
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.version = version
        self.dedupeKey = dedupeKey
    }

    enum CodingKeys: String, CodingKey {
        case id, clientID = "client_id", kind, occurredAt = "occurred_at", data, createdAt = "created_at"
        case updatedAt = "updated_at", version, dedupeKey = "dedupe_key"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        clientID = try c.decode(UUID.self, forKey: .clientID)
        kind = try c.decode(EntryKind.self, forKey: .kind)
        occurredAt = try c.decode(ISODateString.self, forKey: .occurredAt).date
        data = try c.decode(JSONValue.self, forKey: .data)
        createdAt = try c.decode(ISODateString.self, forKey: .createdAt).date
        updatedAt = try c.decode(ISODateString.self, forKey: .updatedAt).date
        version = try c.value(.version, default: 1)
        dedupeKey = try c.decodeIfPresent(String.self, forKey: .dedupeKey)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(clientID, forKey: .clientID)
        try c.encode(kind, forKey: .kind)
        try c.encode(ISODateString(occurredAt), forKey: .occurredAt)
        try c.encode(data, forKey: .data)
        try c.encode(ISODateString(createdAt), forKey: .createdAt)
        try c.encode(ISODateString(updatedAt), forKey: .updatedAt)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(dedupeKey, forKey: .dedupeKey)
    }

    public var glucose: GlucosePayload? { kind == .glucose ? try? data.decode(GlucosePayload.self) : nil }
    public var insulin: InsulinPayload? { kind == .insulin ? try? data.decode(InsulinPayload.self) : nil }
    public var meal: MealPayload? { kind == .meal ? try? data.decode(MealPayload.self) : nil }
    public var activity: ActivityPayload? { kind == .activity ? try? data.decode(ActivityPayload.self) : nil }
    public var activitySummary: ActivitySummaryPayload? { kind == .activitySummary ? try? data.decode(ActivitySummaryPayload.self) : nil }
    public var note: NotePayload? { kind == .note ? try? data.decode(NotePayload.self) : nil }

    /// Free-text note of any entry type.
    public var noteText: String { data.string("note") ?? "" }
}

/// Confirmed therapy parameters (`therapy_profiles.data` in the backend).
public struct TherapySettings: Codable, Equatable, Sendable {
    public var diabetesType: String
    public var insulinTherapyType: String
    public var rapidInsulinName: String
    public var basalInsulinName: String
    public var bolusIncrement: Double
    public var basalIncrement: Double
    public var maxBolus: Double
    /// DIA, hours.
    public var insulinActionDuration: Double
    public var segments: [TherapySegment]
    public var confirmed: Bool

    public init(diabetesType: String = "type1", insulinTherapyType: String = "MDI", rapidInsulinName: String = "Фиасп",
                basalInsulinName: String = "Тресиба", bolusIncrement: Double = 1, basalIncrement: Double = 1,
                maxBolus: Double, insulinActionDuration: Double, segments: [TherapySegment], confirmed: Bool) {
        self.diabetesType = diabetesType
        self.insulinTherapyType = insulinTherapyType
        self.rapidInsulinName = rapidInsulinName
        self.basalInsulinName = basalInsulinName
        self.bolusIncrement = bolusIncrement
        self.basalIncrement = basalIncrement
        self.maxBolus = maxBolus
        self.insulinActionDuration = insulinActionDuration
        self.segments = segments
        self.confirmed = confirmed
    }

    enum CodingKeys: String, CodingKey {
        case diabetesType = "diabetes_type", insulinTherapyType = "insulin_therapy_type"
        case rapidInsulinName = "rapid_insulin_name", basalInsulinName = "basal_insulin_name"
        case bolusIncrement = "bolus_increment", basalIncrement = "basal_increment", maxBolus = "max_bolus"
        case insulinActionDuration = "insulin_action_duration", segments, confirmed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        diabetesType = try c.value(.diabetesType, default: "type1")
        insulinTherapyType = try c.value(.insulinTherapyType, default: "MDI")
        rapidInsulinName = try c.value(.rapidInsulinName, default: "")
        basalInsulinName = try c.value(.basalInsulinName, default: "")
        // Legacy profiles without a device step keep the original 0.1 U policy.
        bolusIncrement = try c.value(.bolusIncrement, default: BolusEngine.legacyIncrement)
        basalIncrement = try c.value(.basalIncrement, default: BolusEngine.legacyIncrement)
        maxBolus = try c.decode(Double.self, forKey: .maxBolus)
        insulinActionDuration = try c.decode(Double.self, forKey: .insulinActionDuration)
        segments = try c.decode([TherapySegment].self, forKey: .segments)
        confirmed = try c.value(.confirmed, default: false)
    }
}

public struct TherapyProfileRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var version: Int
    public var validFrom: Date
    public var validTo: Date?
    /// `active` or `archived`.
    public var status: String
    public var source: String
    public var settings: TherapySettings

    public init(id: UUID = UUID(), version: Int, validFrom: Date, validTo: Date? = nil, status: String = "active",
                source: String = "manual", settings: TherapySettings) {
        self.id = id
        self.version = version
        self.validFrom = validFrom
        self.validTo = validTo
        self.status = status
        self.source = source
        self.settings = settings
    }

    public var isActive: Bool { status == "active" }

    enum CodingKeys: String, CodingKey { case id, version, validFrom = "valid_from", validTo = "valid_to", status, source, settings = "data" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        version = try c.decode(Int.self, forKey: .version)
        validFrom = try c.decode(ISODateString.self, forKey: .validFrom).date
        validTo = try c.decodeIfPresent(ISODateString.self, forKey: .validTo)?.date
        status = try c.value(.status, default: validTo == nil ? "active" : "archived")
        source = try c.value(.source, default: "manual")
        settings = try c.decode(TherapySettings.self, forKey: .settings)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(version, forKey: .version)
        try c.encode(ISODateString(validFrom), forKey: .validFrom)
        try c.encodeIfPresent(validTo.map(ISODateString.init), forKey: .validTo)
        try c.encode(status, forKey: .status)
        try c.encode(source, forKey: .source)
        try c.encode(settings, forKey: .settings)
    }
}

public struct BolusCalculationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var calculatedAt: Date
    public var inputSnapshot: JSONValue
    public var calculationSnapshot: JSONValue
    /// Actually administered dose, stored separately from the recommendation.
    public var actualBolus: Double?
    public var confirmedEntryID: UUID?
    public var algorithmVersion: String

    public init(id: UUID = UUID(), calculatedAt: Date, inputSnapshot: JSONValue, calculationSnapshot: JSONValue,
                actualBolus: Double? = nil, confirmedEntryID: UUID? = nil, algorithmVersion: String = BolusEngine.algorithmVersion) {
        self.id = id
        self.calculatedAt = calculatedAt
        self.inputSnapshot = inputSnapshot
        self.calculationSnapshot = calculationSnapshot
        self.actualBolus = actualBolus
        self.confirmedEntryID = confirmedEntryID
        self.algorithmVersion = algorithmVersion
    }

    public var result: BolusEngine.Result? { try? calculationSnapshot.decode(BolusEngine.Result.self) }
    public var input: BolusInputSnapshot? { try? inputSnapshot.decode(BolusInputSnapshot.self) }

    enum CodingKeys: String, CodingKey {
        case id, calculatedAt = "calculated_at", inputSnapshot = "input_snapshot", calculationSnapshot = "calculation_snapshot"
        case actualBolus = "actual_bolus", confirmedEntryID = "confirmed_entry_id", algorithmVersion = "algorithm_version"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        calculatedAt = try c.decode(ISODateString.self, forKey: .calculatedAt).date
        inputSnapshot = try c.decode(JSONValue.self, forKey: .inputSnapshot)
        calculationSnapshot = try c.decode(JSONValue.self, forKey: .calculationSnapshot)
        actualBolus = try c.decodeIfPresent(Double.self, forKey: .actualBolus)
        confirmedEntryID = try c.decodeIfPresent(UUID.self, forKey: .confirmedEntryID)
        algorithmVersion = try c.value(.algorithmVersion, default: BolusEngine.algorithmVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ISODateString(calculatedAt), forKey: .calculatedAt)
        try c.encode(inputSnapshot, forKey: .inputSnapshot)
        try c.encode(calculationSnapshot, forKey: .calculationSnapshot)
        try c.encodeIfPresent(actualBolus, forKey: .actualBolus)
        try c.encodeIfPresent(confirmedEntryID, forKey: .confirmedEntryID)
        try c.encode(algorithmVersion, forKey: .algorithmVersion)
    }
}

/// Full input snapshot of a calculation (keys of the backend `inputs` dict).
public struct BolusInputSnapshot: Codable, Equatable, Sendable {
    public var glucose: Double?
    public var unit: String
    public var originalUnit: String
    public var originalGlucose: Double?
    public var carbs: Double
    public var startTime: String
    public var endTime: String
    public var icr: Double
    public var isf: Double
    public var target: Double
    public var correctAbove: Double
    public var dia: Double
    public var maxBolus: Double
    public var iob: Double
    public var measuredAt: String?
    public var calculatedAt: String
    public var timezone: String
    public var profileID: String
    public var profileVersion: Int
    public var mealID: String?
    public var iobModel: String
    public var bolusIncrement: Double?
    public var rapidInsulinName: String
    public var basalInsulinName: String
    public var insulinID: String
    public var activeIngredient: String
    public var insulinType: String

    enum CodingKeys: String, CodingKey {
        case glucose, unit, originalUnit = "original_unit", originalGlucose = "original_glucose", carbs
        case startTime = "start_time", endTime = "end_time", icr, isf, target, correctAbove = "correct_above", dia
        case maxBolus = "max_bolus", iob, measuredAt = "measured_at", calculatedAt = "calculated_at", timezone
        case profileID = "profile_id", profileVersion = "profile_version", mealID = "meal_id", iobModel = "iob_model"
        case bolusIncrement = "bolus_increment", rapidInsulinName = "rapid_insulin_name", basalInsulinName = "basal_insulin_name"
        case insulinID = "insulin_id", activeIngredient = "active_ingredient", insulinType = "insulin_type"
    }

    public init(glucose: Double?, unit: String, originalUnit: String, originalGlucose: Double?, carbs: Double, startTime: String,
                endTime: String, icr: Double, isf: Double, target: Double, correctAbove: Double, dia: Double, maxBolus: Double,
                iob: Double, measuredAt: String?, calculatedAt: String, timezone: String, profileID: String, profileVersion: Int,
                mealID: String?, iobModel: String, bolusIncrement: Double?, rapidInsulinName: String, basalInsulinName: String,
                insulinID: String, activeIngredient: String, insulinType: String) {
        self.glucose = glucose
        self.unit = unit
        self.originalUnit = originalUnit
        self.originalGlucose = originalGlucose
        self.carbs = carbs
        self.startTime = startTime
        self.endTime = endTime
        self.icr = icr
        self.isf = isf
        self.target = target
        self.correctAbove = correctAbove
        self.dia = dia
        self.maxBolus = maxBolus
        self.iob = iob
        self.measuredAt = measuredAt
        self.calculatedAt = calculatedAt
        self.timezone = timezone
        self.profileID = profileID
        self.profileVersion = profileVersion
        self.mealID = mealID
        self.iobModel = iobModel
        self.bolusIncrement = bolusIncrement
        self.rapidInsulinName = rapidInsulinName
        self.basalInsulinName = basalInsulinName
        self.insulinID = insulinID
        self.activeIngredient = activeIngredient
        self.insulinType = insulinType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        glucose = try c.decodeIfPresent(Double.self, forKey: .glucose)
        unit = try c.value(.unit, default: "mmol/L")
        originalUnit = try c.value(.originalUnit, default: unit)
        originalGlucose = try c.decodeIfPresent(Double.self, forKey: .originalGlucose)
        carbs = try c.decode(Double.self, forKey: .carbs)
        startTime = try c.value(.startTime, default: "00:00")
        endTime = try c.value(.endTime, default: "24:00")
        icr = try c.decode(Double.self, forKey: .icr)
        isf = try c.decode(Double.self, forKey: .isf)
        target = try c.decode(Double.self, forKey: .target)
        correctAbove = try c.decode(Double.self, forKey: .correctAbove)
        dia = try c.decode(Double.self, forKey: .dia)
        maxBolus = try c.decode(Double.self, forKey: .maxBolus)
        iob = try c.value(.iob, default: 0)
        measuredAt = try c.decodeIfPresent(String.self, forKey: .measuredAt)
        calculatedAt = try c.value(.calculatedAt, default: "")
        timezone = try c.value(.timezone, default: "UTC")
        profileID = try c.value(.profileID, default: "")
        profileVersion = try c.value(.profileVersion, default: 0)
        mealID = try c.decodeIfPresent(String.self, forKey: .mealID)
        iobModel = try c.value(.iobModel, default: IOBEngine.modelVersion)
        bolusIncrement = try c.decodeIfPresent(Double.self, forKey: .bolusIncrement)
        rapidInsulinName = try c.value(.rapidInsulinName, default: "")
        basalInsulinName = try c.value(.basalInsulinName, default: "")
        insulinID = try c.value(.insulinID, default: "custom")
        activeIngredient = try c.value(.activeIngredient, default: "")
        insulinType = try c.value(.insulinType, default: "rapid")
    }
}

public struct NutrientTotals: Codable, Equatable, Sendable {
    public var carbs: Double?
    public var protein: Double?
    public var fat: Double?
    public var calories: Double?
    public var fiber: Double?
    public var sugar: Double?

    public init(carbs: Double?, protein: Double?, fat: Double?, calories: Double?, fiber: Double?, sugar: Double?) {
        self.carbs = carbs
        self.protein = protein
        self.fat = fat
        self.calories = calories
        self.fiber = fiber
        self.sugar = sugar
    }
}

public struct RecipeDefinition: Codable, Equatable, Sendable {
    public var ingredients: [MealItem]
    public var cookedWeight: Double
    public var servings: Int
    public var total: NutrientTotals
    public var perServing: NutrientTotals

    enum CodingKeys: String, CodingKey { case ingredients, cookedWeight = "cooked_weight", servings, total, perServing = "per_serving" }

    public init(ingredients: [MealItem], cookedWeight: Double, servings: Int, total: NutrientTotals, perServing: NutrientTotals) {
        self.ingredients = ingredients
        self.cookedWeight = cookedWeight
        self.servings = servings
        self.total = total
        self.perServing = perServing
    }
}

/// Local food: custom product, saved catalog product (YAZIO/USDA) or recipe.
/// Nutrients are given for one serving of `servingWeight` (`baseUnit` g or ml).
public struct FoodRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var brand: String
    /// `custom`, `yazio`, `usda`, `recipe`.
    public var source: String
    public var externalID: String?
    public var baseUnit: String
    public var servingName: String
    public var servingWeight: Double
    public var carbs: Double
    public var protein: Double
    public var fat: Double
    public var calories: Double
    public var fiber: Double?
    public var sugar: Double?
    public var barcode: String?
    public var isFavorite: Bool
    public var isRecipe: Bool
    public var recipe: RecipeDefinition?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), name: String, brand: String = "", source: String = "custom", externalID: String? = nil,
                baseUnit: String = "g", servingName: String = "100 г", servingWeight: Double = 100, carbs: Double,
                protein: Double = 0, fat: Double = 0, calories: Double = 0, fiber: Double? = nil, sugar: Double? = nil,
                barcode: String? = nil, isFavorite: Bool = false, isRecipe: Bool = false, recipe: RecipeDefinition? = nil,
                createdAt: Date = Date(), updatedAt: Date? = nil, lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.brand = brand
        self.source = source
        self.externalID = externalID
        self.baseUnit = baseUnit
        self.servingName = servingName
        self.servingWeight = servingWeight
        self.carbs = carbs
        self.protein = protein
        self.fat = fat
        self.calories = calories
        self.fiber = fiber
        self.sugar = sugar
        self.barcode = barcode
        self.isFavorite = isFavorite
        self.isRecipe = isRecipe
        self.recipe = recipe
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, brand, source, externalID = "external_id", baseUnit = "base_unit", servingName = "serving_name"
        case servingWeight = "serving_weight", carbs, protein, fat, calories, fiber, sugar, barcode
        case isFavorite = "is_favorite", isRecipe = "is_recipe", recipe, createdAt = "created_at", updatedAt = "updated_at"
        case lastUsedAt = "last_used_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        brand = try c.value(.brand, default: "")
        source = try c.value(.source, default: "custom")
        externalID = try c.decodeIfPresent(String.self, forKey: .externalID)
        baseUnit = try c.value(.baseUnit, default: "g")
        servingName = try c.value(.servingName, default: baseUnit == "ml" ? "100 мл" : "100 г")
        servingWeight = try c.value(.servingWeight, default: 100)
        carbs = try c.decode(Double.self, forKey: .carbs)
        protein = try c.value(.protein, default: 0)
        fat = try c.value(.fat, default: 0)
        calories = try c.value(.calories, default: 0)
        fiber = try c.decodeIfPresent(Double.self, forKey: .fiber)
        sugar = try c.decodeIfPresent(Double.self, forKey: .sugar)
        barcode = try c.decodeIfPresent(String.self, forKey: .barcode)
        isFavorite = try c.value(.isFavorite, default: false)
        isRecipe = try c.value(.isRecipe, default: false)
        recipe = try c.decodeIfPresent(RecipeDefinition.self, forKey: .recipe)
        createdAt = try c.decodeIfPresent(ISODateString.self, forKey: .createdAt)?.date ?? Date(timeIntervalSince1970: 0)
        updatedAt = try c.decodeIfPresent(ISODateString.self, forKey: .updatedAt)?.date ?? createdAt
        lastUsedAt = try c.decodeIfPresent(ISODateString.self, forKey: .lastUsedAt)?.date
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(brand, forKey: .brand)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(externalID, forKey: .externalID)
        try c.encode(baseUnit, forKey: .baseUnit)
        try c.encode(servingName, forKey: .servingName)
        try c.encode(servingWeight, forKey: .servingWeight)
        try c.encode(carbs, forKey: .carbs)
        try c.encode(protein, forKey: .protein)
        try c.encode(fat, forKey: .fat)
        try c.encode(calories, forKey: .calories)
        try c.encode(fiber, forKey: .fiber)
        try c.encode(sugar, forKey: .sugar)
        try c.encodeIfPresent(barcode, forKey: .barcode)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(isRecipe, forKey: .isRecipe)
        try c.encodeIfPresent(recipe, forKey: .recipe)
        try c.encode(ISODateString(createdAt), forKey: .createdAt)
        try c.encode(ISODateString(updatedAt), forKey: .updatedAt)
        try c.encodeIfPresent(lastUsedAt.map(ISODateString.init), forKey: .lastUsedAt)
    }

    /// Identity used for favorites and recents (`provider:external_id`).
    public var catalogKey: String { source + ":" + (externalID ?? id.uuidString.lowercased()) }
    public var unitLabel: String { baseUnit == "ml" ? "мл" : "г" }
}

public struct CycleRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startDate: LocalDate
    public var endDate: LocalDate?
    public var cycleLength: Int
    public var actualOvulationDate: LocalDate?
    public var createdAt: Date

    public init(id: UUID = UUID(), startDate: LocalDate, endDate: LocalDate? = nil, cycleLength: Int = 28,
                actualOvulationDate: LocalDate? = nil, createdAt: Date = Date()) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.cycleLength = cycleLength
        self.actualOvulationDate = actualOvulationDate
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, startDate = "start_date", endDate = "end_date", cycleLength = "cycle_length"
        case actualOvulationDate = "actual_ovulation_date", createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startDate = try c.decode(LocalDate.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(LocalDate.self, forKey: .endDate)
        cycleLength = try c.value(.cycleLength, default: 28)
        actualOvulationDate = try c.decodeIfPresent(LocalDate.self, forKey: .actualOvulationDate)
        createdAt = try c.decodeIfPresent(ISODateString.self, forKey: .createdAt)?.date ?? startDate.startOfDay(in: TimeZone(identifier: "UTC")!)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startDate, forKey: .startDate)
        try c.encodeIfPresent(endDate, forKey: .endDate)
        try c.encode(cycleLength, forKey: .cycleLength)
        try c.encodeIfPresent(actualOvulationDate, forKey: .actualOvulationDate)
        try c.encode(ISODateString(createdAt), forKey: .createdAt)
    }

    public func status(today: LocalDate) -> CycleStatus {
        CycleEngine.status(start: startDate, length: cycleLength, today: today, actualOvulation: actualOvulationDate)
    }
}

public struct AIInsightRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var question: String
    public var response: JSONValue
    public var context: JSONValue
    public var provider: String
    public var model: String
    public var usage: JSONValue
    public var calculationID: UUID?

    public init(id: UUID = UUID(), createdAt: Date = Date(), question: String, response: JSONValue, context: JSONValue,
                provider: String, model: String, usage: JSONValue, calculationID: UUID? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.question = question
        self.response = response
        self.context = context
        self.provider = provider
        self.model = model
        self.usage = usage
        self.calculationID = calculationID
    }

    enum CodingKeys: String, CodingKey {
        case id, createdAt = "created_at", question, response, context, provider, model, usage, calculationID = "calculation_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(ISODateString.self, forKey: .createdAt).date
        question = try c.value(.question, default: "")
        response = try c.value(.response, default: JSONValue.null)
        context = try c.value(.context, default: JSONValue.null)
        provider = try c.value(.provider, default: "openai")
        model = try c.value(.model, default: "")
        usage = try c.value(.usage, default: JSONValue.object([:]))
        calculationID = try c.decodeIfPresent(UUID.self, forKey: .calculationID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ISODateString(createdAt), forKey: .createdAt)
        try c.encode(question, forKey: .question)
        try c.encode(response, forKey: .response)
        try c.encode(context, forKey: .context)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
        try c.encode(usage, forKey: .usage)
        try c.encodeIfPresent(calculationID, forKey: .calculationID)
    }

    public var totalTokens: Int { Self.tokenCount(usage) }

    /// Token count reported by the provider; anything that is not a sane whole number counts as 0.
    public static func tokenCount(_ usage: JSONValue) -> Int {
        guard let value = usage.double("total_tokens"), value >= 0, value < 1e12, let count = Int(exactly: value.rounded()) else { return 0 }
        return count
    }
}

public struct AuditRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var action: String
    public var entityType: String
    public var entityID: String
    public var details: JSONValue?

    public init(id: UUID = UUID(), timestamp: Date = Date(), action: String, entityType: String, entityID: String, details: JSONValue? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.entityType = entityType
        self.entityID = entityID
        self.details = details
    }

    enum CodingKeys: String, CodingKey { case id, timestamp, action, entityType = "entity_type", entityID = "entity_id", details }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(ISODateString.self, forKey: .timestamp).date
        action = try c.decode(String.self, forKey: .action)
        entityType = try c.value(.entityType, default: "")
        entityID = try c.value(.entityID, default: "")
        details = try c.decodeIfPresent(JSONValue.self, forKey: .details)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ISODateString(timestamp), forKey: .timestamp)
        try c.encode(action, forKey: .action)
        try c.encode(entityType, forKey: .entityType)
        try c.encode(entityID, forKey: .entityID)
        try c.encodeIfPresent(details, forKey: .details)
    }
}

/// User preferences (no account, no secrets: API keys live only in the Keychain).
public struct AppPreferences: Codable, Equatable, Sendable {
    public var name: String
    /// Empty = follow the device time zone.
    public var timezoneIdentifier: String
    public var glucoseUnit: GlucoseUnit
    public var themeID: String
    public var mascotID: String
    public var appLockEnabled: Bool
    public var aiProvider: String
    public var aiModel: String
    public var aiConsent: Bool
    public var onboardingCompleted: Bool
    public var yazioEnabled: Bool
    public var yazioCountry: String
    public var yazioLocale: String
    public var usdaEnabled: Bool
    /// The home-screen icon follows the colour of the theme.
    public var iconFollowsTheme: Bool
    /// Apple Health is read automatically (launch, foreground, HealthKit background delivery).
    public var healthAutoSync: Bool
    public var healthLastSync: Date?

    public init(name: String = "Мой дневник", timezoneIdentifier: String = "", glucoseUnit: GlucoseUnit = .mmol,
                themeID: String = "light", mascotID: String = "cat", appLockEnabled: Bool = false, aiProvider: String = "openai",
                aiModel: String = "gpt-4.1-mini", aiConsent: Bool = false, onboardingCompleted: Bool = false,
                yazioEnabled: Bool = true, yazioCountry: String = "RU", yazioLocale: String = "ru_RU", usdaEnabled: Bool = false,
                iconFollowsTheme: Bool = false, healthAutoSync: Bool = false, healthLastSync: Date? = nil) {
        self.name = name
        self.timezoneIdentifier = timezoneIdentifier
        self.glucoseUnit = glucoseUnit
        self.themeID = themeID
        self.mascotID = mascotID
        self.appLockEnabled = appLockEnabled
        self.aiProvider = aiProvider
        self.aiModel = aiModel
        self.aiConsent = aiConsent
        self.onboardingCompleted = onboardingCompleted
        self.yazioEnabled = yazioEnabled
        self.yazioCountry = yazioCountry
        self.yazioLocale = yazioLocale
        self.usdaEnabled = usdaEnabled
        self.iconFollowsTheme = iconFollowsTheme
        self.healthAutoSync = healthAutoSync
        self.healthLastSync = healthLastSync
    }

    enum CodingKeys: String, CodingKey {
        case name, timezoneIdentifier = "timezone", glucoseUnit = "glucose_unit", themeID = "theme_id", mascotID = "mascot_id"
        case appLockEnabled = "app_lock_enabled", aiProvider = "ai_provider", aiModel = "ai_model", aiConsent = "ai_consent"
        case onboardingCompleted = "onboarding_completed", yazioEnabled = "yazio_enabled", yazioCountry = "yazio_country"
        case yazioLocale = "yazio_locale", usdaEnabled = "usda_enabled", iconFollowsTheme = "icon_follows_theme"
        case healthAutoSync = "health_auto_sync", healthLastSync = "health_last_sync"
    }

    public init(from decoder: Decoder) throws {
        let defaults = AppPreferences()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.value(.name, default: defaults.name)
        timezoneIdentifier = try c.value(.timezoneIdentifier, default: defaults.timezoneIdentifier)
        glucoseUnit = try c.value(.glucoseUnit, default: defaults.glucoseUnit)
        themeID = try c.value(.themeID, default: defaults.themeID)
        let mascot = try c.value(.mascotID, default: defaults.mascotID)
        // The rabbit was replaced by the frog; older settings and server copies keep working.
        mascotID = mascot == "rabbit" ? "frog" : mascot
        appLockEnabled = try c.value(.appLockEnabled, default: defaults.appLockEnabled)
        aiProvider = try c.value(.aiProvider, default: defaults.aiProvider)
        aiModel = try c.value(.aiModel, default: defaults.aiModel)
        aiConsent = try c.value(.aiConsent, default: defaults.aiConsent)
        onboardingCompleted = try c.value(.onboardingCompleted, default: defaults.onboardingCompleted)
        yazioEnabled = try c.value(.yazioEnabled, default: defaults.yazioEnabled)
        yazioCountry = try c.value(.yazioCountry, default: defaults.yazioCountry)
        yazioLocale = try c.value(.yazioLocale, default: defaults.yazioLocale)
        usdaEnabled = try c.value(.usdaEnabled, default: defaults.usdaEnabled)
        iconFollowsTheme = try c.value(.iconFollowsTheme, default: defaults.iconFollowsTheme)
        healthAutoSync = try c.value(.healthAutoSync, default: defaults.healthAutoSync)
        healthLastSync = try c.decodeIfPresent(ISODateString.self, forKey: .healthLastSync)?.date
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(timezoneIdentifier, forKey: .timezoneIdentifier)
        try c.encode(glucoseUnit, forKey: .glucoseUnit)
        try c.encode(themeID, forKey: .themeID)
        try c.encode(mascotID, forKey: .mascotID)
        try c.encode(appLockEnabled, forKey: .appLockEnabled)
        try c.encode(aiProvider, forKey: .aiProvider)
        try c.encode(aiModel, forKey: .aiModel)
        try c.encode(aiConsent, forKey: .aiConsent)
        try c.encode(onboardingCompleted, forKey: .onboardingCompleted)
        try c.encode(yazioEnabled, forKey: .yazioEnabled)
        try c.encode(yazioCountry, forKey: .yazioCountry)
        try c.encode(yazioLocale, forKey: .yazioLocale)
        try c.encode(usdaEnabled, forKey: .usdaEnabled)
        try c.encode(iconFollowsTheme, forKey: .iconFollowsTheme)
        try c.encode(healthAutoSync, forKey: .healthAutoSync)
        try c.encodeIfPresent(healthLastSync.map(ISODateString.init), forKey: .healthLastSync)
    }

    public func timeZone(device: TimeZone = .current) -> TimeZone {
        timezoneIdentifier.isEmpty ? device : (TimeZone(identifier: timezoneIdentifier) ?? device)
    }

    public static let themes: [(id: String, name: String)] = [
        ("light", "Minimal Light"), ("dark", "Minimal Dark"), ("cat", "Cat Café"),
        ("pink", "Pink Pastel"), ("dino", "Dino"), ("oled", "OLED Black"), ("lilac", "Lilac"),
    ]

    public static let mascots: [(id: String, emoji: String, name: String)] = [
        ("cat", "🐱", "Кот"), ("siamese", "🐈", "Сиамский кот"), ("pig", "🐷", "Поросёнок"), ("dinosaur", "🦕", "Динозавр"),
        ("frog", "🐸", "Лягушка"), ("otter", "🦦", "Выдра"), ("panda", "🐼", "Панда"),
    ]
}
