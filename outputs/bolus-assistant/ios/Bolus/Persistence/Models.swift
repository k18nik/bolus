import Foundation
import SwiftData

// Local SwiftData store — the only source of truth of the app.
//
// CloudKit readiness: no unique constraints, every attribute has a default value and
// there are no required relationships. Uniqueness (client IDs, HealthKit UUIDs,
// confirmations) is enforced by `DiaryStore` before inserting.

@Model
final class DiaryEntry {
    var id: UUID = UUID()
    var clientID: UUID = UUID()
    /// `EntryKind` raw value: glucose, insulin, meal, activity, activity_summary, note.
    var kind: String = "note"
    var occurredAt: Date = Date()
    /// JSON payload in the reference backend format.
    var data: Data = Data()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var version: Int = 1
    /// External identity for deduplication (HealthKit UUID, bolus confirmation).
    var dedupeKey: String?

    init(record: DiaryRecord) {
        id = record.id
        clientID = record.clientID
        kind = record.kind.rawValue
        occurredAt = record.occurredAt
        data = BolusJSON.data(record.data)
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        version = record.version
        dedupeKey = record.dedupeKey
    }

    func update(from record: DiaryRecord) {
        kind = record.kind.rawValue
        occurredAt = record.occurredAt
        data = BolusJSON.data(record.data)
        updatedAt = record.updatedAt
        version = record.version
        dedupeKey = record.dedupeKey
    }

    var record: DiaryRecord? {
        guard let entryKind = EntryKind(rawValue: kind) else { return nil }
        return DiaryRecord(id: id, clientID: clientID, kind: entryKind, occurredAt: occurredAt, data: BolusJSON.value(data),
                           createdAt: createdAt, updatedAt: updatedAt, version: version, dedupeKey: dedupeKey)
    }
}

/// Versioned therapy profile. ICR, ISF, target and correction threshold are stored per
/// time segment (`segmentsData`); historical versions are never modified.
@Model
final class TherapyProfile {
    var id: UUID = UUID()
    var version: Int = 1
    var validFrom: Date = Date()
    var validTo: Date?
    /// `active` or `archived`.
    var status: String = "active"
    var source: String = "manual"
    var diabetesType: String = "type1"
    /// Insulin therapy: MDI, PUMP or OTHER.
    var insulinTherapyType: String = "MDI"
    var rapidInsulinName: String = ""
    var basalInsulinName: String = ""
    var bolusIncrement: Double = 1
    var basalIncrement: Double = 1
    var maxBolus: Double = 0
    /// DIA, hours.
    var dia: Double = 4
    /// JSON `[TherapySegment]`.
    var segmentsData: Data = Data()
    var confirmed: Bool = false

    init(record: TherapyProfileRecord) {
        id = record.id
        version = record.version
        validFrom = record.validFrom
        validTo = record.validTo
        status = record.status
        source = record.source
        diabetesType = record.settings.diabetesType
        insulinTherapyType = record.settings.insulinTherapyType
        rapidInsulinName = record.settings.rapidInsulinName
        basalInsulinName = record.settings.basalInsulinName
        bolusIncrement = record.settings.bolusIncrement
        basalIncrement = record.settings.basalIncrement
        maxBolus = record.settings.maxBolus
        dia = record.settings.insulinActionDuration
        segmentsData = (try? BolusJSON.encoder.encode(record.settings.segments)) ?? Data()
        confirmed = record.settings.confirmed
    }

    /// Only status and validity end change when a newer version is saved.
    func archive(at date: Date) {
        status = "archived"
        validTo = date
    }

    var segments: [TherapySegment] { (try? BolusJSON.decoder.decode([TherapySegment].self, from: segmentsData)) ?? [] }

    var record: TherapyProfileRecord {
        let settings = TherapySettings(diabetesType: diabetesType, insulinTherapyType: insulinTherapyType, rapidInsulinName: rapidInsulinName,
                                       basalInsulinName: basalInsulinName, bolusIncrement: bolusIncrement, basalIncrement: basalIncrement,
                                       maxBolus: maxBolus, insulinActionDuration: dia, segments: segments, confirmed: confirmed)
        return TherapyProfileRecord(id: id, version: version, validFrom: validFrom, validTo: validTo, status: status, source: source, settings: settings)
    }
}

@Model
final class BolusCalculation {
    var id: UUID = UUID()
    var calculatedAt: Date = Date()
    /// Immutable JSON snapshot of all inputs (profile values, IOB, glucose, carbs).
    var inputSnapshot: Data = Data()
    /// Immutable JSON result of the deterministic engine.
    var calculationSnapshot: Data = Data()
    /// Actually administered dose, stored separately from the recommendation.
    var actualBolus: Double?
    var confirmedEntryID: UUID?
    var algorithmVersion: String = "bolus-v1.1.0"

    init(record: BolusCalculationRecord) {
        id = record.id
        calculatedAt = record.calculatedAt
        inputSnapshot = BolusJSON.data(record.inputSnapshot)
        calculationSnapshot = BolusJSON.data(record.calculationSnapshot)
        actualBolus = record.actualBolus
        confirmedEntryID = record.confirmedEntryID
        algorithmVersion = record.algorithmVersion
    }

    var record: BolusCalculationRecord {
        BolusCalculationRecord(id: id, calculatedAt: calculatedAt, inputSnapshot: BolusJSON.value(inputSnapshot),
                               calculationSnapshot: BolusJSON.value(calculationSnapshot), actualBolus: actualBolus,
                               confirmedEntryID: confirmedEntryID, algorithmVersion: algorithmVersion)
    }
}

/// Custom products, saved catalog products (YAZIO/USDA) and recipes.
@Model
final class Food {
    var id: UUID = UUID()
    var name: String = ""
    var brand: String = ""
    var source: String = "custom"
    var externalID: String?
    var baseUnit: String = "g"
    var servingName: String = "100 г"
    /// Serving weight in grams (or ml for liquids) the nutrients refer to.
    var servingWeight: Double = 100
    var carbs: Double = 0
    var protein: Double = 0
    var fat: Double = 0
    var calories: Double = 0
    var fiber: Double?
    var sugar: Double?
    var barcode: String?
    var isFavorite: Bool = false
    var isRecipe: Bool = false
    /// JSON `RecipeDefinition` for recipes.
    var recipeData: Data?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastUsedAt: Date?

    init(record: FoodRecord) {
        id = record.id
        name = record.name
        brand = record.brand
        source = record.source
        externalID = record.externalID
        baseUnit = record.baseUnit
        servingName = record.servingName
        servingWeight = record.servingWeight
        carbs = record.carbs
        protein = record.protein
        fat = record.fat
        calories = record.calories
        fiber = record.fiber
        sugar = record.sugar
        barcode = record.barcode
        isFavorite = record.isFavorite
        isRecipe = record.isRecipe
        recipeData = record.recipe.flatMap { try? BolusJSON.encoder.encode($0) }
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        lastUsedAt = record.lastUsedAt
    }

    var record: FoodRecord {
        FoodRecord(id: id, name: name, brand: brand, source: source, externalID: externalID, baseUnit: baseUnit, servingName: servingName,
                   servingWeight: servingWeight, carbs: carbs, protein: protein, fat: fat, calories: calories, fiber: fiber, sugar: sugar,
                   barcode: barcode, isFavorite: isFavorite, isRecipe: isRecipe,
                   recipe: recipeData.flatMap { try? BolusJSON.decoder.decode(RecipeDefinition.self, from: $0) },
                   createdAt: createdAt, updatedAt: updatedAt, lastUsedAt: lastUsedAt)
    }
}

@Model
final class Cycle {
    var id: UUID = UUID()
    /// Calendar dates as `yyyy-MM-dd` (time-zone independent).
    var startDate: String = ""
    var endDate: String?
    var cycleLength: Int = 28
    var actualOvulationDate: String?
    var createdAt: Date = Date()

    init(record: CycleRecord) {
        id = record.id
        startDate = record.startDate.description
        endDate = record.endDate?.description
        cycleLength = record.cycleLength
        actualOvulationDate = record.actualOvulationDate?.description
        createdAt = record.createdAt
    }

    func update(from record: CycleRecord) {
        startDate = record.startDate.description
        endDate = record.endDate?.description
        cycleLength = record.cycleLength
        actualOvulationDate = record.actualOvulationDate?.description
    }

    var record: CycleRecord? {
        guard let start = LocalDate(iso: startDate) else { return nil }
        return CycleRecord(id: id, startDate: start, endDate: endDate.flatMap { LocalDate(iso: $0) }, cycleLength: cycleLength,
                           actualOvulationDate: actualOvulationDate.flatMap { LocalDate(iso: $0) }, createdAt: createdAt)
    }
}

/// Local history of AI analyses (question, validated answer, sent context, token usage).
@Model
final class AIInsight {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var question: String = ""
    var responseData: Data = Data()
    var contextData: Data = Data()
    var provider: String = "openai"
    var modelName: String = ""
    var usageData: Data = Data()
    var calculationID: UUID?

    init(record: AIInsightRecord) {
        id = record.id
        createdAt = record.createdAt
        question = record.question
        responseData = BolusJSON.data(record.response)
        contextData = BolusJSON.data(record.context)
        provider = record.provider
        modelName = record.model
        usageData = BolusJSON.data(record.usage)
        calculationID = record.calculationID
    }

    var record: AIInsightRecord {
        AIInsightRecord(id: id, createdAt: createdAt, question: question, response: BolusJSON.value(responseData),
                        context: BolusJSON.value(contextData), provider: provider, model: modelName, usage: BolusJSON.value(usageData),
                        calculationID: calculationID)
    }
}

@Model
final class AuditEvent {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var action: String = ""
    var entityType: String = ""
    var entityID: String = ""
    var details: Data?

    init(record: AuditRecord) {
        id = record.id
        timestamp = record.timestamp
        action = record.action
        entityType = record.entityType
        entityID = record.entityID
        details = record.details.map { BolusJSON.data($0) }
    }

    var record: AuditRecord {
        AuditRecord(id: id, timestamp: timestamp, action: action, entityType: entityType, entityID: entityID,
                    details: details.map { BolusJSON.value($0) })
    }
}

/// Single row with user preferences (JSON `AppPreferences`). Secrets are never stored here.
@Model
final class AppSettings {
    var id: UUID = UUID()
    var payload: Data = Data()
    var updatedAt: Date = Date()

    init(preferences: AppPreferences) {
        payload = (try? BolusJSON.encoder.encode(preferences)) ?? Data()
        updatedAt = Date()
    }

    var preferences: AppPreferences {
        (try? BolusJSON.decoder.decode(AppPreferences.self, from: payload)) ?? AppPreferences()
    }
}

/// Versioned schema so future model changes (and CloudKit) get explicit migrations.
enum BolusSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [DiaryEntry.self, TherapyProfile.self, BolusCalculation.self, Food.self, Cycle.self, AIInsight.self, AuditEvent.self, AppSettings.self]
    }
}

enum BolusMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [BolusSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum PersistenceController {
    /// Local-only store in Application Support. CloudKit is explicitly disabled for now.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: BolusSchemaV1.self)
        let configuration = ModelConfiguration("Bolus", schema: schema, isStoredInMemoryOnly: inMemory, allowsSave: true,
                                               groupContainer: .none, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: BolusMigrationPlan.self, configurations: [configuration])
    }

    /// Store at an explicit file URL (used by persistence tests to simulate an app restart).
    static func makeContainer(url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: BolusSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: BolusMigrationPlan.self, configurations: [configuration])
    }
}
