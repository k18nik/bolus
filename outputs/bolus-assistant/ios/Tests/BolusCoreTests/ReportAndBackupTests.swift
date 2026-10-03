import XCTest
@testable import BolusCore

final class ReportTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let moscow = TimeZone(identifier: "Europe/Moscow")!

    func sampleInput(format: ReportFormat = .pdf, unit: GlucoseUnit = .mmol, nutrition: Bool = true, cycle: Bool = true) throws -> ReportInput {
        let now = referenceInstant
        let factory = EntryFactory(now: now, timeZone: moscow)
        let settings = TherapySettings(maxBolus: 15, insulinActionDuration: 4,
                                       segments: [TherapySegment(startTime: "00:00", endTime: "24:00", icr: 10, isf: 2, target: 6, correctAbove: 7)], confirmed: true)
        let profile = try ProfileWorkflow.newVersion(settings, existing: [], now: now.addingTimeInterval(-86400 * 3)).profile
        var entries = [
            try factory.glucose(value: 6.8, unit: .mmol, measuredAt: now.addingTimeInterval(-3600)),
            try factory.glucose(value: 11.2, unit: .mmol, measuredAt: now.addingTimeInterval(-86400)),
            try factory.meal(name: "Обед", mealType: .lunch, eatenAt: now.addingTimeInterval(-1800),
                             items: [MealItem(nameSnapshot: "Рис", grams: 150, amount: 150, unit: .g, carbs: 42.3, protein: 4, fat: 1, calories: 195)]),
            try factory.insulin(units: 4, type: .rapid, administeredAt: now.addingTimeInterval(-1800), profiles: [profile]),
            try factory.activity(name: "Ходьба", durationMinutes: 30, occurredAt: now.addingTimeInterval(-7200)),
        ]
        entries.append(try factory.note("=SUM(A1)", occurredAt: now))
        let calc = try BolusWorkflow.calculate(.init(glucose: 6.8, unit: .mmol, carbs: 42.3, measuredAt: now), profile: profile,
                                               insulinEntries: entries, now: now, timeZone: moscow)
        let cycleRecord = try factory.cycle(start: LocalDate(iso: "2026-09-20")!)
        var prefs = AppPreferences()
        prefs.glucoseUnit = unit
        let today = LocalDate.today(in: moscow, now: now)
        return ReportInput(options: ReportOptions(type: .doctor, format: format, from: today.adding(days: -6), to: today,
                                                  includeNutrition: nutrition, includeCycle: cycle),
                           entries: entries, profiles: [profile], calculations: [calc], cycles: [cycleRecord],
                           foods: [try FoodNutrition.customFood(name: "Сырник", carbs: 23)], preferences: prefs, timeZone: moscow, generatedAt: now)
    }

    func testTablesMatchServerExport() throws {
        let tables = ReportBuilder.tables(try sampleInput())
        let names = tables.map(\.name)
        XCTAssertTrue(Set(["Summary", "Glucose", "Insulin", "Meals", "Meal Items", "Activities", "Cycle", "Bolus Calculations", "Therapy Profiles", "Patterns"]).isSubset(of: Set(names)))
        let glucose = try XCTUnwrap(tables.first { $0.name == "Glucose" })
        XCTAssertEqual(Array(glucose.columns.prefix(3)), ["id", "timestamp", "value"])
        guard case .text(let stamp) = glucose.rows[0][1] else { return XCTFail("timestamp") }
        XCTAssertTrue(stamp.hasSuffix("+03:00"))
        let summary = try XCTUnwrap(tables.first)
        let mean = summary.rows[0][summary.columns.firstIndex(of: "mean_glucose")!]
        XCTAssertEqual(mean, .number(9))
        let withoutOptional = ReportBuilder.tables(try sampleInput(nutrition: false, cycle: false)).map(\.name)
        XCTAssertFalse(withoutOptional.contains("Cycle") || withoutOptional.contains("Meals") || withoutOptional.contains("Meal Items"))
        let mgdl = ReportBuilder.tables(try sampleInput(unit: .mgdl))
        let mgdlSummary = try XCTUnwrap(mgdl.first)
        XCTAssertEqual(mgdlSummary.rows[0][mgdlSummary.columns.firstIndex(of: "mean_glucose")!], .number(162))
    }

    func testCSVFormulaInjectionBOMAndQuoting() throws {
        XCTAssertEqual(ReportTables.safeCell("=cmd()"), "'=cmd()")
        XCTAssertEqual(ReportTables.safeCell("@SUM(1,2)"), "'@SUM(1,2)")
        XCTAssertEqual(ReportTables.safeCell("2"), "2")
        let table = ReportTable(name: "Notes", columns: ["id", "note"], rows: [[.number(1), .text("=A1, \"x\"")], [.number(2.5), .empty]])
        let csv = ReportTables.csv(table)
        XCTAssertEqual(Array(csv.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(String(decoding: csv.dropFirst(3), as: UTF8.self), "id,note\r\n1,\"'=A1, \"\"x\"\"\"\r\n2.5,\r\n")
    }

    func testZipAndXlsxStructure() throws {
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        var zip = ZipWriter()
        zip.add(path: "a.csv", data: Data("x".utf8), modified: referenceInstant)
        let archive = zip.finalize()
        XCTAssertEqual(Array(archive.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(Array(archive.suffix(22).prefix(4)), [0x50, 0x4B, 0x05, 0x06])
        let workbook = XLSXWriter.workbook(ReportBuilder.tables(try sampleInput()), modified: referenceInstant)
        XCTAssertEqual(Array(workbook.prefix(2)), [0x50, 0x4B])
        XCTAssertEqual(XLSXWriter.columnName(0), "A")
        XCTAssertEqual(XLSXWriter.columnName(25), "Z")
        XCTAssertEqual(XLSXWriter.columnName(26), "AA")
        XCTAssertEqual(XLSXWriter.escape("a<b&\u{0001}"), "a&lt;b&amp;")
        if let directory = ProcessInfo.processInfo.environment["BOLUS_REPORT_OUTPUT"] {
            let base = URL(fileURLWithPath: directory)
            try workbook.write(to: base.appendingPathComponent("sample.xlsx"))
            try ReportTables.csvArchive(ReportBuilder.tables(try sampleInput()), modified: referenceInstant).write(to: base.appendingPathComponent("sample.zip"))
        }
    }

    func testPDFContentIsDeterministicAndHonestAboutMissingData() throws {
        let document = ReportBuilder.pdfContent(try sampleInput())
        XCTAssertEqual(document.blocks.first, .title("BOLUS / DIABETES REPORT"))
        let charts = document.blocks.compactMap { if case .chart(let chart) = $0 { return chart.title } else { return nil } }
        XCTAssertEqual(charts.count, 8)
        let sections = document.blocks.compactMap { if case .section(let title) = $0 { return title } else { return nil } }
        XCTAssertTrue(sections.contains("Терапевтический профиль"))
        XCTAssertTrue(sections.contains("Цикл и глюкоза"))
        var empty = try sampleInput()
        empty.entries = []
        let emptyDocument = ReportBuilder.pdfContent(empty)
        guard case .table(_, let rows, _)? = emptyDocument.blocks.first(where: { if case .table = $0 { return true } else { return false } }) else {
            return XCTFail("metrics table")
        }
        XCTAssertTrue(rows.contains(["Всего инсулина в сутки, ЕД", "нет записей"]))
        XCTAssertTrue(rows.contains(["Средняя глюкоза, ммоль/л", "—"]))
    }

    func testPeriodPresets() throws {
        let today = LocalDate(iso: "2026-10-02")!
        for days in [7, 14, 30, 90] {
            let (from, to) = ReportOptions.period(days: days, endingAt: today)
            XCTAssertEqual(to.days(since: from) + 1, days)
        }
        XCTAssertThrowsError(try ReportOptions(from: today, to: today.adding(days: -1)).validate())
        XCTAssertThrowsError(try ReportOptions(from: today.adding(days: -400), to: today).validate())
    }
}

final class BackupTests: XCTestCase {
    func localDocument() throws -> BackupDocument {
        let now = referenceInstant
        let factory = EntryFactory(now: now, timeZone: TimeZone(identifier: "UTC")!)
        let settings = TherapySettings(maxBolus: 15, insulinActionDuration: 4,
                                       segments: [TherapySegment(startTime: "00:00", endTime: "24:00", icr: 10, isf: 2, target: 6, correctAbove: 7)], confirmed: true)
        let profile = try ProfileWorkflow.newVersion(settings, existing: [], now: now).profile
        let glucose = try factory.glucose(value: 6.8, unit: .mmol, measuredAt: now)
        let calc = try BolusWorkflow.calculate(.init(glucose: 6.8, unit: .mmol, carbs: 30, measuredAt: now), profile: profile, insulinEntries: [], now: now, timeZone: .current)
        return BackupDocument(exportedAt: now, appVersion: "2.0.0", preferences: AppPreferences(name: "Тест", themeID: "dino"), therapyProfiles: [profile],
                              entries: [glucose], bolusCalculations: [calc], foods: [try FoodNutrition.customFood(name: "Сырник", carbs: 23)],
                              cycles: [try factory.cycle(start: LocalDate(iso: "2026-09-20")!)],
                              aiInsights: [], auditEvents: [AuditRecord(action: "backup_export", entityType: "backup", entityID: "all")])
    }

    func testRoundTripKeepsSchemaVersion() throws {
        let document = try localDocument()
        let data = try document.encoded()
        let root = try BolusJSON.decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(root["schemaVersion"], .number(2))
        XCTAssertEqual(root["format"], .string("bolus-local-backup"))
        XCTAssertNotNil(root["entries"]?.arrayValue?.first?["data"]?["value_mmol"])
        let decoded = try BackupMigrator.decode(data)
        XCTAssertEqual(try decoded.encoded(), data)
        // Local records keep sub-microsecond dates; the re-imported copy must still be identical.
        let existing = ExistingData(profiles: document.therapyProfiles, entries: document.entries, calculations: document.bolusCalculations,
                                    foods: document.foods, cycles: document.cycles, insights: document.aiInsights, audit: document.auditEvents)
        let plan = BackupImportPlanner.plan(decoded, existing: existing)
        XCTAssertEqual(plan.newCount, 0)
        XCTAssertTrue(plan.conflicts.isEmpty, "\(plan.conflicts)")
        XCTAssertEqual(plan.identical, document.recordCount)
    }

    func testRejectsUnknownAndNewerFormats() {
        XCTAssertThrowsError(try BackupMigrator.decode(Data("[]".utf8)))
        XCTAssertThrowsError(try BackupMigrator.decode(Data(#"{"hello":1}"#.utf8)))
        XCTAssertThrowsError(try BackupMigrator.decode(Data(#"{"schemaVersion":99}"#.utf8)))
    }

    func testImportNeverOverwritesExistingData() throws {
        let document = try localDocument()
        let fresh = BackupImportPlanner.plan(document, existing: ExistingData())
        XCTAssertEqual(fresh.newCount, document.recordCount)
        XCTAssertTrue(fresh.applyPreferences)
        // Re-import of the same backup changes nothing.
        let existing = ExistingData(profiles: document.therapyProfiles, entries: document.entries, calculations: document.bolusCalculations,
                                    foods: document.foods, cycles: document.cycles, insights: document.aiInsights, audit: document.auditEvents)
        let again = BackupImportPlanner.plan(document, existing: existing)
        XCTAssertEqual(again.newCount, 0)
        XCTAssertEqual(again.identical, document.recordCount)
        XCTAssertFalse(again.applyPreferences)
        // A locally modified entry with the same id is a conflict: the local version is kept.
        var modified = existing
        modified.entries[0].data = .object(["value_mmol": .number(9.9)])
        let conflict = BackupImportPlanner.plan(document, existing: modified)
        XCTAssertEqual(conflict.conflicts.count, 1)
        XCTAssertTrue(conflict.newEntries.isEmpty)
        // A different active profile on the device stays active.
        var other = existing
        other.profiles = [TherapyProfileRecord(version: 1, validFrom: referenceInstant, settings: document.therapyProfiles[0].settings)]
        let profiles = BackupImportPlanner.plan(document, existing: other)
        XCTAssertEqual(profiles.profilesArchivedOnImport, 1)
        XCTAssertEqual(profiles.newProfiles.first?.status, "archived")
        XCTAssertEqual(profiles.newProfiles.first?.settings, document.therapyProfiles[0].settings, "parameters are never changed")
    }

    func testHealthKitDuplicatesByExternalIdentityAreSkipped() throws {
        var document = try localDocument()
        let key = HealthImportPlanner.workoutKey("8f4c3a5e-1b2d-4c6e-9f00-112233445566")
        let workout = DiaryRecord(kind: .activity, occurredAt: referenceInstant, data: .object(["name": .string("Бег"), "duration_minutes": .number(35)]), dedupeKey: key)
        document.entries.append(workout)
        var local = workout
        local.id = UUID()
        local.clientID = UUID()
        let plan = BackupImportPlanner.plan(document, existing: ExistingData(entries: [local]))
        XCTAssertFalse(plan.newEntries.contains { $0.dedupeKey == key })
        XCTAssertEqual(plan.conflicts, ["запись \(key)"])
    }

    /// A real JSON export of the former server (`scripts/generate_legacy_backup_fixture.py`).
    func testMigratesServerBackupV1() throws {
        let document = try BackupMigrator.decode(try Fixture.data("legacy_server_backup"))
        XCTAssertEqual(document.schemaVersion, 2)
        XCTAssertEqual(document.preferences?.name, "Мария")
        XCTAssertEqual(document.preferences?.timezoneIdentifier, "Europe/Moscow")
        XCTAssertEqual(document.entries.count, 9)
        XCTAssertEqual(Set(document.entries.map(\.kind)), Set(EntryKind.allCases))
        XCTAssertEqual(document.therapyProfiles.map(\.version).sorted(), [1, 2])
        XCTAssertEqual(document.therapyProfiles.filter(\.isActive).map(\.version), [2])
        XCTAssertEqual(document.therapyProfiles.first { $0.version == 1 }?.settings.bolusIncrement, 0.5)
        let confirmed = try XCTUnwrap(document.bolusCalculations.first { $0.actualBolus != nil })
        let insulin = try XCTUnwrap(document.entries.first { $0.id == confirmed.confirmedEntryID })
        XCTAssertEqual(insulin.dedupeKey, "bolus:" + confirmed.id.uuidString.lowercased())
        XCTAssertEqual(insulin.insulin?.units, confirmed.actualBolus)
        XCTAssertEqual(document.bolusCalculations.filter { $0.result?.calculationStatus == .blocked }.count, 1)
        XCTAssertNotNil(document.entries.first { $0.dedupeKey == "healthkit-workout:8f4c3a5e-1b2d-4c6e-9f00-112233445566" })
        XCTAssertNotNil(document.entries.first { $0.dedupeKey?.hasPrefix("healthkit-day:") == true })
        XCTAssertEqual(document.cycles.first?.cycleLength, 29)
        XCTAssertEqual(document.aiInsights.first?.totalTokens, 153)
        let recipe = try XCTUnwrap(document.foods.first(where: \.isRecipe))
        XCTAssertEqual(recipe.recipe?.servings, 2)
        XCTAssertEqual(recipe.recipe?.ingredients.count, 2)
        let favorites = document.foods.filter(\.isFavorite)
        XCTAssertEqual(favorites.count, 2, "custom favorite merged into its food, catalog favorite added")
        XCTAssertEqual(document.foods.filter { $0.name == "Сырник домашний" }.count, 1)
        XCTAssertNil(document.foods.first { $0.source == "yazio" }?.fiber)
        XCTAssertFalse(document.auditEvents.isEmpty)
        let meal = try XCTUnwrap(document.entries.first { $0.kind == .meal }?.meal)
        XCTAssertNil(meal.items.first { $0.unit == .ml }?.grams)
        // Historical calculation keeps its snapshot; IOB from the imported confirmed dose works.
        XCTAssertEqual(confirmed.algorithmVersion, "bolus-v1.1.0")
        XCTAssertNoThrow(try BolusWorkflow.currentIOB(entries: document.entries, at: insulin.occurredAt))
        let plan = BackupImportPlanner.plan(document, existing: ExistingData())
        XCTAssertEqual(plan.newEntries.count, 9)
        XCTAssertTrue(plan.conflicts.isEmpty)
    }
}
