import Foundation
import SwiftData
import Observation

/// Local use cases on top of SwiftData. Validation and deterministic calculations come
/// from BolusCore; this type only fetches, persists and publishes changes.
/// Nothing here depends on the network: diary, profile, bolus, IOB, analytics and
/// backups work in Airplane Mode.
@MainActor
@Observable
final class DiaryStore {
    let container: ModelContainer
    /// Incremented after every successful save; views read it to refresh.
    private(set) var revision = 0
    private(set) var preferences = AppPreferences()

    init(container: ModelContainer) {
        self.container = container
        preferences = settingsRow()?.preferences ?? AppPreferences()
    }

    var context: ModelContext { container.mainContext }
    var timeZone: TimeZone { preferences.timeZone() }
    var unit: GlucoseUnit { preferences.glucoseUnit }
    var today: LocalDate { LocalDate.today(in: timeZone) }

    func factory(now: Date = Date()) -> EntryFactory { EntryFactory(now: now, timeZone: timeZone) }

    // MARK: - Persistence helpers

    private func commit() throws {
        do {
            try context.save()
            revision += 1
        } catch {
            context.rollback()
            throw BolusError.validation("Не удалось сохранить данные на устройстве: \(error.localizedDescription)")
        }
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        (try? context.fetch(descriptor)) ?? []
    }

    private func audit(_ action: String, _ type: String, _ id: String, _ details: JSONValue? = nil) {
        context.insert(AuditEvent(record: AuditRecord(action: action, entityType: type, entityID: id, details: details)))
    }

    // MARK: - Preferences

    private func settingsRow() -> AppSettings? { fetch(FetchDescriptor<AppSettings>()).first }

    func updatePreferences(_ change: (inout AppPreferences) -> Void) throws {
        var updated = preferences
        change(&updated)
        if let row = settingsRow() {
            row.payload = try BolusJSON.encoder.encode(updated)
            row.updatedAt = Date()
        } else {
            context.insert(AppSettings(preferences: updated))
        }
        try commit()
        preferences = updated
    }

    // MARK: - Diary entries

    private func entryModels(from: Date? = nil, to: Date? = nil) -> [DiaryEntry] {
        var descriptor: FetchDescriptor<DiaryEntry>
        if let from, let to {
            descriptor = FetchDescriptor<DiaryEntry>(predicate: #Predicate<DiaryEntry> { $0.occurredAt >= from && $0.occurredAt < to },
                                                    sortBy: [SortDescriptor(\DiaryEntry.occurredAt)])
        } else if let from {
            descriptor = FetchDescriptor<DiaryEntry>(predicate: #Predicate<DiaryEntry> { $0.occurredAt >= from },
                                                    sortBy: [SortDescriptor(\DiaryEntry.occurredAt)])
        } else {
            descriptor = FetchDescriptor<DiaryEntry>(sortBy: [SortDescriptor(\DiaryEntry.occurredAt)])
        }
        return fetch(descriptor)
    }

    private func entryModel(id: UUID) -> DiaryEntry? {
        var descriptor = FetchDescriptor<DiaryEntry>(predicate: #Predicate<DiaryEntry> { $0.id == id })
        descriptor.fetchLimit = 1
        return fetch(descriptor).first
    }

    /// Entries in `[from, to)`, chronological.
    func entries(from: Date? = nil, to: Date? = nil) -> [DiaryRecord] {
        entryModels(from: from, to: to).compactMap(\.record)
    }

    func entries(on day: LocalDate) -> [DiaryRecord] {
        entries(from: day.startOfDay(in: timeZone), to: day.adding(days: 1).startOfDay(in: timeZone))
    }

    func entry(id: UUID) -> DiaryRecord? { entryModel(id: id)?.record }

    func allEntries() -> [DiaryRecord] { entries() }

    func latestGlucose() -> DiaryRecord? {
        let kind = EntryKind.glucose.rawValue
        var descriptor = FetchDescriptor<DiaryEntry>(predicate: #Predicate<DiaryEntry> { $0.kind == kind },
                                                    sortBy: [SortDescriptor(\DiaryEntry.occurredAt, order: .reverse),
                                                             SortDescriptor(\DiaryEntry.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return fetch(descriptor).first?.record
    }

    /// Recent meals for the bolus calculator (last `hours`).
    func recentMeals(hours: Double = 6, now: Date = Date()) -> [DiaryRecord] {
        entries(from: now.addingTimeInterval(-hours * 3600), to: now.addingTimeInterval(EntryFactory.futureTolerance))
            .filter { $0.kind == .meal }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    private func insulinWindow(at now: Date) -> [DiaryRecord] {
        entries(from: now.addingTimeInterval(-IOBEngine.lookbackSeconds), to: now.addingTimeInterval(0.001)).filter { $0.kind == .insulin }
    }

    /// Current IOB from actually administered rapid insulin; `nil` if stored data is invalid.
    func currentIOB(at now: Date = Date()) -> Double? {
        try? BolusWorkflow.currentIOB(entries: insulinWindow(at: now), at: now)
    }

    func insert(_ records: [DiaryRecord], cycle: CycleRecord? = nil, action: String = "entry_create") throws {
        for record in records {
            context.insert(DiaryEntry(record: record))
            audit(action, record.kind.rawValue, record.id.uuidString.lowercased())
        }
        if let cycle {
            context.insert(Cycle(record: cycle))
            audit("cycle_create", "cycle", cycle.id.uuidString.lowercased())
        }
        try commit()
    }

    /// Unified "Добавить запись" form: all filled sections are saved in one transaction.
    @discardableResult
    func saveBatch(_ draft: EntryFactory.BatchDraft) throws -> EntryFactory.BatchResult {
        let result = try factory().batch(draft, profiles: profiles())
        try insert(result.entries, cycle: result.cycle)
        for item in draft.mealItems { markFoodUsed(item.foodID, source: item.foodSource) }
        try? context.save()
        return result
    }

    func deleteEntry(id: UUID) throws {
        guard let model = entryModel(id: id), let record = model.record else { throw BolusError.notFound("Запись не найдена") }
        audit("entry_delete", record.kind.rawValue, id.uuidString.lowercased(), record.data)
        if let calculation = record.insulin?.relatedBolusCalculationID {
            // The historical calculation and its actual-dose confirmation stay immutable; deletion is audited.
            audit("confirmed_insulin_entry_delete", "calculation", calculation, .object(["entry_id": .string(id.uuidString.lowercased())]))
        }
        context.delete(model)
        try commit()
    }

    // MARK: - Therapy profile

    private func profileModels() -> [TherapyProfile] {
        fetch(FetchDescriptor<TherapyProfile>(sortBy: [SortDescriptor(\TherapyProfile.version, order: .reverse)]))
    }

    func profiles() -> [TherapyProfileRecord] { profileModels().map(\.record) }

    func activeProfile() -> TherapyProfileRecord? { ProfileWorkflow.active(profiles()) }

    /// Saves a new confirmed version; the previous version is archived, never edited.
    @discardableResult
    func saveProfile(_ settings: TherapySettings) throws -> TherapyProfileRecord {
        let now = Date()
        let models = profileModels()
        let (profile, archived) = try ProfileWorkflow.newVersion(settings, existing: models.map(\.record), now: now)
        if let archived, let model = models.first(where: { $0.id == archived.id }) {
            model.archive(at: now)
        }
        context.insert(TherapyProfile(record: profile))
        audit("therapy_profile_change", "profile", profile.id.uuidString.lowercased(),
              .object(["version": .number(Double(profile.version))]))
        try commit()
        return profile
    }

    // MARK: - Bolus

    private func calculationModel(id: UUID) -> BolusCalculation? {
        var descriptor = FetchDescriptor<BolusCalculation>(predicate: #Predicate<BolusCalculation> { $0.id == id })
        descriptor.fetchLimit = 1
        return fetch(descriptor).first
    }

    func calculations(limit: Int? = 100) -> [BolusCalculationRecord] {
        var descriptor = FetchDescriptor<BolusCalculation>(sortBy: [SortDescriptor(\BolusCalculation.calculatedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return fetch(descriptor).map(\.record)
    }

    func calculation(id: UUID) -> BolusCalculationRecord? { calculationModel(id: id)?.record }

    /// Deterministic local calculation; the snapshot is stored even when blocked.
    func calculateBolus(_ request: BolusWorkflow.Request) throws -> BolusCalculationRecord {
        let now = Date()
        let record = try BolusWorkflow.calculate(request, profile: activeProfile(), insulinEntries: insulinWindow(at: now),
                                                 now: now, timeZone: timeZone)
        context.insert(BolusCalculation(record: record))
        audit("bolus_calculation", "calculation", record.id.uuidString.lowercased(),
              .object(["algorithm_version": .string(record.algorithmVersion),
                       "status": record.calculationSnapshot["calculation_status"] ?? .null]))
        try commit()
        return record
    }

    /// Saves the actually administered dose as a diary entry (idempotent).
    @discardableResult
    func confirmBolus(calculationID: UUID, units: Double, administeredAt: Date) throws -> DiaryRecord? {
        guard let model = calculationModel(id: calculationID) else { throw BolusError.notFound("Расчёт не найден") }
        switch try BolusWorkflow.confirm(model.record, actualUnits: units, administeredAt: administeredAt, now: Date(), profiles: profiles()) {
        case .alreadyConfirmed(let entryID, _):
            return entryID.flatMap(entry(id:))
        case .confirmed(let entry, let calculation):
            let key: String? = entry.dedupeKey
            let existing = fetch(FetchDescriptor<DiaryEntry>(predicate: #Predicate<DiaryEntry> { $0.dedupeKey == key }))
            if let first = existing.first { return first.record }
            context.insert(DiaryEntry(record: entry))
            model.actualBolus = calculation.actualBolus
            model.confirmedEntryID = calculation.confirmedEntryID
            audit("bolus_confirmation", "calculation", calculationID.uuidString.lowercased(), entry.data)
            try commit()
            return entry
        }
    }

    // MARK: - Food

    private func foodModels() -> [Food] {
        fetch(FetchDescriptor<Food>(sortBy: [SortDescriptor(\Food.name)]))
    }

    private func foodModel(id: UUID) -> Food? {
        var descriptor = FetchDescriptor<Food>(predicate: #Predicate<Food> { $0.id == id })
        descriptor.fetchLimit = 1
        return fetch(descriptor).first
    }

    func foods() -> [FoodRecord] { foodModels().map(\.record) }

    func recentFoods() -> [FoodRecord] {
        let now = Date()
        let meals = entries(from: now.addingTimeInterval(-90 * 86400), to: now.addingTimeInterval(EntryFactory.futureTolerance))
        return FoodNutrition.recentFoods(from: meals)
    }

    /// Saves a new local food or a catalog product (deduplicated by catalog key).
    @discardableResult
    func saveFood(_ food: FoodRecord) throws -> FoodRecord {
        if food.source != "custom" && food.source != "recipe",
           let existing = foodModels().first(where: { $0.record.catalogKey == food.catalogKey }) {
            return existing.record
        }
        context.insert(Food(record: food))
        audit(food.isRecipe ? "recipe_create" : "food_create", "food", food.id.uuidString.lowercased())
        try commit()
        return food
    }

    func deleteFood(id: UUID) throws {
        guard let model = foodModel(id: id) else { return }
        context.delete(model)
        audit("food_delete", "food", id.uuidString.lowercased())
        try commit()
    }

    /// Favorites for local foods are a flag; catalog/recent items are saved locally first.
    func toggleFavorite(_ food: FoodRecord) throws {
        if let model = foodModel(id: food.id) ?? foodModels().first(where: { $0.record.catalogKey == food.catalogKey }) {
            model.isFavorite.toggle()
            model.updatedAt = Date()
        } else {
            var copy = food
            copy.id = UUID()
            copy.isFavorite = true
            copy.createdAt = Date()
            copy.updatedAt = copy.createdAt
            context.insert(Food(record: copy))
        }
        try commit()
    }

    func isFavorite(_ food: FoodRecord) -> Bool {
        foodModels().contains { ($0.id == food.id || $0.record.catalogKey == food.catalogKey) && $0.isFavorite }
    }

    private func markFoodUsed(_ foodID: String, source: String) {
        guard !foodID.isEmpty else { return }
        for model in foodModels() where model.id.uuidString.lowercased() == foodID || (model.externalID == foodID && model.source == source) {
            model.lastUsedAt = Date()
        }
    }

    // MARK: - Cycle

    private func cycleModels() -> [Cycle] {
        fetch(FetchDescriptor<Cycle>(sortBy: [SortDescriptor(\Cycle.startDate, order: .reverse)]))
    }

    func cycles() -> [CycleRecord] { cycleModels().compactMap(\.record) }

    func latestCycle() -> CycleRecord? { cycles().max { $0.startDate < $1.startDate } }

    func saveCycle(start: LocalDate, length: Int) throws {
        let record = try factory().cycle(start: start, length: length)
        try insert([], cycle: record)
    }

    func updateCycle(_ record: CycleRecord) throws {
        _ = try factory().cycle(start: record.startDate, length: record.cycleLength, end: record.endDate, ovulation: record.actualOvulationDate)
        guard let model = cycleModels().first(where: { $0.id == record.id }) else { throw BolusError.notFound("Цикл не найден") }
        model.update(from: record)
        audit("cycle_update", "cycle", record.id.uuidString.lowercased())
        try commit()
    }

    func deleteCycle(id: UUID) throws {
        guard let model = cycleModels().first(where: { $0.id == id }) else { return }
        context.delete(model)
        audit("cycle_delete", "cycle", id.uuidString.lowercased())
        try commit()
    }

    // MARK: - AI history

    func insights(limit: Int = 30) -> [AIInsightRecord] {
        var descriptor = FetchDescriptor<AIInsight>(sortBy: [SortDescriptor(\AIInsight.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return fetch(descriptor).map(\.record)
    }

    func allInsights() -> [AIInsightRecord] { fetch(FetchDescriptor<AIInsight>()).map(\.record) }

    func saveInsight(_ record: AIInsightRecord) throws {
        context.insert(AIInsight(record: record))
        audit("ai_insight", "ai_insight", record.id.uuidString.lowercased(), .object(["model": .string(record.model),
                                                                                      "total_tokens": .number(Double(record.totalTokens))]))
        try commit()
    }

    func totalTokens() -> Int { allInsights().reduce(0) { $0 + $1.totalTokens } }

    /// Aggregated AI context (never names, notes or the full database).
    func aiContext(days: Int, calculationID: UUID?) -> JSONValue {
        let from = today.adding(days: -(days - 1))
        return AIContextBuilder.build(entries: entries(from: from.startOfDay(in: timeZone), to: today.adding(days: 1).startOfDay(in: timeZone)),
                                      days: days, today: today, timeZone: timeZone, profile: activeProfile(), latestCycle: latestCycle(),
                                      calculations: calculations(limit: 200), calculation: calculationID.flatMap(calculation(id:)))
    }

    // MARK: - Apple Health (HealthKit → SwiftData)

    /// Upserts workouts by HealthKit UUID and daily summaries by date: repeated syncs never duplicate.
    func applyHealth(_ payload: HealthPayload) throws -> HealthImportPlanner.Plan {
        let keyed = fetch(FetchDescriptor<DiaryEntry>(predicate: #Predicate<DiaryEntry> { $0.dedupeKey != nil }))
        var existing: [String: DiaryRecord] = [:]
        var models: [String: DiaryEntry] = [:]
        for model in keyed {
            guard let key = model.dedupeKey, let record = model.record else { continue }
            existing[key] = record
            models[key] = model
        }
        let plan = try HealthImportPlanner.plan(payload, existing: existing, now: Date())
        for record in plan.inserts { context.insert(DiaryEntry(record: record)) }
        for record in plan.updates {
            if let key = record.dedupeKey, let model = models[key] { model.update(from: record) }
        }
        audit("healthkit_sync", "import", "healthkit", .object(["inserted": .number(Double(plan.inserted)),
                                                                 "updated": .number(Double(plan.updated)),
                                                                 "unchanged": .number(Double(plan.unchanged))]))
        try commit()
        return plan
    }

    // MARK: - Reports and backup

    func auditEvents() -> [AuditRecord] { fetch(FetchDescriptor<AuditEvent>(sortBy: [SortDescriptor(\AuditEvent.timestamp)])).map(\.record) }

    func reportInput(_ options: ReportOptions) -> ReportInput {
        ReportInput(options: options, entries: allEntries(), profiles: profiles(), calculations: calculations(limit: nil), cycles: cycles(),
                    foods: foods(), preferences: preferences, timeZone: timeZone, generatedAt: Date())
    }

    func backupDocument() -> BackupDocument {
        BackupDocument(exportedAt: Date(), appVersion: AppInfo.version, preferences: preferences, therapyProfiles: profiles(),
                       entries: allEntries(), bolusCalculations: calculations(limit: nil), foods: foods(), cycles: cycles(),
                       aiInsights: allInsights(), auditEvents: auditEvents())
    }

    /// "Экспортировать все данные": complete JSON backup with `schemaVersion`.
    func exportBackup() throws -> Data {
        let data = try backupDocument().encoded()
        audit("backup_export", "backup", "all")
        try? context.save()
        return data
    }

    func existingData() -> ExistingData {
        ExistingData(profiles: profiles(), entries: allEntries(), calculations: calculations(limit: nil), foods: foods(), cycles: cycles(),
                     insights: allInsights(), audit: auditEvents())
    }

    /// Reads and migrates a backup and prepares a non-destructive merge plan.
    func planImport(_ data: Data) throws -> BackupImportPlan {
        BackupImportPlanner.plan(try BackupMigrator.decode(data), existing: existingData())
    }

    /// Adds only new records; existing local data is never overwritten.
    func applyImport(_ plan: BackupImportPlan) throws {
        let document = plan.document
        for record in plan.newProfiles { context.insert(TherapyProfile(record: record)) }
        for record in plan.newEntries { context.insert(DiaryEntry(record: record)) }
        for record in plan.newCalculations { context.insert(BolusCalculation(record: record)) }
        for record in plan.newFoods { context.insert(Food(record: record)) }
        for record in plan.newCycles { context.insert(Cycle(record: record)) }
        for record in plan.newInsights { context.insert(AIInsight(record: record)) }
        for record in plan.newAudit { context.insert(AuditEvent(record: record)) }
        var restored = preferences
        if plan.applyPreferences, let imported = document.preferences {
            restored = imported
            // Device-specific security settings are not taken from a file.
            restored.appLockEnabled = preferences.appLockEnabled
            restored.onboardingCompleted = true
            if let row = settingsRow() {
                row.payload = try BolusJSON.encoder.encode(restored)
                row.updatedAt = Date()
            } else {
                context.insert(AppSettings(preferences: restored))
            }
        }
        audit("backup_restore", "backup", "import", .object([
            "schema_version": .number(Double(document.schemaVersion)), "added": .number(Double(plan.newCount)),
            "identical": .number(Double(plan.identical)), "conflicts": .number(Double(plan.conflicts.count)),
        ]))
        try commit()
        preferences = restored
    }

    /// Removes every local record (the Keychain key is removed separately).
    func deleteAllData() throws {
        for model in fetch(FetchDescriptor<DiaryEntry>()) { context.delete(model) }
        for model in fetch(FetchDescriptor<TherapyProfile>()) { context.delete(model) }
        for model in fetch(FetchDescriptor<BolusCalculation>()) { context.delete(model) }
        for model in fetch(FetchDescriptor<Food>()) { context.delete(model) }
        for model in fetch(FetchDescriptor<Cycle>()) { context.delete(model) }
        for model in fetch(FetchDescriptor<AIInsight>()) { context.delete(model) }
        for model in fetch(FetchDescriptor<AuditEvent>()) { context.delete(model) }
        for model in fetch(FetchDescriptor<AppSettings>()) { context.delete(model) }
        try commit()
        preferences = AppPreferences()
    }
}

enum AppInfo {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}
